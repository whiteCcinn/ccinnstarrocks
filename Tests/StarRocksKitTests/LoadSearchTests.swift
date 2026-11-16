import Foundation
import Testing
@testable import StarRocksKit

private func records(_ columns: [String], _ rows: [[String?]]) -> [Record] {
    let lookup = ColumnLookup(names: columns)
    return rows.map { Record(values: $0, lookup: lookup) }
}

/// Columns of `information_schema.loads`, identical on StarRocks 3.3 and 4.1.
private let loadColumns = ["ID", "LABEL", "PROFILE_ID", "DB_NAME", "TABLE_NAME", "USER", "WAREHOUSE", "STATE", "PROGRESS", "TYPE", "PRIORITY",
                           "SCAN_ROWS", "SCAN_BYTES", "FILTERED_ROWS", "UNSELECTED_ROWS", "SINK_ROWS", "RUNTIME_DETAILS", "CREATE_TIME",
                           "LOAD_START_TIME", "LOAD_COMMIT_TIME", "LOAD_FINISH_TIME", "PROPERTIES", "ERROR_MSG", "TRACKING_SQL",
                           "REJECTED_RECORD_PATH", "JOB_ID"]

/// A Stream Load row recorded from StarRocks 4.1 (filtered rows made it fail).
private let streamLoadRow: [String?] = [
    "10639", "probe_bad_1794840585", nil, "shop", "sl_probe", "root", "", "CANCELLED", "0%", "STREAM_LOAD", "NORMAL",
    "0", "51", "1", "0", "1",
    #"{"begin_txn_time_ms": 0, "client_ip": "127.0.0.1", "load_id": "d548c408-a44c-7d63-dd2e-62a8a331d19a", "plan_time_ms": 1, "receive_data_time_ms": 0, "txn_error_msg": "", "txn_id": 31}"#,
    "2026-11-16 14:49:45", nil, nil, "2026-11-16 14:49:45", #"{"timeout": 600}"#, "too many filtered rows",
    "select tracking_log from information_schema.load_tracking_logs where job_id=10639", nil, "10639",
]

private func job(id: String, label: String, database: String? = "shop", table: String? = "orders", state: String = "FINISHED",
                 type: String? = "INSERT", created: String, error: String? = nil, user: String? = "root") -> LoadJob {
    let row: [String?] = [id, label, nil, database, table, user, nil, state, nil, type, nil, nil, nil, nil, nil, nil, nil, created,
                          nil, nil, nil, nil, error, nil, nil, id]
    return LoadJob(record: records(loadColumns, [row])[0])
}

