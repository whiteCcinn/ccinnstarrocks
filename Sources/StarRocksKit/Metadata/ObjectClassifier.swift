import Foundation

/// Pure classification of database objects (design D4) from the rows StarRocks reports:
///
/// - `information_schema.tables`: async MVs appear as `TABLE_TYPE = VIEW`, sync MVs not at all.
/// - `information_schema.tables_config`: `TABLE_ENGINE = MATERIALIZED_VIEW` marks async MVs; `TABLE_MODEL`.
/// - `information_schema.materialized_views` / `SHOW MATERIALIZED VIEWS`: async MVs and sync MVs
///   (`REFRESH_TYPE` `ROLLUP` on 3.x, `SYNC` on 4.x).
/// - `SHOW ALTER MATERIALIZED VIEW`: sync MV → base table.
public enum ObjectClassifier {
    /// One row of the object listing, from `information_schema.tables` or `SHOW FULL TABLES`.
    public struct TableRow: Sendable, Hashable {
        public var name: String
        public var tableType: String?
        public var engine: String?
        public var rowCount: Int64?
        public var dataLength: Int64?
        public var createTime: String?
        public var updateTime: String?
        public var comment: String?

        public init(name: String, tableType: String?, engine: String? = nil, rowCount: Int64? = nil, dataLength: Int64? = nil,
                    createTime: String? = nil, updateTime: String? = nil, comment: String? = nil) {
            self.name = name
            self.tableType = tableType
            self.engine = engine
            self.rowCount = rowCount
            self.dataLength = dataLength
            self.createTime = createTime
            self.updateTime = updateTime
            self.comment = comment
        }

        public init?(record: Record) {
            guard let name = record.text("TABLE_NAME") else { return nil }
            self.init(name: name, tableType: record.text("TABLE_TYPE"), engine: record.text("ENGINE"),
                      rowCount: record.int("TABLE_ROWS"), dataLength: record.int("DATA_LENGTH"),
                      createTime: record.text("CREATE_TIME"), updateTime: record.text("UPDATE_TIME"),
                      comment: record.text("TABLE_COMMENT"))
        }
    }

    static let nativeEngines: Set<String> = ["OLAP", "CLOUD_NATIVE", "STARROCKS", "MATERIALIZED_VIEW", "CLOUD_NATIVE_MATERIALIZED_VIEW"]

    public static func classify(catalog: String, database: String, tables: [TableRow], configs: [Record],
                                materializedViews: [Record], rollupJobs: [Record]) -> [DatabaseObject] {
        var configByName: [String: Record] = [:]
        for config in configs {
            if let name = config.text("TABLE_NAME") { configByName[name] = config }
        }
        var mvByName: [String: MaterializedViewStatus] = [:]
        for row in materializedViews {
            if let name = row.text("TABLE_NAME", "name") { mvByName[name] = materializedViewStatus(row) }
        }
        var baseByRollup: [String: String] = [:]
        for job in rollupJobs {
            if let rollup = job.text("RollupIndexName"), let base = job.text("TableName") { baseByRollup[rollup] = base }
        }

        let isInternal = catalog == SQLText.defaultCatalog
        let isSystemDatabase = ["information_schema", "sys", "_statistics_"].contains(database.lowercased())
        var objects: [DatabaseObject] = []
        var seen = Set<String>()
        objects.reserveCapacity(tables.count + mvByName.count)

        for row in tables where seen.insert(row.name).inserted {
            let config = configByName[row.name]
            let configEngine = config?.text("TABLE_ENGINE")?.uppercased()
            let tableType = row.tableType?.uppercased() ?? ""
            let mv = mvByName[row.name]

            let kind: ObjectKind
            if !isInternal {
                kind = tableType.contains("VIEW") ? .view : .externalTable
            } else if let mv, !mv.isSynchronous {
                kind = .asyncMaterializedView
            } else if configEngine?.contains("MATERIALIZED_VIEW") == true {
                kind = .asyncMaterializedView
            } else if tableType == "SYSTEM VIEW" || (isSystemDatabase && tableType != "BASE TABLE") {
                kind = .systemView
            } else if tableType.contains("VIEW") {
                kind = .view
            } else if let engine = (configEngine ?? row.engine?.uppercased()), !engine.isEmpty, !nativeEngines.contains(engine) {
                kind = .externalTable
            } else {
                kind = .table
            }

            var object = DatabaseObject(catalog: catalog, database: database, name: row.name, kind: kind)
            object.engine = configEngine ?? row.engine
            object.comment = row.comment
            object.rowCount = row.rowCount
            object.dataLength = row.dataLength
            object.createTime = row.createTime
            object.updateTime = row.updateTime
            if let config, kind == .table || kind == .asyncMaterializedView {
                apply(config: config, to: &object)
            }
            if kind == .asyncMaterializedView {
                object.materializedView = mv ?? MaterializedViewStatus(refreshType: "ASYNC", isActive: true)
                if object.rowCount == nil || object.rowCount == 0, let rows = mv?.rowCount { object.rowCount = rows }
            }
            objects.append(object)
        }

        // Synchronous MVs live inside their base table and are absent from `tables`.
        if isInternal {
            for (name, status) in mvByName where status.isSynchronous && seen.insert(name).inserted {
                var object = DatabaseObject(catalog: catalog, database: database, name: name, kind: .syncMaterializedView)
                object.materializedView = status
                object.baseTable = baseByRollup[name] ?? baseTable(fromDefinition: status.definition)
                object.rowCount = status.rowCount
                object.model = .aggregate
                objects.append(object)
            }
        }
        return objects.sorted { ($0.kind, $0.name.lowercased()) < ($1.kind, $1.name.lowercased()) }
    }

