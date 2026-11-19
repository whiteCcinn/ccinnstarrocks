import Foundation
import Testing
@testable import CcinnStarRocksKit

// JOIN mining (knowledge base, phase 3): equi-joins of one statement, then relationships from editor history and from
// view definitions.

private func describe(_ pair: JoinPair) -> String {
    func side(_ reference: TableReference, _ columns: [String]) -> String {
        (reference.database.map { $0 + "." } ?? "") + reference.table + "(" + columns.joined(separator: ",") + ")"
    }
    return side(pair.left, pair.leftColumns) + "=" + side(pair.right, pair.rightColumns)
}

/// Joins of `sql` as `db.table(columns)=table(columns)`; `columns` keys are `table` or `db.table` as written.
private func joins(_ sql: String, columns: [String: [String]] = [:]) -> [String] {
    SQLJoinExtractor.joins(in: sql, columnsOf: { (reference: TableReference) -> [String]? in
        columns[(reference.database.map { $0 + "." } ?? "") + reference.table]
    }).map(describe)
}

/// A small deterministic generator for the fuzz test (SplitMix64).
private struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@Suite("Knowledge inference: JOIN extraction")
struct KnowledgeInferenceJoinExtractorTests {
    @Test func onConditions() {
        #expect(joins("SELECT * FROM report r JOIN dsp d ON r.dsp_id = d.id") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report AS r LEFT OUTER JOIN dsp AS d ON d.id = r.dsp_id AND d.status = 1 WHERE r.dt = '2026-11-01'")
            == ["dsp(id)=report(dsp_id)"])
        #expect(joins("SELECT * FROM report JOIN dsp ON report.dsp_id = dsp.id") == ["report(dsp_id)=dsp(id)"], "unaliased tables")
        #expect(joins("SELECT * FROM a JOIN b ON a.x <=> b.y") == ["a(x)=b(y)"], "null-safe equality")
    }

    @Test func usingNeedsExactlyOnePriorTable() {
        #expect(joins("SELECT * FROM a JOIN b USING (k1, k2)") == ["a(k1,k2)=b(k1,k2)"])
        #expect(joins("SELECT * FROM a JOIN b USING (x) JOIN c USING (y)") == ["a(x)=b(x)"])
        #expect(joins("SELECT * FROM a, b JOIN c USING (k)").isEmpty)
        #expect(joins("SELECT * FROM (SELECT 1 AS k) d JOIN b USING (k)").isEmpty, "derived side")
    }

    @Test func implicitJoinsInWhere() {
        #expect(joins("SELECT * FROM report r, dsp d WHERE r.dsp_id = d.id AND r.dt = '2026-11-01'") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report r WHERE r.dsp_id = r.app_id").isEmpty, "one table")
    }

    @Test func compositeConditionsBecomeOnePair() {
        #expect(joins("SELECT * FROM report_adx_hour h JOIN report_adx_day d ON h.dt = d.dt AND d.app_id = h.app_id AND h.dt = d.dt")
            == ["report_adx_hour(dt,app_id)=report_adx_day(dt,app_id)"])
        #expect(joins("SELECT * FROM a JOIN b ON (a.x = b.y AND ((a.z) = (b.w)))") == ["a(x,z)=b(y,w)"])
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.x JOIN c ON a.y = c.y AND b.z = c.z") == ["a(x)=b(x)", "a(y)=c(y)", "b(z)=c(z)"])
    }

    @Test func aliasesAndQuotedNames() {
        #expect(joins("SELECT * FROM `adx`.`report` AS `r` JOIN dsp AS d ON `r`.`dsp_id` = d.`id`") == ["adx.report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM emp e JOIN emp m ON e.manager_id = m.id") == ["emp(manager_id)=emp(id)"], "self join")
    }

    @Test func databaseQualifiedNames() {
        #expect(joins("SELECT * FROM adx.report r JOIN admin.dsp d ON r.dsp_id = d.id") == ["adx.report(dsp_id)=admin.dsp(id)"])
        #expect(joins("SELECT * FROM adx.report JOIN admin.dsp ON adx.report.dsp_id = admin.dsp.id") == ["adx.report(dsp_id)=admin.dsp(id)"])
        #expect(joins("SELECT * FROM adx.report JOIN admin.dsp ON report.dsp_id = dsp.id") == ["adx.report(dsp_id)=admin.dsp(id)"])
        #expect(joins("SELECT * FROM default_catalog.adx.report r JOIN adx.dsp d ON r.dsp_id = d.id") == ["adx.report(dsp_id)=adx.dsp(id)"])
        #expect(joins("SELECT * FROM hive.adx.report r JOIN adx.dsp d ON r.dsp_id = d.id").isEmpty, "another catalog")
    }

    @Test func eachSubqueryResolvesItsOwnAliases() {
        let nested = "SELECT * FROM report r WHERE r.dsp_id IN (SELECT d.id FROM dsp d JOIN dsp_owner r ON d.owner_id = r.id)"
        #expect(joins(nested) == ["dsp(owner_id)=dsp_owner(id)"])
        #expect(joins("SELECT * FROM report r WHERE EXISTS (SELECT 1 FROM dsp d WHERE d.id = r.dsp_id)") == ["dsp(id)=report(dsp_id)"],
                "a correlated condition reaches the enclosing query")
        #expect(joins("SELECT * FROM (SELECT r.dsp_id FROM report r JOIN dsp d ON r.dsp_id = d.id) x") == ["report(dsp_id)=dsp(id)"])
    }

    @Test func cteAndDerivedSidesAreSkipped() {
        #expect(joins("WITH t AS (SELECT dsp_id FROM report) SELECT * FROM t JOIN dsp d ON t.dsp_id = d.id").isEmpty)
        #expect(joins("WITH t AS (SELECT r.dsp_id FROM report r JOIN dsp d ON r.dsp_id = d.id) SELECT * FROM t") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM (SELECT dsp_id FROM report) x JOIN dsp d ON x.dsp_id = d.id").isEmpty)
        #expect(joins("CREATE VIEW v AS WITH c AS (SELECT * FROM a) SELECT * FROM c JOIN b ON c.x = b.y").isEmpty)
        #expect(joins("SELECT * FROM (WITH c AS (SELECT 1 AS x) SELECT * FROM c JOIN b ON c.x = b.y) q").isEmpty, "a nested CTE")
    }

    @Test func onlyColumnEqualitiesCount() {
        #expect(joins("SELECT * FROM a JOIN b ON a.x = 5").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = '5'").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = @v").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = NULL").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x > b.y").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y + 1").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y OR a.z = b.w").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON NOT a.x = b.y").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON CAST(a.x AS BIGINT) = b.y").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.dt BETWEEN b.start_dt AND b.end_dt AND a.id = b.a_id") == ["a(id)=b(a_id)"])
        #expect(joins("SELECT * FROM a JOIN b ON left(a.code, 2) = b.prefix AND a.id = b.a_id") == ["a(id)=b(a_id)"])
    }

    @Test func unqualifiedColumnsNeedExactlyOneOwner() {
        let known = ["report": ["dsp_id", "dt"], "dsp": ["id", "name"], "a": ["k"], "b": ["k", "k2"]]
        #expect(joins("SELECT * FROM report r JOIN dsp d ON dsp_id = id", columns: known) == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report r, dsp d WHERE dsp_id = d.id", columns: known) == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM a JOIN b ON k = b.k2", columns: known).isEmpty, "two tables have k")
        #expect(joins("SELECT * FROM a JOIN u ON k = u.k2", columns: known).isEmpty, "u's columns are unknown")
        #expect(joins("SELECT * FROM report r JOIN dsp d ON dsp_id = id").isEmpty, "nothing known")
    }

    @Test func commentsHintsAndDroppedCharacters() {
        #expect(joins("SELECT * FROM report r -- JOIN x ON r.a = x.b\nJOIN /* hint */ dsp d ON r.dsp_id /* = x.y */ = d.id")
            == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM a JOIN [broadcast] b ON a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("SELECT * FROM a#\\\u{1}JOIN b ON a.x\u{7F}=\u{1F600}b.y") == ["a(x)=b(y)"])
        #expect(joins("SELECT * FROM t$$ x JOIN b ON x.id = b.t_id WHERE x.s = '$$'") == ["t$$(id)=b(t_id)"])
    }

    @Test func everyStatementOfAScript() {
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y; SELECT * FROM c, d WHERE c.k = d.k;") == ["a(x)=b(y)", "c(k)=d(k)"])
        #expect(joins("INSERT INTO t SELECT * FROM a JOIN b ON a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("INSERT INTO t (c1, c2) SELECT a.x, b.y FROM a, b WHERE a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y WHERE a.k IN (SELECT a.k FROM a JOIN b ON a.x = b.y)") == ["a(x)=b(y)"],
                "repeated pairs once per statement")
        #expect(joins("SHOW TABLES; UPDATE t SET x = 1").isEmpty)
    }

    @Test func deepNestingIsIgnoredNotWalked() {
        let deep = String(repeating: "(SELECT * FROM a JOIN b ON a.x = b.y WHERE a.k IN ", count: 3_000) + String(repeating: ")", count: 3_000)
        #expect(joins("SELECT 1 FROM t WHERE t.k IN " + deep).isEmpty)
        let nested = "SELECT * FROM a WHERE a.k IN " + String(repeating: "(SELECT b.k FROM b JOIN c ON b.x = c.y WHERE b.k IN ", count: 20)
            + "(1)" + String(repeating: ")", count: 20)
        #expect(joins(nested) == ["b(x)=c(y)"])
    }

    @Test func hostileInputNeverCrashes() async {
        let found = await onDedicatedThread { () -> Int in
            var generator = SplitMix(state: 0x5EED)
            let vocabulary = [
                "SELECT", "FROM", "JOIN", "LEFT", "ON", "USING", "WHERE", "AND", "OR", "BETWEEN", "WITH", "AS", "IN", "EXISTS",
                "(", ")", "(", ")", ",", ";", ".", "=", "<=>", "a", "b", "t", "x.y", "a.x", "b.y", "`q`", "db.t", "5", "'s'",
                "--c\n", "/*", "*/", "[broadcast]", "[", "]", "#", "\\", "$$", "NULL", "*", "+", "\"", "`", "RECURSIVE",
                "SELECT * FROM a JOIN b ON a.x = b.y", "FROM a, b WHERE a.x = b.y", "USING (", "WITH c AS (",
            ]
            var total = 0
            for _ in 0..<600 {
                let length = Int(generator.next() % 80)
                var parts: [String] = []
                for _ in 0..<length { parts.append(vocabulary[Int(generator.next() % UInt64(vocabulary.count))]) }
                total += SQLJoinExtractor.joins(in: parts.joined(separator: " "), columnsOf: { (_: TableReference) -> [String]? in ["x", "y"] }).count
            }
            return total
        }
        #expect(found > 0)
    }
}

