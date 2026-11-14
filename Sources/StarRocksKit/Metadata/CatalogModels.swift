import Foundation

/// StarRocks table models (`tables_config.TABLE_MODEL`).
public enum TableModel: String, Sendable, CaseIterable, Hashable {
    case duplicate = "DUP_KEYS"
    case aggregate = "AGG_KEYS"
    case unique = "UNIQUE_KEYS"
    case primary = "PRIMARY_KEYS"

    public init?(serverValue: String?) {
        guard let value = serverValue?.trimmingCharacters(in: .whitespaces).uppercased(), !value.isEmpty else { return nil }
        switch value {
        case "DUP_KEYS", "DUPLICATE", "DUPLICATE_KEYS": self = .duplicate
        case "AGG_KEYS", "AGGREGATE", "AGGREGATE_KEYS": self = .aggregate
        case "UNIQUE_KEYS", "UNIQUE": self = .unique
        case "PRIMARY_KEYS", "PRIMARY": self = .primary
        default: return nil
        }
    }

    /// Compact badge shown next to the table name.
    public var badge: String {
        switch self {
        case .duplicate: "DUP"
        case .aggregate: "AGG"
        case .unique: "UNI"
        case .primary: "PK"
        }
    }

    public var displayName: String {
        switch self {
        case .duplicate: "Duplicate Key"
        case .aggregate: "Aggregate Key"
        case .unique: "Unique Key"
        case .primary: "Primary Key"
        }
    }
}

/// What a catalog object is. Ordered for grouping in the sidebar.
public enum ObjectKind: Int, Sendable, CaseIterable, Comparable, Hashable {
    case table
    case asyncMaterializedView
    case syncMaterializedView
    case view
    case externalTable
    case systemView

    public static func < (lhs: ObjectKind, rhs: ObjectKind) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .table: "Table"
        case .asyncMaterializedView: "Async Materialized View"
        case .syncMaterializedView: "Sync Materialized View"
        case .view: "View"
        case .externalTable: "External Table"
        case .systemView: "System View"
        }
    }

    public var groupTitle: String {
        switch self {
        case .table: "Tables"
        case .asyncMaterializedView, .syncMaterializedView: "Materialized Views"
        case .view: "Views"
        case .externalTable: "External Tables"
        case .systemView: "System Views"
        }
    }

    public var isMaterializedView: Bool { self == .asyncMaterializedView || self == .syncMaterializedView }
    /// Objects backed by StarRocks-managed storage (partitions, tablets).
    public var hasNativeStorage: Bool { self == .table || self == .asyncMaterializedView }
}

/// Refresh/health status of a materialized view (`information_schema.materialized_views`).
public struct MaterializedViewStatus: Sendable, Hashable {
    public enum Health: Sendable, Hashable {
        case healthy, refreshing, failed, inactive, neverRefreshed, maintainedSynchronously
    }

    public var id: String?
    public var refreshType: String
    public var isActive: Bool
    public var inactiveReason: String?
    public var partitionType: String?
    public var taskName: String?
    public var lastRefreshState: String?
    public var lastRefreshStart: String?
    public var lastRefreshFinish: String?
    public var lastRefreshDurationSeconds: Double?
    public var lastRefreshError: String?
    public var rowCount: Int64?
    public var definition: String?
    public var rewriteStatus: String?
    public var refreshPolicy: String?

    public init(refreshType: String, isActive: Bool) {
        self.refreshType = refreshType
        self.isActive = isActive
    }

    public var isSynchronous: Bool {
        let type = refreshType.uppercased()
        return type == "ROLLUP" || type == "SYNC"
    }

    public var health: Health {
        if isSynchronous { return .maintainedSynchronously }
        if !isActive { return .inactive }
        switch lastRefreshState?.uppercased() {
        case "RUNNING", "PENDING": return .refreshing
        case "FAILED": return .failed
        case "SUCCESS", "SKIPPED", "MERGED": return .healthy
        default: return .neverRefreshed
        }
    }
}

/// One table / view / materialized view in a database.
public struct DatabaseObject: Sendable, Hashable, Identifiable {
    public var catalog: String
    public var database: String
    public var name: String
    public var kind: ObjectKind
    public var model: TableModel?
    public var engine: String?
    public var comment: String?
    public var rowCount: Int64?
    public var dataLength: Int64?
    public var createTime: String?
    public var updateTime: String?
    public var partitionKey: String?
    public var distributionKey: String?
    public var distributionType: String?
    public var buckets: Int?
    public var sortKey: String?
    public var primaryKey: String?
    public var properties: [String: String] = [:]
    /// Base table of a synchronous materialized view.
    public var baseTable: String?
    public var materializedView: MaterializedViewStatus?

    public init(catalog: String, database: String, name: String, kind: ObjectKind) {
        self.catalog = catalog
        self.database = database
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(catalog)\u{1F}\(database)\u{1F}\(name)" }
    public var isPartitioned: Bool { !(partitionKey ?? "").isEmpty }
    public var qualifiedName: String {
        catalog == SQLText.defaultCatalog ? SQLText.qualified(database, name) : SQLText.qualified(catalog, database, name)
    }
}

public struct CatalogInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var type: String
    public var comment: String?

    public init(name: String, type: String, comment: String? = nil) {
        self.name = name
        self.type = type
        self.comment = comment
    }

    public var id: String { name }
    public var isInternal: Bool { name == SQLText.defaultCatalog || type.lowercased() == "internal" }
}

public struct ColumnInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var ordinal: Int
    /// Short type, e.g. `bigint`.
    public var dataType: String
    /// Full type, e.g. `decimal(12,2)`.
    public var columnType: String
    public var isNullable: Bool
    public var isKey: Bool
    public var defaultValue: String?
    /// Aggregation (`SUM`, `REPLACE`, …) for aggregate-model value columns.
    public var aggregation: String?
    public var comment: String?

    public init(name: String, ordinal: Int, dataType: String, columnType: String, isNullable: Bool, isKey: Bool,
                defaultValue: String? = nil, aggregation: String? = nil, comment: String? = nil) {
        self.name = name
        self.ordinal = ordinal
        self.dataType = dataType
        self.columnType = columnType
        self.isNullable = isNullable
        self.isKey = isKey
        self.defaultValue = defaultValue
        self.aggregation = aggregation
        self.comment = comment
    }

    public var id: String { name }
}