@Suite("Load filter")
struct LoadFilterTests {
    @Test func defaultFilterHidesInternalStatisticsJobs() {
        let filter = LoadFilter()
        #expect(filter.predicates() == ["(DB_NAME IS NULL OR DB_NAME NOT IN ('_statistics_'))"])
        #expect(filter.sql(from: "information_schema.loads")
            == "SELECT * FROM information_schema.loads WHERE (DB_NAME IS NULL OR DB_NAME NOT IN ('_statistics_')) ORDER BY CREATE_TIME DESC LIMIT 500")
    }

    @Test func anExplicitDatabaseWinsOverTheSystemExclusion() {
        #expect(LoadFilter(database: "_statistics_").predicates() == ["DB_NAME = '_statistics_'"])
        #expect(LoadFilter(includeSystemDatabases: true).predicates().isEmpty)
    }

    @Test func keywordIsACaseInsensitiveSubstringOfTheChosenField() {
        let filter = LoadFilter(keyword: "  20261101_b7 ", field: .label)
        #expect(filter.predicates().last == "INSTR(LOWER(LABEL), LOWER('20261101_b7')) > 0")
    }

    @Test func anyFieldSearchesEveryTextColumnAndTheJobID() {
        let predicate = LoadFilter(keyword: "x", field: .any).predicates().last ?? ""
        for column in ["LABEL", "DB_NAME", "TABLE_NAME", "STATE", "TYPE", "ERROR_MSG", "USER", "CAST(ID AS VARCHAR)"] {
            #expect(predicate.contains("INSTR(LOWER(\(column)), LOWER('x')) > 0"), "\(column)")
        }
        #expect(predicate.hasPrefix("(") && predicate.hasSuffix(")"))
        #expect(predicate.components(separatedBy: " OR ").count == 8)
    }

    @Test func keywordsAreLiteralsNotPatterns() {
        let predicate = LoadFilter(keyword: #"50%_off\'x"#, field: .label).predicates().last
        #expect(predicate == #"INSTR(LOWER(LABEL), LOWER('50%_off\\\'x')) > 0"#)
    }

    @Test func typeAndStatePredicates() {
        let filter = LoadFilter(database: "shop", type: "STREAM_LOAD", state: .active)
        #expect(filter.predicates() == ["DB_NAME = 'shop'", "STATE NOT IN ('FINISHED', 'CANCELLED')", "TYPE = 'STREAM_LOAD'"])
        #expect(LoadFilter(state: .cancelled, includeSystemDatabases: true).predicates() == ["STATE = 'CANCELLED'"])
        #expect(LoadFilter(state: .finished, includeSystemDatabases: true).predicates() == ["STATE = 'FINISHED'"])
    }

    @Test func retryDropsOnlyTheRefinements() {
        let filter = LoadFilter(keyword: "abc", database: "shop", type: "BROKER", state: .active)
        #expect(filter.hasRefinements)
        #expect(filter.predicates(includingRefinements: false) == ["DB_NAME = 'shop'", "STATE NOT IN ('FINISHED', 'CANCELLED')"])
        #expect(!LoadFilter(keyword: "   ").hasRefinements)
    }

    @Test func limitIsClamped() {
        #expect(LoadFilter(limit: 0).sql(from: "t").hasSuffix("LIMIT 1"))
        #expect(LoadFilter(limit: Int.max).sql(from: "t").hasSuffix("LIMIT 10000"))
    }

    @Test func clientMatchingMirrorsTheServer() {
        let stream = LoadJob(record: records(loadColumns, [streamLoadRow])[0])
        #expect(LoadFilter(keyword: "PROBE_BAD").matches(stream))
        #expect(LoadFilter(keyword: "filtered rows", field: .error).matches(stream))
        #expect(LoadFilter(keyword: "10639", field: .jobID).matches(stream))
        #expect(!LoadFilter(keyword: "10639", field: .label).matches(stream))
        #expect(LoadFilter(type: "stream_load").matches(stream))
        #expect(!LoadFilter(type: "BROKER").matches(stream))
        #expect(LoadFilter(state: .cancelled).matches(stream))
        #expect(!LoadFilter(state: .active).matches(stream))
        #expect(!LoadFilter(database: "other").matches(stream))
        let statisticsJob = job(id: "1", label: "insert_x", database: "_statistics_", created: "2026-11-16 10:00:00")
        #expect(!LoadFilter().matches(statisticsJob))
        #expect(LoadFilter(database: "_statistics_").matches(statisticsJob))
        #expect(LoadFilter(keyword: "").matches(stream))
    }
}

@Suite("Load jobs")
struct LoadJobTests {
    @Test func parsesAStreamLoadRow() throws {
        let stream = LoadJob(record: records(loadColumns, [streamLoadRow])[0])
        #expect(stream.jobID == "10639")
        #expect(stream.isStreamLoad)
        #expect(stream.scanBytes == 51)
        #expect(stream.unselectedRows == 0)
        #expect(stream.source == .live)
        #expect(stream.trackingSQL?.hasPrefix("select tracking_log") == true)
        let details = LoadJob.keyValues(json: stream.runtimeDetails)
        #expect(details.map(\.key) == ["begin_txn_time_ms", "client_ip", "load_id", "plan_time_ms", "receive_data_time_ms", "txn_error_msg", "txn_id"])
        #expect(details.first { $0.key == "client_ip" }?.value == "127.0.0.1")
        #expect(details.first { $0.key == "txn_id" }?.value == "31")
        #expect(LoadJob.keyValues(json: stream.properties) == [LoadJob.KeyValue(key: "timeout", value: "600")])
    }

