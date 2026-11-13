public struct OKPacket: Sendable, Equatable {
    public let affectedRows: UInt64
    public let lastInsertID: UInt64
    public let statusFlags: UInt16
    public let warnings: UInt16
    public let info: String

    /// More result sets follow (SERVER_MORE_RESULTS_EXISTS).
    public var hasMoreResults: Bool { statusFlags & 0x0008 != 0 }
}

public struct ErrorPacket: Error, Sendable, Equatable {
    public let code: UInt16
    public let sqlState: String
    public let message: String
}

public enum ServerPacket: Sendable, Equatable {
    case ok(OKPacket)
    case error(ErrorPacket)
    case eof(statusFlags: UInt16)
    case authSwitch(plugin: String, data: [UInt8])
    case authMoreData([UInt8])
    case other([UInt8])

    public static func parse(_ payload: [UInt8], capabilities: Capabilities) throws -> ServerPacket {
        guard let first = payload.first else { throw MySQLWireError.truncated("empty packet") }
        switch first {
        case 0x00 where payload.count >= 7:
            return .ok(try parseOK(payload, capabilities: capabilities))
        case 0xFF:
            return .error(try parseError(payload))
        case 0xFE where payload.count < 9:
            var reader = PayloadReader(payload)
            try reader.skip(1)
            var status: UInt16 = 0
            if capabilities.contains(.protocol41), reader.remaining >= 4 {
                _ = try reader.readUInt16()
                status = try reader.readUInt16()
            }
            return .eof(statusFlags: status)
        case 0xFE:
            var reader = PayloadReader(payload)
            try reader.skip(1)
            let plugin = try reader.readNullTerminatedString()
            var data = reader.readRest()
            if data.last == 0 { data.removeLast() }
            return .authSwitch(plugin: plugin, data: data)
        case 0x01:
            return .authMoreData(Array(payload.dropFirst()))
        default:
            return .other(payload)
        }
    }

    public static func parseOK(_ payload: [UInt8], capabilities: Capabilities) throws -> OKPacket {
        var reader = PayloadReader(payload)
        try reader.skip(1)
        let affected = try reader.readLengthEncodedInteger()
        let lastInsert = try reader.readLengthEncodedInteger()
        var status: UInt16 = 0
        var warnings: UInt16 = 0
        if capabilities.contains(.protocol41) {
            status = try reader.readUInt16()
            warnings = try reader.readUInt16()
        }
        let info = String(decoding: reader.readRest(), as: UTF8.self)
        return OKPacket(affectedRows: affected, lastInsertID: lastInsert, statusFlags: status, warnings: warnings, info: info)
    }

    public static func parseError(_ payload: [UInt8]) throws -> ErrorPacket {
        var reader = PayloadReader(payload)
        try reader.skip(1)
        let code = try reader.readUInt16()
        var state = "HY000"
        if reader.peek == UInt8(ascii: "#"), reader.remaining >= 6 {
            try reader.skip(1)
            state = String(decoding: try reader.readBytes(5), as: UTF8.self)
        }
        return ErrorPacket(code: code, sqlState: state, message: String(decoding: reader.readRest(), as: UTF8.self))
    }

    /// True for the packet that ends a row stream (EOF, or OK with 0xFE header under DEPRECATE_EOF).
    /// A data row can only start with 0xFE when its first value is ≥ 16 MB, i.e. the payload is huge.
    public static func isResultTerminator(_ payload: [UInt8]) -> Bool {
        payload.first == 0xFE && payload.count < 0xFF_FFFF
    }

    /// Status flags carried by a result terminator.
    public static func terminatorStatus(_ payload: [UInt8], capabilities: Capabilities) throws -> UInt16 {
        if capabilities.contains(.deprecateEOF), payload.count >= 7 {
            var reader = PayloadReader(payload)
            try reader.skip(1)
            _ = try reader.readLengthEncodedInteger()
            _ = try reader.readLengthEncodedInteger()
            return try reader.readUInt16()
        }
        guard case let .eof(status) = try parse(payload, capabilities: capabilities) else { return 0 }
        return status
    }
}