// MARK: - History and definitions

@Suite("Knowledge inference: history mining")
struct KnowledgeInferenceHistoryTests {
    typealias F = KnowledgeInferenceFixtures

    private let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe.prod:9030"), catalog: "default_catalog", database: "adx")
    private let admin = ["admin": [F.table("publisher", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("name", "varchar(64)")])]]

    private func knowledge() -> DatabaseKnowledge {
        var knowledge = DatabaseKnowledge(key: key)
        knowledge.tables = [
            F.table("app", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("name", "varchar(64)")]),
            F.table("dsp", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("publisher_id"), F.column("name", "varchar(64)")]),
            F.table("report_adx_day", model: "AGG", [F.column("dt", "date", key: true), F.column("app_id", key: true), F.column("revenue", "decimal(18,6)")]),
            F.table("report_adx_hour", model: "AGG", [
                F.column("dt", "date", key: true), F.column("hour", "tinyint", key: true), F.column("dsp_id", key: true),
                F.column("app_id", key: true), F.column("dsp_request"),
            ]),
            F.table("old_report", state: .dropped, [F.column("dsp_id")]),
        ]
        return knowledge
    }

    private func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + offset) }

    private func entry(_ sql: String, _ database: String?, _ offset: TimeInterval, error: String? = nil) -> QueryHistoryEntry {
        QueryHistoryEntry(sql: sql, database: database, executedAt: at(offset), durationMilliseconds: 5, errorMessage: error)
    }

    /// Profile A: default database `adx`.
    private var profileA: [QueryHistoryEntry] {
        [
            entry("SELECT r.dt, d.name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = '2026-11-01'", "adx", 100),
            entry("SELECT r.dt, d.name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = '2026-11-02'", "adx", 200),
            entry("SELECT * FROM report_adx_hour r JOIN app a ON r.app_id = a.id", "adx", 300, error: "Unknown column 'app_id'"),
            entry("SELECT * FROM dsp d JOIN admin.publisher p ON d.publisher_id = p.id; SHOW TABLES", "adx", 400),
            entry("UPDATE dsp SET name = 'x' WHERE id IN (SELECT r.dsp_id FROM report_adx_hour r JOIN app a ON r.app_id = a.id)", "adx", 500),
            entry("EXPLAIN SELECT * FROM report_adx_hour r JOIN app a ON r.app_id = a.id", "adx", 510),
            entry("SELECT * FROM report_adx_hour r JOIN old_report o ON r.dsp_id = o.dsp_id", "adx", 520),
        ]
    }

    /// Profile B: no default database at first, then `admin`.
    private var profileB: [QueryHistoryEntry] {
        [
            entry("select * from adx.report_adx_hour r join adx.dsp d on d.id = r.dsp_id and r.dt = '2026-11-03' -- secret 42", nil, 600),
            entry("SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id", nil, 700),
            entry("SELECT * FROM adx.report_adx_hour h JOIN adx.report_adx_day x ON h.dt = x.dt AND h.app_id = x.app_id", "admin", 800),
            entry("INSERT INTO adx.report_adx_day SELECT x.dt, x.app_id, 1 FROM adx.report_adx_day x JOIN adx.app a ON x.app_id = a.id", "admin", 900),
            entry("SELECT * FROM adx.report_adx_day a JOIN adx.report_adx_hour b ON a.app_id = b.app_id", "admin", 1_000),
            entry("CREATE VIEW v AS SELECT d.id FROM adx.dsp d JOIN unknown_table u ON d.id = u.dsp_id", "admin", 1_100),
        ]
    }

    @Test func historyOfTwoProfilesBecomesRelationships() throws {
        let relationships = HistoryJoinMiner.relationships(entries: profileA + profileB, knowledge: knowledge(), otherDatabases: admin, now: F.now)
        #expect(relationships.map(F.describe).sorted() == [
            "dsp(publisher_id)->admin.publisher(id)",
            "report_adx_day(app_id)->app(id)",
            "report_adx_day(app_id)->report_adx_hour(app_id)",
            "report_adx_hour(app_id,dt)->report_adx_day(app_id,dt)",
            "report_adx_hour(dsp_id)->dsp(id)",
        ])
        #expect(relationships.map(\.id) == relationships.map(\.id).sorted())
        let kinds = Dictionary(uniqueKeysWithValues: relationships.map { (F.describe($0), $0.kind) })
        #expect(kinds["report_adx_day(app_id)->report_adx_hour(app_id)"] == .manyToMany, "no side is unique")
        #expect(kinds["report_adx_hour(app_id,dt)->report_adx_day(app_id,dt)"] == .manyToOne, "hours roll up into days")

        let dsp = try #require(relationships.first { F.describe($0) == "report_adx_hour(dsp_id)->dsp(id)" })
        #expect(dsp.kind == .manyToOne)
        #expect(dsp.fingerprints == ["report_adx_hour": "fp-report_adx_hour", "dsp": "fp-dsp"])
        #expect(dsp.evidence == [Evidence(source: .history, statements: 2, count: 3, lastSeen: at(600), samples: [
            "select * from adx.report_adx_hour r join adx.dsp d on d.id = r.dsp_id and r.dt = ?",
            "SELECT r.dt, d.name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = ?",
        ], at: F.now)])

        let publisher = try #require(relationships.first { $0.to.database == "admin" })
        #expect(publisher.fingerprints == ["dsp": "fp-dsp", "admin.publisher": "fp-publisher"])
    }

    @Test func samplesAreFewDigestsWithoutLiterals() throws {
        let shapes = (0..<5).map { (index: Int) -> QueryHistoryEntry in
            entry("SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.hour = \(index) AND r.dt = 'secret-\(index)'"
                    + String(repeating: " AND r.dsp_request > 0", count: index), "adx", TimeInterval(index))
        }
        let relationship = try #require(HistoryJoinMiner.relationships(entries: shapes, knowledge: knowledge(), now: F.now).first)
        let evidence = try #require(relationship.evidence.first)
        #expect(evidence.statements == 5)
        #expect(evidence.count == 5)
        let samples = try #require(evidence.samples)
        #expect(samples.count == 3)
        #expect(samples.first?.hasSuffix(String(repeating: " AND r.dsp_request > ?", count: 4)) == true, "newest first")
        #expect(samples.allSatisfy { !$0.contains("secret") && !$0.contains("'") && $0.count <= 500 })
    }

    @Test func nothingFromFailedOrForeignStatements() {
        let failed = [entry("SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id", "adx", 1, error: "timeout")]
        #expect(HistoryJoinMiner.relationships(entries: failed, knowledge: knowledge(), now: F.now).isEmpty)
        let elsewhere = [entry("SELECT * FROM shop.orders o JOIN shop.users u ON o.user_id = u.id", "adx", 1)]
        #expect(HistoryJoinMiner.relationships(entries: elsewhere, knowledge: knowledge(), now: F.now).isEmpty)
        let missingColumn = [entry("SELECT * FROM report_adx_hour r JOIN dsp d ON r.nope = d.id", "adx", 1)]
        #expect(HistoryJoinMiner.relationships(entries: missingColumn, knowledge: knowledge(), now: F.now).isEmpty)
    }

    @Test func declaredKeysDecideTheDirection() {
        var withDeclared = knowledge()
        withDeclared.tables.append(F.table("dsp_owner", [F.column("code", "varchar(16)"), F.column("owner", "varchar(64)")]))
        withDeclared.tables.append(F.table("dsp_detail", [F.column("owner_code", "varchar(16)")]))
        let entries = [entry("SELECT * FROM dsp_owner o JOIN dsp_detail d ON o.code = d.owner_code", "adx", 1)]
        #expect(HistoryJoinMiner.relationships(entries: entries, knowledge: withDeclared, now: F.now).map(\.kind) == [.manyToMany])
        withDeclared.relationships = [Relationship(from: .init(table: "dsp_detail", columns: ["owner_code"]), to: .init(table: "dsp_owner", columns: ["code"]),
                                                   kind: .manyToOne, evidence: [Evidence(source: .declared)])]
        let mined = HistoryJoinMiner.relationships(entries: entries, knowledge: withDeclared, now: F.now)
        #expect(mined.map(F.describe) == ["dsp_detail(owner_code)->dsp_owner(code)"])
        #expect(mined.map(\.kind) == [.manyToOne])
    }

    // One table on both ends: one fingerprint (a dictionary literal with the key twice would trap).
    @Test func selfJoinsAreRelationshipsOfOneTable() throws {
        var staff = knowledge()
        staff.tables.append(F.table("emp", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("manager_id")]))
        let entries = [
            entry("SELECT * FROM emp e JOIN emp m ON e.manager_id = m.id", "adx", 1),
            entry("SELECT * FROM emp a JOIN emp b ON a.id = b.id", "adx", 2),
        ]
        let mined = HistoryJoinMiner.relationships(entries: entries, knowledge: staff, now: F.now)
        #expect(mined.map(F.describe) == ["emp(manager_id)->emp(id)"], "joining a key to itself says nothing")
        #expect(try #require(mined.first).fingerprints == ["emp": "fp-emp"])
    }

    @Test func viewDefinitionsGiveDefinitionEvidence() throws {
        let view = HistoryJoinMiner.definitionRelationships(
            definition: "SELECT `adx`.`r`.`dt`, d.name FROM `adx`.`report_adx_hour` `r` JOIN `dsp` `d` ON `r`.`dsp_id` = `d`.`id` WHERE r.dt > '2026-01-01'",
            viewName: "v_report", knowledge: knowledge(), now: F.now)
        #expect(view.map(F.describe) == ["report_adx_hour(dsp_id)->dsp(id)"])
        #expect(try #require(view.first).evidence == [Evidence(source: .definition, symbol: "v_report", at: F.now)])

        let materialized = HistoryJoinMiner.definitionRelationships(
            definition: "CREATE MATERIALIZED VIEW mv_day REFRESH ASYNC AS SELECT h.dt, sum(h.dsp_request) FROM report_adx_hour h JOIN app a ON h.app_id = a.id GROUP BY h.dt;",
            viewName: "mv_day", knowledge: knowledge(), now: F.now)
        #expect(materialized.map(F.describe) == ["report_adx_hour(app_id)->app(id)"])

        let crossDatabase = "SELECT * FROM dsp d JOIN admin.publisher p ON d.publisher_id = p.id"
        #expect(HistoryJoinMiner.definitionRelationships(definition: crossDatabase, viewName: "v", knowledge: knowledge(), now: F.now).isEmpty)
        #expect(HistoryJoinMiner.definitionRelationships(definition: crossDatabase, viewName: "v", knowledge: knowledge(), otherDatabases: admin, now: F.now)
            .map(F.describe) == ["dsp(publisher_id)->admin.publisher(id)"])
    }
}
