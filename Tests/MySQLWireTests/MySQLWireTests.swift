import Foundation
import Testing
@testable import MySQLWire

@Suite("MySQL packet framing")
struct FramingTests {
    @Test func framesAndReassemblesPackets() throws {
        let payload: [UInt8] = Array("hello".utf8)
        let framed = PacketCodec.frame(payload, sequence: 3)
        #expect(framed == [5, 0, 0, 3] + payload)
        var framer = PacketFramer()
        for byte in framed.dropLast() {
            framer.append([byte])
            #expect(try framer.nextPacket() == nil)
        }
        framer.append([framed.last!])
        let packet = try #require(try framer.nextPacket())
        #expect(packet.sequence == 3)
        #expect(packet.payload == payload)
    }

    @Test func largePayloadsAreSplitAndJoined() throws {
        let payload = [UInt8](repeating: 7, count: PacketCodec.maxChunk + 10)
        let framed = PacketCodec.frame(payload, sequence: 0)
        #expect(framed.count == payload.count + 8)
        var framer = PacketFramer()
        framer.append(framed)
        let packet = try #require(try framer.nextPacket())
        #expect(packet.payload.count == payload.count)
        #expect(packet.sequence == 1)
    }

    @Test func exactMultipleOfChunkEndsWithEmptyPacket() throws {
        let payload = [UInt8](repeating: 1, count: PacketCodec.maxChunk)
        let framed = PacketCodec.frame(payload, sequence: 0)
        #expect(framed.count == payload.count + 8)
        var framer = PacketFramer()
        framer.append(framed)
        #expect(try framer.nextPacket()?.payload.count == PacketCodec.maxChunk)
    }

    @Test func oversizedLogicalPacketsAreRejected() {
        var framer = PacketFramer(maxPayload: 1024)
        framer.append([0xFF, 0xFF, 0xFF, 0])
        #expect(throws: MySQLWireError.self) { try framer.nextPacket() }
    }
}

@Suite("MySQL payload encoding")
struct PayloadTests {
    static let lengthEncodedVectors: [(UInt64, [UInt8])] = [
        (0, [0]), (250, [250]), (251, [0xFC, 251, 0]), (65_535, [0xFC, 0xFF, 0xFF]),
        (65_536, [0xFD, 0, 0, 1]), (16_777_216, [0xFE, 0, 0, 0, 1, 0, 0, 0, 0]),
    ]

    @Test(arguments: lengthEncodedVectors)
    func lengthEncodedIntegers(value: UInt64, bytes: [UInt8]) throws {
        var writer = PayloadWriter()
        writer.writeLengthEncoded(value)
        #expect(writer.bytes == bytes)
        var reader = PayloadReader(bytes)
        #expect(try reader.readLengthEncodedInteger() == value)
        #expect(reader.isAtEnd)
    }

    @Test func nullMarkerInLengthEncodedString() throws {
        var reader = PayloadReader([0xFB, 3, 0x61, 0x62, 0x63])
        #expect(try reader.readLengthEncodedBytes() == nil)
        #expect(try reader.readLengthEncodedBytes() == Array("abc".utf8))
    }

    @Test func truncatedReadsThrow() {
        var reader = PayloadReader([0xFC, 1])
        #expect(throws: MySQLWireError.self) { try reader.readLengthEncodedInteger() }
        var stringReader = PayloadReader([5, 0x61])
        #expect(throws: MySQLWireError.self) { try stringReader.readLengthEncodedBytes() }
    }

    @Test func randomPayloadsNeverCrash() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<10_000 {
            let bytes = (0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = try? ServerPacket.parse(bytes, capabilities: .standard)
            _ = try? ColumnDefinition(payload: bytes)
            _ = try? TextRow.decode(bytes, columnCount: Int.random(in: 0...8, using: &rng))
            _ = try? HandshakeV10(payload: bytes)
        }
    }
}

