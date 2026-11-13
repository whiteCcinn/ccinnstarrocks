import Foundation
import MySQLWire
import StarRocksKit

/// CSV / TSV rendering of result sets.
public enum ResultExport {
    /// RFC 4180 CSV. Text cells that a spreadsheet would evaluate as a formula (`=`, `+`, `-`, `@`,
    /// tab, CR) are prefixed with `'`; numeric columns are left untouched so negative numbers survive.
    public static func csv(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool = true) -> String {
        var output = ""
        output.reserveCapacity(rows.count * max(1, columns.count) * 12)
        write(columns: columns, rows: rows, includeHeader: includeHeader) { output += $0 }
        return output
    }

    /// Streams CSV to a file in ~1 MB chunks so large results do not need one giant string.
    public static func writeCSV(to url: URL, columns: [ColumnDefinition], rows: [[String?]]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = ""
        var failure: (any Error)?
        write(columns: columns, rows: rows, includeHeader: true) { chunk in
            guard failure == nil else { return }
            buffer += chunk
            if buffer.utf8.count >= 1 << 20 {
                do { try handle.write(contentsOf: Data(buffer.utf8)) } catch { failure = error }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if let failure { throw failure }
        try handle.write(contentsOf: Data(buffer.utf8))
    }

    private static func write(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool, emit: (String) -> Void) {
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

    /// Tab-separated text for the clipboard (pastes into spreadsheets); NULL becomes empty.
    public static func tsv(columns: [ColumnDefinition], rows: [[String?]], includeHeader: Bool = true) -> String {
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        if includeHeader { lines.append(columns.map { cleanTSV($0.name) }.joined(separator: "\t")) }
        for row in rows {
            lines.append(columns.indices.map { index in index < row.count ? cleanTSV(row[index] ?? "") : "" }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    static func cleanTSV(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return value }
        return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// `INSERT INTO t (…) VALUES (…);` statements for the selected rows.
    public static func insertStatements(table: String, columns: [ColumnDefinition], rows: [[String?]]) -> String {
        let columnList = columns.map { SQLText.quoteIdentifier($0.name) }.joined(separator: ", ")
        return rows.map { row in
            let values = columns.indices.map { index -> String in
                guard index < row.count, let value = row[index] else { return "NULL" }
                return columns[index].type.isNumeric && TextValue.double(value) != nil ? value : SQLText.literal(value)
            }.joined(separator: ", ")
            return "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
        }.joined(separator: "\n")
    }
}
