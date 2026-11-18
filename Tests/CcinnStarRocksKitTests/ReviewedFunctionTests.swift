import Foundation
import Testing
@testable import CcinnStarRocksKit

/// 1.3.2 review: a deny list cannot keep up with StarRocks's FE "meta" functions, which SHOW BUILTIN FUNCTIONS does not
/// list. Probed on 3.3 and 4.1 for an account with only SELECT on shop.orders: lookup_string (3.3) and dict_mapping (4.1)
/// return rows of shop.customers; get_query_dump returns another table's DDL, partition row counts and column statistics;
/// inspect_mv_meta and inspect_mv_plan (and on 4.1 inspect_mv_refresh_info and inspect_table_partition_info) describe a
/// materialized view the account cannot read. AI read-only queries may call only reviewed built-in functions.
@Suite("Reviewed functions for AI")
struct ReviewedFunctionTests {
    static let leakingCalls = [
        "lookup_string('shop.customers', '1', 'name')",
        "dict_mapping('shop.customers', 1, 'name')",
        "get_query_dump('select * from shop.customers')",
        "get_query_dump('select * from shop.customers', true)",
        "get_query_dump_from_query_id('01a1ed58-b960-787d-a723-b8e66463fa14')",
        "inspect_mv_meta('shop.mv_city_daily')",
        "inspect_mv_plan('shop.mv_city_daily')",
        "inspect_mv_refresh_info('shop.mv_city_daily')",
        "inspect_table_partition_info('shop.customers')",
        "dictionary_get('shop_dict', 1)",
        "list_rowsets(10018, 1)",
        "host_name()",
        "INSPECT_RELATED_MV('shop.customers')",
        "`inspect_mv_meta`('shop.mv_city_daily')",
        "Lookup_String ('shop.customers', '1', 'name')",
        "inspect_some_future_function('x')",
        "get_query_dump/* c */('select 1')",
    ]

