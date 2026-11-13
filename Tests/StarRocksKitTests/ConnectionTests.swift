import Foundation
import MySQLWire
import Testing
@testable import StarRocksKit

private func configuration(password: String = "secret", database: String? = "shop", allowCleartext: Bool = false) -> ConnectionConfiguration {
    ConnectionConfiguration(endpoint: Endpoint(host: "fake", port: 9030), username: "ccinn", password: password, database: database,
                            connectTimeout: 2, allowCleartextPassword: allowCleartext)
}

private func connect(_ server: FakeMySQLServer, configuration: ConnectionConfiguration = configuration()) async throws -> MySQLConnection {
    try await MySQLConnection.connect(configuration) { _, _ in server }
}

@Suite("MySQL connection")
struct ConnectionTests {
    @Test func handshakeSendsCredentialsAndDatabase() async throws {
        let server = FakeMySQLServer(connectionID: 99)
        let connection = try await connect(server)
        #expect(connection.connectionID == 99)
        #expect(connection.protocolVersion == "8.0.33")

        var reader = PayloadReader(server.handshakeResponse)
        let capabilities = Capabilities(rawValue: try reader.readUInt32())
        #expect(capabilities.contains(.connectWithDB))
        #expect(!capabilities.contains(.deprecateEOF), "classic EOF framing is requested for maximum compatibility")
        _ = try reader.readBytes(4 + 1 + 23)
        #expect(try reader.readNullTerminatedString() == "ccinn")
        let token = try #require(try reader.readLengthEncodedBytes())
        #expect(token == AuthPlugin.nativePassword(password: "secret", scramble: Array(1...20)))
        #expect(try reader.readNullTerminatedString() == "shop")
        #expect(try reader.readNullTerminatedString() == "mysql_native_password")
    }