@Suite("MySQL handshake and auth")
struct HandshakeTests {
    /// Handshake captured from a StarRocks 3.3 FE (scramble replaced with a fixed value).
    static func handshakePayload(plugin: String = "mysql_native_password") -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(10)
        writer.writeNullTerminated("8.0.33")
        writer.writeUInt32(42)
        writer.writeBytes(Array(1...8))
        writer.writeUInt8(0)
        let capabilities = Capabilities.standard.union([.pluginAuth, .secureConnection, .protocol41]).rawValue
        writer.writeUInt16(UInt16(truncatingIfNeeded: capabilities))
        writer.writeUInt8(33)
        writer.writeUInt16(2)
        writer.writeUInt16(UInt16(truncatingIfNeeded: capabilities >> 16))
        writer.writeUInt8(21)
        writer.writeBytes([UInt8](repeating: 0, count: 10))
        writer.writeBytes(Array(9...20) + [0])
        writer.writeNullTerminated(plugin)
        return writer.bytes
    }

    @Test func parsesHandshake() throws {
        let handshake = try HandshakeV10(payload: Self.handshakePayload())
        #expect(handshake.serverVersion == "8.0.33")
        #expect(handshake.connectionID == 42)
        #expect(handshake.scramble == Array(1...20))
        #expect(handshake.authPluginName == "mysql_native_password")
        #expect(handshake.capabilities.contains(.protocol41))
    }

    @Test func nativePasswordMatchesReference() {
        // Reference computed with Python hashlib: SHA1(pw) XOR SHA1(scramble + SHA1(SHA1(pw))).
        let token = AuthPlugin.nativePassword(password: "secret", scramble: Array(1...20))
        #expect(token.map { String(format: "%02x", $0) }.joined() == "b32bb3a583e1340c0a1108d58b1be49781ad8c2f")
        #expect(AuthPlugin.nativePassword(password: "", scramble: Array(1...20)).isEmpty)
    }

    @Test func clearPasswordIsNullTerminated() {
        #expect(AuthPlugin.clearPassword(password: "pw") == [0x70, 0x77, 0])
    }

    @Test func handshakeResponseLayout() throws {
        let response = HandshakeResponse41(capabilities: [.protocol41, .secureConnection, .pluginAuth, .connectWithDB, .pluginAuthLenencData],
                                           username: "root", authResponse: [1, 2, 3], database: "shop",
                                           authPluginName: "mysql_native_password")
        var reader = PayloadReader(response.encode())
        let capabilities = Capabilities(rawValue: try reader.readUInt32())
        #expect(capabilities.contains(.connectWithDB))
        _ = try reader.readUInt32() // max packet
        #expect(try reader.readUInt8() == 45) // utf8mb4
        _ = try reader.readBytes(23)
        #expect(try reader.readNullTerminatedString() == "root")
        #expect(try reader.readLengthEncodedBytes() == [1, 2, 3])
        #expect(try reader.readNullTerminatedString() == "shop")
        #expect(try reader.readNullTerminatedString() == "mysql_native_password")
    }

    @Test func authSwitchRequest() throws {
        var writer = PayloadWriter()
        writer.writeUInt8(0xFE)
        writer.writeNullTerminated("mysql_clear_password")
        writer.writeBytes([9, 9])
        guard case let .authSwitch(plugin, data) = try ServerPacket.parse(writer.bytes, capabilities: .standard) else {
            Issue.record("expected auth switch")
            return
        }
        #expect(plugin == "mysql_clear_password")
        #expect(data == [9, 9])
    }
}

@Suite("MySQL results")
struct ResultTests {
    @Test func parsesOKAndError() throws {
        let ok: [UInt8] = [0x00, 0x05, 0x00, 0x02, 0x00, 0x01, 0x00]
        guard case let .ok(packet) = try ServerPacket.parse(ok, capabilities: .standard) else {
            Issue.record("expected OK")
            return
        }
        #expect(packet.affectedRows == 5)
        #expect(packet.statusFlags == 2)
        #expect(packet.warnings == 1)

        var writer = PayloadWriter()
        writer.writeUInt8(0xFF)
        writer.writeUInt16(1064)
        writer.writeBytes(Array("#42000".utf8))
        writer.writeBytes(Array("Syntax error".utf8))
        guard case let .error(error) = try ServerPacket.parse(writer.bytes, capabilities: .standard) else {
            Issue.record("expected ERR")
            return
        }
        #expect(error.code == 1064)
        #expect(error.sqlState == "42000")
        #expect(error.message == "Syntax error")
    }

    static func columnPayload(name: String, type: ColumnType) -> [UInt8] {
        var writer = PayloadWriter()
        for part in ["def", "shop", "orders", "orders", name, name] { writer.writeLengthEncodedString(part) }
        writer.writeLengthEncoded(0x0C)
        writer.writeUInt16(33)
        writer.writeUInt32(255)
        writer.writeUInt8(type.rawValue)
        writer.writeUInt16(0)
        writer.writeUInt8(0)
        writer.writeUInt16(0)
        return writer.bytes
    }

    @Test func parsesColumnDefinition() throws {
        let column = try ColumnDefinition(payload: Self.columnPayload(name: "total", type: .newDecimal))
        #expect(column.name == "total")
        #expect(column.table == "orders")
        #expect(column.schema == "shop")
        #expect(column.type == .newDecimal)
        #expect(column.type.kind == .decimal)
    }

    @Test func decodesRowsWithNulls() throws {
        var writer = PayloadWriter()
        writer.writeLengthEncodedString("1")
        writer.writeUInt8(0xFB)
        writer.writeLengthEncodedString("Penang")
        let row = try TextRow.decode(writer.bytes, columnCount: 3)
        #expect(row == ["1", nil, "Penang"])
        #expect(throws: MySQLWireError.self) { try TextRow.decode(writer.bytes, columnCount: 4) }
    }

    @Test func recognisesEOFAndRowTerminators() {
        #expect(ServerPacket.isResultTerminator([0xFE, 0, 0, 2, 0]))
        #expect(!ServerPacket.isResultTerminator([0x01, 0x41]))
    }

    @Test func columnTypeKinds() {
        #expect(ColumnType.longLong.kind == .integer)
        #expect(ColumnType.double.kind == .float)
        #expect(ColumnType.date.kind == .date)
        #expect(ColumnType.datetime.kind == .dateTime)
        #expect(ColumnType.varString.kind == .text)
        #expect(ColumnType.json.kind == .json)
    }
}