    /// Refused in every shape that reaches the server: run_query, explain_query (with and without COSTS), EXPLAIN text,
    /// CTEs, subqueries, table functions, SHOW … WHERE, and execute_statement (the read-write path).
    @Test(arguments: leakingCalls)
    func leakingCallsAreRefusedEverywhere(call: String) {
        let queries = [
            "SELECT \(call) AS v",
            "SELECT city, \(call) FROM shop.orders",
            "SELECT * FROM shop.orders WHERE city = \(call)",
            "WITH x AS (SELECT \(call) AS v) SELECT * FROM x",
            "WITH x(v) AS (SELECT \(call)) SELECT * FROM x",
            "SELECT * FROM (SELECT \(call) AS v) d",
            "SELECT * FROM shop.orders WHERE city IN (SELECT \(call))",
            "SELECT * FROM shop.orders WHERE EXISTS (SELECT \(call))",
            "SELECT abs(length(\(call)))",
            "SELECT * FROM TABLE(\(call))",
            "(SELECT 1) UNION ALL (SELECT \(call))",
        ]
        for sql in queries {
            #expect(throws: ReadOnlySQLGuard.Rejection.self, "run_query: \(sql)") {
                try ReadOnlySQLGuard.wireStatement(for: sql, rowLimit: 11, database: "shop")
            }
            for costs in [false, true] {
                #expect(throws: ReadOnlySQLGuard.Rejection.self, "explain_query: \(sql)") {
                    try ReadOnlySQLGuard.explainStatement(for: sql, costs: costs, database: "shop")
                }
            }
            #expect(ReadOnlySQLGuard.check("EXPLAIN VERBOSE \(sql)") != nil, "\(sql)")
            #expect(throws: MCPToolError.self, "execute_statement: \(sql)") { try StarRocksMCPTools.executableStatement(sql) }
            #expect(throws: MCPToolError.self, "execute_statement: \(sql)") {
                try StarRocksMCPTools.executableStatement("INSERT INTO shop.copy \(sql)")
            }
        }
        for sql in ["SHOW TABLES WHERE Tables_in_shop = \(call)", "SHOW FULL TABLES FROM shop WHERE \(call) IS NOT NULL",
                    "SHOW PARTITIONS FROM shop.orders WHERE PartitionName = \(call)", "SHOW VARIABLES WHERE Value = \(call)",
                    "ADMIN SHOW REPLICA STATUS FROM shop.orders WHERE Status = \(call)"] {
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
            #expect(throws: ReadOnlySQLGuard.Rejection.self, "run_query: \(sql)") {
                try ReadOnlySQLGuard.wireStatement(for: sql, rowLimit: 11, database: "shop")
            }
            #expect(throws: MCPToolError.self, "execute_statement: \(sql)") { try StarRocksMCPTools.executableStatement(sql) }
        }
    }

    @Test func deniedFunctionsKeepTheirReason() {
        #expect(ReadOnlySQLGuard.check("SELECT lookup_string('shop.customers', '1', 'name')")?.hasPrefix("LOOKUP_STRING() is not available to AI") == true)
        #expect(ReadOnlySQLGuard.check("SELECT inspect_mv_plan('shop.mv')")?.hasPrefix("INSPECT_MV_PLAN() is not available to AI") == true)
        #expect(ReadOnlySQLGuard.check("SELECT * FROM FILES('path' = 'file:///etc/passwd')")?.hasPrefix("FILES() is not available to AI") == true)
    }

    /// User-defined functions can do anything (read files, call out), so AI may not call them; qualified calls are UDFs,
    /// even when the name matches a reviewed built-in. Unknown names are refused too: deny by default.
    @Test(arguments: [
        "SELECT my_udf(city) FROM shop.orders",
        "SELECT shop.my_udf(city) FROM shop.orders",
        "SELECT default_catalog.shop.my_udf(city) FROM shop.orders",
        "SELECT `shop`.`my_udf`(city) FROM shop.orders",
        "SELECT shop . my_udf /* c */ (city) FROM shop.orders",
        "SELECT shop.abs(total) FROM shop.orders",
        "SELECT `shop`.`abs`(total) FROM shop.orders",
        "SELECT shop.1fn(total) FROM shop.orders",
        "SELECT 1fn(total) FROM shop.orders",
        "SELECT * FROM shop.my_table_function(1)",
        "SELECT * FROM TABLE(shop.my_table_function(1))",
        "SELECT * FROM shop.orders, LATERAL my_udtf(city) t",
        "SELECT abs(my_udf(total)) FROM shop.orders",
        "SELECT sum(total) OVER (PARTITION BY my_udf(city)) FROM shop.orders",
        "SELECT city FROM shop.orders ORDER BY my_udf(city)",
        "SELECT CAST(my_udf(total) AS DECIMAL(10, 2)) FROM shop.orders",
        "SELECT \"abs\"(total) FROM shop.orders",
        "SELECT 'abs'(total) FROM shop.orders",
        "SELECT `select`(1)", "SELECT `in`(1)", "SELECT `as`(1)",
        "SELECT password('x')", "SELECT try_cast('1' AS INT)", "SELECT nvl(city, 'x') FROM shop.orders",
        "SHOW TABLES WHERE my_udf(Tables_in_shop) = 1",
        "EXPLAIN SELECT my_udf(1)", "EXPLAIN COSTS (SELECT shop.my_udf(1))",
        "ADMIN SHOW REPLICA STATUS FROM shop.orders WHERE my_udf(Status) = 1",
        "WITH c AS (SELECT 1 AS a) SELECT c(1) AS x FROM c",
    ])
    func unreviewedAndUserDefinedFunctionsAreRefused(sql: String) {
        let reason = ReadOnlySQLGuard.check(sql)
        #expect(reason?.contains("is not on CcinnStarRocks's list of reviewed functions for AI") == true, "\(sql): \(reason ?? "allowed")")
    }

    @Test func theRefusalNamesTheFunction() throws {
        #expect(ReadOnlySQLGuard.check("SELECT My_Udf(1)") == "`my_udf()` is not on CcinnStarRocks's list of reviewed functions for AI (functions that read files, other users' data or the network are excluded). Run it in the SQL editor if it is needed.")
        #expect(ReadOnlySQLGuard.check("SELECT Shop.`My_Udf`(1)")?.hasPrefix("`shop.my_udf()` is not on CcinnStarRocks's list") == true)
        #expect(throws: ReadOnlySQLGuard.Rejection.self) { try ReadOnlySQLGuard.wireStatement(for: "SELECT my_udf(1)", rowLimit: 11, database: "shop") }
        #expect(throws: ReadOnlySQLGuard.Rejection.self) { try ReadOnlySQLGuard.explainStatement(for: "SELECT my_udf(1)", costs: true, database: "shop") }
        // execute_statement is the read-write path the user enabled for that connection: it refuses only denied functions.
        #expect(try StarRocksMCPTools.executableStatement("SELECT my_udf(1)") == "SELECT my_udf(1)")
    }

    /// Probed on 3.3 and 4.1: these words are not reserved there, so before `(` the server reads a call (a UDF of that
    /// name would run). `INTERVAL (1) DAY` after `+` is `interval(1)` aliased DAY; `BINARY(a, b)` and `ROLLUP(…)` outside
    /// GROUP BY are calls; EXCEPT is reserved on 3.3 only.
    @Test(arguments: [
        "SELECT order_date + INTERVAL (1) DAY FROM shop.orders",
        "SELECT binary(city, 1) FROM shop.orders",
        "SELECT city FROM shop.orders GROUP BY city, ROLLUP (city)",
        "SELECT city FROM shop.orders ORDER BY rollup(city)",
        "SELECT tablet(1)", "SELECT 1, partitions(1)", "SELECT replica(1)", "SELECT tablets(1)",
        "SELECT * FROM shop.orders, tablet(1)",
        "SELECT * FROM shop.orders, LATERAL tablet(1) t",
        "SELECT * FROM shop.orders WHERE total = tablet(1)",
        "SELECT 10 DIV tablet(1)", "SELECT 1, 10 MOD tablet(1)",
        "SELECT except(1)", "SELECT minus(1)", "SELECT except((SELECT 1))",
        "SELECT any(1)", "SELECT some(1)", "SELECT offset(1)", "SELECT temporary(1)", "SELECT recursive(1)",
        "SELECT string(1)", "SELECT datetime(1)", "SELECT varbinary(1)", "SELECT decimal256(1)", "SELECT xor(1)",
        "SELECT 1 < varbinary(1)", "SELECT costs(1)", "SELECT verbose(1)", "SELECT logical(1)", "SELECT sets(1)",
        "SELECT grouping sets(1)", "SELECT of(1)", "SELECT escape(1)", "SELECT interval(1)", "SELECT array(1)",
    ])
    func nonReservedWordsBeforeParenthesesAreCalls(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql)?.contains("is not on CcinnStarRocks's list of reviewed functions for AI") == true, "\(sql)")
    }

    /// Deny by default costs some valid SQL; each is a rare spelling with a plain alternative.
    @Test(arguments: [
        "SELECT 1 EXCEPT ((SELECT 2))",                 // EXCEPT (SELECT 2)
        "SELECT CAST(NULL AS ARRAY<VARBINARY(10)>)",    // ARRAY<VARBINARY>
        "SELECT * FROM shop.data TABLET (1)",           // shop.`data` TABLET (1)
        "SELECT order_date + INTERVAL (1) DAY FROM shop.orders",              // INTERVAL 1 DAY: here `interval(1)` aliased DAY
        "SELECT * FROM shop.orders WHERE order_date > now() - INTERVAL (7) DAY", // INTERVAL 7 DAY
        "SELECT city FROM shop.orders QUALIFY (row_number() OVER (PARTITION BY city ORDER BY total)) = 1", // QUALIFY row_number() …
    ])
    func knownOverRefusals(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    /// Probed on 3.3 and 4.1. A name right after a select-list star (after SELECT, DISTINCT, ALL, `,` or `.`) is a syntax
    /// error, never a call, so `* EXCEPT (…)` and `* EXCLUDE (…)` (4.1) are column lists; after a value, `*` multiplies and
    /// `2 * exclude(1)` is a call. Inside a function call's parentheses a call followed by a time unit is a syntax error
    /// for every unit and argument form, so there `INTERVAL (n) DAY` is an interval; elsewhere it may be `interval(n)`
    /// aliased DAY, or (with no unit, or another word) a call.
    @Test(arguments: [
        "SELECT * EXCEPT (city) FROM shop.orders", "SELECT * EXCLUDE (city, channel) FROM shop.orders",
        "SELECT o.* EXCLUDE (city) FROM shop.orders o", "SELECT DISTINCT * EXCLUDE (city) FROM shop.orders",
        "SELECT ALL * EXCEPT (city) FROM shop.orders", "SELECT 1 AS a, * EXCEPT (city) FROM shop.orders",
        "SELECT date_add(order_date, INTERVAL (1) DAY) FROM shop.orders", "SELECT date_sub(now(), INTERVAL (1 + 1) HOUR)",
        "SELECT if(true, now() + INTERVAL (1) DAY, now())", "SELECT array_agg(city ORDER BY order_date + INTERVAL (2) MONTH) FROM shop.orders",
        "SELECT array_map(x -> x + INTERVAL (1) YEAR, [now()])", "SELECT CAST(now() + INTERVAL (3) MINUTE AS DATE)",
        "SELECT date_add(order_date, interval (total) second) FROM shop.orders",
    ])
    func starColumnListsAndIntervalsInArgumentsAreAllowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    @Test(arguments: [
        "SELECT 2 * exclude(1)", "SELECT 2 * except(1)", "SELECT total * exclude(1) FROM shop.orders", "SELECT count(* except(1))",
        "SELECT o.total * exclude(1) FROM shop.orders o", "SELECT `*` exclude(1)",
        "SELECT concat('a', INTERVAL (1))", "SELECT group_concat(INTERVAL (1) SEPARATOR ',')", "SELECT array_agg(INTERVAL (1) ORDER BY 1)",
        "SELECT abs(INTERVAL (1) DIV 2)", "SELECT abs(INTERVAL (1) IS NULL)", "SELECT (INTERVAL (1) DAY)", "SELECT abs((SELECT INTERVAL (1) DAY))",
        "SELECT EXISTS (SELECT INTERVAL (1) DAY)", "SELECT * FROM shop.orders WHERE city IN (INTERVAL (1) DAY)", "SELECT my_udf(INTERVAL (1) DAY)",
        "SELECT sum(1) OVER (ORDER BY INTERVAL (1) DAY)", "SELECT abs(INTERVAL (1) DAYS)", "SELECT abs(`INTERVAL` (1) DAY)",
    ])
    func starsAfterValuesAndIntervalsElsewhereAreCalls(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql)?.contains("list of reviewed functions") == true, "\(sql)")
    }

    @Test(arguments: [
        "SELECT city, count(*), sum(total), avg(total), min(order_date), max(order_date), count(DISTINCT customer_id), COUNT(DISTINCT (city)) FROM shop.orders GROUP BY city HAVING sum(total) > (100)",
        "SELECT city, total, row_number() OVER (PARTITION BY city ORDER BY total DESC), rank() OVER (ORDER BY total), sum(total) OVER (PARTITION BY city ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), lag(total, 1) OVER (PARTITION BY city ORDER BY order_date) FROM shop.orders",
        "SELECT CAST(total AS DECIMAL(10, 2)), CAST(city AS VARCHAR(20)), CAST(city AS CHAR(3)), CAST(total AS DECIMAL64(18, 4)), CAST(city AS VARBINARY(10)), CAST(city AS BINARY(3)), CONVERT(total, DECIMAL(10, 2)), cast(total AS DOUBLE) FROM shop.orders",
        "SELECT CAST(NULL AS ARRAY<DECIMAL(10, 2)>), CAST(NULL AS MAP<INT, VARCHAR(10)>), CAST(NULL AS STRUCT<a DECIMAL128(30, 2), b DECIMALV2(10, 2)>), CAST(NULL AS ARRAY<DECIMAL32(5, 1)>)",
        "SELECT EXTRACT(YEAR FROM order_date), date_trunc('month', order_date), date_format(order_date, '%Y-%m'), datediff(now(), order_date), date_add(order_date, INTERVAL 1 DAY), timestampdiff(DAY, order_date, now()), timestampadd(HOUR, 1, order_date), year(order_date), month(order_date), day(order_date), str_to_date('2024-01-01', '%Y-%m-%d'), current_date(), curdate(), CURRENT_TIMESTAMP FROM shop.orders",
        "SELECT array_map(x -> x * 2, [1, 2, 3]), array_map((x, y) -> x + y, [1], [2]), array_filter(x -> x > 1, [1, 2]), named_struct('a', 1, 'b', 2), struct(1, 2), map(1, 'a'), map_keys(map{1:2}), row(1, 2), element_at([1, 2], 1), array_agg(city), ARRAY<INT>[1, 2]",
        "WITH c(a, b) AS (SELECT city, total FROM shop.orders), d(x) AS (SELECT 1) SELECT * FROM c, d",
        "WITH `c`(a) AS (SELECT 1), data(b) AS (SELECT 2) SELECT * FROM `c`, data",
        "WITH RECURSIVE c(n) AS (SELECT 1) SELECT * FROM c",
        "SELECT * FROM (SELECT 1, 2) t(a, b)", "SELECT * FROM (SELECT 1, 2) AS t(a, b)", "SELECT * FROM (SELECT 1, 2) `t`(a, b)",
        "SELECT * FROM (VALUES (1, 'a'), (2, 'b')) AS v(id, name)", "SELECT * FROM (VALUES (1)) v(a)",
        "SELECT count(*) FROM shop.orders PARTITION (p202401)", "SELECT count(*) FROM shop.orders PARTITIONS (p202401, p202402)",
        "SELECT count(*) FROM shop.orders TEMPORARY PARTITION (tp1)", "SELECT count(*) FROM shop.orders TABLET (10018)",
        "SELECT count(*) FROM orders TABLET(10018)", "SELECT count(*) FROM shop.`orders` TABLET (10018, 10019)",
        "SELECT count(*) FROM shop.orders PARTITION (p202401) TABLET (10018) REPLICA (1)", "SELECT count(*) FROM shop.orders TABLETS (10018)",
        "SELECT count(*) FROM shop.orders REPLICA (1)", "SELECT * FROM shop.orders o JOIN shop.customers TABLET (2) ON o.customer_id = customers.id",
        "SELECT count(*) FROM shop.orders a, shop.customers TABLET (2)",
        "SELECT * FROM shop.orders WHERE city IN ('a', 'b') AND EXISTS (SELECT 1 FROM shop.orders o2 WHERE o2.id = orders.id) AND NOT (total > 1) OR (total BETWEEN (1) AND (2))",
        "SELECT CASE (city) WHEN ('a') THEN (1) ELSE (2) END, CASE WHEN (total > 1) THEN (total) END FROM shop.orders",
        "SELECT 1 UNION ALL (SELECT 2) UNION (SELECT 3) UNION DISTINCT (SELECT 4) INTERSECT (SELECT 3) EXCEPT (SELECT 4) MINUS (SELECT 5)",
        "SELECT 1 EXCEPT (WITH a AS (SELECT 1) SELECT * FROM a)", "SELECT 1 MINUS (WITH a AS (SELECT 1) SELECT * FROM a)",
        "(SELECT 1) UNION ((SELECT 2))",
        "SELECT * FROM shop.orders a JOIN shop.customers b ON (a.customer_id = b.id) JOIN (SELECT 1 AS id) c USING (id)",
        "SELECT * FROM shop.orders, LATERAL (SELECT 1) x", "SELECT * FROM shop.orders, unnest([1, 2]) AS u(x)",
        "SELECT * FROM shop.orders CROSS JOIN LATERAL unnest([1, 2]) t(x)", "SELECT * FROM TABLE(generate_series(1, 10))",
        "SELECT * FROM generate_series(1, 10) AS g(n)",
        "SELECT city, channel FROM shop.orders GROUP BY ROLLUP (city, channel)", "SELECT city FROM shop.orders GROUP BY CUBE (city, channel)",
        "SELECT city, grouping(city), grouping_id(city, channel) FROM shop.orders GROUP BY GROUPING SETS ((city), (channel), ())",
        "SELECT (SELECT max(total) FROM shop.orders), (1) DIV (2), 10 DIV (3), 10 MOD (3), 'a' LIKE ('a%'), 'a' NOT RLIKE ('b'), 'a' REGEXP ('a'), like('a', 'a'), rlike('a', 'a')",
        "SELECT if(total > 1, 1, 2), ifnull(city, ''), coalesce(city, channel), nullif(city, ''), isnull(city), isnotnull(city), greatest(1, 2), concat('a', city), substr(city, 1, 2), upper(city), trim(city), length(city), replace(city, 'a', 'b'), left(city, 1), right(city, 1), round(total, 2), abs(total), floor(total), ceil(total), mod(total, 2) FROM shop.orders",
        "SELECT percentile_approx(total, 0.5), approx_count_distinct(customer_id), group_concat(city ORDER BY city SEPARATOR ','), any_value(city), max_by(city, total), stddev(total), variance(total), count_if(total > 1) FROM shop.orders",
        "SELECT database(), schema(), user(), current_user(), current_role(), connection_id(), catalog(), session_id(), current_warehouse(), current_group(), version(), current_version(), last_query_id(), typeof(1), CURRENT_USER",
        "SELECT get_json_string(parse_json('{}'), '$.a'), json_query(parse_json('{}'), '$.a'), json_object('a', 1), `abs`(-1), `ABS`(-1)",
        "SELECT abs(-1)", "SELECT ABS (-1)", "SELECT abs/* c */(-1)",
        "EXPLAIN (SELECT 1)", "EXPLAIN COSTS (SELECT abs(1))", "EXPLAIN VERBOSE SELECT sum(total) FROM shop.orders", "EXPLAIN LOGICAL (SELECT 1)",
        "SHOW TABLET FROM shop.orders PARTITION (p202401)", "SHOW PARTITIONS FROM shop.orders WHERE PartitionName = upper('p1')",
        "ADMIN SHOW REPLICA STATUS FROM shop.orders PARTITION (p1, p2) WHERE STATUS != 'OK'",
        "ADMIN SHOW REPLICA DISTRIBUTION FROM shop.orders PARTITION (p202401)",
    ])
    func ordinaryAnalyticsAreAllowed(sql: String) throws {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
        _ = try ReadOnlySQLGuard.wireStatement(for: sql, rowLimit: 11, database: "shop")
    }

    @Test func callsAreFoundWhereTheServerReadsThem() {
        #expect(Self.calls("SELECT abs(x), sum(y) OVER (PARTITION BY z) FROM t WHERE a IN (1) AND EXISTS (SELECT count(*) FROM u)")
            == ["abs", "sum", "count"])
        #expect(Self.calls("SELECT CAST(a AS DECIMAL(10, 2)), EXTRACT(YEAR FROM d) FROM t PARTITION (p) TABLET (1)") == ["cast", "extract"])
        #expect(Self.calls("WITH c(a) AS (SELECT f(1)), d(b) AS (SELECT 2) SELECT * FROM (SELECT g()) x(y)") == ["f", "g"])
        #expect(Self.calls("SELECT a.b.c(1), `d`.e (2), 'f'(3), 4g(4)") == ["a.b.c", "d.e", "'f'", "4g"])
        #expect(SQLFunctionCalls.calls(in: [], lexer: SQLLexer("")).isEmpty)
        // Only plain ASCII words grant an exception: `ın` upper-cases to IN and `Aſ` to AS, yet neither is exempt here
        // (the guard refuses such names before this anyway).
        #expect(Self.calls("SELECT x ın (1), CAST(y Aſ my_udf(2))") == ["ın", "cast", "my_udf"])
        let qualified = Self.lexed("SELECT shop.f(1), g(2)")
        #expect(SQLFunctionCalls.calls(in: qualified.tokens, lexer: qualified.lexer).map(\.isQualified) == [true, false])
    }

    /// Every word the guard reads as syntax before `(`: never a call when bare, always one when back-quoted. The
    /// integration test checks each is reserved on the live servers.
    @Test func syntaxKeywordsArePinned() {
        #expect(SQLFunctionCalls.syntaxKeywords == [
            "ALL", "AND", "AS", "BETWEEN", "BY", "CASE", "CUBE", "DECIMAL", "DECIMAL128", "DECIMAL32", "DECIMAL64", "DECIMALV2",
            "DISTINCT", "DIV", "ELSE", "EXISTS", "FROM", "HAVING", "IN", "INTERSECT", "JOIN", "LATERAL", "NOT", "ON", "OR", "OVER",
            "PARTITION", "SELECT", "TABLE", "THEN", "UNION", "USING", "VALUES", "VARCHAR", "WHEN", "WHERE",
        ])
        for word in SQLFunctionCalls.syntaxKeywords {
            #expect(Self.calls("SELECT x \(word) (1)").isEmpty, "\(word)")
            #expect(Self.calls("SELECT x \(word.lowercased())(1)").isEmpty, "\(word)")
            #expect(Self.calls("SELECT `\(word)`(1)") == [word.lowercased()], "\(word)")
        }
    }

    @Test func theReviewedListIsPinned() {
        let names = ReviewedFunctions.names
        #expect(ReviewedFunctions.listed.count == 816)
        #expect(ReviewedFunctions.unlisted == [
            "cast", "catalog", "connection_id", "convert", "current_group", "current_role", "current_user", "current_warehouse",
            "database", "element_at", "extract", "isnotnull", "isnull", "map", "rlike", "schema", "session_id", "struct",
            "timestampadd", "timestampdiff", "typeof", "user",
        ])
        #expect(names.count == 838)
        #expect(ReviewedFunctions.listed.isDisjoint(with: ReviewedFunctions.unlisted))
        #expect(names.allSatisfy { name in !name.isEmpty && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" } })
        #expect(names.filter(ReadOnlySQLGuard.isDeniedFunction).isEmpty)
        #expect(!names.contains { $0.hasPrefix("inspect_") })
        for name in ["abs", "sum", "count", "row_number", "date_trunc", "array_map", "named_struct", "generate_series", "unnest", "like", "regexp"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(ReadOnlySQLGuard.deniedFunctions == [
            "ai_query", "dict_mapping", "dictionary_get", "files", "get_query_dump", "get_query_dump_from_query_id", "get_query_profile",
            "host_name", "list_rowsets", "lookup_string",
        ])
        #expect(ReviewedFunctions.unlistedMetaFunctions == [
            "dict_mapping", "dictionary_get", "files", "get_query_dump", "get_query_dump_from_query_id", "inspect_all_pipes",
            "inspect_hive_part_info", "inspect_memory", "inspect_memory_detail", "inspect_mv_meta", "inspect_mv_plan",
            "inspect_mv_refresh_info", "inspect_mv_relationships", "inspect_related_mv", "inspect_table_partition_info",
            "inspect_task_runs", "lookup_string",
        ])
        for name in ReviewedFunctions.unlistedMetaFunctions {
            #expect(ReadOnlySQLGuard.isDeniedFunction(name) && !names.contains(name), "\(name)")
            #expect(ReadOnlySQLGuard.check("SELECT \(name)('x')")?.contains("is not available to AI") == true, "\(name)")
            #expect(throws: MCPToolError.self, "\(name)") { try StarRocksMCPTools.executableStatement("SELECT \(name)('x')") }
        }
    }

    /// Linear in the number of tokens, with no recursion: deep nesting and unbalanced parentheses neither crash nor stall.
    @Test func deepAndUnbalancedTextIsHandled() {
        let depth = 20_000
        let nested = "SELECT " + String(repeating: "abs(", count: depth) + "1" + String(repeating: ")", count: depth)
        #expect(ReadOnlySQLGuard.check(nested) == nil)
        let chain = "SELECT " + Array(repeating: "a", count: depth).joined(separator: ".") + "(1)"
        #expect(ReadOnlySQLGuard.check(chain) != nil)
        for sql in ["SELECT abs((((", "SELECT ))) abs(1", "SELECT abs(", "WITH c(", "WITH c(a) AS", "WITH c(a) AS (", "SELECT x AS (",
                    "SELECT (", ")", "(", "SELECT abs(1)) my_udf(", "SELECT tablet(", "SELECT FROM TABLET("] {
            _ = ReadOnlySQLGuard.check(sql)
            _ = Self.calls(sql)
        }
        #expect(Self.calls("SELECT my_udf(") == ["my_udf"])
        #expect(Self.calls("SELECT x) my_udf(1)").isEmpty, "after `)`: an alias with columns")
    }

    private static func lexed(_ sql: String) -> (tokens: [SQLToken], lexer: SQLLexer) {
        let lexer = SQLLexer(sql)
        return (lexer.tokens().filter { $0.kind != .comment }, lexer)
    }

    private static func calls(_ sql: String) -> [String] {
        let (tokens, lexer) = lexed(sql)
        return SQLFunctionCalls.calls(in: tokens, lexer: lexer).map(\.name)
    }
}

