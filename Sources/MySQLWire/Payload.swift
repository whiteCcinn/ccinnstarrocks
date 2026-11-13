/// Errors raised while decoding MySQL protocol data. Never thrown for valid server traffic.
public enum MySQLWireError: Error, Sendable, Equatable, CustomStringConvertible {
    case truncated(String)
    case malformed(String)
    case packetTooLarge(Int)

    public var description: String {
        switch self {
        case let .truncated(context): "MySQL packet truncated while reading \(context)"
        case let .malformed(reason): "Malformed MySQL packet: \(reason)"
        case let .packetTooLarge(size): "MySQL packet of \(size) bytes exceeds the allowed size"
        }
    }
}

/// Bounds-checked little-endian reader over one packet payload.
public struct PayloadReader: Sendable {
    private let bytes: [UInt8]
    public private(set) var position = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - position }
    public var isAtEnd: Bool { position >= bytes.count }
    public var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func require(_ count: Int, _ context: String) throws {
        guard count >= 0, count <= remaining else { throw MySQLWireError.truncated(context) }
    }

    public mutating func readUInt8() throws -> UInt8 {
        try require(1, "uint8")
        defer { position += 1 }
        return bytes[position]
    }

    public mutating func readUInt16() throws -> UInt16 {
        try require(2, "uint16")
        defer { position += 2 }
        return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
    }

    public mutating func readUInt24() throws -> UInt32 {
        try require(3, "uint24")
        defer { position += 3 }
        return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8 | UInt32(bytes[position + 2]) << 16
    }

    public mutating func readUInt32() throws -> UInt32 {
        try require(4, "uint32")
        defer { position += 4 }
        var value: UInt32 = 0
        for offset in (0..<4).reversed() { value = value << 8 | UInt32(bytes[position + offset]) }
        return value
    }

    public mutating func readUInt64() throws -> UInt64 {
        try require(8, "uint64")
        defer { position += 8 }
        var value: UInt64 = 0
        for offset in (0..<8).reversed() { value = value << 8 | UInt64(bytes[position + offset]) }
        return value
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try require(count, "\(count) bytes")
        defer { position += count }
        return Array(bytes[position..<(position + count)])
    }

    public mutating func readRest() -> [UInt8] {
        defer { position = bytes.count }
        return Array(bytes[min(position, bytes.count)...])
    }

    public mutating func skip(_ count: Int) throws {
        try require(count, "skip")
        position += count
    }

    /// Reads up to (and consumes) a NUL byte; tolerates a missing terminator at the end of the payload.
    public mutating func readNullTerminatedBytes() -> [UInt8] {
        let start = position
        while position < bytes.count, bytes[position] != 0 { position += 1 }
        let result = Array(bytes[start..<position])
        if position < bytes.count { position += 1 }
        return result
    }

    public mutating func readNullTerminatedString() throws -> String {
        String(decoding: readNullTerminatedBytes(), as: UTF8.self)
    }

    /// Length-encoded integer. Returns `nil` for the NULL marker (0xFB).
    public mutating func readLengthEncodedIntegerOrNull() throws -> UInt64? {
        let first = try readUInt8()
        switch first {
        case 0..<0xFB: return UInt64(first)
        case 0xFB: return nil
        case 0xFC: return UInt64(try readUInt16())
        case 0xFD: return UInt64(try readUInt24())
        case 0xFE: return try readUInt64()
        default: throw MySQLWireError.malformed("invalid length-encoded integer prefix 0xFF")
        }
    }

    public mutating func readLengthEncodedInteger() throws -> UInt64 {
        guard let value = try readLengthEncodedIntegerOrNull() else {
            throw MySQLWireError.malformed("unexpected NULL marker")
        }
        return value
    }

    /// Length-encoded byte string; `nil` for SQL NULL.
    public mutating func readLengthEncodedBytes() throws -> [UInt8]? {
        guard let length = try readLengthEncodedIntegerOrNull() else { return nil }
        guard length <= UInt64(remaining) else { throw MySQLWireError.truncated("length-encoded string of \(length) bytes") }
        return try readBytes(Int(length))
    }

    public mutating func readLengthEncodedString() throws -> String {
        String(decoding: try readLengthEncodedBytes() ?? [], as: UTF8.self)
    }
}

/// Little-endian payload builder.
public struct PayloadWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func writeUInt8(_ value: UInt8) { bytes.append(value) }

    public mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func writeUInt24(_ value: UInt32) {
        for shift in [0, 8, 16] { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    public mutating func writeUInt32(_ value: UInt32) {
        for shift in [0, 8, 16, 24] { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    public mutating func writeUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }

    public mutating func writeBytes<C: Collection>(_ data: C) where C.Element == UInt8 { bytes.append(contentsOf: data) }

    public mutating func writeNullTerminated(_ string: String) {
        bytes.append(contentsOf: string.utf8.filter { $0 != 0 })
        bytes.append(0)
    }

    public mutating func writeLengthEncoded(_ value: UInt64) {
        switch value {
        case 0..<251:
            bytes.append(UInt8(value))
        case 251..<65_536:
            bytes.append(0xFC)
            writeUInt16(UInt16(value))
        case 65_536..<16_777_216:
            bytes.append(0xFD)
            writeUInt24(UInt32(value))
        default:
            bytes.append(0xFE)
            writeUInt64(value)
        }
    }

    public mutating func writeLengthEncodedBytes(_ data: [UInt8]) {
        writeLengthEncoded(UInt64(data.count))
        bytes.append(contentsOf: data)
    }

    public mutating func writeLengthEncodedString(_ string: String) {
        writeLengthEncodedBytes(Array(string.utf8))
    }
}