    @Test func keyValuesTolerateJunkAndNesting() {
        #expect(LoadJob.keyValues(json: nil).isEmpty)
        #expect(LoadJob.keyValues(json: "not json").isEmpty)
        #expect(LoadJob.keyValues(json: "[1, 2]").isEmpty)
        let nested = LoadJob.keyValues(json: #"{"b": {"x": 1}, "a": [true, null], "c": false}"#)
        #expect(nested.map(\.key) == ["a", "b", "c"])
        #expect(nested[0].value == "[true,null]")
        #expect(nested[1].value == #"{"x":1}"#)
        #expect(nested[2].value == "false")
    }

    @Test(arguments: [("LOADING", true), ("PENDING", true), ("BEFORE_LOAD", true), ("COMMITED", true), ("PREPARED", true),
                      ("FINISHED", false), ("CANCELLED", false), ("cancelled", false)])
    func activeMeansNotTerminal(state: String, active: Bool) {
        #expect(job(id: "1", label: "l", state: state, created: "x").isActive == active)
    }

    @Test func onlyCancellableTypesOfferCancel() {
        #expect(job(id: "1", label: "l", state: "LOADING", type: "BROKER", created: "x").canCancel)
        #expect(job(id: "1", label: "l", state: "LOADING", type: "INSERT", created: "x").canCancel)
        #expect(!job(id: "1", label: "l", state: "LOADING", type: "STREAM_LOAD", created: "x").canCancel)
        #expect(!job(id: "1", label: "l", state: "LOADING", type: "ROUTINE_LOAD", created: "x").canCancel)
        #expect(!job(id: "1", label: "l", state: "FINISHED", type: "BROKER", created: "x").canCancel)
    }

    @Test func typeDisplayNames() {
        #expect(LoadJob.displayName(forType: "STREAM_LOAD") == "Stream Load")
        #expect(LoadJob.displayName(forType: "BROKER") == "Broker Load")
        #expect(LoadJob.displayName(forType: "INSERT") == "INSERT")
        #expect(LoadJob.displayName(forType: "SPARK") == "Spark Load")
        #expect(LoadJob.displayName(forType: "SOMETHING_NEW") == "SOMETHING_NEW")
        #expect(LoadJob.displayName(forType: nil) == "")
    }
}

@Suite("Load search merge")
struct LoadSearchMergeTests {
    @Test func dedupesPrefersLiveAndSortsNewestFirst() {
        let live = [job(id: "3", label: "c", state: "LOADING", created: "2026-11-16 10:03:00"),
                    job(id: "2", label: "b", state: "LOADING", created: "2026-11-16 10:02:00")]
        var history = [job(id: "2", label: "b", state: "FINISHED", created: "2026-11-16 10:02:00"),
                       job(id: "1", label: "a", created: "2026-11-15 09:00:00"),
                       job(id: "1", label: "a", created: "2026-11-15 09:00:00")]
        for index in history.indices { history[index].source = .history }
        let merged = LoadSearchResult.merge(live: live, history: history, limit: 10)
        #expect(merged.jobs.map(\.jobID) == ["3", "2", "1"])
        #expect(merged.jobs[1].state == "LOADING", "the live row wins")
        #expect(merged.jobs[2].source == .history)
        #expect(!merged.reachedLimit)
        #expect(Set(merged.jobs.map(\.id)).count == merged.jobs.count)
    }

    @Test func limitAndReachedLimit() {
        let live = (0..<5).map { job(id: "\($0)", label: "l\($0)", created: "2026-11-16 10:0\($0):00") }
        let merged = LoadSearchResult.merge(live: live, history: [], limit: 3)
        #expect(merged.jobs.map(\.jobID) == ["4", "3", "2"])
        #expect(merged.reachedLimit)
        #expect(LoadSearchResult.merge(live: Array(live.prefix(3)), history: [], limit: 3).reachedLimit)
    }