/// MySQL column types (text protocol).
public struct ColumnType: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let decimal = ColumnType(rawValue: 0)
    public static let tiny = ColumnType(rawValue: 1)
    public static let short = ColumnType(rawValue: 2)
    public static let long = ColumnType(rawValue: 3)
    public static let float = ColumnType(rawValue: 4)
    public static let double = ColumnType(rawValue: 5)
    public static let null = ColumnType(rawValue: 6)
    public static let timestamp = ColumnType(rawValue: 7)
    public static let longLong = ColumnType(rawValue: 8)
    public static let int24 = ColumnType(rawValue: 9)
    public static let date = ColumnType(rawValue: 10)
    public static let time = ColumnType(rawValue: 11)
    public static let datetime = ColumnType(rawValue: 12)
    public static let year = ColumnType(rawValue: 13)
    public static let newDate = ColumnType(rawValue: 14)
    public static let varchar = ColumnType(rawValue: 15)
    public static let bit = ColumnType(rawValue: 16)
    public static let json = ColumnType(rawValue: 245)
    public static let newDecimal = ColumnType(rawValue: 246)
    public static let enumeration = ColumnType(rawValue: 247)
    public static let set = ColumnType(rawValue: 248)
    public static let tinyBlob = ColumnType(rawValue: 249)
    public static let mediumBlob = ColumnType(rawValue: 250)
    public static let longBlob = ColumnType(rawValue: 251)
    public static let blob = ColumnType(rawValue: 252)
    public static let varString = ColumnType(rawValue: 253)
    public static let string = ColumnType(rawValue: 254)
    public static let geometry = ColumnType(rawValue: 255)

    public enum Kind: Sendable, Hashable {
        case integer, float, decimal, date, dateTime, time, text, json, binary, null
    }

    public var kind: Kind {
        switch rawValue {
        case 1, 2, 3, 8, 9, 13: .integer
        case 4, 5: .float
        case 0, 246: .decimal
        case 10, 14: .date
        case 7, 12: .dateTime
        case 11: .time
        case 245: .json
        case 6: .null
        case 16, 255: .binary
        default: .text
        }
    }

    public var isNumeric: Bool { kind == .integer || kind == .float || kind == .decimal }
    public var isTemporal: Bool { kind == .date || kind == .dateTime }
}

/// Column definition (Protocol::ColumnDefinition41).
public struct ColumnDefinition: Sendable, Equatable {
    public let schema: String
    public let table: String
    public let originalTable: String
    public let name: String
    public let originalName: String
    public let characterSet: UInt16
    public let length: UInt32
    public let type: ColumnType
    public let flags: UInt16
    public let decimals: UInt8

    public init(payload: [UInt8]) throws {
        var reader = PayloadReader(payload)
        _ = try reader.readLengthEncodedString() // catalog
        schema = try reader.readLengthEncodedString()
        table = try reader.readLengthEncodedString()
        originalTable = try reader.readLengthEncodedString()
        name = try reader.readLengthEncodedString()
        originalName = try reader.readLengthEncodedString()
        _ = try reader.readLengthEncodedInteger() // length of fixed fields (0x0c)
        characterSet = try reader.readUInt16()
        length = try reader.readUInt32()
        type = ColumnType(rawValue: try reader.readUInt8())
        flags = try reader.readUInt16()
        decimals = try reader.readUInt8()
    }

    public init(name: String, type: ColumnType, table: String = "", schema: String = "") {
        self.schema = schema
        self.table = table
        originalTable = table
        self.name = name
        originalName = name
        characterSet = 33
        length = 0
        self.type = type
        flags = 0
        decimals = 0
    }
}

public enum TextRow {
    /// Decodes one text-protocol row into UTF-8 strings (`nil` = SQL NULL).
    public static func decode(_ payload: [UInt8], columnCount: Int) throws -> [String?] {
        var reader = PayloadReader(payload)
        var values: [String?] = []
        values.reserveCapacity(columnCount)
        for _ in 0..<max(0, columnCount) {
            if let bytes = try reader.readLengthEncodedBytes() {
                values.append(String(decoding: bytes, as: UTF8.self))
            } else {
                values.append(nil)
            }
        }
        guard reader.isAtEnd else { throw MySQLWireError.malformed("row has more values than columns") }
        return values
    }
}

/// Client commands.
public enum Command {
    public static func query(_ sql: String) -> [UInt8] { [0x03] + Array(sql.utf8) }
    public static func initDB(_ database: String) -> [UInt8] { [0x02] + Array(database.utf8) }
    public static let ping: [UInt8] = [0x0E]
    public static let quit: [UInt8] = [0x01]
}
