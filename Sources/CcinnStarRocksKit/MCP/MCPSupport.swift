import Foundation
import MySQLWire
import StarRocksKit

/// A tool failure explained to the model (becomes an `isError` result).
public struct MCPToolError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Chooses which saved profile a tool call uses and with which access level.
public struct MCPProfileResolver: Sendable {
    public struct Resolved: Sendable {
        public let profile: ConnectionProfile
        public let access: MCPAccess
    }

    public let profiles: [ConnectionProfile]
    public let defaultProfile: String?
    public let forceReadOnly: Bool

    public init(profiles: [ConnectionProfile], defaultProfile: String?, forceReadOnly: Bool) {
        self.profiles = profiles
        self.defaultProfile = defaultProfile?.trimmingCharacters(in: .whitespaces).isEmpty == false ? defaultProfile : nil
        self.forceReadOnly = forceReadOnly
    }

    /// Profiles the user enabled for MCP, sorted by name.
    public var enabledProfiles: [ConnectionProfile] {
        profiles.filter { $0.mcpAccess != .disabled }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public var anyWritable: Bool {
        !forceReadOnly && enabledProfiles.contains { $0.mcpAccess == .readWrite }
    }

    public func access(of profile: ConnectionProfile) -> MCPAccess {
        forceReadOnly && profile.mcpAccess == .readWrite ? .readOnly : profile.mcpAccess
    }

    public func resolve(_ requested: String?) throws -> Resolved {
        let enabled = enabledProfiles
        let names = enabled.map(\.displayName).joined(separator: ", ")
        let target = requested?.trimmingCharacters(in: .whitespaces).isEmpty == false ? requested : defaultProfile
        guard let target else {
            if enabled.count == 1, let only = enabled.first { return Resolved(profile: only, access: access(of: only)) }
            if enabled.isEmpty {
                throw MCPToolError("No connection allows AI access. In CcinnStarRocks, open the connection and set “AI access (MCP)” to Read-only or Read & write.")
            }
            throw MCPToolError("Several connections are available; pass `connection` with one of: \(names).")
        }
        let match = profiles.first { $0.id.uuidString.caseInsensitiveCompare(target) == .orderedSame }
            ?? profiles.first { $0.displayName.caseInsensitiveCompare(target) == .orderedSame }
        guard let match else {
            throw MCPToolError("Unknown connection “\(target)”. Available connections: \(names.isEmpty ? "none" : names).")
        }
        guard match.mcpAccess != .disabled else {
            throw MCPToolError("Connection “\(match.displayName)” does not allow AI access. Available connections: \(names.isEmpty ? "none" : names).")
        }
        return Resolved(profile: match, access: access(of: match))
    }
}

/// Name and type of a result column for encoding.
public struct ColumnInfoLite: Sendable {
    public let name: String
    public let kind: ColumnType.Kind

    public init(name: String, kind: ColumnType.Kind) {
        self.name = name
        self.kind = kind
    }
}

public enum MCPResultEncoder {
    public static let defaultMaxBytes = 256 * 1024

    /// Rows as JSON arrays (integers and floats as numbers, everything else as exact strings),
    /// cut to `maxBytes` of serialized output.
    public static func rows(columns: [ColumnInfoLite], rows: [[String?]], truncatedByServer: Bool,
                            maxBytes: Int = defaultMaxBytes) -> JSONValue {
        let columnList: JSONValue = .array(columns.map { ["name": .string($0.name), "type": .string(typeName($0.kind))] })
        var budget = max(1_024, maxBytes) - columnList.serialized().utf8.count - 128
        var encoded: [JSONValue] = []
        encoded.reserveCapacity(min(rows.count, 1_000))
        var cut = false
        for row in rows {
            let value: JSONValue = .array(columns.indices.map { index in
                cell(index < row.count ? row[index] : nil, kind: columns[index].kind)
            })
            let size = value.serialized().utf8.count + 1
            if size > budget {
                cut = true
                break
            }
            budget -= size
            encoded.append(value)
        }
        return [
            "columns": columnList,
            "rows": .array(encoded),
            "row_count": .int(Int64(encoded.count)),
            "truncated": .bool(truncatedByServer || cut),
        ]
    }

    static func cell(_ value: String?, kind: ColumnType.Kind) -> JSONValue {
        guard let value else { return .null }
        switch kind {
        case .integer:
            if let number = Int64(value) { return .int(number) }
        case .float:
            if let number = TextValue.double(value) { return .double(number) }
        default:
            break
        }
        return .string(value)
    }

    static func typeName(_ kind: ColumnType.Kind) -> String {
        switch kind {
        case .integer: "integer"
        case .float: "float"
        case .decimal: "decimal"
        case .date: "date"
        case .dateTime: "datetime"
        case .time: "time"
        case .text: "string"
        case .json: "json"
        case .binary: "binary"
        case .null: "null"
        }
    }
}

/// Append-only JSON-lines audit of MCP tool calls (rotated at 5 MB). Never contains secrets.
public actor MCPAuditLog {
    public nonisolated let fileURL: URL
    private let maxBytes: UInt64

    public init(directory: URL, maxBytes: UInt64 = 5 * 1024 * 1024) {
        fileURL = directory.appendingPathComponent("mcp-audit.jsonl")
        self.maxBytes = maxBytes
    }

    public func record(tool: String, connection: String?, statement: String?, durationMilliseconds: Double, rows: Int?, error: String?) {
        var entry: [String: JSONValue] = [
            "time": .string(ISO8601DateFormatter().string(from: Date())),
            "tool": .string(tool),
            "duration_ms": .double((durationMilliseconds * 10).rounded() / 10),
        ]
        if let connection { entry["connection"] = .string(connection) }
        if let statement { entry["statement"] = .string(String(SQLRedactor.redact(statement).prefix(20_000))) }
        if let rows { entry["rows"] = .int(Int64(rows)) }
        if let error { entry["error"] = .string(String(error.prefix(2_000))) }
        let line = JSONValue.object(entry).serialized() + "\n"
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value, size > maxBytes {
            let rotated = fileURL.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: fileURL, to: rotated)
        }
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