    @Test func identifiersCannotCollide() {
        let a = job(id: "1", label: "23_x", created: "2026-11-16 10:00:00")
        let b = job(id: "12", label: "3_x", created: "2026-11-16 10:00:00")
        #expect(a.id != b.id)
        #expect(LoadSearchResult.merge(live: [a, b], history: [], limit: 10).jobs.count == 2)
    }

    @Test func jobsWithoutIDsAreKeyedByLabel() {
        let a = job(id: "", label: "same", created: "2026-11-16 10:00:00")
        let merged = LoadSearchResult.merge(live: [a, a], history: [], limit: 10)
        #expect(merged.jobs.count == 1)
    }
}

@Suite("Load search against a server")
struct LoadSearchClientTests {
    private func connect(_ cluster: FakeCluster) async throws -> StarRocksClient {
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", connectTimeout: 2)
        return try await StarRocksClient.connect(configuration, poolSize: 1, transportFactory: cluster.transportFactory)
    }

    private static func loadRows(_ rows: [[String?]]) -> [[UInt8]] {
        FakeMySQLServer.resultSet(loadColumns.map { ($0, .varString) }, rows)
    }

    private static let olderRow: [String?] = ["7", "orders_20261101_b7", nil, "shop", "orders", "etl", nil, "FINISHED", "100%", "BROKER", nil,
                                              "10", "100", "0", "0", "10", nil, "2026-11-01 01:00:00", nil, nil, nil, nil, nil, nil, nil, "7"]

