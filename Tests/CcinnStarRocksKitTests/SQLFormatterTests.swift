import Foundation
import Testing
@testable import CcinnStarRocksKit

@Suite("SQL formatter")
struct SQLFormatterTests {
    private func format(_ sql: String, _ options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        SQLFormatter.format(sql, options: options)
    }

    @Test func selectListsBreakOneItemPerLine() {
        #expect(format("select a, b from t where x = 1 and y = 2 order by a") == """
            SELECT
              a,
              b
            FROM t
            WHERE x = 1
              AND y = 2
            ORDER BY a
            """)
    }

    @Test func aSingleItemStaysOnTheClauseLine() {
        #expect(format("select count(*) from t limit 10") == "SELECT count(*)\nFROM t\nLIMIT 10")
        #expect(format("SELECT DISTINCT a, b FROM t") == "SELECT DISTINCT\n  a,\n  b\nFROM t")
    }

    @Test func joinsAndTheirConditions() {
        #expect(format("select o.id, c.name from orders o left join customers c on o.cid = c.id and c.x > 0 where o.total>10") == """
            SELECT
              o.id,
              c.name
            FROM orders o
            LEFT JOIN customers c
              ON o.cid = c.id
              AND c.x > 0
            WHERE o.total > 10
            """)
        #expect(format("select * from a cross join b inner join c using (id)") == "SELECT *\nFROM a\nCROSS JOIN b\nINNER JOIN c USING (id)")
    }

    @Test func subqueriesAreIndented() {
        #expect(format("select * from (select a from t) s where a in (select a from u where b = 1)") == """
            SELECT *
            FROM (
              SELECT a
              FROM t
            ) s
            WHERE a IN (
              SELECT a
              FROM u
              WHERE b = 1
            )
            """)
    }

    @Test func commonTableExpressions() {
        #expect(format("with x as (select 1 as a), y as (select 2 as b) select * from x, y") == """
            WITH x AS (
              SELECT 1 AS a
            ),
            y AS (
              SELECT 2 AS b
            )
            SELECT *
            FROM x, y
            """)
    }

    @Test func betweenKeepsItsAnd() {
        #expect(format("select a from t where d between 1 and 5 and b = 2 or c is not null") == """
            SELECT a
            FROM t
            WHERE d BETWEEN 1 AND 5
              AND b = 2
              OR c IS NOT NULL
            """)
    }

    @Test func conditionsInsideParenthesesStayInline() {
        #expect(format("select a from t where (a = 1 or b = 2) and c = 3") == "SELECT a\nFROM t\nWHERE (a = 1 OR b = 2)\n  AND c = 3")
    }

    @Test func caseExpressionsWithSeveralBranches() {
        #expect(format("select case when a then 1 when b then 2 else 3 end as x, y from t") == """
            SELECT
              CASE
                WHEN a THEN 1
                WHEN b THEN 2
                ELSE 3
              END AS x,
              y
            FROM t
            """)
        #expect(format("select case when a then 1 end from t") == "SELECT CASE WHEN a THEN 1 END\nFROM t")
    }

    @Test func groupByHavingAndWindows() {
        #expect(format("select city, sum(total) over (partition by city order by d) s from t group by city, d having sum(total) > 10") == """
            SELECT
              city,
              sum(total) OVER (PARTITION BY city ORDER BY d) s
            FROM t
            GROUP BY
              city,
              d
            HAVING sum(total) > 10
            """)
    }

    @Test func insertUpdateAndDelete() {
        #expect(format("insert into t (a, b) values (1, 'x'), (2, 'y')") == "INSERT INTO t (a, b)\nVALUES\n  (1, 'x'),\n  (2, 'y')")
        #expect(format("insert into t select a from u") == "INSERT INTO t\nSELECT a\nFROM u")
        #expect(format("update t set a = 1, b = 2 where id = 3") == "UPDATE t\nSET\n  a = 1,\n  b = 2\nWHERE id = 3")
        #expect(format("delete from t where id = 3") == "DELETE FROM t\nWHERE id = 3")
    }

    @Test func starRocksTableDefinitions() {
        let sql = """
            create table shop.t (id bigint not null comment 'id', name varchar(32), total decimal(12, 2)) \
            duplicate key(id) partition by range(dt) (start ("2024-01-01") end ("2024-02-01") every (interval 1 day)) \
            distributed by hash(id) buckets 8 properties ("replication_num" = "1", "storage_medium" = "SSD")
            """
        #expect(format(sql) == """
            CREATE TABLE shop.t (
              id BIGINT NOT NULL comment 'id',
              name VARCHAR(32),
              total DECIMAL(12, 2)
            )
            DUPLICATE KEY(id)
            PARTITION BY RANGE(dt) (start ("2024-01-01") end ("2024-02-01") every (interval 1 day))
            DISTRIBUTED BY HASH(id) BUCKETS 8
            PROPERTIES (
              "replication_num" = "1",
              "storage_medium" = "SSD"
            )
            """)
    }

    @Test func stringsQuotedNamesAndCommentsAreUntouched() {
        #expect(format("select 'a  b', `x  y` -- keep\nfrom t /* c  d */ where a=1") == """
            SELECT
              'a  b',
              `x  y` -- keep
            FROM t /* c  d */
            WHERE a = 1
            """)
        #expect(format("-- header\n\nselect /*+ SET_VAR(query_timeout = 10) */ a, b from t") == """
            -- header
            SELECT /*+ SET_VAR(query_timeout = 10) */
              a,
              b
            FROM t
            """)
    }

    @Test func statementsAreSeparatedByABlankLine() {
        #expect(format("select 1;select 2;\n\n\nuse shop") == "SELECT 1;\n\nSELECT 2;\n\nUSE shop")
        #expect(format("select 1; -- done\nselect 2") == "SELECT 1; -- done\n\nSELECT 2")
        #expect(format("select 1;\n") == "SELECT 1;\n", "a trailing newline is kept")
    }

    @Test func operatorsAndPunctuation() {
        #expect(format("select a+b*-1, t.*, arr[1], -x, @v, @@session.query_timeout, a<>b, c>=-2 from t") == """
            SELECT
              a + b * -1,
              t.*,
              arr[1],
              -x,
              @v,
              @@session.query_timeout,
              a <> b,
              c >= -2
            FROM t
            """)
        #expect(format("select cast(a as int), if(b, 1, 2), date_format(d,'%Y') from t") == """
            SELECT
              cast(a AS INT),
              IF(b, 1, 2),
              date_format(d, '%Y')
            FROM t
            """)
    }

    @Test func onlySafeWordsChangeCase() {
        // `status`, `date` and `comment` are not reserved: they may be names, and table names are case-sensitive.
        #expect(format("select status, date from Orders") == "SELECT\n  status,\n  date\nFROM Orders")
        #expect(format("SELECT a FROM t", SQLFormatOptions(keywordCase: .lower)) == "select a\nfrom t")
        #expect(format("Select a From t", SQLFormatOptions(keywordCase: .preserve)) == "Select a\nFrom t")
        #expect(format("select a from t", SQLFormatOptions(indentWidth: 4)) == "SELECT a\nFROM t")
        #expect(format("select a, b from t", SQLFormatOptions(indentWidth: 4)) == "SELECT\n    a,\n    b\nFROM t")
    }

    @Test func windowFramesAndNullOrdering() {
        #expect(format("select sum(a) over (order by b rows between unbounded preceding and 1 following) from t order by a nulls last")
            == "SELECT sum(a) OVER (ORDER BY b ROWS BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING)\nFROM t\nORDER BY a NULLS LAST")
        #expect(format("select first, last, nulls from t") == "SELECT\n  first,\n  last,\n  nulls\nFROM t", "names stay names")
    }

    @Test func emptyAndWhitespaceInput() {
        #expect(format("") == "")
        #expect(format("   \n  ") == "")
        #expect(format("-- just a note") == "-- just a note")
    }

    @Test func unbalancedAndUnterminatedInputNeverCrash() {
        #expect(format("select (a from t") != nil)
        #expect(format("select a) from t") != nil)
        #expect(format("select 'abc") == "SELECT 'abc")
        #expect(format("select /* open") == "SELECT /* open")
    }

    @Test func formattingIsIdempotent() throws {
        for sql in Self.corpus {
            let once = try #require(format(sql), "\(sql)")
            #expect(format(once) == once, "\(sql)")
        }
    }

    /// The safety property: the formatted text has the same tokens (only whitespace and the case of safe keywords differ).
    @Test func randomInputKeepsItsTokens() {
        let alphabet = Array("select from where and or between case when then end ( ) , ; . 'x y' `a b` -- c\n /* d */ 1 2.5 a b t + - * = <> [ ] @v ")
        var generator = SystemRandomNumberGenerator()
        var refused = 0
        for _ in 0..<3_000 {
            let text = String((0..<Int.random(in: 0...120, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            guard let formatted = SQLFormatter.format(text) else { // refused: never wrong, at worst unhelpful
                refused += 1
                continue
            }
            #expect(SQLFormatter.sameTokens(text, formatted), "\(text.debugDescription) -> \(formatted.debugDescription)")
            #expect(SQLFormatter.format(formatted) == formatted, "not idempotent: \(text.debugDescription)")
        }
        #expect(refused < 15, "the formatter should almost never have to refuse (\(refused) of 3000)")
    }

    @Test func cursorPositionsMapAcrossFormatting() throws {
        let original = "select a,b from   t where x=1"
        let formatted = try #require(format(original))
        // After `from` in the original → after `FROM` in the result.
        let afterFrom = (original as NSString).range(of: "from").upperBound
        #expect(SQLFormatter.mapOffset(afterFrom, from: original, to: formatted) == (formatted as NSString).range(of: "FROM").upperBound)
        #expect(SQLFormatter.mapOffset(0, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(original.utf16.count, from: original, to: formatted) == formatted.utf16.count)
        #expect(SQLFormatter.mapOffset(-5, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(10_000, from: original, to: formatted) == formatted.utf16.count)
    }

    @Test func selectionsCoverWholeTokensAndAreCheckedInTheWholeText() throws {
        let text = "select 'a   b' from t; select x,y from u"
        let ns = text as NSString
        // The second statement alone formats normally.
        let second = ns.range(of: "select x,y from u")
        #expect(SQLFormatter.formatSelection(in: text, range: second) == SQLFormatEdit(range: second, replacement: "SELECT\n  x,\n  y\nFROM u"))
        // A selection starting inside the string covers the whole string, which keeps its spaces.
        let string = ns.range(of: "'a   b'")
        let fromEnd = ns.range(of: "from").upperBound
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: string.location + 2, length: fromEnd - string.location - 2))
            == SQLFormatEdit(range: NSRange(location: string.location, length: fromEnd - string.location), replacement: "'a   b' FROM"))
        // Review #3: a boundary inside a name never turns part of it into a keyword (`from use|r` → `FROM USEr`).
        let users = "select * from user"
        let length = (users as NSString).length
        #expect(SQLFormatter.formatSelection(in: users, range: NSRange(location: 0, length: length - 1))
            == SQLFormatEdit(range: NSRange(location: 0, length: length), replacement: "SELECT *\nFROM user"))
        let named = "select color from t"
        let or = NSRange(location: (named as NSString).range(of: "color").location + 3, length: 2)
        #expect(SQLFormatter.formatSelection(in: named, range: or)?.replacement == "color")
        // Only whitespace selected: nothing to do. Out of range: refused.
        #expect(SQLFormatter.formatSelection(in: "a  b", range: NSRange(location: 1, length: 1))
            == SQLFormatEdit(range: NSRange(location: 1, length: 1), replacement: " "))
        #expect(SQLFormatter.formatSelection(in: text, range: NSRange(location: 0, length: 10_000)) == nil)
    }

    // MARK: Review regressions

    /// Review #1: words StarRocks accepts as names keep their case; table names are case-sensitive.
    @Test func wordsTheServerAcceptsAsNamesKeepTheirCase() {
        #expect(format("with `current` as (select 1 x) select * from current") == """
            WITH `current` AS (
              SELECT 1 x
            )
            SELECT *
            FROM current
            """)
        #expect(format("select a as interval, b rollup, c as current from shop.semi") == """
            SELECT
              a AS interval,
              b rollup,
              c AS current
            FROM shop.semi
            """)
        for word in ["anti", "binary", "cast", "current", "except", "interval", "minus", "preceding", "rollup", "row", "semi", "end"] {
            #expect(!SQLFormatter.caseSafeKeywords.contains(word.uppercased()))
            #expect(format("select 1 from shop.\(word)") == "SELECT 1\nFROM shop.\(word)")
            #expect(format("select 1 from \(word)") == "SELECT 1\nFROM \(word)")
        }
        #expect(SQLFormatter.caseSafeKeywords.isSubset(of: SQLKeywords.all), "only words the lexer reports as keywords")
    }

    /// Review #4: comments on one line keep their order.
    @Test func commentsOnOneLineStayTogether() {
        #expect(format("select a\n/* x */ /* y */\nfrom t") == "SELECT a\n/* x */ /* y */\nFROM t")
        #expect(format("select 1;\n/* header */ -- note\nselect 2;") == "SELECT 1;\n\n/* header */ -- note\nSELECT 2;")
        #expect(format("select x\n/* b */ -- c\ny") == "SELECT x\n  /* b */ -- c\n  y")
    }

    /// Review #5 and #8: whitespace never appears between tokens that touch in the input unless the server provably
    /// reads them as separate tokens, and never disappears where the server could join them.
    @Test func touchingTokensStayTouching() {
        #expect(format("select 0xabc_flag from t") == "SELECT 0xabc_flag\nFROM t")
        #expect(format("select 0xzz, 0x1F from t") == "SELECT\n  0xzz,\n  0x1F\nFROM t")
        #expect(format(#"select x'0F', N'abc', _utf8'a', \N, t.1abc from t"#) == #"""
            SELECT
              x'0F',
              N'abc',
              _utf8'a',
              \N,
              t.1abc
            FROM t
            """#)
        #expect(format("select a::int, b :: int from t") == "SELECT\n  a::INT,\n  b :: INT\nFROM t")
        let colons = format("select a :: :int")
        #expect(colons == "SELECT a :: :INT")
        #expect(colons.flatMap { format($0) } == colons, "idempotent")
        #expect(format("select a+b,c=-1,@v:=1 from t") == "SELECT\n  a + b,\n  c = -1,\n  @v := 1\nFROM t")
        #expect(format("select `a`from t") == "SELECT `a`\nFROM t", "a closing back-quote ends the name")
        #expect(SQLLexer.tokenize("0xabc_flag").count == 1)
        #expect(!SQLFormatter.sameTokens("select 0xabc_flag", "select 0xabc _flag"))
        #expect(!SQLFormatter.sameTokens("select a:: :int", "select a:::int"))
    }

    /// Review #6 and the cross-port findings: words recognised by position need their whole context.
    @Test func positionalKeywordsNeedTheirContext() {
        #expect(format("select 1 following from t") == "SELECT 1 following\nFROM t")
        #expect(format("select nulls first from t") == "SELECT nulls first\nFROM t")
        #expect(format("select a from t order by nulls") == "SELECT a\nFROM t\nORDER BY nulls")
        #expect(format("select current, row, preceding, offset from t limit 5") == "SELECT\n  current,\n  row,\n  preceding,\n  offset\nFROM t\nLIMIT 5")
        #expect(format("select a from t limit 10 offset 5") == "SELECT a\nFROM t\nLIMIT 10\nOFFSET 5")
        #expect(format("select sum(a) over (partition by b order by c rows between current row and unbounded following) from t")
            == "SELECT sum(a) OVER (PARTITION BY b ORDER BY c ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)\nFROM t")
        #expect(format("select group_concat(a order by b nulls last) from t") == "SELECT group_concat(a ORDER BY b NULLS LAST)\nFROM t")
        // ENGINE = inside the query of CREATE … AS SELECT is a comparison; PROPERTIES where the name goes is the name.
        #expect(format("create table t2 as select k, engine = 'x' from t") == "CREATE TABLE t2 AS\nSELECT\n  k,\n  engine = 'x'\nFROM t")
        #expect(format("create view v as select a from t where engine = 'OLAP'") == "CREATE view v AS\nSELECT a\nFROM t\nWHERE engine = 'OLAP'")
        #expect(format("create view properties (a) as select 1") == "CREATE view properties (a) AS\nSELECT 1")
        #expect(format("create or replace materialized view view as select 1") == "CREATE OR REPLACE materialized view view AS\nSELECT 1")
        #expect(format("drop view if exists v") == "DROP view IF EXISTS v")
        #expect(format("create table t properties (\"a\" = \"b\") as select 1") == "CREATE TABLE t\nPROPERTIES (\n  \"a\" = \"b\"\n) AS\nSELECT 1")
        // Set operators only between queries: an alias called minus stays an alias.
        #expect(format("select a minus from t") == "SELECT a minus\nFROM t")
        #expect(format("select 1 minus select 2") == "SELECT 1\nMINUS\nSELECT 2")
        #expect(format("select 1 except select 2") == "SELECT 1\nEXCEPT\nSELECT 2")
    }

    /// Cross-port (b) and (c): names after `.` and AS; FROM inside expressions is not a clause.
    @Test func namesAfterDotsAndAliasesAndFromInsideExpressions() {
        #expect(format("select t.end, t.window, a as following, b as window, c as qualify from t") == """
            SELECT
              t.end,
              t.window,
              a AS following,
              b AS window,
              c AS qualify
            FROM t
            """)
        #expect(format("select a from t where a is not distinct from b and c = 1") == "SELECT a\nFROM t\nWHERE a IS NOT DISTINCT FROM b\n  AND c = 1")
        #expect(format("select extract(year from d), substring(s from 1 for 2), trim(both ' ' from s) from t") == """
            SELECT
              extract(year FROM d),
              substring(s FROM 1 FOR 2),
              trim(both ' ' FROM s)
            FROM t
            """)
        #expect(format("select sum(a) over w from t window w as (order by b rows between 1 preceding and current row)")
            == "SELECT sum(a) OVER w\nFROM t\nWINDOW w AS (ORDER BY b ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)")
        #expect(format("select a window from t") == "SELECT a window\nFROM t")
        // Keywords written against their `(` are calls; clause and operator words get their space.
        #expect(format("select user(), schema(), quarter('2020-01-01'), interval(3,1,5), insert('abc',1,1,'x') from t where a in(1) and exists(select 1)")
            == "SELECT\n  user(),\n  SCHEMA(),\n  quarter('2020-01-01'),\n  interval(3, 1, 5),\n  INSERT('abc', 1, 1, 'x')\nFROM t\nWHERE a IN (1)\n  AND EXISTS (\n    SELECT 1\n  )")
        #expect(format("select a from t group by rollup(a, b)") == "SELECT a\nFROM t\nGROUP BY rollup(a, b)")
    }

    /// Review #7: deep nesting stays linear (indentation is capped) and a running format can be cancelled.
    @Test func deepNestingIsLinearAndFormattingIsCancellable() async throws {
        let nested = String(repeating: "select (", count: 50_000)
        let started = ContinuousClock.now
        let formatted = try #require(format(nested))
        #expect(ContinuousClock.now - started < .seconds(15), "debug build bound")
        let widest = formatted.components(separatedBy: "\n").map { line in line.prefix { $0 == " " }.count }.max() ?? 0
        #expect(widest <= SQLFormatter.maxIndentLevel * 2)

        let statement = "select a, b, case when x then 1 when y then 2 end from t where a = 1 and b = 2;\n"
        let script = String(repeating: statement, count: 40_000)
        let job = Task.detached { SQLFormatter.format(script) }
        job.cancel()
        #expect(await job.value == nil)
    }

    // MARK: Second review

    /// Second review (1): a word next to `.` is a name. It never closes or opens a CASE and never changes case;
    /// recasing `end.a` to `END.a` made the server read another table (5 → 6).
    @Test func wordsNextToADotAreAlwaysNames() {
        // The alias `end` leaves this statement's CASE structure unproven (two bare `end` words): written as is.
        #expect(format("select case when 1=1 then end.a else 0 end from (select 5 a) end, (select 6 a) `END`") == """
            SELECT case when 1 = 1 then end.a else 0 end
            FROM (
              SELECT 5 a
            ) end, (
              SELECT 6 a
            ) `END`
            """)
        // `end.a` counts as a possible terminator too: two `end`s for one CASE, so the CASE stays as written.
        #expect(format("select case when 1=1 then end.a else 0 end from (select 5 a) t") == """
            SELECT case when 1 = 1 then end.a else 0 end
            FROM (
              SELECT 5 a
            ) t
            """)
        #expect(format("select t.case, case.x, minus.y, end . z, when.w from t") == """
            SELECT
              t.case,
              case.x,
              minus.y,
              end.z,
              when.w
            FROM t
            """)
        #expect(format("select case when a then b end from t where end.c = 1") == "SELECT case when a then b end\nFROM t\nWHERE end.c = 1")
        #expect(format("select case when a then b end from t where x.c = 1") == "SELECT CASE WHEN a THEN b END\nFROM t\nWHERE x.c = 1")
    }

    /// Second review (2): a set operator needs a proven query operand; `minus (x)` is an alias with a column list.
    @Test func setOperatorsNeedAProvenQueryOperand() {
        #expect(format("select minus.x from (select 1 a) minus (x)") == "SELECT minus.x\nFROM (\n  SELECT 1 a\n) minus (x)")
        #expect(format("select except.x from (select 1 a) except (x)") == "SELECT except.x\nFROM (\n  SELECT 1 a\n) except (x)")
        #expect(format("select 1 minus (select 2)") == "SELECT 1\nMINUS (\n  SELECT 2\n)")
        #expect(format("select 1 except ((select 2))") == "SELECT 1\nEXCEPT ((\n  SELECT 2\n))")
        #expect(format("select 1 minus all select 2") == "SELECT 1\nMINUS ALL\nSELECT 2")
        #expect(format("select 1 minus all (x)") == "SELECT 1 minus ALL (x)")
    }

    /// Second review (c): keyword-named names in many positions keep their exact text, or formatting is refused.
    /// The oracle is the template, not the formatter: every `{w}` slot is a name.
    @Test func keywordNamedNamesKeepTheirTextEverywhere() throws {
        let names = ["end", "minus", "except", "current", "interval", "row", "preceding", "following", "unbounded", "nulls",
                     "first", "last", "offset", "window", "qualify", "semi", "anti", "rollup", "properties", "engine", "buckets",
                     "distributed", "duplicate", "hash", "random", "view", "materialized", "cast", "binary", "date", "status"]
        let templates = [
            "select {w} from t",
            "select a {w} from t",
            "select a as {w}, b from t",
            "select {w}.a, t.{w} from t {w}",
            "select case when {w}.a = 1 then {w}.b else 0 end from t {w}",
            "select case when a then {w}.b end from (select 1 a) {w}, u",
            "select * from (select 1 a) {w}, (select 2 a) x where {w}.a = x.a",
            "select {w}.x from (select 1 a) {w} ({w}x)",
            "select x from t {w} join u on {w}.id = u.id left join v on v.id = {w}.id",
            "with {w} as (select 1 a) select * from {w}",
            "select {w}, count(*) from t group by {w} order by {w} desc",
            "select a from t order by {w} nulls first, {w}.b",
            "select sum(a) over (partition by {w} order by {w}.b rows between unbounded preceding and current row) from t {w}",
            "select a from t {w} limit 10 offset 2",
            "insert into {w} ({w}, b) select {w}, b from {w}.{w}",
            "update {w} set {w} = 1 where {w}.{w} = 2",
            "create table {w} ({w} int) duplicate key({w}) distributed by hash({w}) buckets 1",
            "create view {w} ({w}) as select {w} from {w}",
        ]
        for name in names {
            for spelling in [name, name.uppercased(), name.prefix(1).uppercased() + name.dropFirst()] {
                for template in templates {
                    // The slots' UTF-16 offsets: only those tokens are names (the template's own keywords may be spelled alike).
                    var sql = ""
                    var slots = Set<Int>()
                    for (position, part) in template.components(separatedBy: "{w}").enumerated() {
                        if position > 0 {
                            slots.insert(sql.utf16.count)
                            sql += spelling
                        }
                        sql += part
                    }
                    guard let formatted = format(sql) else { continue } // refused: never wrong
                    #expect(SQLFormatter.sameTokens(sql, formatted), "\(sql)")
                    let original = SQLLexer(sql)
                    let result = SQLLexer(formatted)
                    let before = original.tokens()
                    let after = result.tokens()
                    try #require(before.count == after.count, "\(sql)")
                    for index in before.indices where slots.contains(before[index].range.lowerBound) {
                        #expect(result.text(of: after[index]) == original.text(of: before[index]), "\(sql) → \(formatted)")
                    }
                }
            }
        }
    }

    /// Second review (3): a word in a name slot is a name, and DDL clause words count only in CREATE TABLE /
    /// MATERIALIZED VIEW after the object name. `ON properties (c)` once became `ON PROPERTIES (` (another table).
    @Test func nameSlotsAreNamesAndDDLWordsNeedTheirStatement() {
        #expect(format("create index idx on properties (c) using bitmap") == "CREATE INDEX idx ON properties (c) USING BITMAP")
        #expect(format("create index properties on t (c) using bitmap") == "CREATE INDEX properties ON t (c) USING BITMAP")
        #expect(format("create database properties") == "CREATE DATABASE properties")
        #expect(format("insert into properties (a) values (1)") == "INSERT INTO properties (a)\nVALUES (1)")
        #expect(format("update properties set a = 1") == "UPDATE properties\nSET a = 1")
        #expect(format("select a from t join properties on properties.id = t.id") == "SELECT a\nFROM t\nJOIN properties\n  ON properties.id = t.id")
        #expect(format("select a from end join minus on end.id = minus.id") == "SELECT a\nFROM end\nJOIN minus\n  ON end.id = minus.id")
        #expect(format("create index i on t (c) properties (\"a\" = \"b\")") == "CREATE INDEX i ON t (c) properties (\"a\" = \"b\")")
        #expect(format("create table properties (k int) distributed by hash(k) buckets 1") == """
            CREATE TABLE properties (
              k INT
            )
            DISTRIBUTED BY HASH(k) BUCKETS 1
            """)
        #expect(format("create materialized view mv distributed by hash(k) as select 1 k") == "CREATE materialized view mv\nDISTRIBUTED BY HASH(k) AS\nSELECT 1 k")
        #expect(format("create view v (k) as select 1 k") == "CREATE view v (k) AS\nSELECT 1 k")
    }

    /// Second review (4): numbers end where the server ends them. Digit-led words are one identifier (`1abc`, `1e2x`,
    /// `0x1F`); after a fraction or a signed exponent the server splits (`1.5x`, `1.end`, `1e+5x`).
    @Test func numbersEndWhereTheServerEndsThem() {
        func texts(_ sql: String) -> [String] {
            let lexer = SQLLexer(sql)
            return lexer.tokens().map { lexer.text(of: $0) }
        }
        #expect(texts("1abc") == ["1abc"])
        #expect(texts("1e2x") == ["1e2x"])
        #expect(texts("0x1F") == ["0x1F"])
        #expect(texts("1e2") == ["1e2"])
        #expect(texts("1.e2") == ["1.e2"])
        #expect(texts("1.5x") == ["1.5", "x"])
        #expect(texts("1.end") == ["1.", "end"])
        #expect(texts("1.5e2end") == ["1.5e2", "end"])
        #expect(texts("1e+5x") == ["1e+5", "x"])
        #expect(texts(".5x") == [".5x"])
        #expect(texts(".5e+2x") == [".5e+2", "x"])
        // A token boundary between two word characters is where lexers disagree: refused rather than trusted.
        #expect(format("select case when 1=1 then 1.5end, end.a from (select 5 a) end, (select 6 a) `END`") == nil)
        #expect(format("select 1.5x") == nil)
        #expect(format("select 1.5 x") == "SELECT 1.5 x")
        #expect(SQLFormatter.formatSelection(in: "select 1.5x; select a,b from t", range: NSRange(location: 13, length: 17)) == nil)
    }

    /// Second review (5): `$$ … $$` (inline UDF bodies, StarRocks 4.1) is one opaque token, kept byte for byte.
    @Test func dollarQuotedBodiesAreOpaque() throws {
        let body = "\ndef inc(x):\n    if x is None:\n        return None\n    return True if x else False  # (unbalanced\n"
        let sql = "create function f(int) returns boolean properties (\"symbol\" = \"inc\", \"type\" = \"Python\", \"file\" = \"inline\") as $$\(body)$$"
        let lexer = SQLLexer(sql, dollarQuotedBlocks: true)
        let blocks = lexer.tokens().filter { lexer.text(of: $0).hasPrefix("$$") }
        #expect(blocks.count == 1)
        #expect(blocks.first.map { lexer.text(of: $0) } == "$$\(body)$$")
        #expect(blocks.first?.kind == .string)
        // Formatted only where the server is known to read `$$` as a block; the body comes through byte-identical.
        let options = SQLFormatOptions(dollarQuotedBlocks: true)
        let formatted = try #require(SQLFormatter.format(sql, options: options))
        #expect(formatted.hasSuffix("AS $$\(body)$$"))
        #expect(SQLFormatter.format(formatted, options: options) == formatted)
        #expect(SQLFormatter.format(sql) == nil, "StarRocks 3.3 reads `$$` as part of a name: refused")
        #expect(SQLLexer(sql).tokens().allSatisfy { $0.kind != .string || !SQLLexer(sql).text(of: $0).hasPrefix("$$") },
                "the shared lexer reads `$$` as StarRocks 3.3 does")
        #expect(SQLFormatter.format("select $$ ( $$; select 1", options: options) == "SELECT $$ ( $$;\n\nSELECT 1")
        // An unterminated block is a lexical error: refused.
        #expect(SQLFormatter.format("select 1 as $$ def f(", options: options) == nil)
        // Like the server: a block made only of name characters is a name, and a longer name wins.
        #expect(SQLLexer.tokenize("$$abc$$").first?.kind == .identifier)
        #expect(SQLLexer.tokenize("$$abc$$def$$").count == 1)
        #expect(SQLFormatOptions.dollarQuotedBlocksSupported(major: 4, minor: 1))
        #expect(!SQLFormatOptions.dollarQuotedBlocksSupported(major: 3, minor: 3))
        #expect(!SQLFormatOptions.dollarQuotedBlocksSupported(major: 4, minor: 0), "only versions verified to read blocks")
    }

    /// Second review (5): local diagnostics skip a `$$` body when the server reads blocks; statement splitting (shared,
    /// security-relevant) always sees what StarRocks 3.3 sees.
    @Test func dollarQuotedBodiesInLintAndSplitting() {
        let script = "create function f(int) returns int properties (\"file\" = \"inline\") as $$\ndef f(x):\n    return (x;\n$$;\nselect 1"
        #expect(SQLStatementSplitter.split(script).count == 3, "never fewer statements than any supported server sees")
        #expect(SQLLinter.diagnose(script, dollarQuotedBlocks: true).isEmpty)
        let open = SQLLinter.diagnose("select 1 as $$ def f(", dollarQuotedBlocks: true)
        #expect(open.map(\.message) == ["Unterminated string: add the closing $$"])
    }

    /// Second review: variants of the name rules (brackets, a CTE qualifier, table-function aliases, function names).
    @Test func nameRuleVariants() {
        #expect(format("select [end.a] from (select 1 a) end") == "SELECT [end.a]\nFROM (\n  SELECT 1 a\n) end")
        #expect(format("with end as (select 1 a) select end.a from end") == "WITH end AS (\n  SELECT 1 a\n)\nSELECT end.a\nFROM end")
        #expect(format("select * from t, unnest([1]) except(v)") == "SELECT *\nFROM t, unnest([1]) except(v)")
        #expect(format("select * from t, unnest([1]) minus(v)") == "SELECT *\nFROM t, unnest([1]) minus(v)")
        #expect(format("create function properties(int) returns int properties (\"a\" = \"b\") as $$ x $$", SQLFormatOptions(dollarQuotedBlocks: true))
            == "CREATE FUNCTION properties(INT) returns INT properties (\"a\" = \"b\") AS $$ x $$")
    }

    /// Second review (7): an indent width is clamped however it is set; nothing can trap.
    @Test func indentWidthIsAlwaysClamped() {
        var options = SQLFormatOptions()
        options.indentWidth = -1
        #expect(options.indentWidth == 1)
        #expect(format("select a, b from t", options) == "SELECT\n a,\n b\nFROM t")
        options.indentWidth = .max
        #expect(options.indentWidth == 8)
        #expect(format("select a, b from t", options) == "SELECT\n        a,\n        b\nFROM t")
        #expect(SQLFormatOptions(indentWidth: .min).indentWidth == 1)
    }

    /// Second review (8): `'root'@'%'` stays one user identity, and the check rejects a space inserted into it.
    @Test func userIdentitiesStayTouching() {
        #expect(format("grant select on t to 'root'@'%'") == "GRANT SELECT ON t TO 'root'@'%'")
        #expect(!SQLFormatter.sameTokens("grant select on t to 'root'@'%'", "GRANT SELECT ON t TO 'root' @'%'"))
        #expect(!SQLFormatter.sameTokens("grant select on t to 'root'@'%'", "GRANT SELECT ON t TO 'root'@ '%'"))
    }

    /// Second review (9): a word with any non-ASCII character is a name, never a keyword (`ﬁrst` is not FIRST).
    @Test func nonASCIIWordsAreNeverKeywords() {
        // The formatter treats them as names; the shared lexer upper-cases like the server (`ın` is IN there).
        #expect(format("select diﬆinct a from t order by a nulls ﬁrst") == "SELECT diﬆinct a\nFROM t\nORDER BY a nulls ﬁrst")
        // `ſ` upper-cases to S for the server: `ſelect` is SELECT there, so the formatter refuses (see below).
        #expect(format("select 1 ſelect") == nil)
        #expect(format("select ﬁrst from t") == "SELECT ﬁrst\nFROM t")
        // The check compares letter case on ASCII only: any change to a non-ASCII scalar is a mismatch.
        #expect(!SQLFormatter.sameTokens("select 1 ſelect", "SELECT 1 SELECT"))
        #expect(!SQLFormatter.sameTokens("select ﬁrst", "SELECT FIrst"))
    }

    /// Second review (11): brackets and braces nest; a keyword keeps its space before `[`; no lone commas;
    /// statement words are left as written.
    @Test func bracketsBracesAndLayoutDetails() {
        #expect(format("select [1,2,3], map{1:2,3:4} from t") == "SELECT\n  [1, 2, 3],\n  map{1:2, 3:4}\nFROM t")
        #expect(format("select unnest([1]), arr [1] from t") == "SELECT\n  unnest([1]),\n  arr[1]\nFROM t")
        #expect(format("SELECT [1]") == "SELECT [1]")
        #expect(format("select 1 # c\n, 2") == "SELECT\n  1 # c\n  , 2")
        #expect(format("select a /* x */ -- y\n, b from t") == "SELECT\n  a /* x */ -- y\n  , b\nFROM t")
        #expect(format("create view v as select 1") == "CREATE view v AS\nSELECT 1")
        #expect(format("explain verbose select 1") == "EXPLAIN verbose SELECT 1")
    }

    /// Second review (11): a formatted selection takes the indentation of its first line.
    @Test func aFormattedSelectionKeepsTheIndentOfItsFirstLine() {
        let text = "-- report\n    select a, b from t where x = 'p\nq'"
        let range = (text as NSString).range(of: "select a, b from t where x = 'p\nq'")
        #expect(SQLFormatter.formatSelection(in: text, range: range)?.replacement == "SELECT\n      a,\n      b\n    FROM t\n    WHERE x = 'p\nq'")
    }

    /// Second review (12): CRLF input gets CRLF output; line breaks inside strings and comments do not count.
    @Test func crlfInputGetsCrlfOutput() {
        #expect(format("select a,\r\nb from t\r\n") == "SELECT\r\n  a,\r\n  b\r\nFROM t\r\n")
        #expect(format("select 1;\r\nselect 2") == "SELECT 1;\r\n\r\nSELECT 2")
        #expect(format("select 'x\r\ny', a from t") == "SELECT\n  'x\r\ny',\n  a\nFROM t")
    }

    /// Second review (CASE proof): CASE layout and case changes need a statement-level proof (as many bare `end`
    /// words as CASE keywords, each paired); otherwise every CASE token stays as written. `else view end` lost its END
    /// to a name-slot rule once, and the next bare `end` (a CTE) was taken for it.
    @Test func caseStructureNeedsAStatementLevelProof() {
        for column in ["view", "overwrite"] {
            let repro = "with end as (select 5 a), `END` as (select 6 a) select case when 1=1 then 1 else \(column) end x, a from (select 1 \(column)) t1, end"
            let formatted = format(repro) ?? ""
            #expect(formatted.contains("case when 1 = 1 then 1 else \(column) end x"), "\(formatted)")
            #expect(formatted.hasPrefix("WITH end AS ("), "\(formatted)")
            #expect(formatted.hasSuffix(", end"), "\(formatted)")
        }
        #expect(format("select case when a then 1 end, case when b then 2 else 3 end from t")
            == "SELECT\n  CASE WHEN a THEN 1 END,\n  CASE\n    WHEN b THEN 2\n    ELSE 3\n  END\nFROM t")
        #expect(format("select case when a then 1 end from end") == "SELECT case when a then 1 end\nFROM end", "unproven: as written")
        // `end.a` can be the real terminator (field access on the CASE result): every bare `end` counts.
        let fieldAccess = "with `end` as (select 5 a), `END` as (select 6 a) select case when 1=1 then named_struct('a', 1) end.a x, a from (select 0 z) t1, end"
        let formatted = format(fieldAccess) ?? ""
        #expect(formatted.contains("case when 1 = 1 then named_struct('a', 1) end.a x"), "\(formatted)")
        #expect(formatted.hasSuffix(") t1, end"), "\(formatted)")
        #expect(format("select case when a then named_struct('a', 1) end.a from t") == "SELECT case when a then named_struct('a', 1) end.a\nFROM t")
    }

    /// Second review (CASE proof): `end` as a CTE, table alias, column and column alias next to CASE expressions never
    /// changes, and neither do the names right before a real END.
    @Test func endNamesNextToCaseExpressionsNeverChange() throws {
        let templates = [
            "select case when a then 1 else {x} end {e} from t",
            "select case when {e} = 1 then {e} else 0 end from (select 1 {e}) {e}",
            "with {e} as (select 1 a) select case when a = 1 then {x} end from {e}",
            "select {e}, case when b then {x} end from t {e}",
            "select case when a then case when b then {x} end end from t, {e}",
            "select case {e} when 1 then {x} end as {e} from t join {e} on {e}.a = t.a",
            "select case when a then {x} end, {e}.b from {e} where case when {e} then 1 end = 1",
            "select case when a then named_struct('a', {x}) end.a, {e} from t, {e}",
            "select case when {e}.a = 1 then named_struct('b', 2) end.b {e} from {e}",
            "with {e} as (select 1 a) select case when 1 = 1 then named_struct('a', 1) end.a x, a from (select 0 z) t1, {e}",
            "select case when a then named_struct('a', {x}) end.a x from (select 0 z) t1, {e}",
            "select case when a then named_struct('a', 1) end . a, {x} from {e}",
        ]
        for e in ["end", "End", "END"] {
            for x in ["view", "overwrite", "status", "current", "end"] {
                for template in templates {
                    var sql = ""
                    var slots = Set<Int>()
                    var rest = Substring(template)
                    while let marker = rest.firstIndex(of: "{") {
                        sql += rest[..<marker]
                        let name = rest[marker...].hasPrefix("{e}") ? e : x
                        slots.insert(sql.utf16.count)
                        sql += name
                        rest = rest[rest.index(marker, offsetBy: 3)...]
                    }
                    sql += rest
                    guard let formatted = format(sql) else { continue }
                    #expect(SQLFormatter.sameTokens(sql, formatted), "\(sql)")
                    let original = SQLLexer(sql)
                    let result = SQLLexer(formatted)
                    let before = original.tokens()
                    let after = result.tokens()
                    try #require(before.count == after.count)
                    for index in before.indices where slots.contains(before[index].range.lowerBound) {
                        #expect(result.text(of: after[index]) == original.text(of: before[index]), "\(sql) → \(formatted)")
                    }
                }
            }
        }
    }

    /// Third review: StarRocks upper-cases per character (Java), so `exiſts` is EXISTS and `ıf` is IF. Taking such a
    /// word for a name misleads the rules that infer from a word not being a keyword (the table name slot moved, and
    /// `properties` became PROPERTIES), so the formatter refuses it.
    @Test func wordsWithLettersThatUpperCaseToASCIIAreRefused() {
        let repro = "create table if not exiſts properties (k int) duplicate key(k) distributed by hash(k) buckets 1 properties ('replication_num' = '1')"
        #expect(format(repro) == nil)
        for word in ["ıf", "aſ", "ınto", "vıew", "materıalized", "ın", "@ſ"] {
            #expect(format("select a from t where x = 1 and \(word)") == nil, "\(word)")
        }
        // In strings, comments and back-quoted names they are only text.
        #expect(format("select 'exiſts', `ıf` from t -- ſ") == "SELECT\n  'exiſts',\n  `ıf`\nFROM t -- ſ")
        // Ligatures have no one-letter upper case for the server: names, formatted.
        #expect(format("select ﬁrst from t") == "SELECT ﬁrst\nFROM t")
    }

    /// The characters whose simple upper case (Java's `Character.toUpperCase`) is an ASCII letter: exactly ı and ſ.
    @Test func onlyDotlessIAndLongSUpperCaseToASCII() {
        var found: [UInt16] = []
        for value in UInt32(0x80)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue } // surrogates
            let upper = scalar.properties.uppercaseMapping.unicodeScalars
            guard upper.count == 1, let mapped = upper.first, mapped.isASCII, mapped.properties.isAlphabetic else { continue }
            found.append(UInt16(value))
        }
        #expect(found == [0x131, 0x17F])
        #expect(SQLFormatter.lettersUpperCasingToASCII == Set(found))
    }

    @Test func trailingSpacesOfLineCommentsAreKept() {
        #expect(format("select a -- note   \nfrom t") == "SELECT a -- note   \nFROM t")
    }

    @Test func aMegabyteScriptFormatsQuickly() throws {
        let statement = "select o.id, sum(o.total) total, case when o.x > 1 then 'a' when o.x < 0 then 'b' else 'c' end k "
            + "from shop.orders o left join shop.customers c on o.cid = c.id and c.city in ('KL', 'PG') "
            + "where o.d between '2024-01-01' and '2024-12-31' and o.status = 'paid' group by o.id, k order by total desc limit 10;\n"
        let script = String(repeating: statement, count: 1_048_576 / statement.utf8.count + 1)
        let started = ContinuousClock.now
        let formatted = try #require(format(script))
        #expect(ContinuousClock.now - started < .seconds(20), "debug build bound; release is far faster")
        #expect(formatted.count > script.count)
    }

    static let corpus = [
        "select a, b from t where x = 1 and y = 2 order by a",
        "select * from (select a from t) s where a in (select a from u)",
        "with x as (select 1), y as (select 2) select * from x join y on x.a = y.a",
        "select case when a then 1 when b then 2 else 3 end x from t; update t set a = 1, b = 2",
        "create table t (a int, b varchar(10)) duplicate key(a) distributed by hash(a) buckets 8 properties (\"a\" = \"b\")",
        "select 'a' -- c\n, b from t /* x */ where a between 1 and 2 and b = 1",
        "insert into t (a, b) values (1, 2), (3, 4); delete from t where a = 1",
    ]
}
