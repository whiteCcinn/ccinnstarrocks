import Foundation
import MySQLWire

/// Human-readable sizes reported by `SHOW PARTITIONS` / `SHOW TABLET` / `SHOW BACKENDS`
/// (`0B`, `403.652 KB`, `1.2GB`, `71.644 GB`) → bytes (1024-based, as StarRocks prints them).
public enum ByteSize {
    public static func parse(_ text: String?) -> Int64? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let plain = Int64(text) { return plain }
        let numberPart = text.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = Double(numberPart), value.isFinite, value >= 0 else { return nil }
        let unit = text.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).uppercased()
        let exponent: Double
        switch unit {
        case "", "B", "BYTES": exponent = 0
        case "K", "KB", "KIB": exponent = 1
        case "M", "MB", "MIB": exponent = 2
        case "G", "GB", "GIB": exponent = 3
        case "T", "TB", "TIB": exponent = 4
        case "P", "PB", "PIB": exponent = 5
        default: return nil
        }
        let bytes = value * pow(1024, exponent)
        guard bytes < Double(Int64.max) else { return Int64.max }
        return Int64(bytes.rounded())
    }
}

/// Bounds of a range/list partition, parsed from StarRocks' textual form, e.g.
/// `[types: [DATE]; keys: [2024-01-01]; ..types: [DATE]; keys: [2024-02-01]; )`.
public struct PartitionBounds: Sendable, Hashable {
    public var lower: String?
    public var upper: String?
    /// Values of a list partition, or the raw text when the shape is unknown.
    public var values: String?

    public static func parse(_ raw: String?) -> PartitionBounds {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return PartitionBounds() }
        let keys = raw.matches(of: /keys:\s*\[([^\]]*)\]/).map { String($0.output.1) }
        if keys.count == 2 {
            return PartitionBounds(lower: display(keys[0]), upper: display(keys[1]))
        }
        return PartitionBounds(values: raw)
    }

    private static func display(_ key: String) -> String {
        // Multi-column keys are comma separated; StarRocks prints the minimum date as 0000-01-01.
        key.trimmingCharacters(in: .whitespaces)
    }

    public var summary: String {
        if let lower, let upper { return "[\(lower), \(upper))" }
        return values ?? ""
    }
}

public struct PartitionInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var state: String?
    public var partitionKey: String?
    public var bounds: PartitionBounds
    public var buckets: Int?
    public var replicationNum: Int?
    public var storageMedium: String?
    public var dataSize: Int64?
    public var rowCount: Int64?
    public var visibleVersion: Int64?
    public var visibleVersionTime: String?
    public var cooldownTime: String?
    public var isTemporary: Bool

    public init(record: Record, isTemporary: Bool = false) {
        name = record.text("PartitionName", "PARTITION_NAME") ?? "?"
        id = record.text("PartitionId", "PARTITION_ID") ?? name
        state = record.text("State")
        partitionKey = record.text("PartitionKey")
        bounds = PartitionBounds.parse(record.text("Range", "List", "PartitionValue", "PARTITION_VALUE"))
        buckets = record.int("Buckets", "BUCKETS").map { Int(clamping: $0) }
        replicationNum = record.int("ReplicationNum", "REPLICATION_NUM").map { Int(clamping: $0) }
        storageMedium = record.text("StorageMedium", "STORAGE_MEDIUM")
        dataSize = ByteSize.parse(record.text("DataSize", "DATA_SIZE"))
        rowCount = record.int("RowCount", "ROW_COUNT")
        visibleVersion = record.int("VisibleVersion", "VISIBLE_VERSION")
        visibleVersionTime = record.text("VisibleVersionTime", "VISIBLE_VERSION_TIME")
        let cooldown = record.text("CooldownTime", "COOLDOWN_TIME")
        cooldownTime = cooldown?.hasPrefix("9999-12-31") == true ? nil : cooldown
        self.isTemporary = isTemporary
    }
}

/// One replica of one tablet (`SHOW TABLET FROM t`).
public struct TabletReplica: Sendable, Hashable, Identifiable {
    public var tabletID: String
    public var replicaID: String
    public var backendID: String
    public var dataSize: Int64?
    public var rowCount: Int64?
    public var state: String?
    public var version: Int64?
    public var versionCount: Int64?
    public var isConsistent: Bool?

    public var id: String { "\(tabletID)/\(replicaID)" }

    public init(record: Record) {
        tabletID = record.text("TabletId") ?? "?"
        replicaID = record.text("ReplicaId") ?? "?"
        backendID = record.text("BackendId") ?? "?"
        dataSize = ByteSize.parse(record.text("DataSize"))
        rowCount = record.int("RowCount")
        state = record.text("State")
        version = record.int("Version")
        versionCount = record.int("VersionCount")
        isConsistent = record.bool("IsConsistent")
    }

    public init(tabletID: String, replicaID: String = "1", backendID: String = "1", dataSize: Int64?, rowCount: Int64?) {
        self.tabletID = tabletID
        self.replicaID = replicaID
        self.backendID = backendID
        self.dataSize = dataSize
        self.rowCount = rowCount
    }
}

/// Share of a table's replicas on one backend (`ADMIN SHOW REPLICA DISTRIBUTION`).
public struct ReplicaShare: Sendable, Hashable, Identifiable {
    public var backendID: String
    public var replicaCount: Int64
    public var percent: Double?

    public var id: String { backendID }
}

/// Storage per index (base table + sync MVs) from `SHOW DATA FROM db.t`.
public struct IndexStorage: Sendable, Hashable, Identifiable {
    public var indexName: String
    public var size: Int64?
    public var replicaCount: Int64?
    public var rowCount: Int64?

    public var id: String { indexName }
}

/// One execution of a task (async MV refresh, submitted task) from `information_schema.task_runs`.
public struct TaskRun: Sendable, Hashable, Identifiable {
    public var queryID: String
    public var taskName: String
    public var state: String
    public var database: String?
    public var createTime: String?
    public var finishTime: String?
    public var progress: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var definition: String?
    public var extraMessage: String?

    public var id: String { queryID + taskName + (createTime ?? "") }

    public init(record: Record) {
        queryID = record.text("QUERY_ID") ?? ""
        taskName = record.text("TASK_NAME") ?? ""
        state = record.text("STATE") ?? "UNKNOWN"
        database = record.text("DATABASE")
        createTime = record.text("CREATE_TIME")
        finishTime = record.text("FINISH_TIME")
        progress = record.text("PROGRESS")
        errorCode = record.text("ERROR_CODE").flatMap { $0 == "0" ? nil : $0 }
        errorMessage = record.text("ERROR_MESSAGE")
        definition = record.text("DEFINITION")
        extraMessage = record.text("EXTRA_MESSAGE")
    }

    /// Seconds between create and finish (or now, when still running).
    public func duration(now: Date = Date()) -> TimeInterval? {
        guard let start = createTime.flatMap(LocalTime.parse) else { return nil }
        let end = finishTime.flatMap(LocalTime.parse) ?? (isActive ? now : nil)
        return end.map { max(0, $0.timeIntervalSince(start)) }
    }

    public var isActive: Bool { ["RUNNING", "PENDING"].contains(state.uppercased()) }
}

/// FE timestamps are printed in the FE's local time zone without an offset; the app assumes the
/// cluster and the Mac share a zone for "elapsed" figures, which is the common case.
public enum LocalTime {
    public static func parse(_ text: String) -> Date? {
        guard let utc = TextValue.dateTime(text) else { return nil }
        return utc.addingTimeInterval(-TimeInterval(TimeZone.current.secondsFromGMT(for: utc)))
    }
}