    static func apply(config: Record, to object: inout DatabaseObject) {
        object.model = TableModel(serverValue: config.text("TABLE_MODEL"))
        object.primaryKey = config.text("PRIMARY_KEY").map(stripQuotes)
        object.partitionKey = config.text("PARTITION_KEY").map(stripQuotes)
        object.distributionKey = config.text("DISTRIBUTE_KEY").map(stripQuotes)
        object.distributionType = config.text("DISTRIBUTE_TYPE")
        object.buckets = config.int("DISTRIBUTE_BUCKET").map { Int(clamping: $0) }
        object.sortKey = config.text("SORT_KEY").map(stripQuotes)
        if let json = config.text("PROPERTIES") { object.properties = parseProperties(json) }
    }

    public static func materializedViewStatus(_ row: Record) -> MaterializedViewStatus {
        var status = MaterializedViewStatus(refreshType: row.text("REFRESH_TYPE", "refresh_type") ?? "ASYNC",
                                            isActive: row.bool("IS_ACTIVE", "is_active") ?? true)
        status.id = row.text("MATERIALIZED_VIEW_ID", "id")
        status.inactiveReason = row.text("INACTIVE_REASON", "inactive_reason")
        status.partitionType = row.text("PARTITION_TYPE", "partition_type")
        status.taskName = row.text("TASK_NAME", "task_name")
        status.lastRefreshState = row.text("LAST_REFRESH_STATE", "last_refresh_state")
        status.lastRefreshStart = row.text("LAST_REFRESH_START_TIME", "last_refresh_start_time")
        status.lastRefreshFinish = row.text("LAST_REFRESH_FINISHED_TIME", "last_refresh_finished_time")
        status.lastRefreshDurationSeconds = row.double("LAST_REFRESH_DURATION", "last_refresh_duration")
        status.lastRefreshError = row.text("LAST_REFRESH_ERROR_MESSAGE", "last_refresh_error_message")
        status.rowCount = row.int("TABLE_ROWS", "rows")
        status.definition = row.text("MATERIALIZED_VIEW_DEFINITION", "text")
        status.rewriteStatus = row.text("QUERY_REWRITE_STATUS", "query_rewrite_status")
        status.refreshPolicy = row.text("REFRESH_POLICY", "refresh_policy")
        if status.refreshPolicy?.uppercased() == "NONE" { status.refreshPolicy = nil }
        return status
    }

    /// `FROM <name>` of a sync MV definition (fallback when the alter job has been cleaned up).
    static func baseTable(fromDefinition definition: String?) -> String? {
        guard let definition else { return nil }
        let pattern = /(?i)\bfrom\s+`?([A-Za-z0-9_$]+)`?(?:\s*\.\s*`?([A-Za-z0-9_$]+)`?)?/
        guard let match = definition.firstMatch(of: pattern) else { return nil }
        return String(match.output.2 ?? match.output.1)
    }

    static func stripQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "")
    }

    /// `tables_config.PROPERTIES` is a JSON object of strings.
    static func parseProperties(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object { result[key] = "\(value)" }
        return result
    }
}
