import Foundation
import MySQLWire
import os
@testable import StarRocksKit

/// In-memory MySQL server speaking just enough protocol for connection tests.
final class FakeMySQLServer: ByteTransport, @unchecked Sendable {
    enum AuthFlow: Sendable {
        case accept
        case reject(code: UInt16, message: String)
        case switchTo(plugin: String)
    }

    enum Reply: Sendable {
        case packets([[UInt8]])
        /// Never answers (until the transport is closed or the query is interrupted).
        case hang
        /// Answers after a delay (or earlier with an "interrupted" error when killed).
        case delayed([[UInt8]], seconds: Double)
    }

    private struct State {
        var outbox: [UInt8] = []
        var receiver: CheckedContinuation<[UInt8], any Error>?
        var closed = false
        var framer = PacketFramer()
        var phase = 0 // 0 = awaiting HandshakeResponse, 1 = awaiting auth-switch reply, 2 = commands
        var handshakeResponse: [UInt8] = []
        var authSwitchReply: [UInt8] = []
        var queries: [String] = []
        var queryGeneration = 0
        var pendingQuery = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let auth: AuthFlow
    private let connectionID: UInt32
    private let handler: @Sendable (String) -> Reply

    init(connectionID: UInt32 = 7, auth: AuthFlow = .accept, handler: @escaping @Sendable (String) -> Reply = { _ in .packets([FakeMySQLServer.ok()]) }) {
        self.auth = auth
        self.connectionID = connectionID
        self.handler = handler
        enqueue([Self.greeting(connectionID: connectionID)], firstSequence: 0)
    }

    var queries: [String] { state.withLockUnchecked { $0.queries } }
    var handshakeResponse: [UInt8] { state.withLockUnchecked { $0.handshakeResponse } }
    var authSwitchReply: [UInt8] { state.withLockUnchecked { $0.authSwitchReply } }
    var isClosed: Bool { state.withLockUnchecked { $0.closed } }

    // MARK: ByteTransport

