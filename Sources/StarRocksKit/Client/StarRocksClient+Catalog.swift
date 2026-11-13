import Foundation

/// Catalog browsing (design D3: `information_schema` first, `SHOW` fallbacks).
extension StarRocksClient {
    public func catalogs() async throws -> [CatalogInfo] {
        guard let result = try? await execute("SHOW CATALOGS") else {
            return [CatalogInfo(name: SQLText.defaultCatalog, type: "Internal")]
        }
        let catalogs = result.records.compactMap { record -> CatalogInfo? in
            guard let name = record.text("Catalog") ?? record.values.first ?? nil else { return nil }
            return CatalogInfo(name: name, type: record.text("Type") ?? "", comment: record.text("Comment"))
        }
        return catalogs.isEmpty ? [CatalogInfo(name: SQLText.defaultCatalog, type: "Internal")] : catalogs
    }

    public func databases(catalog: String = SQLText.defaultCatalog) async throws -> [String] {
        let sql = catalog == SQLText.defaultCatalog ? "SHOW DATABASES" : "SHOW DATABASES FROM \(SQLText.quoteIdentifier(catalog))"
        let result = try await execute(sql)
        return result.rows.compactMap { $0.first ?? nil }.sorted { Self.databaseOrder($0, $1) }
    }

    /// User databases first, system databases last.
    static func databaseOrder(_ lhs: String, _ rhs: String) -> Bool {
        let system: Set<String> = ["_statistics_", "information_schema", "sys"]
        let (lhsSystem, rhsSystem) = (system.contains(lhs.lowercased()), system.contains(rhs.lowercased()))
        if lhsSystem != rhsSystem { return !lhsSystem }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    /// Every table, view and materialized view in a database, classified (design D4).
    public func objects(catalog: String = SQLText.defaultCatalog, database: String) async throws -> [DatabaseObject] {
        guard catalog == SQLText.defaultCatalog else {
            return try await externalObjects(catalog: catalog, database: database)
        }
        let schema = SQLText.literal(database)
        async let tablesResult = try? execute("""
            SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, CREATE_TIME, UPDATE_TIME, TABLE_COMMENT \
            FROM information_schema.tables WHERE TABLE_SCHEMA = \(schema)
            """)
        async let configsResult = try? execute("SELECT * FROM information_schema.tables_config WHERE TABLE_SCHEMA = \(schema)")
        async let viewsResult = try? execute("SELECT * FROM information_schema.materialized_views WHERE TABLE_SCHEMA = \(schema)")
        async let rollupsResult = try? execute("SHOW ALTER MATERIALIZED VIEW FROM \(SQLText.quoteIdentifier(database))")

        var tables = await tablesResult?.records.compactMap(ObjectClassifier.TableRow.init(record:))
        if tables == nil {
            tables = try await showFullTables(catalog: catalog, database: database)
        }
        var materializedViews = await viewsResult?.records
        if materializedViews == nil {
            materializedViews = (try? await execute("SHOW MATERIALIZED VIEWS FROM \(SQLText.quoteIdentifier(database))"))?.records
        }
        return ObjectClassifier.classify(catalog: catalog, database: database, tables: tables ?? [],
                                         configs: await configsResult?.records ?? [],
                                         materializedViews: materializedViews ?? [],
                                         rollupJobs: await rollupsResult?.records ?? [])
    }

    private func externalObjects(catalog: String, database: String) async throws -> [DatabaseObject] {
        let tables = try await showFullTables(catalog: catalog, database: database)
        return ObjectClassifier.classify(catalog: catalog, database: database, tables: tables, configs: [], materializedViews: [], rollupJobs: [])
    }

    private func showFullTables(catalog: String, database: String) async throws -> [ObjectClassifier.TableRow] {
        let target = catalog == SQLText.defaultCatalog ? SQLText.quoteIdentifier(database) : SQLText.qualified(catalog, database)
        let result: ResultSet
        do {
            result = try await execute("SHOW FULL TABLES FROM \(target)")
        } catch {
            result = try await execute("SHOW TABLES FROM \(target)")
        }
        return result.records.compactMap { record in
            guard let name = record.values.first ?? nil else { return nil }
            return ObjectClassifier.TableRow(name: name, tableType: record.text("Table_type"))
        }
    }

    // MARK: Columns

    /// Columns of one object. Sync MVs are resolved through `DESC <base> ALL`.
    public func columns(of object: DatabaseObject) async throws -> [ColumnInfo] {
        if object.kind == .syncMaterializedView, let base = object.baseTable {
            let result = try await execute("DESC \(SQLText.qualified(object.database, base)) ALL")
            return Self.indexColumns(result, index: object.name)
        }
        if object.catalog == SQLText.defaultCatalog {
            let byTable = try await columnsByTable(database: object.database, table: object.name)
            if let columns = byTable[object.name], !columns.isEmpty { return columns }
        }
        let result = try await execute("DESC \(object.qualifiedName)")
        return Self.describeColumns(result)
    }

    /// All columns of a database (or one table) keyed by table name; feeds completion and the grid.
    public func columnsByTable(database: String, table: String? = nil) async throws -> [String: [ColumnInfo]] {
        var sql = """
            SELECT TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT, IS_NULLABLE, DATA_TYPE, COLUMN_TYPE, \
            COLUMN_KEY, EXTRA, COLUMN_COMMENT FROM information_schema.columns WHERE TABLE_SCHEMA = \(SQLText.literal(database))
            """
        if let table { sql += " AND TABLE_NAME = \(SQLText.literal(table))" }
        let result = try await execute(sql)
        var columns: [String: [ColumnInfo]] = [:]
        for record in result.records {
            guard let tableName = record.text("TABLE_NAME"), let name = record.text("COLUMN_NAME") else { continue }
            let dataType = record.text("DATA_TYPE") ?? ""
            let extra = record.text("EXTRA")
            columns[tableName, default: []].append(ColumnInfo(
                name: name, ordinal: Int(clamping: record.int("ORDINAL_POSITION") ?? 0), dataType: dataType,
                columnType: record.text("COLUMN_TYPE") ?? dataType, isNullable: record.text("IS_NULLABLE")?.uppercased() != "NO",
                isKey: !(record.text("COLUMN_KEY") ?? "").isEmpty, defaultValue: record.text("COLUMN_DEFAULT"),
                aggregation: Self.aggregation(extra), comment: record.text("COLUMN_COMMENT")))
        }
        for key in columns.keys { columns[key]?.sort { $0.ordinal < $1.ordinal } }
        return columns
    }

    static func aggregation(_ extra: String?) -> String? {
        guard let extra = extra?.uppercased(), !extra.isEmpty, extra != "NONE" else { return nil }
        let known = ["SUM", "MIN", "MAX", "REPLACE", "REPLACE_IF_NOT_NULL", "HLL_UNION", "BITMAP_UNION", "PERCENTILE_UNION"]
        return known.first { extra == $0 || extra.hasPrefix($0 + " ") }
    }

    /// `DESC t` / `SHOW FULL COLUMNS` shape: Field, Type, Null, Key, Default, Extra[, Comment].
    static func describeColumns(_ result: ResultSet) -> [ColumnInfo] {
        result.records.enumerated().compactMap { offset, record in
            guard let name = record.text("Field", "COLUMN_NAME") else { return nil }
            let type = record.text("Type") ?? ""
            let key = record.text("Key")?.lowercased()
            return ColumnInfo(name: name, ordinal: offset + 1, dataType: type.components(separatedBy: "(").first ?? type, columnType: type,
                              isNullable: record.text("Null")?.uppercased() != "NO", isKey: key == "true" || key == "yes" || key == "pri",
                              defaultValue: record.text("Default"), aggregation: aggregation(record.text("Extra")),
                              comment: record.text("Comment"))
        }
    }

    /// Columns of one index from `DESC <table> ALL` (rows of an index continue with a blank IndexName).
    static func indexColumns(_ result: ResultSet, index: String) -> [ColumnInfo] {
        var current: String?
        var rows: [[String?]] = []
        for record in result.records {
            if let name = record.text("IndexName") { current = name }
            if current == index, record.text("Field") != nil { rows.append(record.values) }
        }
        return describeColumns(ResultSet(columns: result.columns, rows: rows))
    }

    // MARK: DDL

    public func ddl(of object: DatabaseObject) async throws -> String {
        switch object.kind {
        case .syncMaterializedView:
            return object.materializedView?.definition ?? "-- Definition unavailable"
        case .asyncMaterializedView:
            let result = try await execute("SHOW CREATE MATERIALIZED VIEW \(object.qualifiedName)")
            return Self.createStatement(result) ?? ""
        default:
            let result = try await execute("SHOW CREATE TABLE \(object.qualifiedName)")
            return Self.createStatement(result) ?? ""
        }
    }

    static func createStatement(_ result: ResultSet) -> String? {
        guard let record = result.first else { return nil }
        if let index = result.columns.firstIndex(where: { $0.name.lowercased().hasPrefix("create") }) {
            return record.values[index]
        }
        return record.values.count > 1 ? record.values[1] : record.values.first ?? nil
    }
}