/// 1.3.2 review (probed on 3.3 and 4.1): every spelling under which the server calls a function is a call for the guard,
/// and no other way of invoking a function exists (higher-order functions take only lambdas; there is no call/apply).
@Suite("Function call spellings")
struct FunctionCallSpellingTests {
    @Test(arguments: [
        // Back-quoted, any case: `lookup_string`(…) returned 'Customer 1' on 3.3.
        "SELECT `lookup_string`('shop.customers', '1', 'name')", "SELECT `LOOKUP_STRING`('shop.customers', '1', 'name')",
        "SELECT `Get_Query_Dump`('select 1')",
        // Comments and line breaks between the name and `(`.
        "SELECT lookup_string -- c\n ('shop.customers', '1', 'name')", "SELECT lookup_string\n\n('shop.customers', '1', 'name')",
        "SELECT lookup_string /* c */ ('shop.customers', '1', 'name')",
        // Database-qualified names fall back to built-ins on the server (`shop.upper('x')` is 'X').
        "SELECT shop.lookup_string('shop.customers', '1', 'name')", "SELECT `shop`.`files`('path' = 'file:///etc/hostname')",
        "SELECT shop.inspect_mv_meta('shop.mv_city_daily')", "SELECT default_catalog.shop.get_query_dump('select 1')",
        // A double-quoted name is an identifier in the trino dialect.
        "SELECT \"lookup_string\"('shop.customers', '1', 'name')", "SELECT \"ai_query\"('p', '{}')", "SELECT \"get_query_dump\"('select 1')",
        // Lambda bodies and table functions hold ordinary calls.
        "SELECT array_map(x -> lookup_string('shop.customers', x, 'name'), ['1'])",
        "SELECT array_filter(x -> get_query_dump(x) IS NOT NULL, ['select 1'])",
        "SELECT * FROM shop.orders, LATERAL inspect_mv_plan('shop.mv_city_daily') t", "SELECT * FROM TABLE(list_rowsets(1, 1))",
    ])
    func everySpellingOfALeakingCallIsRefused(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
        #expect(throws: MCPToolError.self, "execute_statement: \(sql)") { try StarRocksMCPTools.executableStatement(sql) }
    }

