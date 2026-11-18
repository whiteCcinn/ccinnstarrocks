import Foundation
import MySQLWire
import Testing
@testable import StarRocksKit

/// 1.3.2 review: with `sql_dialect = trino` (an account property `session.sql_dialect`, or the global default on clusters
/// migrated from Trino), StarRocks reads `"name"` as an identifier, so `SELECT "lookup_string"(…)` and
/// `information_schema."tasks"` ran past text checks that read `"…"` as a string. A `SET_VAR` hint does not switch the
/// parse. Connections that require it (AI access) set the StarRocks dialect on every connection and verify it before
/// anything else runs, failing closed; only a server without the variable (error 1193) is accepted unverified.
@Suite("StarRocks dialect pin")
struct StarRocksDialectTests {
    private static func configuration(requiresDialect: Bool = true,
                                      variables: [(name: String, value: String)] = ConnectionConfiguration.defaultSessionVariables)
        -> ConnectionConfiguration {
        var configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake", port: 9030), username: "ai", connectTimeout: 2,
                                                    sessionVariables: variables)
        configuration.requiresStarRocksDialect = requiresDialect
        return configuration
    }

    /// A server whose replies to the pin are scripted; every other statement succeeds.
    private static func server(set: FakeMySQLServer.Reply, verify: FakeMySQLServer.Reply) -> FakeMySQLServer {
        FakeMySQLServer(answersSET: false) { sql in
            if sql == StarRocksDialect.setStatement { return set }
            if sql == StarRocksDialect.verifyStatement { return verify }
            return .packets([FakeMySQLServer.ok()])
        }
    }

    private static let ok = FakeMySQLServer.Reply.packets([FakeMySQLServer.ok()])

    private static func dialect(_ value: String?) -> FakeMySQLServer.Reply {
        .packets(FakeMySQLServer.resultSet([("@@sql_dialect", .varString)], [[value]]))
    }

    private static func failure(_ code: UInt16, _ message: String) -> FakeMySQLServer.Reply {
        .packets([FakeMySQLServer.error(code: code, message: message)])
    }

    private static func connect(_ server: FakeMySQLServer, _ configuration: ConnectionConfiguration = configuration()) async throws -> MySQLConnection {
        try await MySQLConnection.connect(configuration) { _, _ in server }
    }

    private static func isDialectRefusal(_ error: any Error) -> Bool {
        (error as? StarRocksError)?.message.contains("StarRocks SQL dialect") == true
    }

    @Test(arguments: ["StarRocks", "starrocks", "STARROCKS"])
    func theStarRocksDialectIsAccepted(value: String) async throws {
        let server = Self.server(set: Self.ok, verify: Self.dialect(value))
        let connection = try await Self.connect(server)
        let pin: [String] = [StarRocksDialect.setStatement, StarRocksDialect.verifyStatement]
        #expect(Array(server.queries.suffix(2)) == pin)
        #expect(StarRocksDialect.setStatement == "SET sql_dialect = 'StarRocks'")
        #expect(StarRocksDialect.verifyStatement == "SELECT @@sql_dialect")
        await connection.close()
    }

    /// The SET took effect but the session still reads another dialect: refused, and the connection is closed.
    @Test(arguments: ["trino", "Trino", "", " StarRocks", "StarRocks2", nil] as [String?])
    func anotherDialectIsRefused(value: String?) async throws {
        let server = Self.server(set: Self.ok, verify: Self.dialect(value))
        await #expect { _ = try await Self.connect(server) } throws: { Self.isDialectRefusal($0) }
        #expect(server.isClosed)
    }

    /// The SET itself failed (no privilege, a syntax error, anything): the dialect is unknown, so refused.
    @Test(arguments: [(1227, "Access denied"), (1064, "Getting syntax error"), (1105, "Unknown error"), (1231, "Variable 'sql_dialect' can't be set")])
    func aFailedSetIsRefused(code: Int, message: String) async throws {
        let server = Self.server(set: Self.failure(UInt16(code), message), verify: Self.dialect("StarRocks"))
        await #expect { _ = try await Self.connect(server) } throws: { Self.isDialectRefusal($0) }
        #expect(!server.queries.contains(StarRocksDialect.verifyStatement))
    }

    /// The verification failed, 1193 included: the SET succeeded, so the variable exists and its value must be read.
    @Test(arguments: [(1105, "Unknown error"), (1193, "Unknown system variable 'sql_dialect'")])
    func aFailedVerificationIsRefused(code: Int, message: String) async throws {
        let server = Self.server(set: Self.ok, verify: Self.failure(UInt16(code), message))
        await #expect { _ = try await Self.connect(server) } throws: { Self.isDialectRefusal($0) }
    }

    /// A server without the variable (error 1193 on the SET) has only its own dialect: accepted, nothing more is sent.
    @Test func aServerWithoutTheVariableIsAccepted() async throws {
        let server = Self.server(set: Self.failure(1193, "Unknown system variable 'sql_dialect'"), verify: Self.dialect("trino"))
        let connection = try await Self.connect(server)
        #expect(server.queries.last == StarRocksDialect.setStatement)
        #expect(!server.queries.contains(StarRocksDialect.verifyStatement))
        await connection.close()
    }

    /// The app's own connections keep the account's dialect: nothing is sent unless required.
    @Test func connectionsThatDoNotRequireItAreUntouched() async throws {
        let server = Self.server(set: Self.failure(1105, "must not be sent"), verify: Self.dialect("trino"))
        let connection = try await Self.connect(server, Self.configuration(requiresDialect: false))
        #expect(!server.queries.contains { $0.contains("sql_dialect") })
        await connection.close()
    }

    /// A configured session variable cannot undo the pin: it runs after them.
    @Test func thePinRunsAfterConfiguredSessionVariables() async throws {
        let server = Self.server(set: Self.ok, verify: Self.dialect("StarRocks"))
        let configuration = Self.configuration(variables: [(name: "sql_dialect", value: "trino"), (name: "query_timeout", value: "60")])
        let connection = try await Self.connect(server, configuration)
        #expect(server.queries == ["SET sql_dialect = 'trino'", "SET query_timeout = '60'", StarRocksDialect.setStatement,
                                   StarRocksDialect.verifyStatement])
        await connection.close()
    }

    /// Every connection of a client that requires it is pinned before its first statement: pool connections (the
    /// app-built metadata statements) and session connections (the AI's SQL), reconnects included.
    @Test func everyConnectionIsPinnedBeforeItsFirstStatement() async throws {
        let cluster = FakeCluster { sql in
            sql == StarRocksDialect.verifyStatement ? .packets(FakeCluster.rows("StarRocks")) : .packets(FakeCluster.rows("ok"))
        }
        let configuration = Self.configuration()
        let client = try await StarRocksClient.connect(configuration, poolSize: 1, transportFactory: cluster.transportFactory)
        #expect(client.configuration.requiresStarRocksDialect)
        let session = client.openSession(database: "shop")
        _ = try await session.run("SELECT \"ai\"")
        await session.close()
        _ = try await session.run("SELECT \"again\"")
        await session.close()
        await client.close()
        let statements = cluster.statementsByConnection
        #expect(statements.count == 3, "one pool connection and two session connections")
        for connection in statements {
            let pin = try #require(connection.firstIndex(of: StarRocksDialect.setStatement), "\(connection)")
            #expect(connection.indices.contains(pin + 1) && connection[pin + 1] == StarRocksDialect.verifyStatement, "\(connection)")
            #expect(connection.prefix(pin).allSatisfy { $0.hasPrefix("SET ") }, "only session variables come first: \(connection)")
        }
        let everyStatement: [String] = statements.flatMap { $0 }
        let aiStatements: [String] = everyStatement.filter { $0.hasPrefix("SELECT \"") }
        let expected: [String] = ["SELECT \"ai\"", "SELECT \"again\""]
        #expect(aiStatements == expected)
    }

    /// A client whose server reads another dialect sends nothing but the pin.
    @Test func aRefusedConnectionSendsNothingElse() async throws {
        let cluster = FakeCluster { sql in
            sql == StarRocksDialect.verifyStatement ? .packets(FakeCluster.rows("trino")) : .packets(FakeCluster.rows("ok"))
        }
        await #expect { _ = try await StarRocksClient.connect(Self.configuration(), poolSize: 1, transportFactory: cluster.transportFactory) }
            throws: { Self.isDialectRefusal($0) }
        #expect(!cluster.statements.contains { !$0.hasPrefix("SET ") && $0 != StarRocksDialect.verifyStatement })
    }
}
