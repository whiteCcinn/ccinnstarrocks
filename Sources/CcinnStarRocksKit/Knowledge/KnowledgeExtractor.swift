import CryptoKit
import Foundation
import StarRocksKit

/// Where extraction reads a database's structure: `StarRocksClient`, or a fake in tests.
public protocol KnowledgeSchemaSource: Sendable {
    var knowledgeServerVersion: String? { get }
    func objects(catalog: String, database: String) async throws -> [DatabaseObject]
    func columnsByTable(database: String, tables: [String]?) async throws -> [String: [ColumnInfo]]
    func viewDefinitions(database: String) async throws -> [String: String]
    func clusterHints() async throws -> ClusterHints?
}

extension StarRocksClient: KnowledgeSchemaSource {
    public var knowledgeServerVersion: String? { serverInfo.versionString }
}

/// One object as the server reports it, before it becomes `TableFacts`.
public struct ExtractedTable: Sendable {
    public var object: DatabaseObject
    public var columns: [ColumnInfo]
    /// The query of a view or materialized view: read for lineage, joins and the fingerprint, never stored.
    public var definition: String?

    public init(object: DatabaseObject, columns: [ColumnInfo], definition: String?) {
        self.object = object
        self.columns = columns
        self.definition = definition
    }
}

/// One database's structure at one moment.
public struct ExtractedSchema: Sendable {
    public var database: String
    public var serverVersion: String?
    public var clusterHints: ClusterHints?
    public var tables: [ExtractedTable]

    public init(database: String, serverVersion: String?, clusterHints: ClusterHints?, tables: [ExtractedTable]) {
        self.database = database
        self.serverVersion = serverVersion
        self.clusterHints = clusterHints
        self.tables = tables
    }
}

/// Reads one database of `default_catalog` in a handful of metadata queries, whatever its size: objects (with their
/// models, keys and properties), all columns, view definitions and the cluster's identity hints. Metadata only; no rows.
public enum KnowledgeExtractor {
    public static func extract(database: String, from source: some KnowledgeSchemaSource) async throws -> ExtractedSchema {
        async let objects = source.objects(catalog: SQLText.defaultCatalog, database: database)
        async let columns = source.columnsByTable(database: database, tables: nil)
        async let views = source.viewDefinitions(database: database)
        async let hints = source.clusterHints()
        let columnsByTable = try await columns
        let viewDefinitions = try await views
        let tables = try await objects.filter { $0.kind != .systemView }.map { (object: DatabaseObject) -> ExtractedTable in
            let definition: String? = object.kind == .view ? viewDefinitions[object.name] : object.materializedView?.definition
            return ExtractedTable(object: object, columns: columnsByTable[object.name] ?? [], definition: definition)
        }
        return ExtractedSchema(database: database, serverVersion: source.knowledgeServerVersion, clusterHints: try await hints, tables: tables)
    }
}

/// Fingerprints that say whether knowledge written against a table still describes it.
public enum SchemaFingerprint {
    /// Kind, model, keys and every column's name, type, nullability, key flag and aggregation in ordinal order, plus the
    /// digest of a view's query (literals replaced, so a changed date filter is not a new structure). Comments, sizes,
    /// row counts, buckets and properties are not part of it.
    public static func structure(kind: TableFacts.Kind, model: String?, keys: TableFacts.Keys, columns: [ColumnFacts], definition: String?) -> String {
        var lines: [String] = ["v1", kind.rawValue, model ?? "-"]
        lines.append([keys.primary, keys.sort, keys.distribution, keys.partition].map { $0.joined(separator: ",") }.joined(separator: "|"))
        for column in columns {
            let nullability = column.isNullable ? "N" : "NN"
            let key = column.isKey ? "K" : "-"
            lines.append([column.name, column.type.lowercased(), nullability, key, column.aggregation ?? "-"].joined(separator: "\t"))
        }
        if let definition { lines.append("q\t" + SQLDigest.digest(definition)) }
        return hash(lines.joined(separator: "\n"))
    }

    /// The table's and its columns' comments: a changed comment refreshes the stored text without making knowledge stale.
    public static func comments(table comment: String?, columns: [ColumnFacts]) -> String {
        let lines: [String] = [comment ?? ""] + columns.map { $0.name + "\t" + ($0.comment ?? "") }
        return hash(lines.joined(separator: "\n"))
    }

    /// 24 hex characters of SHA-256: plenty to detect change, small in every relationship and note that records it.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
