import Foundation
import MySQLWire
import StarRocksKit

/// What a result can be copied or saved as.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, tsv, excel, insert, multiRowInsert

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .excel: "Excel"
        case .insert: "SQL INSERT, One per Row"
        case .multiRowInsert: "SQL INSERT, Multi-row"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .excel: "xlsx"
        case .insert, .multiRowInsert: "sql"
        }
    }

    /// Text that can go to the clipboard; an Excel workbook is a file only.
    public var isCopyable: Bool { self != .excel }
}

/// CSV, TSV, Excel and SQL INSERT renderings of result sets.
public enum ResultExport {
    /// Rows and cut cells of a written file.
    public typealias Summary = XLSXWriter.Summary

    /// Rows per multi-row INSERT and its size budget: well under `max_allowed_packet` defaults (4 MB and up).
    public static let rowsPerStatement = 1_000
    public static let maxStatementBytes = 1 << 20

    /// The text of a copyable format (empty for Excel, which is a file only).
    public static func render(_ format: ExportFormat, columns: [ColumnDefinition], rows: [[String?]], table: String) -> String {
        var output = ""
        output.reserveCapacity(rows.count * max(1, columns.count) * 12)
        emitText(format, columns: columns, rows: rows, table: table) { output += $0 }
        return output
    }

    /// Writes `format` to `url`. Text is streamed in ~1 MB chunks and ends with a line break; Excel gets a workbook with
    /// typed cells. A failed export leaves no file behind.
    @discardableResult
    public static func write(_ format: ExportFormat, to url: URL, columns: [ColumnDefinition], rows: [[String?]], table: String,
                             sheetName: String) throws -> Summary {
        if format == .excel {
            return try XLSXWriter.write(to: url, sheetName: sheetName, header: columns.map(\.name), kinds: cellKinds(columns), rows: rows)
        }
        try writeText(to: url) { emit in
            emitText(format, columns: columns, rows: rows, table: table, emit: emit)
            if format != .csv, !rows.isEmpty || format == .tsv { emit("\n") }
        }
        return Summary(rows: rows.count, truncatedCells: 0)
    }

    private static func emitText(_ format: ExportFormat, columns: [ColumnDefinition], rows: [[String?]], table: String, emit: (String) -> Void) {
        switch format {
        case .csv: writeCSV(columns: columns, rows: rows, includeHeader: true, emit: emit)
        case .tsv: writeTSV(columns: columns, rows: rows, includeHeader: true, emit: emit)
        case .insert: insertStatements(table: table, columns: columns, rows: rows, emit: emit)
        case .multiRowInsert:
            multiRowInsert(table: table, columns: columns, rows: rows, rowsPerStatement: rowsPerStatement, maxStatementBytes: maxStatementBytes, emit: emit)
        case .excel: break
        }
    }

    /// How each column is stored in a workbook: integers and decimals exactly (decimals with their scale), floating
    /// point as numbers, the rest as text.
    static func cellKinds(_ columns: [ColumnDefinition]) -> [XLSXWriter.CellKind] {
        columns.map { (column: ColumnDefinition) -> XLSXWriter.CellKind in
            switch column.type.kind {
            case .integer: .integer
            case .decimal: .decimal(scale: Int(column.decimals))
            case .float: .approximateNumber
            default: .text
            }
        }
    }

    // MARK: CSV

    /// RFC 4180 CSV. Text cells that a spreadsheet would evaluate as a formula (`=`, `+`, `-`, `@`,
    /// tab, CR) are prefixed with `'`; numeric columns are left untouched so negative numbers survive.
    public static func csv(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool = true) -> String {
        var output = ""
        output.reserveCapacity(rows.count * max(1, columns.count) * 12)
        writeCSV(columns: columns, rows: rows, includeHeader: includeHeader) { output += $0 }
        return output
    }

    /// Streams CSV to a file in ~1 MB chunks so large results do not need one giant string.
    public static func writeCSV(to url: URL, columns: [ColumnDefinition], rows: [[String?]]) throws {
        try writeText(to: url) { emit in writeCSV(columns: columns, rows: rows, includeHeader: true, emit: emit) }
    }

    private static func writeCSV(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool, emit: (String) -> Void) {
        let numeric = columns.map(\.type.isNumeric)
        if includeHeader {
            emit(columns.map { escapeCSV($0.name, neutralize: true) }.joined(separator: ",") + "\r\n")
        }
        for row in rows {
            var line = ""
            for index in columns.indices {
                if index > 0 { line += "," }
                guard index < row.count, let value = row[index] else { continue }
                line += escapeCSV(value, neutralize: !numeric[index])
            }
            emit(line + "\r\n")
        }
    }

