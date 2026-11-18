import Foundation
import MySQLWire
import Testing
@testable import CcinnStarRocksKit

@Suite("Result export formats")
struct ResultExportFormatTests {
    let columns = [ColumnDefinition(name: "id", type: .longLong, table: "orders", schema: "shop"),
                   ColumnDefinition(name: "city", type: .varString, table: "orders", schema: "shop"),
                   ColumnDefinition(name: "total", type: .newDecimal, table: "orders", schema: "shop")]
    let rows: [[String?]] = [["1", "Kuala Lumpur", "12.50"], ["2", "O'Neil", nil], ["3", nil, "-0.5"]]

    private func temporaryURL(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-format-\(UUID().uuidString).\(fileExtension)")
    }

    @Test func formatsAndWhatTheyAreFor() {
        #expect(ExportFormat.allCases == [.csv, .tsv, .excel, .insert, .multiRowInsert])
        #expect(ExportFormat.allCases.filter(\.isCopyable) == [.csv, .tsv, .insert, .multiRowInsert], "a workbook is a file only")
        #expect(ExportFormat.allCases.map(\.fileExtension) == ["csv", "tsv", "xlsx", "sql", "sql"])
    }

    @Test func oneInsertPerRowIsUnchanged() {
        #expect(ResultExport.render(.insert, columns: columns, rows: rows, table: "`t`") == """
        INSERT INTO `t` (`id`, `city`, `total`) VALUES (1, 'Kuala Lumpur', 12.50);
        INSERT INTO `t` (`id`, `city`, `total`) VALUES (2, 'O''Neil', NULL);
        INSERT INTO `t` (`id`, `city`, `total`) VALUES (3, NULL, -0.5);
        """)
    }

    @Test func multiRowInsertListsOneRowPerLine() {
        #expect(ResultExport.render(.multiRowInsert, columns: columns, rows: rows, table: "`t`") == """
        INSERT INTO `t` (`id`, `city`, `total`) VALUES
          (1, 'Kuala Lumpur', 12.50),
          (2, 'O''Neil', NULL),
          (3, NULL, -0.5);
        """)
        #expect(ResultExport.render(.multiRowInsert, columns: columns, rows: [], table: "`t`").isEmpty)
    }

    // Each statement stays under the server's packet limit: a new one every N rows or past the byte budget.
    @Test func multiRowInsertStartsANewStatementByRowsAndBySize() {
        let many = (1...5).map { ["\($0)", "c\($0)", "\($0).0"] as [String?] }
        let byRows = ResultExport.multiRowInsert(table: "`t`", columns: columns, rows: many, rowsPerStatement: 2)
        #expect(byRows.components(separatedBy: "INSERT INTO").count - 1 == 3)
        #expect(byRows.hasSuffix("(5, 'c5', 5.0);"))
        #expect(byRows.contains("(2, 'c2', 2.0);\nINSERT INTO `t` (`id`, `city`, `total`) VALUES\n  (3, 'c3', 3.0),"))

        let big = String(repeating: "x", count: 600)
        let bySize = ResultExport.multiRowInsert(table: "`t`", columns: columns, rows: [["1", big, nil], ["2", big, nil], ["3", "small", nil]],
                                                 maxStatementBytes: 1_000)
        #expect(bySize.components(separatedBy: "INSERT INTO").count - 1 == 2, "a row that would pass the budget starts a new statement")
        let oversized = ResultExport.multiRowInsert(table: "`t`", columns: columns, rows: [["1", String(repeating: "y", count: 5_000), nil]],
                                                    maxStatementBytes: 1_000)
        #expect(oversized.components(separatedBy: "INSERT INTO").count - 1 == 1, "a row larger than the budget still gets a statement")
    }

    @Test func nonFiniteNumbersAreQuoted() {
        let double = [ColumnDefinition(name: "x", type: .double)]
        #expect(ResultExport.render(.insert, columns: double, rows: [["nan"], ["inf"], ["1.5"]], table: "`t`") == """
        INSERT INTO `t` (`x`) VALUES ('nan');
        INSERT INTO `t` (`x`) VALUES ('inf');
        INSERT INTO `t` (`x`) VALUES (1.5);
        """)
    }

    // INSERTs go to the table the rows came from, never to the query's alias.
    @Test func insertTargetIsTheSourceTable() {
        #expect(ResultExport.insertTarget(columns: columns) == "`shop`.`orders`")
        let joined = [ColumnDefinition(name: "id", type: .long, table: "o", schema: "shop"), ColumnDefinition(name: "name", type: .varString, table: "c", schema: "shop")]
        #expect(ResultExport.insertTarget(columns: joined) == "`o`")
        #expect(ResultExport.insertTarget(columns: [ColumnDefinition(name: "n", type: .longLong)]) == "`table`")
        #expect(ResultExport.insertTarget(columns: []) == "`table`")
    }

    // StarRocks sends no table in column metadata: a plain single-table SELECT names it instead.
    @Test func singleSourceTableOfAStatement() {
        let cases: [(String, String?)] = [
            ("select * from shop.orders order by order_id limit 20000", "`shop`.`orders`"),
            ("SELECT a, b FROM orders o WHERE x = 1", "`orders`"),
            ("select * from orders as o;", "`orders`"),
            ("select * from default_catalog.shop.orders", "`default_catalog`.`shop`.`orders`"),
            ("select * from `my table` t group by 1 having count(*) > 1", "`my table`"),
            ("select * from t partition (p1) limit 5", "`t`"),
            ("/* hint */ select count(*) from t -- note", "`t`"),
            ("select * from a join b on a.id = b.id", nil),
            ("select * from a, b", nil),
            ("select * from a left outer join b using (id)", nil),
            ("select * from (select 1) t", nil),
            ("select 1 union all select 2 from t", nil),
            ("with x as (select 1) select * from x", nil),
            ("select 1", nil),
            ("select * from t1 where id in (select id from t2)", "`t1`"),
            ("show tables from shop", nil),
        ]
        for (sql, expected) in cases {
            #expect(ResultExport.singleSourceTable(of: sql) == expected, "\(sql)")
        }
    }

    @Test func insertTargetPrefersColumnsThenTheStatement() {
        let unnamed = [ColumnDefinition(name: "id", type: .longLong), ColumnDefinition(name: "city", type: .varString)]
        #expect(ResultExport.insertTarget(columns: unnamed, sql: "select * from shop.orders") == "`shop`.`orders`")
        #expect(ResultExport.insertTarget(columns: unnamed, sql: "select * from a join b") == "`table`")
        #expect(ResultExport.insertTarget(columns: columns, sql: "select * from other") == "`shop`.`orders`", "the server's metadata wins")
        let aliased = [ColumnDefinition(name: "id", type: .long, table: "o", schema: "shop"), ColumnDefinition(name: "n", type: .long)]
        #expect(ResultExport.insertTarget(columns: aliased, sql: "select o.id, 1 n from shop.orders o") == "`shop`.`orders`",
                "an alias in the metadata loses to the statement's table")
    }

    @Test func textFilesHoldWhatIsCopied() throws {
        for format in ExportFormat.allCases where format.isCopyable {
            let url = temporaryURL(format.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            let summary = try ResultExport.write(format, to: url, columns: columns, rows: rows, table: "`t`", sheetName: "orders")
            #expect(summary.rows == 3)
            let text = try String(contentsOf: url, encoding: .utf8)
            let rendered = ResultExport.render(format, columns: columns, rows: rows, table: "`t`")
            #expect(text == (format == .csv ? rendered : rendered + "\n"), "\(format)")
        }
    }

    @Test func excelFileTypesCellsByColumn() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = try ResultExport.write(.excel, to: url, columns: columns, rows: rows, table: "`t`", sheetName: "orders")
        #expect(summary == XLSXWriter.Summary(rows: 3, truncatedCells: 0))
        #expect(ResultExport.cellKinds(columns) == [.integer, .text, .decimal(scale: 0)], "test columns carry no scale")
        #expect(ResultExport.cellKinds([ColumnDefinition(name: "f", type: .double), ColumnDefinition(name: "d", type: .datetime)])
                == [.approximateNumber, .text])
    }

    @Test func excelRefusesMoreRowsThanASheetHolds() {
        #expect(throws: XLSXWriter.Failure.self) {
            try XLSXWriter.write(to: temporaryURL("xlsx"), sheetName: "t", header: ["id"], kinds: [.integer],
                                 rows: [["1"], ["2"]], rowLimit: 1)
        }
    }
}
