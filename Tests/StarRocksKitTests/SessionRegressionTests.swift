import Foundation
import MySQLWire
import os
import Testing
@testable import StarRocksKit

/// A fake cluster: every connection is a `FakeMySQLServer`; `KILL QUERY <id>` interrupts that connection.
final class FakeCluster: Sendable {
    private struct State {
        var nextID: UInt32 = 100
        var servers: [UInt32: FakeMySQLServer] = [:]
        var handshakeDatabases: [String?] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let reply: @Sendable (String) -> FakeMySQLServer.Reply

    init(reply: @escaping @Sendable (String) -> FakeMySQLServer.Reply) {
        self.reply = reply
    }

    /// Every statement received, grouped by connection in creation order (the fake server answers
    /// `SET` itself, so its own query log is the complete record).
    var statements: [String] {
        let servers = state.withLockUnchecked { $0.servers }
        return servers.keys.sorted().flatMap { servers[$0]?.queries ?? [] }
    }
    var handshakeDatabases: [String?] { state.withLockUnchecked { $0.handshakeDatabases } }

    var transportFactory: TransportFactory {
        { [self] _, _ in
            let id = state.withLockUnchecked { state -> UInt32 in
                state.nextID += 1
                return state.nextID
            }
            let server = FakeMySQLServer(connectionID: id) { [self] sql in
                if sql.hasPrefix("KILL QUERY "), let target = UInt32(sql.dropFirst(11)) {
                    state.withLockUnchecked { $0.servers[target] }?.interrupt()
                    return .packets([FakeMySQLServer.ok()])
                }
                return reply(sql)
            }
            state.withLockUnchecked { $0.servers[id] = server }
            return HandshakeRecorder(server: server, cluster: self)
        }
    }

    fileprivate func record(database: String?) {
        state.withLockUnchecked { $0.handshakeDatabases.append(database) }
    }

    static func rows(_ value: String) -> [[UInt8]] {
        FakeMySQLServer.resultSet([("v", .varString)], [[value]])
    }
}

/// Records the database requested in each handshake.
private final class HandshakeRecorder: ByteTransport, @unchecked Sendable {
    let server: FakeMySQLServer
    let cluster: FakeCluster
    private var sawHandshake = false

    init(server: FakeMySQLServer, cluster: FakeCluster) {
        self.server = server
        self.cluster = cluster
    }

    func send(_ bytes: [UInt8]) async throws {
        if !sawHandshake {
            sawHandshake = true
            var framer = PacketFramer()
            framer.append(bytes)
            if let packet = try framer.nextPacket() { cluster.record(database: Self.database(in: packet.payload)) }
        }
        try await server.send(bytes)
    }

    func receive() async throws -> [UInt8] { try await server.receive() }
    func close() { server.close() }

    static func database(in payload: [UInt8]) -> String? {
        var reader = PayloadReader(payload)
        guard let capabilities = try? Capabilities(rawValue: reader.readUInt32()), (try? reader.skip(4 + 1 + 23)) != nil else { return nil }
        _ = try? reader.readNullTerminatedString()
        _ = try? reader.readLengthEncodedBytes()
        guard capabilities.contains(.connectWithDB) else { return nil }
        return try? reader.readNullTerminatedString()
    }
}

@Suite("Session and cancellation regressions")
struct SessionRegressionTests {
    private func connect(_ cluster: FakeCluster, database: String? = nil, poolSize: Int = 1) async throws -> StarRocksClient {
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", database: database, connectTimeout: 2)
        return try await StarRocksClient.connect(configuration, poolSize: poolSize, transportFactory: cluster.transportFactory)
    }

    @Test func cancelledBeforeSendingDoesNotKillTheNextQuery() async throws {
        let cluster = FakeCluster { sql in sql.contains("slow") ? .delayed(FakeCluster.rows("slow"), seconds: 0.4) : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.query("SELECT 'cancelled'")
        }
        _ = try? await cancelled.value
        // The pool's only connection is reused by an unrelated query; it must not be killed.
        let result = try await client.query("SELECT 'slow'")
        #expect(result.last?.scalar == "slow")
        #expect(!cluster.statements.contains { $0.hasPrefix("KILL") })
        await client.close()
    }

    @Test func lateCancelDoesNotCloseTheNextRun() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("first") { return .hang }
            if sql.contains("second") { return .delayed(FakeCluster.rows("second"), seconds: 0.8) }
            return .packets(FakeCluster.rows("ok"))
        }
        let client = try await connect(cluster)
        let session = client.openSession()
        let first = Task { try await session.run("SELECT 'first'") }
        try await Task.sleep(for: .milliseconds(100))
        let cancel = Task { await session.cancel(graceSeconds: 0.3) }
        await #expect { _ = try await first.value } throws: { ($0 as? StarRocksError)?.kind == .cancelled }
        // Re-run immediately on the same connection; the pending cancel's grace period expires meanwhile.
        let second = try await session.run("SELECT 'second'")
        #expect(second.last?.scalar == "second")
        await cancel.value
        #expect(try await session.run("SELECT 3").last?.scalar == "ok")
        await session.close()
        await client.close()
    }

    @Test func reconnectAfterSetCatalogKeepsTheSessionContext() async throws {
        let cluster = FakeCluster { _ in .packets([FakeMySQLServer.ok()]) }
        let client = try await connect(cluster, database: "sales")
        let session = client.openSession()
        _ = try await session.run("SET CATALOG hive")
        _ = try await session.run("SET query_timeout = 600")
        #expect(await session.database == nil)
        // Force a reconnect.
        if let id = await session.connectionID { _ = id }
        await session.close()
        _ = try await session.run("SELECT 1")
        let last = cluster.handshakeDatabases.last ?? "unset"
        #expect(last == nil, "the profile database must not be requested in another catalog")
        let replay = cluster.statements.suffix(3)
        #expect(replay.contains("SET CATALOG `hive`"))
        #expect(replay.contains("SET query_timeout = 600"))
        #expect(!cluster.statements.contains { $0.hasPrefix("USE") })
        await client.close()
    }

    @Test func rejectedConcurrentRunKeepsStopWorking() async throws {
        let cluster = FakeCluster { sql in sql.contains("long") ? .hang : .packets(FakeCluster.rows("ok")) }
        let client = try await connect(cluster)
        let session = client.openSession()
        let long = Task { try await session.run("SELECT 'long'") }
        try await Task.sleep(for: .milliseconds(100))
        await #expect { _ = try await session.run("SELECT 2") } throws: { ($0 as? StarRocksError)?.kind == .busy }
        #expect(await session.runningConnectionID != nil, "the rejected run must not clear the running statement")
        await session.cancel(graceSeconds: 1)
        await #expect { _ = try await long.value } throws: { ($0 as? StarRocksError)?.kind == .cancelled }
        await session.close()
        await client.close()
    }

    @Test func classifiesSessionStatements() {
        #expect(SessionContextChange.parse("SET query_timeout = 10") == .sessionVariable("SET query_timeout = 10"))
        #expect(SessionContextChange.parse("set role all") == .sessionVariable("set role all"))
        #expect(SessionContextChange.parse("SET GLOBAL query_timeout = 10") == nil)
        #expect(SessionContextChange.parse("SET PASSWORD = PASSWORD('x')") == nil)
        #expect(SessionContextChange.parse("set @@global.x = 1") == nil)
    }
}