    @Test func filtersOnTheServerAndIncludesHistory() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("information_schema.loads") { return .packets(Self.loadRows([streamLoadRow])) }
            if sql.contains("_statistics_.loads_history") { return .packets(Self.loadRows([Self.olderRow])) }
            return .packets([FakeMySQLServer.ok()])
        }
        let client = try await connect(cluster)
        let result = try await client.searchLoads(LoadFilter(keyword: "o"), includeHistory: true)
        #expect(result.jobs.map(\.jobID) == ["10639", "7"])
        #expect(result.jobs.last?.source == .history)
        #expect(!result.filteredOnClient)
        #expect(result.historyError == nil)
        let statements = cluster.statements.filter { $0.contains("loads") }
        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.contains("INSTR(LOWER(LABEL), LOWER('o')) > 0") })
        await client.close()
    }

    @Test func historyFailureIsReportedNotThrown() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("information_schema.loads") { return .packets(Self.loadRows([streamLoadRow])) }
            if sql.contains("loads_history") { return .packets([FakeMySQLServer.error(code: 5203, message: "Access denied; you need the SELECT privilege")]) }
            return .packets([FakeMySQLServer.ok()])
        }
        let client = try await connect(cluster)
        let result = try await client.searchLoads(LoadFilter(), includeHistory: true)
        #expect(result.jobs.count == 1)
        #expect(result.historyError?.contains("Access denied") == true)
        await client.close()
    }

    @Test func rejectedRefinementsAreRetriedAndAppliedOnTheClient() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("INSTR(") { return .packets([FakeMySQLServer.error(code: 1064, message: "Column 'USER' cannot be resolved")]) }
            if sql.contains("information_schema.loads") { return .packets(Self.loadRows([streamLoadRow, Self.olderRow])) }
            return .packets([FakeMySQLServer.ok()])
        }
        let client = try await connect(cluster)
        let result = try await client.searchLoads(LoadFilter(keyword: "b7", field: .label))
        #expect(result.jobs.map(\.jobID) == ["7"])
        #expect(result.filteredOnClient)
        await client.close()
    }

    @Test func showLoadFallbackForAChosenDatabase() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("information_schema.loads") { return .packets([FakeMySQLServer.error(code: 1064, message: "Unknown table 'loads'")]) }
            if sql.hasPrefix("SHOW LOAD FROM `shop`") {
                return .packets(FakeMySQLServer.resultSet([("JobId", .varString), ("Label", .varString), ("State", .varString), ("Type", .varString)],
                                                          [["1", "old_a", "FINISHED", "BROKER"], ["2", "new_b", "CANCELLED", "BROKER"]]))
            }
            return .packets([FakeMySQLServer.ok()])
        }
        let client = try await connect(cluster)
        let result = try await client.searchLoads(LoadFilter(keyword: "new", database: "shop"))
        #expect(result.jobs.map(\.label) == ["new_b"])
        #expect(result.jobs.first?.database == "shop")
        #expect(result.filteredOnClient)
        let all = try await client.loads(database: "shop")
        #expect(all.map(\.label) == ["new_b", "old_a"], "newest (last listed) first")
        await client.close()
    }

    /// StarRocks 3.1/3.2: `DATABASE_NAME` instead of `DB_NAME`, and no `ID`, `TABLE_NAME` or `USER` columns.
    private static let legacyColumns = ["JOB_ID", "LABEL", "DATABASE_NAME", "STATE", "PROGRESS", "TYPE", "PRIORITY", "SCAN_ROWS", "FILTERED_ROWS",
                                        "UNSELECTED_ROWS", "SINK_ROWS", "CREATE_TIME", "LOAD_START_TIME", "LOAD_FINISH_TIME", "ERROR_MSG", "TRACKING_SQL"]

    private static func legacyServer(_ sql: String) -> FakeMySQLServer.Reply {
        guard sql.contains("information_schema.loads") else { return .packets([FakeMySQLServer.ok()]) }
        for column in ["DB_NAME", "CAST(ID", "USER", "TABLE_NAME"] where sql.contains(column) {
            return .packets([FakeMySQLServer.error(code: 1064, message: "Getting analyzing error. Detail message: Column '\(column)' cannot be resolved.")])
        }
        return .packets(FakeMySQLServer.resultSet(legacyColumns.map { ($0, .varString) }, [
            ["11", "nightly_orders", "shop", "LOADING", "40%", "BROKER", "NORMAL", "0", "0", "0", "0", "2026-11-16 10:00:00", nil, nil, nil, nil],
            ["10", "insert_stats", "_statistics_", "FINISHED", "100%", "INSERT", "NORMAL", "0", "0", "0", "1", "2026-11-16 09:59:00", nil, nil, nil, nil],
        ]))
    }

    @Test func olderVersionsWithoutDBNameStillListLoads() async throws {
        let cluster = FakeCluster { Self.legacyServer($0) }
        let client = try await connect(cluster)
        let all = try await client.searchLoads(LoadFilter())
        #expect(all.jobs.map(\.label) == ["nightly_orders"], "statistics jobs are filtered on the client")
        #expect(all.jobs.first?.database == "shop", "DATABASE_NAME is read")
        #expect(all.jobs.first?.canCancel == true)
        let active = try await client.loads(activeOnly: true)
        #expect(active.map(\.label) == ["nightly_orders"])
        let searched = try await client.searchLoads(LoadFilter(keyword: "NIGHTLY", field: .label))
        #expect(searched.jobs.map(\.label) == ["nightly_orders"])
        #expect(searched.filteredOnClient)
        await client.close()
    }

    @Test func historyTimeoutsAndNetworkErrorsAreNotices() async throws {
        let cluster = FakeCluster { sql in
            if sql.contains("information_schema.loads") { return .packets(Self.loadRows([streamLoadRow])) }
            if sql.contains("loads_history") { return .hang }
            return .packets([FakeMySQLServer.ok()])
        }
        let configuration = ConnectionConfiguration(endpoint: Endpoint(host: "fake"), username: "root", connectTimeout: 2)
        let client = try await StarRocksClient.connect(configuration, poolSize: 2, transportFactory: cluster.transportFactory)
        let result = try await client.searchLoads(LoadFilter(), includeHistory: true, historyTimeout: 0.3)
        #expect(result.jobs.map(\.jobID) == ["10639"])
        #expect(result.historyError != nil)
        await client.close()
    }

    @Test func errorsWithoutAFallbackPropagate() async throws {
        let cluster = FakeCluster { _ in .packets([FakeMySQLServer.error(code: 1064, message: "boom")]) }
        let client = try await connect(cluster)
        await #expect { _ = try await client.searchLoads(LoadFilter()) } throws: { ($0 as? StarRocksError)?.message == "boom" }
        await client.close()
    }
}
