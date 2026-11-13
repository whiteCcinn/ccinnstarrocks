import Foundation
import Testing
@testable import StarRocksKit

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
        let loads = try await client.loads(database: "shop")
        #expect(loads.contains { $0.state == "FINISHED" && $0.sinkRows == 20000 })
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