    func send(_ bytes: [UInt8]) async throws {
        var packets: [PacketFramer.Packet] = []
        try state.withLockUnchecked { state in
            guard !state.closed else { throw StarRocksError(.connectionClosed, "closed") }
            state.framer.append(bytes)
            while let packet = try state.framer.nextPacket() { packets.append(packet) }
        }
        for packet in packets { handle(packet) }
    }

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            state.withLockUnchecked { state in
                if !state.outbox.isEmpty {
                    let bytes = state.outbox
                    state.outbox.removeAll()
                    continuation.resume(returning: bytes)
                } else if state.closed {
                    continuation.resume(throwing: StarRocksError(.connectionClosed, "closed"))
                } else {
                    state.receiver = continuation
                }
            }
        }
    }

    func close() {
        let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
            state.closed = true
            defer { state.receiver = nil }
            return state.receiver
        }
        receiver?.resume(throwing: StarRocksError(.connectionClosed, "closed"))
    }

    /// Simulates `KILL QUERY` from another connection: the running statement fails with 1317.
    func interrupt() {
        let pending = state.withLockUnchecked { state -> Bool in
            defer { state.pendingQuery = false }
            return state.pendingQuery
        }
        if pending { enqueue([Self.error(code: 1317, state: "70100", message: "Query execution was interrupted")], firstSequence: 1) }
    }

    // MARK: Protocol

    private func handle(_ packet: PacketFramer.Packet) {
        let phase = state.withLockUnchecked { $0.phase }
        switch phase {
        case 0:
            state.withLockUnchecked {
                $0.handshakeResponse = packet.payload
                $0.phase = 2
            }
            switch auth {
            case .accept:
                enqueue([Self.ok()], firstSequence: packet.sequence &+ 1)
            case let .reject(code, message):
                enqueue([Self.error(code: code, state: "28000", message: message)], firstSequence: packet.sequence &+ 1)
            case let .switchTo(plugin):
                state.withLockUnchecked { $0.phase = 1 }
                var writer = PayloadWriter()
                writer.writeUInt8(0xFE)
                writer.writeNullTerminated(plugin)
                writer.writeBytes(Array(repeating: 5, count: 20) + [0])
                enqueue([writer.bytes], firstSequence: packet.sequence &+ 1)
            }
        case 1:
            state.withLockUnchecked {
                $0.authSwitchReply = packet.payload
                $0.phase = 2
            }
            enqueue([Self.ok()], firstSequence: packet.sequence &+ 1)
        default:
            guard let command = packet.payload.first else { return }
            switch command {
            case 0x03:
                let sql = String(decoding: packet.payload.dropFirst(), as: UTF8.self)
                state.withLockUnchecked { $0.queries.append(sql) }
                // Session setup issued by every connection.
                if sql.uppercased().hasPrefix("SET ") {
                    enqueue([Self.ok()], firstSequence: 1)
                    return
                }
                let generation = state.withLockUnchecked { state -> Int in
                    state.queryGeneration += 1
                    state.pendingQuery = true
                    return state.queryGeneration
                }
                switch handler(sql) {
                case let .packets(packets):
                    state.withLockUnchecked { $0.pendingQuery = false }
                    enqueue(packets, firstSequence: 1)
                case .hang:
                    break
                case let .delayed(packets, seconds):
                    Task {
                        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                        let stillPending = self.state.withLockUnchecked { state -> Bool in
                            guard state.pendingQuery, state.queryGeneration == generation else { return false }
                            state.pendingQuery = false
                            return true
                        }
                        if stillPending { self.enqueue(packets, firstSequence: 1) }
                    }
                }
            case 0x0E:
                enqueue([Self.ok()], firstSequence: 1)
            case 0x01:
                close()
            default:
                enqueue([Self.error(code: 1047, state: "08S01", message: "Unknown command")], firstSequence: 1)
            }
        }
    }

    private func enqueue(_ payloads: [[UInt8]], firstSequence: UInt8) {
        var bytes: [UInt8] = []
        var sequence = firstSequence
        for payload in payloads {
            bytes += PacketCodec.frame(payload, sequence: sequence)
            sequence &+= 1
        }
        let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
            if let receiver = state.receiver {
                state.receiver = nil
                return receiver
            }
            state.outbox += bytes
            return nil
        }
        receiver?.resume(returning: bytes)
    }

    // MARK: Packet builders

    static func greeting(connectionID: UInt32, plugin: String = "mysql_native_password") -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(10)
        writer.writeNullTerminated("8.0.33")
        writer.writeUInt32(connectionID)
        writer.writeBytes(Array(1...8))
        writer.writeUInt8(0)
        let capabilities = Capabilities.client.union(.deprecateEOF).rawValue
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

    static func ok(affectedRows: UInt64 = 0, status: UInt16 = 0x0002) -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(0)
        writer.writeLengthEncoded(affectedRows)
        writer.writeLengthEncoded(0)
        writer.writeUInt16(status)
        writer.writeUInt16(0)
        return writer.bytes
    }

    static func error(code: UInt16, state: String = "HY000", message: String) -> [UInt8] {
        var writer = PayloadWriter()
        writer.writeUInt8(0xFF)
        writer.writeUInt16(code)
        writer.writeBytes(Array(("#" + state).utf8))
        writer.writeBytes(Array(message.utf8))
        return writer.bytes
    }

    static func eof(status: UInt16 = 0x0002) -> [UInt8] {
        [0xFE, 0, 0, UInt8(truncatingIfNeeded: status), UInt8(truncatingIfNeeded: status >> 8)]
    }

    static func column(_ name: String, _ type: ColumnType) -> [UInt8] {
        var writer = PayloadWriter()
        for part in ["def", "shop", "t", "t", name, name] { writer.writeLengthEncodedString(part) }
        writer.writeLengthEncoded(0x0C)
        writer.writeUInt16(33)
        writer.writeUInt32(255)
        writer.writeUInt8(type.rawValue)
        writer.writeUInt16(0)
        writer.writeUInt8(0)
        writer.writeUInt16(0)
        return writer.bytes
    }

    static func row(_ values: [String?]) -> [UInt8] {
        var writer = PayloadWriter()
        for value in values {
            if let value { writer.writeLengthEncodedString(value) } else { writer.writeUInt8(0xFB) }
        }
        return writer.bytes
    }

    /// Classic (non-DEPRECATE_EOF) text result set.
    static func resultSet(_ columns: [(String, ColumnType)], _ rows: [[String?]], moreResults: Bool = false) -> [[UInt8]] {
        var writer = PayloadWriter()
        writer.writeLengthEncoded(UInt64(columns.count))
        var packets = [writer.bytes]
        packets += columns.map { column($0.0, $0.1) }
        packets.append(eof())
        packets += rows.map(row)
        packets.append(eof(status: moreResults ? 0x000A : 0x0002))
        return packets
    }
}
