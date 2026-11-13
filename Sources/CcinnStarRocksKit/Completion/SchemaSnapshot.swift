import Foundation
import StarRocksKit

/// Case-insensitive `database.table` key.
public struct TableKey: Hashable, Sendable, CustomStringConvertible {
    public let database: String
    public let table: String

    public init(database: String, table: String) {
        self.database = database.lowercased()
        self.table = table.lowercased()
    }

    public var description: String { "\(database).\(table)" }
}

/// What completion knows about the schema. Built by the app from lazily loaded metadata; immutable,
/// so completion runs off the main actor without locks.
public struct SchemaSnapshot: Sendable {
    public struct ObjectEntry: Sendable, Hashable {
        public let name: String
        public let kind: ObjectKind

        public init(name: String, kind: ObjectKind) {
            self.name = name
            self.kind = kind
        }
    }

    public var currentCatalog: String
    public var currentDatabase: String?
    public var catalogs: [String]
    public var databases: [String]
    /// Objects per database (keys lower-cased).
    public var objectsByDatabase: [String: [ObjectEntry]]
    public var columnsByTable: [TableKey: [ColumnInfo]]

    public init(currentCatalog: String = SQLText.defaultCatalog, currentDatabase: String? = nil, catalogs: [String] = [],
                databases: [String] = [], objectsByDatabase: [String: [ObjectEntry]] = [:], columnsByTable: [TableKey: [ColumnInfo]] = [:]) {
        self.currentCatalog = currentCatalog
        self.currentDatabase = currentDatabase
        self.catalogs = catalogs
        self.databases = databases
        self.objectsByDatabase = Dictionary(objectsByDatabase.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.columnsByTable = columnsByTable
    }

    public func objects(in database: String) -> [ObjectEntry]? {
        objectsByDatabase[database.lowercased()]
    }

    public func columns(database: String, table: String) -> [ColumnInfo]? {
        columnsByTable[TableKey(database: database, table: table)]
    }

    public func isDatabase(_ name: String) -> Bool {
        databases.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func isCatalog(_ name: String) -> Bool {
        catalogs.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func object(named name: String, in database: String) -> ObjectEntry? {
        objects(in: database)?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