    static func escapeCSV(_ value: String, neutralize: Bool) -> String {
        var value = value
        if neutralize, let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || value != value.trimmingCharacters(in: .whitespaces) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: TSV

    /// Tab-separated text for the clipboard (pastes into spreadsheets); NULL becomes empty.
    public static func tsv(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool = true) -> String {
        var output = ""
        writeTSV(columns: columns, rows: rows, includeHeader: includeHeader) { output += $0 }
        return output
    }

    private static func writeTSV(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool, emit: (String) -> Void) {
        var first = true
        func line(_ text: String) {
            emit(first ? text : "\n" + text)
            first = false
        }
        if includeHeader { line(columns.map { cleanTSV($0.name) }.joined(separator: "\t")) }
        for row in rows {
            line(columns.indices.map { index in index < row.count ? cleanTSV(row[index] ?? "") : "" }.joined(separator: "\t"))
        }
    }

    static func cleanTSV(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return value }
        return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: SQL INSERT

    /// The table INSERT statements go to: the source table when every column comes from the same one (`db`.`t`, not
    /// the query's alias), else the one table a plain `SELECT` reads, else the first column's table, else a placeholder
    /// to replace.
    public static func insertTarget(columns: [ColumnDefinition], sql: String? = nil) -> String {
        if let first = columns.first, !first.originalTable.isEmpty,
           columns.allSatisfy({ $0.originalTable == first.originalTable && $0.schema == first.schema }) {
            return SQLText.qualified(first.schema, first.originalTable)
        }
        if let sql, let table = singleSourceTable(of: sql) { return table }
        if let table = columns.first?.table, !table.isEmpty { return SQLText.quoteIdentifier(table) }
        return "`table`"
    }

    /// The single table a plain `SELECT … FROM [catalog.][db.]t [[AS] alias] …` reads, quoted. `nil` for anything
    /// that reads more than one source: joins, comma lists, derived tables, CTEs and set operations. Subqueries in
    /// WHERE do not count: their rows are not in the result.
    public static func singleSourceTable(of sql: String) -> String? {
        singleSourceTableParts(of: sql).map { SQLText.qualified($0[0], $0.count > 1 ? $0[1] : nil, $0.count > 2 ? $0[2] : nil) }
    }

    /// The source table's name for file and sheet names: from the column metadata, else from a single-table statement.
    public static func sourceTableName(columns: [ColumnDefinition], sql: String?) -> String? {
        if let first = columns.first, !first.originalTable.isEmpty, columns.allSatisfy({ $0.originalTable == first.originalTable }) {
            return first.originalTable
        }
        return sql.flatMap(singleSourceTableParts)?.last
    }

    /// `[catalog, db, table]`'s non-empty suffix as written, unquoted.
    static func singleSourceTableParts(of sql: String) -> [String]? {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        let words: [String] = tokens.map { (token: SQLToken) -> String in token.kind == .keyword ? lexer.text(of: token).uppercased() : "" }
        guard words.first == "SELECT" else { return nil }
        func isPunctuation(_ index: Int, _ text: String) -> Bool {
            guard tokens[index].kind == .punctuation else { return false }
            return lexer.text(of: tokens[index]) == text
        }
        var depth = 0
        var from: Int?
        for index in tokens.indices {
            if isPunctuation(index, "(") { depth += 1 }
            if isPunctuation(index, ")") { depth -= 1 }
            guard depth == 0 else { continue }
            switch words[index] {
            case "FROM":
                guard from == nil else { return nil }
                from = index
            case "JOIN", "UNION", "INTERSECT", "EXCEPT", "MINUS", "LATERAL": return nil
            default: break
            }
        }
        guard let from else { return nil }
        func isName(_ index: Int) -> Bool {
            switch tokens[index].kind {
            case .identifier, .quotedIdentifier: return true
            case .keyword: return !SQLKeywords.reserved.contains(words[index])
            default: return false
            }
        }
        var parts: [String] = []
        var index = from + 1
        while index < tokens.count, isName(index) {
            parts.append(lexer.identifierValue(of: tokens[index]))
            index += 1
            guard index + 1 < tokens.count, isPunctuation(index, ".") else { break }
            index += 1
        }
        guard (1...3).contains(parts.count) else { return nil }
        // An optional alias, then the end of the statement or the next clause: a comma means a second table.
        if index < tokens.count, words[index] == "AS" { index += 1 }
        let partitionWords: Set<String> = ["PARTITION", "PARTITIONS", "TEMPORARY", "TABLET"]
        if index < tokens.count, isName(index), !partitionWords.contains(words[index]) { index += 1 }
        let following: Set<String> = ["WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "WINDOW", "QUALIFY", "PARTITION", "PARTITIONS",
                                      "TEMPORARY", "TABLET", "INTO", "FOR"]
        if index == tokens.count || isPunctuation(index, ";") { return parts }
        guard following.contains(words[index]) else { return nil }
        return parts
    }

    /// `INSERT INTO t (…) VALUES (…);` statements for the selected rows, one per line.
    public static func insertStatements(table: String, columns: [ColumnDefinition], rows: [[String?]]) -> String {
        var output = ""
        insertStatements(table: table, columns: columns, rows: rows) { output += $0 }
        return output
    }

    private static func insertStatements(table: String, columns: [ColumnDefinition], rows: [[String?]], emit: (String) -> Void) {
        let head = "INSERT INTO \(table) (\(columnList(columns))) VALUES "
        for (index, row) in rows.enumerated() {
            emit((index == 0 ? "" : "\n") + head + tuple(row, columns: columns) + ";")
        }
    }

    /// `INSERT INTO t (…) VALUES` with one row per line. A new statement starts every `rowsPerStatement` rows, or
    /// before a row that would take the statement past `maxStatementBytes`, so each one fits the server's packet limit.
    public static func multiRowInsert(table: String, columns: [ColumnDefinition], rows: [[String?]], rowsPerStatement: Int = rowsPerStatement,
                                      maxStatementBytes: Int = maxStatementBytes) -> String {
        var output = ""
        multiRowInsert(table: table, columns: columns, rows: rows, rowsPerStatement: rowsPerStatement, maxStatementBytes: maxStatementBytes) {
            output += $0
        }
        return output
    }

    private static func multiRowInsert(table: String, columns: [ColumnDefinition], rows: [[String?]], rowsPerStatement: Int,
                                       maxStatementBytes: Int, emit: (String) -> Void) {
        let head = "INSERT INTO \(table) (\(columnList(columns))) VALUES"
        let rowsPerStatement = max(1, rowsPerStatement)
        var rowsInStatement = 0
        var statementBytes = 0
        for row in rows {
            let values = tuple(row, columns: columns)
            let separatorBytes = 4 // ",\n  " or "\n  "
            let rowBytes: Int = separatorBytes + values.utf8.count
            let isFull: Bool = rowsInStatement >= rowsPerStatement
            let wouldOverflow: Bool = statementBytes + rowBytes + 1 > maxStatementBytes
            if rowsInStatement > 0, isFull || wouldOverflow {
                emit(";\n")
                rowsInStatement = 0
            }
            if rowsInStatement == 0 {
                emit(head)
                statementBytes = head.utf8.count
            }
            emit((rowsInStatement == 0 ? "\n  " : ",\n  ") + values)
            statementBytes += rowBytes
            rowsInStatement += 1
        }
        if rowsInStatement > 0 { emit(";") }
    }

    private static func columnList(_ columns: [ColumnDefinition]) -> String {
        columns.map { SQLText.quoteIdentifier($0.name) }.joined(separator: ", ")
    }

    /// `(1, 'text', NULL)`: numbers as they are when they are finite numbers, everything else as a string literal.
    private static func tuple(_ row: [String?], columns: [ColumnDefinition]) -> String {
        "(" + columns.indices.map { index -> String in
            guard index < row.count, let value = row[index] else { return "NULL" }
            guard columns[index].type.isNumeric, let number = TextValue.double(value), number.isFinite else { return SQLText.literal(value) }
            return value
        }.joined(separator: ", ") + ")"
    }

    // MARK: Files

    /// Streams text to `url` in ~1 MB chunks; removes the file when writing fails.
    private static func writeText(to url: URL, produce: ((String) -> Void) -> Void) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ZipArchiveError.cannotCreate(url.path) }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var buffer = ""
            var failure: (any Error)?
            produce { chunk in
                guard failure == nil else { return }
                buffer += chunk
                if buffer.utf8.count >= 1 << 20 {
                    do { try handle.write(contentsOf: Data(buffer.utf8)) } catch { failure = error }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if let failure { throw failure }
            try handle.write(contentsOf: Data(buffer.utf8))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
