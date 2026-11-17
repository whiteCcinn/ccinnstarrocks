import Foundation
import Testing
@testable import StarRocksKit
import CcinnStarRocksKit

/// Live tests against StarRocks containers started by `scripts/sr-up.sh`:
///   export CCINNSR_IT_URIS="3.3=127.0.0.1:19033,4.1=127.0.0.1:19041"
enum IntegrationEnvironment {
    struct Target: Sendable, CustomTestStringConvertible {
        let label: String
        let endpoint: Endpoint
        var testDescription: String { "StarRocks \(label)" }
    }

    static let targets: [Target] = {
        guard let raw = ProcessInfo.processInfo.environment["CCINNSR_IT_URIS"] else { return [] }
        return raw.split(separator: ",").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let address = parts[1].split(separator: ":")
            guard address.count == 2, let port = Int(address[1]) else { return nil }
            return Target(label: String(parts[0]), endpoint: Endpoint(host: String(address[0]), port: port))
        }
    }()

    static var isEnabled: Bool { !targets.isEmpty }

    static func client(_ target: Target, user: String = "root", password: String = "") async throws -> StarRocksClient {
        try await StarRocksClient.connect(ConnectionConfiguration(endpoint: target.endpoint, username: user, password: password))
    }
}

@Suite("StarRocks integration", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct StarRocksIntegrationTests {
    @Test(arguments: IntegrationEnvironment.targets)
    func connectsAndReportsServerInfo(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let version = try #require(client.serverInfo.version)
        #expect("\(version.major).\(version.minor)" == target.label)
        #expect(client.serverInfo.runMode == "shared_nothing")
        #expect(client.serverInfo.currentUser?.contains("root") == true)
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func nativePasswordUserAndWrongPassword(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target, user: "ccinn", password: "ccinn-secret")
        #expect(try await client.execute("SELECT 41 + 1").scalar == "42")
        await client.close()
        await #expect {
            _ = try await IntegrationEnvironment.client(target, user: "ccinn", password: "wrong")
        } throws: { ($0 as? StarRocksError)?.kind == .authentication }
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func typesNullsAndUnicode(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let result = try await client.execute("""
            SELECT CAST(1 AS BIGINT) AS i, CAST(2.50 AS DECIMAL(10,2)) AS d, CAST('2024-02-29' AS DATE) AS dt,
                   CAST('2024-02-29 10:11:12' AS DATETIME) AS ts, 'Kuala Lumpur 吉隆坡 🇲🇾' AS s, NULL AS n, parse_json('{"a":1}') AS j
            """)
        let row = try #require(result.first)
        #expect(row.int("i") == 1)
        #expect(row.double("d") == 2.5)
        #expect(row.text("dt") == "2024-02-29")
        #expect(row.text("ts") == "2024-02-29 10:11:12")
        #expect(row.text("s") == "Kuala Lumpur 吉隆坡 🇲🇾")
        #expect(row.raw("n") == nil)
        #expect(result.columns.map(\.type.kind)[0...3] == [.integer, .decimal, .date, .dateTime])
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func rowLimitTruncates(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let results = try await client.query("SELECT * FROM shop.orders", limits: RowLimits(maxRows: 100, drainRows: 100_000))
        let result = try #require(results.last)
        #expect(result.rows.count == 100)
        #expect(result.isTruncated)
        // The pool connection is still healthy after the drain.
        #expect(try await client.execute("SELECT COUNT(*) FROM shop.orders").scalar == "20000")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func serverErrorsAreReportedWithCodes(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        await #expect {
            _ = try await client.execute("SELECT * FROM shop.no_such_table")
        } throws: { error in
            let error = error as? StarRocksError
            return error?.kind == .server && error?.code != nil
        }
        #expect(try await client.execute("SELECT 1").scalar == "1")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func classifiesEveryObjectKind(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        #expect(try await client.catalogs().contains { $0.name == "default_catalog" })
        let databases = try await client.databases()
        #expect(databases.first == "shop")
        let objects = try await client.objects(database: "shop")
        let byName = Dictionary(uniqueKeysWithValues: objects.map { ($0.name, $0) })
        #expect(byName["orders"]?.kind == .table)
        #expect(byName["orders"]?.model == .duplicate)
        #expect(byName["orders"]?.partitionKey == "order_date")
        #expect(byName["orders"]?.buckets == 4)
        #expect(byName["customers"]?.model == .primary)
        #expect(byName["daily_metrics"]?.model == .aggregate)
        #expect(byName["events_latest"]?.model == .unique)
        #expect(byName["v_paid_orders"]?.kind == .view)
        #expect(byName["mv_city_daily"]?.kind == .asyncMaterializedView)
        #expect(byName["mv_city_daily"]?.materializedView?.isActive == true)
        #expect(byName["mv_city_daily"]?.materializedView?.taskName?.hasPrefix("mv-") == true)
        #expect(byName["mv_orders_by_channel"]?.kind == .syncMaterializedView)
        #expect(byName["mv_orders_by_channel"]?.baseTable == "orders")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func columnsAndDDL(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let objects = try await client.objects(database: "shop")
        let orders = try #require(objects.first { $0.name == "orders" })
        let columns = try await client.columns(of: orders)
        #expect(columns.map(\.name) == ["order_id", "order_date", "city", "channel", "status", "total", "qty"])
        #expect(columns[0].isKey)
        #expect(columns[0].comment == "order identifier")
        #expect(columns[5].columnType.lowercased().hasPrefix("decimal"))

        let syncMV = try #require(objects.first { $0.kind == .syncMaterializedView })
        let mvColumns = try await client.columns(of: syncMV)
        #expect(mvColumns.map(\.name).contains("channel"))
        #expect(mvColumns.contains { $0.aggregation == "SUM" })

        for object in objects where object.kind != .syncMaterializedView {
            let ddl = try await client.ddl(of: object)
            #expect(ddl.uppercased().hasPrefix("CREATE"), "DDL of \(object.name)")
        }
        let all = try await client.columnsByTable(database: "shop")
        #expect(all["customers"]?.isEmpty == false)
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func partitionsTabletsAndStorage(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let partitions = try await client.partitions(database: "shop", table: "orders")
        #expect(partitions.count == 13)
        let first = try #require(partitions.first)
        #expect(first.name == "p202401")
        #expect(first.bounds.lower == "2024-01-01")
        #expect(first.bounds.upper == "2024-02-01")
        #expect(first.buckets == 4)
        let tablets = try await client.tablets(database: "shop", table: "orders", partition: "p202401")
        #expect(tablets.count == 4)
        let all = try await client.tablets(database: "shop", table: "orders")
        #expect(all.count == 52)
        let rollup = try await client.tablets(database: "shop", table: "orders", partition: "p202401", index: "mv_orders_by_channel")
        #expect(rollup.count == 4)
        #expect(Set(rollup.map(\.tabletID)).isDisjoint(with: tablets.map(\.tabletID)))
        let distribution = try await client.replicaDistribution(database: "shop", table: "orders")
        #expect(distribution.first?.replicaCount ?? 0 > 0)
        let storage = try await client.storage(database: "shop", table: "orders")
        #expect(storage.contains { $0.indexName == "orders" })
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func materializedViewRefreshAndTaskRuns(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let status = try #require(try await client.materializedViewStatus(database: "shop", name: "mv_city_daily"))
        let taskName = try #require(status.taskName)
        try await client.refreshMaterializedView(database: "shop", name: "mv_city_daily", force: true)
        var runs: [TaskRun] = []
        for _ in 0..<20 {
            runs = try await client.taskRuns(taskName: taskName)
            if runs.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(!runs.isEmpty)
        #expect(runs.allSatisfy { $0.taskName == taskName })
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func operationsSurfaces(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let processes = try await client.processList()
        #expect(!processes.isEmpty)
        // StarRocks expires old load records, so create a fresh (idempotent) one: an upsert into a unique-key table.
        let label = "ccinn_it_\(UInt32.random(in: 0...UInt32.max))"
        _ = try await client.execute("INSERT INTO shop.events_latest WITH LABEL \(label) SELECT 0, '2024-06-01 00:00:00', 'online'")
        let loads = try await client.loads(database: "shop")
        #expect(loads.contains { $0.label == label && $0.state == "FINISHED" && $0.sinkRows == 1 })
        _ = try await client.routineLoads(database: "shop")
        let alters = try await client.alterJobs(database: "shop")
        #expect(alters.contains { $0.kind == .rollup && $0.indexName == "mv_orders_by_channel" })
        let nodes = try await client.nodes()
        #expect(nodes.contains { $0.role == .frontend && $0.isAlive })
        #expect(nodes.contains { $0.role == .backend && $0.isAlive && ($0.totalCapacity ?? 0) > 0 })
        let activity = await client.activity(databases: ["shop"])
        #expect(activity.unavailable.isEmpty, "\(activity.unavailable)")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func loadSearchFiltersOnTheServer(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let token = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let label = "ccinn_it_Search_\(token)"
        _ = try await client.execute("INSERT INTO shop.events_latest WITH LABEL \(label) SELECT 0, '2024-06-01 00:00:00', 'online'")

        // Case-insensitive label fragment, scoped to the field, type and state.
        let found = try await client.searchLoads(LoadFilter(keyword: "SEARCH_\(token.uppercased())", field: .label, type: "INSERT", state: .finished))
        #expect(found.jobs.map(\.label) == [label])
        #expect(!found.filteredOnClient)
        #expect(try await client.searchLoads(LoadFilter(keyword: token, type: "STREAM_LOAD")).jobs.isEmpty)
        #expect(try await client.searchLoads(LoadFilter(keyword: token, field: .error)).jobs.isEmpty)

        // Statistics jobs (written every minute) are hidden unless their database is chosen.
        let all = try await client.searchLoads(LoadFilter(limit: 2_000))
        #expect(!all.jobs.contains { $0.database == "_statistics_" })
        let statistics = try await client.searchLoads(LoadFilter(database: "_statistics_", limit: 50))
        #expect(statistics.jobs.allSatisfy { $0.database == "_statistics_" })

        // History is readable by root on 3.3+ and merges without duplicates.
        let withHistory = try await client.searchLoads(LoadFilter(database: "shop", limit: 2_000), includeHistory: true)
        #expect(withHistory.historyError == nil)
        #expect(Set(withHistory.jobs.map(\.id)).count == withHistory.jobs.count)
        #expect(withHistory.jobs.contains { $0.label == label })
    }

    /// Formatted statements run and return exactly what the originals return.
    @Test(arguments: IntegrationEnvironment.targets)
    func formattedStatementsRunTheSame(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let statements = [
            "select o.city, count(*) n, sum(o.total) as total from shop.orders o where o.order_date between '2024-01-01' and '2024-06-30' and o.status in ('paid','shipped') group by o.city having count(*) > 0 order by total desc, o.city limit 5",
            "select c.customer_id, c.city, (select count(*) from shop.orders x where x.city = c.city) as orders, count(o.order_id) n from shop.customers c left join shop.orders o on o.city = c.city and o.total > 10 where c.customer_id < 20 group by c.customer_id, c.city order by c.customer_id",
            "with paid as (select * from shop.orders where status = 'paid'), cities as (select distinct city from paid) select case when count(*) > 10 then 'many' when count(*) > 0 then 'some' else 'none' end k, count(*) from cities",
            "select city, sum(total) over (partition by city order by order_date, order_id rows between unbounded preceding and current row) s from shop.orders order by city, order_date, order_id limit 10",
            "/* note */ select /*+ SET_VAR(query_timeout = 30) */ -1 * qty as q, `city` from shop.orders where -total < 0 order by order_id limit 3 -- end",
            "show partitions from shop.orders",
            "show create table shop.orders",
            "select * from shop.v_paid_orders order by 1 limit 3",
            // Review regressions: names the server accepts keep their case; touching tokens stay touching.
            "with `current` as (select 1 x) select * from current",
            "select a as interval, b rollup, c as current from (select 1 a, 2 b, 3 c) semi",
            "select 0xabc_flag, t.1abc from (select 7 as `0xabc_flag`, 8 as `1abc`) t",
            "select sum(qty) over (partition by city order by order_id rows between current row and unbounded following) s from shop.orders order by order_id limit 5",
            "select city, order_id from shop.orders order by city nulls last, order_id limit 5 offset 2",
            "select user(), year('2020-01-01'), quarter('2020-01-01'), date_add('2020-01-01', interval -1 day)",
        ]
        for statement in statements {
            let formatted = try #require(SQLFormatter.format(statement), "\(statement)")
            #expect(formatted != statement)
            let expected = try await client.execute(statement)
            let actual = try await client.execute(formatted)
            #expect(actual.columnNames == expected.columnNames, "\(formatted)")
            #expect(actual.rows == expected.rows, "\(formatted)")
        }
        // DDL: the formatted CREATE TABLE creates the same table.
        let name = "ccinn_fmt_\(UInt32.random(in: 0...UInt32.max))"
        let ddl = "create table shop.\(name) (id bigint not null comment 'id', name varchar(32), total decimal(12, 2)) duplicate key(id) distributed by hash(id) buckets 2 properties (\"replication_num\" = \"1\")"
        let formattedDDL = try #require(SQLFormatter.format(ddl))
        _ = try await client.execute(formattedDDL)
        let created = try await client.execute("SHOW CREATE TABLE shop.\(name)").rows.first?.last ?? nil
        _ = try await client.execute("DROP TABLE shop.\(name) FORCE")
        #expect(created?.contains("DUPLICATE KEY(`id`)") == true)
        #expect(created?.contains("DISTRIBUTED BY HASH(`id`) BUCKETS 2") == true)
    }

    /// Statements whose keyword-named names once changed meaning when formatted: raw and formatted must behave the
    /// same (the same rows, or both rejected where a version does not accept the name).
    @Test(arguments: IntegrationEnvironment.targets)
    func keywordNamedNamesBehaveTheSameFormatted(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let statements = [
            "select case when 1=1 then end.a else 0 end from (select 5 a) end, (select 6 a) `END`",
            "select minus.x from (select 1 a) minus (x)",
            "select except.x from (select 1 a) except (x)",
            "select current.a, end.a from (select 1 a) current, (select 2 a) end",
            "select case when end.a > 0 then minus.a else end.a end from (select 3 a) end, (select 4 a) minus",
            "select 1 a minus select 2",
            "select 1 a minus (select 2)",
            "with end as (select 5 a), `END` as (select 6 a) select case when 1=1 then 1 else view end x, a from (select 1 view) t1, end",
            "with end as (select 5 a), `END` as (select 6 a) select case when 1=1 then 1 else overwrite end x, a from (select 1 overwrite) t1, end",
            "select [end.a] from (select 1 a) end",
            "with end as (select 7 a) select end.a from end",
            "select * from (select 1 a) t, unnest([1, 2]) minus(v) order by v",
            "select * from (select 1 a) t, unnest([1, 2]) except(v) order by v",
            "select case when 1=1 then 1.5 end, end.a from (select 5 a) end, (select 6 a) `END`",
            "with `end` as (select 5 a), `END` as (select 6 a) select case when 1=1 then named_struct('a', 1) end.a x, a from (select 0 z) t1, end",
            "select case when 1=1 then named_struct('a', 5) end.a",
        ]
        // The server upper-cases per character: `exiſts` is EXISTS there. The formatter refuses such words.
        let folded = "select count(*) from (select 1 a) t where exiſts (select 1)"
        let value = try await client.execute(folded).rows.first?.first ?? nil
        #expect(value == "1", "the server reads exiſts as EXISTS")
        for refused in [folded, "create table if not exiſts properties (k int) duplicate key(k) distributed by hash(k) buckets 1 properties ('replication_num' = '1')"] {
            #expect(SQLFormatter.format(refused) == nil, "\(refused)")
        }
        for statement in statements {
            let formatted = try #require(SQLFormatter.format(statement), "\(statement)")
            let raw = await outcome(client, statement)
            let actual = await outcome(client, formatted)
            #expect(raw == actual, "\(statement)\n→ \(formatted)")
        }
    }

    /// The lexer ends number-like words where the server does. The server's reading of `SELECT <text>` shows in the
    /// result: one column labelled with the trailing word = number + alias; "Column '<text>' cannot be resolved" = one
    /// identifier; any other result = one literal. A trailing END is read inside a CASE (closed = a separate END).
    /// Wherever the two disagree, the formatter must refuse.
    @Test(arguments: IntegrationEnvironment.targets)
    func lexerEndsNumbersWhereTheServerDoes(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let prefixes = ["1", "12", "1.", "1.5", ".5", "1e2", "1E2", "1e+2", "1e-2", "1.5e2", "1.e2", "0x1F", "0x", "1_0"]
        let words = ["x", "abc", "e", "e2", "E5", "_y", "$z"]
        var disagreements: [String] = []
        func check(_ sql: String, _ text: String, server: [String]) {
            let lexer = SQLLexer(text)
            let ours = lexer.tokens().map { lexer.text(of: $0) }
            guard ours != server else { return }
            disagreements.append("\(text): server \(server), lexer \(ours)")
            #expect(SQLFormatter.format(sql) == nil, "\(sql): the lexer disagrees with the server, so the formatter must refuse")
        }
        for prefix in prefixes {
            for word in words {
                let text = prefix + word
                let sql = "SELECT \(text)"
                do {
                    let result = try await client.execute(sql)
                    if result.columnNames.count == 1, let label = result.columnNames.first, !label.isEmpty,
                       label.count < text.count, text.lowercased().hasSuffix(label.lowercased()) {
                        check(sql, text, server: [String(text.dropLast(label.count)), String(text.suffix(label.count))])
                    } else {
                        check(sql, text, server: [text])
                    }
                } catch {
                    let message = ((error as? StarRocksError)?.message ?? "\(error)").lowercased()
                    // "Column '<text>' cannot be resolved" or "Unexpected input '<text>'": one token.
                    if message.contains("'\(text.lowercased())'"), message.contains("cannot be resolved") || message.contains("unexpected input") {
                        check(sql, text, server: [text])
                    } else {
                        disagreements.append("\(text): unexpected server answer \(message)")
                    }
                }
            }
            let text = prefix + "end"
            let sql = "SELECT CASE WHEN TRUE THEN \(text)"
            let closed = (try? await client.execute(sql)) != nil
            check(sql, text, server: closed ? [prefix, "end"] : [text])
        }
        #expect(disagreements.isEmpty, "\(disagreements)")
    }

    /// `$$` per version: StarRocks 4.1 reads `$$ … $$` as one token, 3.3 reads `$$a` as a name. The formatter's version
    /// rule turns blocks on exactly where the server reads them; on 4.1 a formatted inline UDF keeps its body byte for
    /// byte and is accepted, and on 3.3 the formatter refuses.
    @Test(arguments: IntegrationEnvironment.targets)
    func dollarQuotedBlocksFollowTheServerVersion(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let version = try #require(client.serverInfo.releaseVersion, "current_version() answered")
        let blocks = SQLFormatOptions.dollarQuotedBlocksSupported(major: version.major, minor: version.minor)
        // The server's reading of `$$a b ( $$`: one token ("Unexpected input '$$a b ( $$'") or several.
        var serverReadsOneToken = false
        do {
            _ = try await client.execute("SELECT $$a b ( $$")
        } catch {
            serverReadsOneToken = ((error as? StarRocksError)?.message ?? "\(error)").contains("'$$a b ( $$'")
        }
        #expect(serverReadsOneToken == blocks, "the version rule matches the server")
        let lexer = SQLLexer("$$a b ( $$", dollarQuotedBlocks: blocks)
        #expect((lexer.tokens().count == 1) == serverReadsOneToken)

        let body = "\ndef inc(x):\n    if x is None:\n        return None\n    return True if x else False  # ( unbalanced\n"
        let name = "ccinn_fmt_udf_\(UInt32.random(in: 0...UInt32.max))"
        let sql = "create function shop.\(name)(int) returns boolean properties (\"symbol\" = \"inc\", \"type\" = \"Python\", \"file\" = \"inline\") as $$\(body)$$"
        let formatted = SQLFormatter.format(sql, options: SQLFormatOptions(dollarQuotedBlocks: blocks))
        guard blocks else {
            #expect(formatted == nil, "a server that does not read blocks: refused")
            return
        }
        let text = try #require(formatted)
        #expect(text.hasSuffix("AS $$\(body)$$"), "the body is byte-identical")
        _ = try await client.execute(text)
        _ = try await client.execute("DROP FUNCTION shop.\(name)(INT)")
    }

    private enum Outcome: Equatable {
        case rows(columns: [String], rows: [[String?]])
        case rejected
    }

    private func outcome(_ client: StarRocksClient, _ sql: String) async -> Outcome {
        do {
            let result = try await client.execute(sql)
            return .rows(columns: result.columnNames, rows: result.rows)
        } catch {
            return .rejected
        }
    }

    /// Every word the formatter may recase anywhere is rejected as a table name and as an alias, so recasing it can
    /// never name another table. A StarRocks release that frees one of these words fails here.
    @Test(arguments: IntegrationEnvironment.targets)
    func caseSafeKeywordsAreNeverNames(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        var accepted: [String] = []
        for word in SQLFormatter.caseSafeKeywords.sorted() {
            let name = word.lowercased()
            for probe in ["SELECT 1 FROM shop.\(name)", "SELECT 1 AS \(name)"] {
                do {
                    _ = try await client.execute(probe)
                    accepted.append(probe)
                } catch {
                    let message = (error as? StarRocksError)?.message ?? "\(error)"
                    if !message.lowercased().contains("syntax error") { accepted.append("\(probe) → \(message)") }
                }
            }
        }
        #expect(accepted.isEmpty, "accepted as names: \(accepted)")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func clusterConfiguration(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }

        let frontend = try await client.frontendConfig()
        let keep = try #require(frontend.first { $0.name == "label_keep_max_second" })
        #expect(keep.isMutable == true)
        #expect(keep.type == "int")
        #expect(ConfigStatement.edit(for: keep)?.contains("ADMIN SET FRONTEND CONFIG ('label_keep_max_second' = ") == true)

        let backend = try await client.backendConfig()
        let workers = try #require(backend.first { $0.name == "alter_tablet_worker_count" })
        #expect(workers.defaultValue != nil)
        #expect(!workers.nodes.isEmpty)
        #expect(workers.nodes.allSatisfy { $0.host != nil }, "node ids map to hosts")
        #expect(Set(backend.map(\.id)).count == backend.count, "one row per name")

        // A changed global variable is reported as modified, then restored.
        let before = try #require(try await client.variables().first { $0.name == "query_timeout" })
        let original = try #require(before.value)
        #expect(before.defaultValue == "300")
        _ = try await client.execute("SET GLOBAL query_timeout = 301")
        let changed: ConfigItem?
        do {
            changed = try await client.variables().first { $0.name == "query_timeout" }
        } catch {
            _ = try? await client.execute("SET GLOBAL query_timeout = \(original)")
            throw error
        }
        _ = try await client.execute("SET GLOBAL query_timeout = \(original)")
        #expect(changed?.value == "301")
        #expect(changed?.isModified == true)
        // Stock clusters must not look modified because of encodings or placeholders.
        let stock = try await client.variables()
        #expect(stock.first { $0.name == "sql_mode" }?.isModified != true)
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func configurationPrivilegesDegradePerScope(target: IntegrationEnvironment.Target) async throws {
        // `ccinn` holds the root role but it is not activated by default: no OPERATE on SYSTEM.
        let client = try await IntegrationEnvironment.client(target, user: "ccinn", password: "ccinn-secret")
        defer { Task { await client.close() } }
        #expect(try await !client.variables().isEmpty)
        await #expect { _ = try await client.frontendConfig() } throws: { ($0 as? StarRocksError)?.message.contains("OPERATE") == true }
        await #expect { _ = try await client.backendConfig() } throws: { ($0 as? StarRocksError)?.message.contains("OPERATE") == true }
        let loads = try await client.searchLoads(LoadFilter(), includeHistory: true)
        #expect(loads.historyError?.contains("loads_history") == true)
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func sessionKeepsContextAndCancels(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let session = client.openSession()
        _ = try await session.run("USE shop")
        #expect(await session.database == "shop")
        #expect(try await session.run("SELECT COUNT(*) FROM customers").last?.scalar == "500")

        // A long-running statement is stopped by KILL QUERY; the session connection survives.
        let longQuery = "SELECT COUNT(*) FROM TABLE(generate_series(1, 2000000000)) a"
        let running = Task { try await session.run(longQuery) }
        try await Task.sleep(for: .milliseconds(800))
        let started = ContinuousClock.now
        await session.cancel(graceSeconds: 5)
        await #expect { _ = try await running.value } throws: { _ in true }
        #expect(ContinuousClock.now - started < .seconds(6))
        #expect(try await session.run("SELECT 7").last?.scalar == "7")
        await session.close()
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func cancellingAPooledQueryKillsItServerSide(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        defer { Task { await client.close() } }
        let task = Task { try await client.query("SELECT COUNT(*) FROM TABLE(generate_series(1, 2000000000)) a /* ccinn-cancel-probe */") }
        try await Task.sleep(for: .milliseconds(800))
        task.cancel()
        await #expect { _ = try await task.value } throws: { ($0 as? StarRocksError)?.kind == .cancelled }
        var stillRunning = true
        for _ in 0..<20 {
            let processes = try await client.processList()
            stillRunning = processes.contains { $0.statement?.contains("ccinn-cancel-probe") == true && $0.isRunningStatement }
            if !stillRunning { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(!stillRunning)
    }
}