    @Test(arguments: [
        "SELECT `upper`('x')", "SELECT `UPPER`('x')", "SELECT upper -- c\n ('x')", "SELECT upper /* c */ ('x')",
        "SELECT array_map(x -> upper(x), ['a'])", "SELECT array_map((x, y) -> concat(x, y), ['a'], ['b'])",
    ])
    func reviewedFunctionsInEverySpellingAreAllowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    /// Qualified calls reach built-ins, so every one is refused for AI, reviewed names included.
    @Test(arguments: ["SELECT shop.upper('x')", "SELECT `shop`.`upper`('x')", "SELECT \"upper\"('x')"])
    func qualifiedOrQuotedReviewedNamesAreRefused(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql)?.contains("list of reviewed functions") == true, "\(sql)")
    }
}

/// With `sql_dialect = trino` the server reads `"…"` as a name. AI connections pin the StarRocks dialect (see
/// StarRocksDialect); the guard also reads double-quoted text as a name wherever a name is checked, in case it is not.
@Suite("AI and the SQL dialect")
struct AIDialectTests {
    @Test(arguments: [
        "SELECT \"task_name\", substr(\"definition\", 1, 50) FROM information_schema.\"tasks\"",
        "SELECT * FROM \"information_schema\".\"tasks\"", "SELECT * FROM \"INFORMATION_SCHEMA\".tasks",
        "SELECT * FROM \"_statistics_\".\"query_history\"", "SELECT * FROM \"starrocks_audit_db__\".\"starrocks_audit_tbl__\"",
        "SELECT \"files\"('path' = 'file:///etc/passwd')", "SELECT \"lookup_string\"('shop.customers', '1', 'name')",
        "SELECT \"inspect_mv_meta\"('shop.mv_city_daily')",
    ])
    func trinoSpellingsOfSecretSourcesAreRefused(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
        #expect(throws: MCPToolError.self, "execute_statement: \(sql)") { try StarRocksMCPTools.executableStatement(sql) }
    }

