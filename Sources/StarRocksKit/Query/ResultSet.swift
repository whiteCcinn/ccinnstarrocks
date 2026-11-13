import Foundation
import MySQLWire

/// Case-insensitive column-name → index map shared by every record of a result.
public struct ColumnLookup: Sendable, Equatable {
    private let indices: [String: Int]
    public let names: [String]

    public init(names: [String]) {
        self.names = names
        var indices: [String: Int] = [:]
        indices.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            let key = name.lowercased()
            if indices[key] == nil { indices[key] = index }
        }
        self.indices = indices
    }

    /// Index of the first of `names` that exists (alternatives cover renamed columns across versions).
    public func index(of names: [String]) -> Int? {
        for name in names {
            if let index = indices[name.lowercased()] { return index }
        }
        return nil
    }
}

/// One row with access by column name (design D2: never by position for metadata).
public struct Record: Sendable {
    public let values: [String?]
    let lookup: ColumnLookup

    public init(values: [String?], lookup: ColumnLookup) {
        self.values = values
        self.lookup = lookup
    }

    /// Raw value of the first existing column among `names`; `nil` when missing or SQL NULL.
    public func raw(_ names: String...) -> String? { raw(names) }

    public func raw(_ names: [String]) -> String? {
        guard let index = lookup.index(of: names), index < values.count else { return nil }
        return values[index]
    }

    public func has(_ name: String) -> Bool { lookup.index(of: [name]) != nil }

    /// Column names in result order.
    public var lookupNames: [String] { lookup.names }

    /// Trimmed text; `nil` for missing, SQL NULL, empty and textual null markers (`NULL`, `\N`).
    public func text(_ names: String...) -> String? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Self.isNullMarker(value) ? nil : value
    }

    public func int(_ names: String...) -> Int64? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return TextValue.integer(value)
    }

    public func double(_ names: String...) -> Double? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return TextValue.double(value)
    }

    public func bool(_ names: String...) -> Bool? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch value {
        case "true", "1", "yes", "y", "on": return true
        case "false", "0", "no", "n", "off": return false
        default: return nil
        }
    }

    static func isNullMarker(_ value: String) -> Bool {
        value.isEmpty || value == "NULL" || value == "null" || value == "\\N"
    }
}

/// One result of a statement: either a row set (`columns` non-empty) or an OK summary.
public struct ResultSet: Sendable {
    public let columns: [ColumnDefinition]
    public let rows: [[String?]]
    public let affectedRows: UInt64
    public let lastInsertID: UInt64
    public let warnings: UInt16
    public let info: String
    /// More rows existed than the configured limit; they were discarded.
    public let isTruncated: Bool
    public let lookup: ColumnLookup

    public init(columns: [ColumnDefinition], rows: [[String?]], isTruncated: Bool = false, warnings: UInt16 = 0) {
        self.columns = columns
        self.rows = rows
        self.isTruncated = isTruncated
        self.warnings = warnings
        affectedRows = 0
        lastInsertID = 0
        info = ""
        lookup = ColumnLookup(names: columns.map(\.name))
    }

    public init(ok: OKPacket) {
        columns = []
        rows = []
        isTruncated = false
        affectedRows = ok.affectedRows
        lastInsertID = ok.lastInsertID
        warnings = ok.warnings
        info = ok.info
        lookup = ColumnLookup(names: [])
    }

    public var hasRowSet: Bool { !columns.isEmpty }
    public var columnNames: [String] { columns.map(\.name) }

    public func record(at index: Int) -> Record? {
        guard rows.indices.contains(index) else { return nil }
        return Record(values: rows[index], lookup: lookup)
    }

    public var records: [Record] { rows.map { Record(values: $0, lookup: lookup) } }
    public var first: Record? { record(at: 0) }

    /// First column of the first row (scalar queries).
    public var scalar: String? { rows.first?.first ?? nil }
}

/// Bounds applied while reading rows (design D5).
public struct RowLimits: Sendable, Equatable {
    /// Rows kept per result set.
    public var maxRows: Int
    /// Bytes of row payload kept per result set.
    public var maxBytes: Int
    /// Rows beyond the limit that are still read and discarded to keep the connection reusable;
    /// after that the connection is dropped instead (cheaper than draining a huge result).
    public var drainRows: Int

    public init(maxRows: Int = 100_000, maxBytes: Int = 512 * 1024 * 1024, drainRows: Int = 20_000) {
        self.maxRows = max(0, maxRows)
        self.maxBytes = max(0, maxBytes)
        self.drainRows = max(0, drainRows)
    }

    public static let metadata = RowLimits(maxRows: 100_000, maxBytes: 256 * 1024 * 1024, drainRows: 0)
}