    @Test func rejectedCredentialsSurfaceAsAuthenticationError() async {
        let server = FakeMySQLServer(auth: .reject(code: 1045, message: "Access denied for user 'ccinn'"))
        await #expect {
            _ = try await connect(server)
        } throws: { error in
            let error = error as? StarRocksError
            return error?.kind == .authentication && error?.code == 1045
        }
        #expect(server.isClosed)
    }

    @Test func clearPasswordSwitchRequiresOptIn() async throws {
        let refused = FakeMySQLServer(auth: .switchTo(plugin: "mysql_clear_password"))
        await #expect(throws: StarRocksError.self) { _ = try await connect(refused) }

        let allowed = FakeMySQLServer(auth: .switchTo(plugin: "mysql_clear_password"))
        _ = try await connect(allowed, configuration: configuration(allowCleartext: true))
        #expect(allowed.authSwitchReply == Array("secret".utf8) + [0])
    }

    @Test func nativePasswordSwitchUsesTheNewScramble() async throws {
        let server = FakeMySQLServer(auth: .switchTo(plugin: "mysql_native_password"))
        _ = try await connect(server)
        #expect(server.authSwitchReply == AuthPlugin.nativePassword(password: "secret", scramble: Array(repeating: 5, count: 20)))
    }

    @Test func readsRowsWithNullsAndNameLookup() async throws {
        let server = FakeMySQLServer { _ in
            .packets(FakeMySQLServer.resultSet([("TABLE_NAME", .varString), ("TABLE_ROWS", .longLong)],
                                               [["orders", "20000"], ["v_paid", nil]]))
        }
        let connection = try await connect(server)
        let result = try await connection.execute("SELECT 1")
        #expect(result.columnNames == ["TABLE_NAME", "TABLE_ROWS"])
        #expect(result.rows.count == 2)
        let records = result.records
        #expect(records[0].text("table_name") == "orders")
        #expect(records[0].int("TABLE_ROWS") == 20000)
        #expect(records[1].int("TABLE_ROWS") == nil)
        #expect(records[1].text("missing", "TABLE_NAME") == "v_paid")
        #expect(!result.isTruncated)
    }

    @Test func okPacketReportsAffectedRows() async throws {
        let server = FakeMySQLServer { _ in .packets([FakeMySQLServer.ok(affectedRows: 42)]) }
        let connection = try await connect(server)
        let result = try await connection.execute("DELETE FROM t")
        #expect(!result.hasRowSet)
        #expect(result.affectedRows == 42)
    }

    @Test func serverErrorKeepsConnectionUsable() async throws {
        let server = FakeMySQLServer { sql in
            sql.contains("bad")
                ? .packets([FakeMySQLServer.error(code: 1064, state: "42000", message: "Getting syntax error")])
                : .packets(FakeMySQLServer.resultSet([("x", .longLong)], [["1"]]))
        }
        let connection = try await connect(server)
        await #expect {
            _ = try await connection.execute("bad sql")
        } throws: { ($0 as? StarRocksError)?.kind == .server && ($0 as? StarRocksError)?.sqlState == "42000" }
        #expect(await !connection.isBroken)
        #expect(try await connection.execute("SELECT 1").scalar == "1")
    }

    @Test func errorInsideRowStreamIsReported() async throws {
        let server = FakeMySQLServer { _ in
            var packets = FakeMySQLServer.resultSet([("x", .longLong)], [["1"]])
            packets.removeLast()
            packets.append(FakeMySQLServer.error(code: 1317, message: "Query cancelled"))
            return .packets(packets)
        }
        let connection = try await connect(server)
        await #expect { _ = try await connection.execute("SELECT x") } throws: { ($0 as? StarRocksError)?.isQueryInterrupted == true }
        #expect(await !connection.isBroken)
    }

    @Test func multipleResultsAreCollected() async throws {
        let server = FakeMySQLServer { _ in
            .packets(FakeMySQLServer.resultSet([("a", .longLong)], [["1"]], moreResults: true)
                + [FakeMySQLServer.ok(affectedRows: 3, status: 0x000A)]
                + FakeMySQLServer.resultSet([("b", .varString)], [["x"], ["y"]]))
        }
        let connection = try await connect(server)
        let results = try await connection.query("SELECT 1; DELETE ...; SELECT 'x'")
        #expect(results.count == 3)
        #expect(results[1].affectedRows == 3)
        #expect(results[2].rows.count == 2)
    }

    @Test func rowLimitTruncatesAndDrainsSmallOverflow() async throws {
        let rows = (0..<50).map { [String($0)] as [String?] }
        let server = FakeMySQLServer { _ in .packets(FakeMySQLServer.resultSet([("n", .longLong)], rows)) }
        let connection = try await connect(server)
        let result = try await connection.execute("SELECT n", limits: RowLimits(maxRows: 10, drainRows: 100))
        #expect(result.rows.count == 10)
        #expect(result.isTruncated)
        #expect(await !connection.isBroken, "a small overflow is drained so the connection stays reusable")
    }

    @Test func hugeOverflowAbandonsTheConnection() async throws {
        let rows = (0..<50).map { [String($0)] as [String?] }
        let server = FakeMySQLServer { _ in .packets(FakeMySQLServer.resultSet([("n", .longLong)], rows)) }
        let connection = try await connect(server)
        let result = try await connection.execute("SELECT n", limits: RowLimits(maxRows: 10, drainRows: 5))
        #expect(result.rows.count == 10)
        #expect(result.isTruncated)
        #expect(await connection.isBroken)
        #expect(server.isClosed)
    }

    @Test func cancellationClosesTheSocket() async throws {
        let server = FakeMySQLServer { _ in .hang }
        let connection = try await connect(server)
        let task = Task { try await connection.execute("SELECT sleep(100)") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect { _ = try await task.value } throws: { ($0 as? StarRocksError)?.kind == .cancelled }
        #expect(await connection.isBroken)
        #expect(server.isClosed)
    }

    @Test func overlappingStatementsFailFast() async throws {
        let server = FakeMySQLServer { _ in .hang }
        let connection = try await connect(server)
        let first = Task { try await connection.execute("SELECT sleep(100)") }
        try await Task.sleep(for: .milliseconds(50))
        await #expect { _ = try await connection.execute("SELECT 1") } throws: { ($0 as? StarRocksError)?.kind == .busy }
        first.cancel()
        _ = try? await first.value
    }

    @Test func handshakeTimeoutIsReported() async {
        // A server that accepts TCP but never sends a greeting.
        let silent = SilentTransport()
        let config = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "u", connectTimeout: 1)
        let started = ContinuousClock.now
        await #expect {
            _ = try await MySQLConnection.connect(config) { _, _ in silent }
        } throws: { ($0 as? StarRocksError)?.kind == .timeout }
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}

private final class SilentTransport: ByteTransport, Sendable {
    func send(_ bytes: [UInt8]) async throws {}
    func receive() async throws -> [UInt8] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
    func close() {}
}
