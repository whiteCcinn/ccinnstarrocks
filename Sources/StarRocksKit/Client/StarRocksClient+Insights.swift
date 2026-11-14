import Foundation

/// Table insights: partitions, tablets, replica distribution, storage, MV refresh history.
extension StarRocksClient {
    public func partitions(database: String, table: String, includeTemporary: Bool = false) async throws -> [PartitionInfo] {
        let target = SQLText.qualified(database, table)
        let result = try await execute("SHOW PARTITIONS FROM \(target)")
        var partitions = result.records.map { PartitionInfo(record: $0) }
        if includeTemporary, let temporary = try? await execute("SHOW TEMPORARY PARTITIONS FROM \(target)") {
            partitions += temporary.records.map { PartitionInfo(record: $0, isTemporary: true) }
        }
        return partitions
    }

    /// Tablet replicas of one index (default: the base index, i.e. the table itself), optionally of
    /// one partition. Without the index filter, sync-MV tablets would be mixed into skew analysis.
    public func tablets(database: String, table: String, partition: String? = nil, index: String? = nil) async throws -> [TabletReplica] {
        var sql = "SHOW TABLET FROM \(SQLText.qualified(database, table))"
        if let partition { sql += " PARTITION (\(SQLText.quoteIdentifier(partition)))" }
        sql += " WHERE IndexName = \(SQLText.literal(index ?? table))"
        return try await execute(sql).records.map(TabletReplica.init(record:))
    }

    /// Requires an admin role; callers should present the error as "not permitted" rather than fail the view.
    public func replicaDistribution(database: String, table: String) async throws -> [ReplicaShare] {
        let result = try await execute("ADMIN SHOW REPLICA DISTRIBUTION FROM \(SQLText.qualified(database, table))")
        return result.records.compactMap { record in
            guard let backend = record.text("BackendId") else { return nil }
            let percent = record.text("Percent").flatMap { TextValueParsing.percent($0) }
            return ReplicaShare(backendID: backend, replicaCount: record.int("ReplicaNum") ?? 0, percent: percent)
        }
    }

    /// Size and rows per index (base + sync MVs). The summary row `Total` is not an index and is dropped.
    public func storage(database: String, table: String) async throws -> [IndexStorage] {
        let result = try await execute("SHOW DATA FROM \(SQLText.qualified(database, table))")
        return Self.indexStorage(result.records)
    }

    static func indexStorage(_ records: [Record]) -> [IndexStorage] {
        records.compactMap { record in
            guard let index = record.text("IndexName"), index != "Total" || record.text("TableName") != nil else { return nil }
            return IndexStorage(indexName: index, size: ByteSize.parse(record.text("Size")),
                                replicaCount: record.int("ReplicaCount"), rowCount: record.int("RowCount"))
        }
    }

    // MARK: Materialized views

    /// Current status of one materialized view.
    public func materializedViewStatus(database: String, name: String) async throws -> MaterializedViewStatus? {
        let result = try await execute("""
            SELECT * FROM information_schema.materialized_views \
            WHERE TABLE_SCHEMA = \(SQLText.literal(database)) AND TABLE_NAME = \(SQLText.literal(name))
            """)
        return result.first.map(ObjectClassifier.materializedViewStatus)
    }

    /// Task runs, newest first, filtered by task name (e.g. `mv-10460`), database and/or state.
    public func taskRuns(taskName: String? = nil, database: String? = nil, states: [String] = [], limit: Int = 200) async throws -> [TaskRun] {
        var predicates: [String] = []
        if let taskName { predicates.append("TASK_NAME = \(SQLText.literal(taskName))") }
        if let database { predicates.append("`DATABASE` = \(SQLText.literal(database))") }
        if !states.isEmpty { predicates.append("STATE IN (\(states.map(SQLText.literal).joined(separator: ", ")))") }
        var sql = "SELECT * FROM information_schema.task_runs"
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        sql += " ORDER BY CREATE_TIME DESC LIMIT \(max(1, min(limit, 10_000)))"
        return try await execute(sql).records.map(TaskRun.init(record:))
    }

    /// Starts an asynchronous refresh (optionally forced and/or limited to a partition range).
    public func refreshMaterializedView(database: String, name: String, force: Bool = false,
                                        partitionStart: String? = nil, partitionEnd: String? = nil) async throws {
        var sql = "REFRESH MATERIALIZED VIEW \(SQLText.qualified(database, name))"
        if let partitionStart, let partitionEnd {
            sql += " PARTITION START (\(SQLText.literal(partitionStart))) END (\(SQLText.literal(partitionEnd)))"
        }
        if force { sql += " FORCE" }
        _ = try await execute(sql)
    }

    public func cancelMaterializedViewRefresh(database: String, name: String) async throws {
        _ = try await execute("CANCEL REFRESH MATERIALIZED VIEW \(SQLText.qualified(database, name))")
    }

    /// Re-activates an inactive MV (e.g. after its base table was re-created).
    public func activateMaterializedView(database: String, name: String) async throws {
        _ = try await execute("ALTER MATERIALIZED VIEW \(SQLText.qualified(database, name)) ACTIVE")
    }
}

enum TextValueParsing {
    /// `100.00 %` → 100.0
    static func percent(_ text: String) -> Double? {
        let number = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), value.isFinite else { return nil }
        return value
    }
}