    @Test(arguments: [
        "SELECT city FROM shop.orders WHERE city = \"Penang\"", "SELECT \"a\" AS x", "SELECT * FROM shop.orders WHERE note = \"information_schema.tasks\"",
        "SELECT * FROM shop.orders WHERE city IN (\"files\", \"tasks\")", "SELECT 'information_schema' AS s, \"x\" AS t",
    ])
    func doubleQuotedLiteralsStayAllowed(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    @Test func aiConnectionsRequireTheStarRocksDialect() {
        let profile = ConnectionProfile(name: "p", host: "h", port: 9030, username: "u", defaultDatabase: "shop", connectTimeout: 5, mcpAccess: .readOnly)
        #expect(ClientOpener.configuration(profile: profile, password: "pw", forAI: true).requiresStarRocksDialect)
        #expect(!ClientOpener.configuration(profile: profile, password: "pw", forAI: false).requiresStarRocksDialect, "the editor keeps the account's dialect")
        #expect(StarRocksMCPTools.dialectRefusal(ClientOpener.configuration(profile: profile, password: "pw", forAI: true)) == nil)
        #expect(StarRocksMCPTools.dialectRefusal(ClientOpener.configuration(profile: profile, password: "pw", forAI: false))?.contains("dialect") == true)
    }
}
