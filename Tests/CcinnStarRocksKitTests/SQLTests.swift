import Foundation
import Testing
import MySQLWire
@testable import CcinnStarRocksKit
import StarRocksKit

@Suite("SQL lexer")
struct SQLLexerTests {
    private func kinds(_ sql: String) -> [(SQLToken.Kind, String)] {
        let lexer = SQLLexer(sql)
        return lexer.tokens().map { ($0.kind, lexer.text(of: $0)) }
    }

    @Test func classifiesTokens() {
        let tokens = kinds("SELECT `order id`, 'it''s', 3.5e2, @@query_timeout FROM t -- note")
        #expect(tokens.map(\.0) == [.keyword, .quotedIdentifier, .punctuation, .string, .punctuation, .number, .punctuation,
                                    .variable, .keyword, .identifier, .comment])
        #expect(tokens.last?.1 == "-- note")
    }

    @Test func handlesCommentsStringsAndUnicode() {
        let tokens = kinds("/* multi\nline */ select '吉隆坡\\'' # hash comment\n x")
        #expect(tokens.map(\.0) == [.comment, .keyword, .string, .comment, .identifier])
        #expect(tokens[2].1 == "'吉隆坡\\''")
    }

    @Test func unterminatedConstructsExtendToEnd() {
        #expect(kinds("select 'abc").last?.0 == .string)
        #expect(kinds("select /* abc").last?.0 == .comment)
        #expect(kinds("select `abc").last?.0 == .quotedIdentifier)
    }

    @Test func rangesAreUTF16() {
        let sql = "select '🇲🇾' x"
        let lexer = SQLLexer(sql)
        let identifier = lexer.tokens().last!
        #expect(identifier.nsRange.location == (sql as NSString).range(of: "x").location)
    }

    @Test func memberAccessIsNotANumber() {
        #expect(kinds("t.col").map(\.0) == [.identifier, .punctuation, .identifier])
        #expect(kinds("select .5").last?.0 == .number)
    }

    @Test func randomInputNeverCrashes() {
        let alphabet = Array("select from 'x' \"y\" `z` -- # /* */ ; . , ( ) @ 0x1F 1e9 吉 \\ \n")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = String((0..<Int.random(in: 0...80, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            _ = SQLLexer.tokenize(text)
            _ = SQLStatementSplitter.split(text)
            _ = AutoLimit.apply(to: text, limit: 10)
            _ = CompletionEngine.complete(text: text, cursor: Int.random(in: 0...text.utf16.count, using: &generator), schema: SchemaSnapshot())
        }
    }
}

@Suite("Statements")
struct StatementTests {
    @Test func splitsOutsideStringsAndComments() {
        let script = "select ';' as a; -- c;\nselect 2 /* ; */;\n\n  ;  select `x;y` from t"
        let statements = SQLStatementSplitter.split(script)
        #expect(statements.map(\.text) == ["select ';' as a", "select 2 /* ; */", "select `x;y` from t"])
    }

    @Test func statementUnderCursor() {
        let script = "select 1;\nselect 2;\n"
        let second = (script as NSString).range(of: "2").location
        #expect(SQLStatementSplitter.statement(at: second, in: script)?.text == "select 2")
        #expect(SQLStatementSplitter.statement(at: 0, in: script)?.text == "select 1")
        #expect(SQLStatementSplitter.statement(at: script.utf16.count, in: script)?.text == "select 2")
    }

    @Test(arguments: [
        ("SELECT * FROM orders", "SELECT * FROM orders LIMIT 1000", true),
        ("select * from orders;", "select * from orders LIMIT 1000;", true),
        ("SELECT * FROM t -- trailing", "SELECT * FROM t LIMIT 1000 -- trailing", true),
        ("WITH c AS (SELECT 1 LIMIT 5) SELECT * FROM c", "WITH c AS (SELECT 1 LIMIT 5) SELECT * FROM c LIMIT 1000", true),
        ("SELECT * FROM t LIMIT 10", "SELECT * FROM t LIMIT 10", false),
        ("select a from t union all select b from u limit 3", "select a from t union all select b from u limit 3", false),
        ("SELECT * FROM t INTO OUTFILE 's3://x'", "SELECT * FROM t INTO OUTFILE 's3://x'", false),
        ("SHOW TABLES", "SHOW TABLES", false),
        ("INSERT INTO t SELECT * FROM u", "INSERT INTO t SELECT * FROM u", false),
    ])
    func autoLimit(input: String, expected: String, applied: Bool) {
        let outcome = AutoLimit.apply(to: input, limit: 1000)
        #expect(outcome.sql == expected)
        #expect(outcome.applied == applied)
    }

    @Test func statementKinds() {
        #expect(SQLStatementKind.of("-- c\n select 1") == .query)
        #expect(SQLStatementKind.of("explain costs select 1") == .explain)
        #expect(SQLStatementKind.of("DROP TABLE t").isMutation)
        #expect(SQLStatementKind.of("show tables") == .show)
        #expect(!SQLStatementKind.of("with x as (select 1) select * from x").isMutation)
    }
}

@Suite("Completion")
struct CompletionTests {
    static let schema = SchemaSnapshot(
        currentDatabase: "shop",
        catalogs: ["default_catalog", "hive"],
        databases: ["shop", "ads"],
        objectsByDatabase: [
            "shop": [.init(name: "orders", kind: .table), .init(name: "customers", kind: .table),
                     .init(name: "mv_city_daily", kind: .asyncMaterializedView), .init(name: "v_paid_orders", kind: .view),
                     .init(name: "mv_orders_by_channel", kind: .syncMaterializedView)],
            "ads": [.init(name: "impressions", kind: .table)],
        ],
        columnsByTable: [
            TableKey(database: "shop", table: "orders"): [
                ColumnInfo(name: "order_id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: false, isKey: true),
                ColumnInfo(name: "city", ordinal: 2, dataType: "varchar", columnType: "varchar(32)", isNullable: false, isKey: false),
                ColumnInfo(name: "total", ordinal: 3, dataType: "decimal", columnType: "decimal(12,2)", isNullable: true, isKey: false),
            ],
            TableKey(database: "shop", table: "customers"): [
                ColumnInfo(name: "customer_id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: false, isKey: true),
                ColumnInfo(name: "city", ordinal: 2, dataType: "varchar", columnType: "varchar(32)", isNullable: true, isKey: false),
            ],
        ])

    private func complete(_ textWithCursor: String) -> CompletionResult {
        let cursor = (textWithCursor as NSString).range(of: "|").location
        let text = textWithCursor.replacingOccurrences(of: "|", with: "")
        return CompletionEngine.complete(text: text, cursor: cursor, schema: Self.schema)
    }

    @Test func columnsOfAnAlias() {
        let result = complete("SELECT o.| FROM orders o")
        #expect(result.items.map(\.label) == ["order_id", "city", "total"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(result.items.allSatisfy { $0.kind == .column })
    }

    @Test func aliasMemberWithPrefixReplacesOnlyThePrefix() {
        let result = complete("SELECT o.ci| FROM orders AS o")
        #expect(result.items.first?.label == "city")
        #expect(result.prefix == "ci")
        #expect(result.replacementRange == 9..<11)
    }

    @Test func tablesAfterFrom() {
        let labels = complete("SELECT * FROM |").items.map(\.label)
        #expect(labels.contains("orders"))
        #expect(labels.contains("mv_city_daily"))
        #expect(labels.contains("v_paid_orders"))
        #expect(!labels.contains("mv_orders_by_channel"), "sync MVs are not queryable by name")
        #expect(labels.contains("ads"))
        #expect(!labels.contains("SELECT"))
    }

    @Test func tablesAfterJoinAndComma() {
        #expect(complete("SELECT * FROM orders o JOIN cu|").items.first?.label == "customers")
        #expect(complete("SELECT * FROM orders o, |").items.contains { $0.label == "customers" })
    }

    @Test func keywordsAfterATableReference() {
        let labels = complete("SELECT * FROM orders o |").items.map(\.label)
        #expect(labels.contains("WHERE"))
        #expect(labels.contains("JOIN"))
        #expect(!labels.contains("orders"))
    }

    @Test func columnsInWhereFromEveryJoinedTable() {
        let result = complete("SELECT * FROM orders o JOIN customers c ON o.city = c.city WHERE cus|")
        #expect(result.items.first?.label == "customer_id")
        let city = complete("SELECT * FROM orders o JOIN customers c WHERE ci|").items.filter { $0.label == "city" }
        #expect(city.count == 2)
    }

    @Test func membersOfADatabase() {
        let labels = complete("SELECT * FROM ads.|").items.map(\.label)
        #expect(labels == ["impressions"])
    }

    @Test func columnsOfQualifiedTable() {
        #expect(complete("SELECT shop.orders.t| FROM shop.orders").items.first?.label == "total")
    }

    @Test func missingColumnsAreReported() {
        let result = complete("SELECT | FROM ads.impressions")
        #expect(result.missingColumns == [TableKey(database: "ads", table: "impressions")])
    }

    @Test func cteAndDerivedColumns() {
        let cte = complete("WITH top AS (SELECT city, SUM(total) AS revenue FROM orders GROUP BY city) SELECT t.| FROM top t")
        #expect(Set(cte.items.map(\.label)) == ["city", "revenue"])
        let derived = complete("SELECT d.| FROM (SELECT order_id AS id, city FROM orders) d")
        #expect(Set(derived.items.map(\.label)) == ["id", "city"])
    }

    @Test func statementStartAndShow() {
        #expect(complete("|").items.contains { $0.label == "SELECT" })
        #expect(complete("SHOW |").items.contains { $0.label == "PARTITIONS FROM" })
        #expect(complete("show partitions from |").items.contains { $0.label == "orders" })
        let materializedViews = complete("REFRESH MATERIALIZED VIEW |").items
        #expect(materializedViews.prefix(2).map(\.label) == ["mv_city_daily", "mv_orders_by_channel"])
        #expect(!materializedViews.contains { $0.label == "orders" })
        #expect(complete("use |").items.contains { $0.label == "ads" })
    }

    @Test func noCompletionInsideStringsAndComments() {
        #expect(complete("SELECT 'or|' FROM orders").items.isEmpty)
        #expect(complete("SELECT 1 -- or|").items.isEmpty)
    }

    @Test func functionsAndFuzzyMatching() {
        let items = complete("SELECT dt| FROM orders").items
        #expect(items.first?.label == "date_trunc")
        #expect(items.first?.insertText == "date_trunc(")
        #expect(complete("SELECT approx_c| FROM orders").items.first?.label == "approx_count_distinct")
    }

    @Test func onlyTheCurrentStatementIsAnalysed() {
        let result = complete("SELECT * FROM customers c;\nSELECT c.| FROM orders c")
        #expect(result.items.map(\.label).contains("order_id"))
        #expect(!result.items.map(\.label).contains("customer_id"))
    }

    @Test func quotesReservedAndUnusualNames() {
        #expect(CompletionEngine.quoteIfNeeded("order") == "`order`")
        #expect(CompletionEngine.quoteIfNeeded("my col") == "`my col`")
        #expect(CompletionEngine.quoteIfNeeded("city") == "city")
        #expect(CompletionEngine.quoteIfNeeded("吉隆坡") == "`吉隆坡`")
    }
}

@Suite("Review regressions")
struct ReviewRegressionTests {
    @Test func withDeleteIsAMutationAndNeverAutoLimited() {
        let sql = "WITH x AS (SELECT id FROM t WHERE flag) DELETE FROM t WHERE id IN (SELECT id FROM x)"
        #expect(SQLStatementKind.of(sql) == .dataModification)
        #expect(SQLStatementKind.of(sql).isMutation)
        #expect(AutoLimit.apply(to: sql, limit: 1000).applied == false)
        #expect(SQLStatementKind.of("WITH a AS (SELECT 1) SELECT * FROM a") == .query)
        #expect(AutoLimit.apply(to: "WITH a AS (SELECT 1) SELECT * FROM a", limit: 10).applied)
    }

    @Test(arguments: ["LOAD LABEL shop.l1 (DATA INFILE('s3://b/x') INTO TABLE t)", "RESTORE SNAPSHOT shop.s FROM repo", "BACKUP SNAPSHOT shop.s TO repo",
                      "EXPORT TABLE t TO 's3://b/'", "SET GLOBAL query_timeout = 1", "FROBNICATE everything", "ADMIN SET FRONTEND CONFIG ('a'='b')"])
    func confirmableStatements(sql: String) {
        #expect(SQLStatementKind.of(sql).isMutation, "\(sql)")
    }

    @Test func readsAreNotMutations() {
        for sql in ["SELECT 1", "SHOW TABLES", "ADMIN SHOW FRONTEND CONFIG", "SET query_timeout = 5", "USE shop", "EXPLAIN SELECT 1"] {
            #expect(!SQLStatementKind.of(sql).isMutation, "\(sql)")
        }
    }

    @Test func redactsCredentials() {
        #expect(SQLRedactor.redact("CREATE USER 'a'@'%' IDENTIFIED BY 'p@ss'") == "CREATE USER 'a'@'%' IDENTIFIED BY '***'")
        #expect(SQLRedactor.redact("ALTER USER a IDENTIFIED WITH mysql_native_password BY \"x\"") == "ALTER USER a IDENTIFIED WITH mysql_native_password BY \"***\"")
        #expect(SQLRedactor.redact("SET PASSWORD = PASSWORD('x')") == "SET PASSWORD = PASSWORD('***')")
        let catalog = #"CREATE EXTERNAL CATALOG h PROPERTIES ("type"="hive", "aws.s3.access_key"="AKIA", "aws.s3.secret_key" = "s3cr3t", "aws.s3.region"="us-east-1")"#
        let redacted = SQLRedactor.redact(catalog)
        #expect(!redacted.contains("AKIA") && !redacted.contains("s3cr3t"))
        #expect(redacted.contains("\"hive\"") && redacted.contains("us-east-1"))
        #expect(SQLRedactor.redact("SELECT 'password' FROM t") == "SELECT 'password' FROM t")
    }
}

@Suite("Chart robustness")
struct ChartRobustnessTests {
    @Test func extremeRangesDoNotTrap() {
        let columns = [ColumnDefinition(name: "x", type: .double), ColumnDefinition(name: "y", type: .double)]
        var rows: [[String?]] = (0..<3_000).map { [String(Double($0)), "1"] }
        rows.append(["1.6e308", "1"])
        rows.append(["-1.6e308", "1"])
        let huge = ChartDataBuilder.build(columns: columns, rows: rows, spec: ChartSpec(kind: .line, xColumn: 0, yColumns: [1]), roles: [.numeric, .numeric])
        #expect(huge.points.count <= 2_100)
        let tiny: [[String?]] = (0..<3_000).map { [$0 % 2 == 0 ? "0" : "5e-324", "1"] }
        let denormal = ChartDataBuilder.build(columns: columns, rows: tiny, spec: ChartSpec(kind: .line, xColumn: 0, yColumns: [1], aggregation: .none),
                                              roles: [.numeric, .numeric])
        #expect(!denormal.points.isEmpty)
    }
}
