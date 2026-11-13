import Foundation
import Testing
@testable import StarRocksKit

private func records(_ columns: [String], _ rows: [[String?]]) -> [Record] {
    let lookup = ColumnLookup(names: columns)
    return rows.map { Record(values: $0, lookup: lookup) }
}

@Suite("Object classification")
struct ObjectClassifierTests {
    // Shapes recorded from StarRocks 3.3 (`ROLLUP`, view engine "") and 4.1 (`SYNC`, view engine "VIEW").
    static let tables: [ObjectClassifier.TableRow] = [
        .init(name: "orders", tableType: "BASE TABLE", engine: "StarRocks"),
        .init(name: "customers", tableType: "BASE TABLE", engine: "StarRocks"),
        .init(name: "v_paid_orders", tableType: "VIEW", engine: nil),
        .init(name: "mv_city_daily", tableType: "VIEW", engine: "StarRocks"),
        .init(name: "mysql_ext", tableType: "BASE TABLE", engine: "MySQL"),
    ]

    static func configs(viewEngine: String) -> [Record] {
        records(["TABLE_NAME", "TABLE_ENGINE", "TABLE_MODEL", "PRIMARY_KEY", "PARTITION_KEY", "DISTRIBUTE_KEY", "DISTRIBUTE_BUCKET", "SORT_KEY", "PROPERTIES"], [
            ["orders", "OLAP", "DUP_KEYS", "", "`order_date`", "`order_id`", "4", "`order_id`, `order_date`", #"{"replication_num":"1"}"#],
            ["customers", "OLAP", "PRIMARY_KEYS", "`customer_id`", "", "`customer_id`", "2", "`customer_id`", "{}"],
            ["v_paid_orders", viewEngine, "", "", "", "", "0", "", ""],
            ["mv_city_daily", "MATERIALIZED_VIEW", "DUP_KEYS", "", "", "`city`", "2", "`order_date`, `city`", "{}"],
            ["mysql_ext", "MYSQL", "", "", "", "", "0", "", ""],
        ])
    }

    static func materializedViews(syncType: String) -> [Record] {
        records(["TABLE_NAME", "REFRESH_TYPE", "IS_ACTIVE", "TASK_NAME", "LAST_REFRESH_STATE", "TABLE_ROWS", "MATERIALIZED_VIEW_DEFINITION"], [
            ["mv_city_daily", "ASYNC", "true", "mv-10460", "SUCCESS", "1975", "CREATE MATERIALIZED VIEW ..."],
            ["mv_orders_by_channel", syncType, "true", "", "null", "0", "CREATE MATERIALIZED VIEW mv_orders_by_channel ASSELECT channel FROM orders GROUP BY channel"],
        ])
    }

    @Test(arguments: [("", "ROLLUP"), ("VIEW", "SYNC")])
    func classifiesAcrossVersions(viewEngine: String, syncType: String) {
        let rollups = records(["TableName", "RollupIndexName", "State"], [["orders", "mv_orders_by_channel", "FINISHED"]])
        let objects = ObjectClassifier.classify(catalog: "default_catalog", database: "shop", tables: Self.tables,
                                                configs: Self.configs(viewEngine: viewEngine),
                                                materializedViews: Self.materializedViews(syncType: syncType), rollupJobs: rollups)
        let byName = Dictionary(uniqueKeysWithValues: objects.map { ($0.name, $0) })
        #expect(byName["orders"]?.kind == .table)
        #expect(byName["orders"]?.model == .duplicate)
        #expect(byName["orders"]?.partitionKey == "order_date")
        #expect(byName["orders"]?.properties["replication_num"] == "1")
        #expect(byName["customers"]?.primaryKey == "customer_id")
        #expect(byName["v_paid_orders"]?.kind == .view)
        #expect(byName["mv_city_daily"]?.kind == .asyncMaterializedView)
        #expect(byName["mv_city_daily"]?.rowCount == 1975)
        #expect(byName["mv_city_daily"]?.materializedView?.health == .healthy)
        #expect(byName["mv_orders_by_channel"]?.kind == .syncMaterializedView)
        #expect(byName["mv_orders_by_channel"]?.baseTable == "orders")
        #expect(byName["mysql_ext"]?.kind == .externalTable)
        // Grouped: tables, async MVs, sync MVs, views, external.
        #expect(objects.map(\.kind) == objects.map(\.kind).sorted())
    }

    @Test func syncBaseTableFallsBackToDefinition() {
        let objects = ObjectClassifier.classify(catalog: "default_catalog", database: "shop", tables: [], configs: [],
                                                materializedViews: Self.materializedViews(syncType: "ROLLUP"), rollupJobs: [])
        #expect(objects.first { $0.kind == .syncMaterializedView }?.baseTable == "orders")
    }

    @Test func externalCatalogObjectsAreExternal() {
        let objects = ObjectClassifier.classify(catalog: "hive", database: "logs", tables: [.init(name: "events", tableType: "BASE TABLE")],
                                                configs: [], materializedViews: [], rollupJobs: [])
        #expect(objects.first?.kind == .externalTable)
        #expect(objects.first?.qualifiedName == "`hive`.`logs`.`events`")
    }

    @Test func materializedViewHealth() {
        var status = MaterializedViewStatus(refreshType: "ASYNC", isActive: true)
        #expect(status.health == .neverRefreshed)
        status.lastRefreshState = "FAILED"
        #expect(status.health == .failed)
        status.lastRefreshState = "RUNNING"
        #expect(status.health == .refreshing)
        status.isActive = false
        #expect(status.health == .inactive)
        #expect(MaterializedViewStatus(refreshType: "SYNC", isActive: true).health == .maintainedSynchronously)
    }

    @Test func tableModelBadges() {
        #expect(TableModel(serverValue: "PRIMARY_KEYS")?.badge == "PK")
        #expect(TableModel(serverValue: "dup_keys") == .duplicate)
        #expect(TableModel(serverValue: "") == nil)
    }
}

@Suite("Insight parsing")
struct InsightParsingTests {
    @Test(arguments: [("0B", 0 as Int64?), ("403.652 KB", 413_340), ("1.5GB", 1_610_612_736), ("850B", 850), ("0.000 B", 0), ("12", 12), ("n/a", nil), ("", nil)])
    func parsesByteSizes(text: String, bytes: Int64?) {
        #expect(ByteSize.parse(text) == bytes)
    }

