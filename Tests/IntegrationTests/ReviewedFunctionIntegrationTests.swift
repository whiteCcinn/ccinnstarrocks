import Foundation
import Testing
@testable import CcinnStarRocksKit
@testable import StarRocksKit

/// AI read-only queries call only reviewed functions (deny by default). These checks keep that true on the live servers:
/// a StarRocks version that lists a function nobody has reviewed fails here until it is reviewed or denied, and the words
/// the guard reads as syntax before `(` must still be syntax for the server. Read-only: nothing is created.
@Suite("Reviewed functions", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct ReviewedFunctionIntegrationTests {
    @Test(arguments: IntegrationEnvironment.targets)
    func everyListedFunctionIsReviewedOrDenied(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let listed = Set(try await client.execute("SHOW BUILTIN FUNCTIONS").rows.compactMap { $0.first ?? nil }.map { $0.lowercased() })
        #expect(listed.count > 400, "SHOW BUILTIN FUNCTIONS listed \(listed.count) names")
        let unreviewed = listed.filter { !ReviewedFunctions.names.contains($0) && !ReadOnlySQLGuard.isDeniedFunction($0) }.sorted()
        #expect(unreviewed.isEmpty, """
            StarRocks \(target.label) lists functions nobody has reviewed for AI: \(unreviewed.joined(separator: ", ")). \
            Check what each reads (files, other users' data, server internals, the network) as an account with SELECT on \
            one table, then add it to ReviewedFunctions or ReadOnlySQLGuard.deniedFunctions.
            """)
        // The functions the listing omits but the server runs (probed): the guard refuses every one, in any query.
        for name in ReviewedFunctions.unlistedMetaFunctions {
            #expect(!listed.contains(name) || ReadOnlySQLGuard.isDeniedFunction(name), "\(name)")
            for sql in ["SELECT \(name)('shop.customers')", "SELECT * FROM TABLE(\(name)('shop.customers'))",
                        "WITH x AS (SELECT \(name)('shop.customers') AS v) SELECT * FROM x"] {
                #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
            }
        }
        for name in listed where ReadOnlySQLGuard.isDeniedFunction(name) {
            #expect(ReadOnlySQLGuard.check("SELECT \(name)('x')") != nil, "\(name)")
        }
    }

    /// The guard reads these words before `(` as syntax, not as calls; that holds only while the server reserves them.
    /// A function's arguments never start with SELECT or WITH, which is why `EXCEPT (SELECT …` and `MINUS (SELECT …` are
    /// set operations although EXCEPT and MINUS are not reserved everywhere.
    @Test(arguments: IntegrationEnvironment.targets)
    func syntaxWordsAreNeverCallsOnTheServer(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        var probes = SQLFunctionCalls.syntaxKeywords.sorted().map { "SELECT 1, \($0)(1, 2)" }
        probes += ["SELECT 1, zz_no_such_function(SELECT 1)", "SELECT 1, except(SELECT 1)", "SELECT 1, minus(SELECT 1)",
                   "SELECT 1, except(WITH a AS (SELECT 1) SELECT * FROM a)"]
        // A name right after `)` or AS, a CTE-shaped `name(…) AS (`, and a name right after a table name are never calls.
        probes += ["SELECT (1) zz_no_such_function(1)", "SELECT (SELECT 1) zz_no_such_function(1)", "SELECT CAST(1 AS INT) zz_no_such_function(1)",
                   "SELECT sum(total) OVER () zz_no_such_function(1) FROM shop.orders", "SELECT 1 FROM shop.orders WHERE (1) zz_no_such_function(1)",
                   "SELECT * FROM shop.orders PARTITION (p202401) zz_no_such_function(1)", "SELECT 1 AS zz_no_such_function(1)",
                   "SELECT CAST(1 AS zz_no_such_function(1))", "SELECT * FROM shop.orders AS zz_no_such_function(1)",
                   "WITH zz_no_such_function(1) AS (SELECT 1) SELECT 1", "SELECT 1, zz_no_such_function(1) AS (SELECT 1)",
                   "SELECT * FROM shop.orders zz_no_such_function(1)"]
        // A name right after a select-list star is never a call (`* EXCEPT (…)`, `* EXCLUDE (…)` are column lists).
        probes += ["SELECT * zz_no_such_function(1) FROM shop.orders", "SELECT o.* zz_no_such_function(1) FROM shop.orders o",
                   "SELECT 1, * zz_no_such_function(1) FROM shop.orders", "SELECT DISTINCT * zz_no_such_function(1) FROM shop.orders",
                   "SELECT ALL * zz_no_such_function(1) FROM shop.orders"]
        // Inside a call's parentheses a call followed by a time unit is never valid, so `INTERVAL (n) UNIT` is an interval there.
        probes += SQLFunctionCalls.intervalUnits.sorted().map { "SELECT concat('a', zz_no_such_function(1) \($0))" }
        probes += ["SELECT array_agg(1 ORDER BY zz_no_such_function(1) DAY)", "SELECT group_concat(zz_no_such_function(1) DAY)",
                   "SELECT count(DISTINCT zz_no_such_function(1) DAY)", "SELECT cast(zz_no_such_function(1) DAY AS INT)",
                   "SELECT extract(YEAR FROM zz_no_such_function(1) DAY)", "SELECT array_map(x -> zz_no_such_function(1) DAY, [1])",
                   "SELECT * FROM TABLE(generate_series(zz_no_such_function(1) DAY, 2))", "SELECT struct(zz_no_such_function(1) DAY)",
                   "SELECT if(zz_no_such_function(1) DAY, 1, 2)", "SELECT convert(zz_no_such_function(1) DAY, INT)"]
        for sql in probes {
            let message = await Self.failure(client, sql)
            #expect(Self.isSyntaxError(message), "StarRocks \(target.label) does not read `\(sql)` as a syntax error: \(message ?? "it ran")")
        }
        // A bare function name is never invoked: higher-order functions take only lambdas, so the guard need not
        // treat a name without `(` as a call.
        for sql in ["SELECT array_map(upper, ['a'])", "SELECT array_filter(upper, ['a'])", "SELECT array_sortby(upper, ['a'])",
                    "SELECT any_match(upper, ['a'])", "SELECT map_apply(upper, map{1:2})", "SELECT array_map(lookup_string, ['x'])"] {
            #expect(await Self.failure(client, sql) != nil, "StarRocks \(target.label) ran \(sql)")
        }
        // The probes can tell: a word that is not reserved reaches function lookup, and so do `2 * exclude(1)`, a
        // top-level `+ INTERVAL (1) DAY` (`interval(1)` aliased DAY) and `INTERVAL (1)` without a unit.
        for sql in ["SELECT 1, tablet(1, 2)", "SELECT 2 * exclude(1)", "SELECT now() + INTERVAL (1) DAY", "SELECT concat('a', INTERVAL (1))"] {
            let control = await Self.failure(client, sql)
            #expect(control?.contains("No matching function") == true, "\(sql): \(control ?? "it ran")")
        }
    }

    /// Through the real MCP subprocess: the review's leaking calls and a UDF-shaped call are refused by run_query and
    /// explain_query before reaching the server; ordinary analytics with reviewed functions are served.
    @Test(.enabled(if: MCPProcess.binaryExists), arguments: IntegrationEnvironment.targets)
    func mcpServesReviewedFunctionsOnly(target: IntegrationEnvironment.Target) async throws {
        let process = try MCPProcess(target: target)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let refused = [
            "SELECT lookup_string('shop.customers', '1', 'name') AS v",
            "SELECT dict_mapping('shop.customers', 1, 'name') AS v",
            "SELECT get_query_dump('select * from shop.customers') AS v",
            "SELECT inspect_mv_meta('shop.mv_city_daily') AS v",
            "WITH x AS (SELECT inspect_mv_plan('shop.mv_city_daily') AS v) SELECT * FROM x",
            "SELECT shop.zz_no_such_udf(1) AS v",
        ]
        var id: Int64 = 10
        for sql in refused {
            for tool in ["run_query", "explain_query"] {
                id += 1
                let response = try await process.request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                                          "params": ["name": .string(tool), "arguments": ["sql": .string(sql), "database": "shop"]]])
                let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
                #expect(response["result"]?["isError"] == .bool(true), "\(tool): \(sql)")
                #expect(text.contains("is not available to AI") || text.contains("list of reviewed functions"), "\(tool): \(text)")
            }
        }
        let served = try await process.call(id: 90, "run_query", ["database": "shop", "sql": """
            WITH c(city, total) AS (SELECT city, total FROM orders)
            SELECT city, count(*) AS n, CAST(sum(total) AS DECIMAL(18, 2)) AS revenue, max(length(city)) AS l,
                   row_number() OVER (ORDER BY count(*) DESC) AS r
            FROM c GROUP BY city
            """])
        #expect((served["row_count"]?.intValue ?? 0) > 0)
    }

    private static func failure(_ client: StarRocksClient, _ sql: String) async -> String? {
        do {
            _ = try await client.execute(sql)
            return nil
        } catch {
            return (error as? StarRocksError)?.message ?? "\(error)"
        }
    }

    private static func isSyntaxError(_ message: String?) -> Bool {
        guard let message, !message.contains("No matching function") else { return false }
        return message.contains("Unexpected input") || message.contains("No viable statement")
    }
}

/// 1.3.2 review: an account whose `session.sql_dialect` property (or the global default) is trino reads `"…"` as names,
/// so `"lookup_string"(…)`, `"get_query_dump"(…)`, `information_schema."tasks"` and, on 4.1, `"ai_query"(…)` ran past the
/// text checks, and a `\'` in the app's own quoted literals ended the string. AI connections pin the StarRocks dialect on
/// every connection and verify it. Creates and drops one account (no tables).
@Suite("MCP and the SQL dialect", .enabled(if: IntegrationEnvironment.isEnabled && MCPProcess.binaryExists), .serialized)
struct MCPDialectTests {
    @Test(arguments: IntegrationEnvironment.targets)
    func aTrinoAccountIsPinnedToStarRocks(target: IntegrationEnvironment.Target) async throws {
        let admin = try await IntegrationEnvironment.client(target)
        defer { Task { await admin.close() } }
        let user = "zz_al_dialect_\(String(UInt32.random(in: 0...UInt32.max), radix: 36))"
        _ = try await admin.execute("CREATE USER '\(user)'@'%'")
        do {
            _ = try await admin.execute("GRANT SELECT ON TABLE shop.orders TO USER '\(user)'@'%'")
            _ = try await admin.execute("ALTER USER '\(user)'@'%' SET PROPERTIES ('session.sql_dialect' = 'trino')")
            try await check(target, user: user)
        } catch {
            _ = try? await admin.execute("DROP USER '\(user)'@'%'")
            throw error
        }
        _ = try? await admin.execute("DROP USER '\(user)'@'%'")
    }

    private func check(_ target: IntegrationEnvironment.Target, user: String) async throws {
        // The threat is real: the account's own sessions read "…" as names, and `\'` ends a string.
        let plain = try await IntegrationEnvironment.client(target, user: user)
        defer { Task { await plain.close() } }
        #expect(try await plain.execute("SELECT @@sql_dialect").scalar?.lowercased() == "trino")
        #expect(try await plain.execute("SELECT \"upper\"('x')").scalar == "X")
        let escaped = try await plain.execute(#"SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = 'x\' OR 1=1 -- '"#)
        #expect(!escaped.rows.isEmpty, "a backslash-escaped quote ends the string in trino")
        // The app's literals double the quote instead, so even an unpinned connection keeps a quoted name one value.
        #expect(try await plain.objects(database: "x' OR 1=1 -- ").isEmpty)

        // A client that requires the StarRocks dialect pins it on every connection.
        var configuration = ConnectionConfiguration(endpoint: target.endpoint, username: user)
        configuration.requiresStarRocksDialect = true
        let pinned = try await StarRocksClient.connect(configuration)
        defer { Task { await pinned.close() } }
        #expect(try await pinned.execute("SELECT @@sql_dialect").scalar == "StarRocks")
        let session = pinned.openSession(database: "shop")
        #expect(try await session.run("SELECT @@sql_dialect").last?.scalar == "StarRocks")
        await session.close()
        #expect(try await pinned.objects(database: "x' OR 1=1 -- ").isEmpty)

        // Through MCP as that account: the reviewer's statements are refused and the AI's own session reads StarRocks.
        let process = try MCPProcess(target: target, username: user, allowPrivileged: false)
        defer { process.terminate() }
        _ = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                       "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let refused = [
            "SELECT \"ai_query\"('p', '{\"model\":\"m\",\"endpoint\":\"http://127.0.0.1:9/x\"}')",
            "SELECT \"task_name\", substr(\"definition\", 1, 50) FROM information_schema.\"tasks\"",
            "SELECT \"lookup_string\"('shop.customers', '1', 'name')",
            "SELECT \"get_query_dump\"('select * from shop.customers')",
            "SELECT \"upper\"('x')",
        ]
        var id: Int64 = 10
        for sql in refused {
            for tool in ["run_query", "explain_query"] {
                id += 1
                let response = try await process.request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                                          "params": ["name": .string(tool), "arguments": ["sql": .string(sql), "database": "shop"]]])
                #expect(response["result"]?["isError"] == .bool(true), "\(tool): \(sql)")
                #expect(!response.serialized().contains("Customer 1") && !response.serialized().contains("table_meta"), "\(tool): \(sql)")
            }
        }
        let dialect = try await process.call(id: 90, "run_query", ["sql": "SELECT @@sql_dialect AS d", "database": "shop"])
        #expect(dialect["rows"]?[0]?[0] == .string("StarRocks"))
        let tables = try await process.call(id: 91, "list_tables", ["database": "x' OR 1=1 -- "])
        #expect(tables["count"] == .int(0), "a quoted name stays one literal")
        let orders = try await process.call(id: 92, "run_query", ["sql": "SELECT count(*) AS n FROM orders", "database": "shop"])
        #expect(orders["row_count"] == .int(1))
    }
}

/// SQLText.literal is one string with the exact value in the StarRocks dialect, and one string (backslashes doubled at
/// worst) in trino: a quote in a value never ends it. Read-only (a session-scoped SET only).
@Suite("Literals in both dialects", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct LiteralDialectTests {
    static let values: [String] = ["x' UNION SELECT 'injected' -- ", "x\\' UNION SELECT 'injected' -- ", "x'", "x\\", "\\'", "O'Neil",
                         "it's \\ ok", "50%_off\\'x", "吉隆坡'", "''", "\\\\''"]

    @Test(arguments: IntegrationEnvironment.targets)
    func aQuoteNeverEndsALiteral(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let session = client.openSession()
        defer { Task { await session.close() } }
        for dialect in ["StarRocks", "trino"] {
            _ = try await session.run("SET sql_dialect = '\(dialect)'")
            for value in Self.values {
                let result = try #require(try await session.run("SELECT \(SQLText.literal(value)) AS v").last)
                let expected: String = dialect == "StarRocks" ? value : value.replacingOccurrences(of: "\\", with: "\\\\")
                #expect(result.rows.count == 1 && result.rows.first?.count == 1, "\(dialect): \(value.debugDescription)")
                #expect(result.rows.first?.first == expected, "\(dialect): \(value.debugDescription)")
            }
        }
        _ = try await session.run("SET sql_dialect = 'StarRocks'")
    }
}