    @Test func parsesRangeBounds() {
        let bounds = PartitionBounds.parse("[types: [DATE]; keys: [2024-01-01]; ..types: [DATE]; keys: [2024-02-01]; )")
        #expect(bounds.lower == "2024-01-01")
        #expect(bounds.upper == "2024-02-01")
        #expect(bounds.summary == "[2024-01-01, 2024-02-01)")
        #expect(PartitionBounds.parse("(('beijing'), ('shanghai'))").values == "(('beijing'), ('shanghai'))")
    }

    @Test func partitionFromShowPartitions() {
        let record = records(["PartitionId", "PartitionName", "State", "Range", "Buckets", "DataSize", "RowCount", "CooldownTime"], [
            ["10307", "p202401", "NORMAL", "[types: [DATE]; keys: [2024-01-01]; ..types: [DATE]; keys: [2024-02-01]; )", "4", "14.2KB", "1580", "9999-12-31 15:59:59"],
        ])[0]
        let partition = PartitionInfo(record: record)
        #expect(partition.name == "p202401")
        #expect(partition.dataSize == 14_541)
        #expect(partition.rowCount == 1580)
        #expect(partition.cooldownTime == nil)
    }

    @Test func processesAndNodesTolerateVersionDifferences() {
        // 3.3 has no ServerName/QueryId; 4.1 adds them and uses large connection ids.
        let v33 = records(["Id", "User", "Command", "Time", "Info"], [["24", "root", "Query", "3", "select sleep(3)"]])
        let v41 = records(["ServerName", "Id", "User", "Command", "Info", "QueryId"], [["fe1", "33554453", "root", "Sleep", nil, nil]])
        #expect(SessionProcess(record: v33[0])?.isRunningStatement == true)
        let idle = SessionProcess(record: v41[0])
        #expect(idle?.connectionID == 33_554_453)
        #expect(idle?.isRunningStatement == false)

        let backend = records(["BackendId", "IP", "Alive", "TotalCapacity", "UsedPct", "MemUsedPct"], [["10001", "127.0.0.1", "true", "118.498 GB", "39.54 %", "3.26 %"]])[0]
        let node = ClusterNode(role: .backend, record: backend)
        #expect(node.isAlive)
        #expect(node.usedPercent == 39.54)
        #expect(node.fields.count == 6)
    }
}
