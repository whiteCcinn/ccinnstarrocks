import Foundation
import Testing
@testable import CcinnStarRocksKit

// Relationship inference (knowledge base, phase 3): declared constraints, naming heuristics and confidence. JOIN
// mining is in KnowledgeInferenceJoinTests.swift.

enum KnowledgeInferenceFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func table(_ name: String, kind: TableFacts.Kind = .table, model: String? = nil, primary: [String] = [],
                      state: TableFacts.State = .fresh, _ columns: [ColumnFacts]) -> TableFacts {
        TableFacts(name: name, kind: kind, model: model, keys: TableFacts.Keys(primary: primary), columns: columns,
                   fingerprint: "fp-" + name, state: state, firstSeen: now)
    }

    static func column(_ name: String, _ type: String = "bigint", key: Bool = false, comment: String? = nil) -> ColumnFacts {
        ColumnFacts(name: name, type: type, isKey: key, comment: comment)
    }

    static func describe(_ end: Relationship.End) -> String {
        (end.database.map { $0 + "." } ?? "") + end.table + "(" + end.columns.joined(separator: ",") + ")"
    }

    static func describe(_ relationship: Relationship) -> String {
        describe(relationship.from) + "->" + describe(relationship.to)
    }
}

// MARK: - Declared constraints

@Suite("Knowledge inference: declared constraints")
struct KnowledgeInferenceConstraintTests {
    typealias ForeignKey = ForeignKeyConstraintParser.ForeignKey

    @Test func aForeignKeyNamesColumnsTableAndTargetColumns() {
        #expect(ForeignKeyConstraintParser.foreignKeys("(dsp_id) REFERENCES dsp(id)")
            == [ForeignKey(columns: ["dsp_id"], target: TableReference(table: "dsp"), targetColumns: ["id"])])
    }

    @Test func severalQualifiedAndCompositeConstraints() {
        let parsed = ForeignKeyConstraintParser.foreignKeys(
            "(lo_custkey) REFERENCES customer(c_custkey);(lo_partkey) REFERENCES default_catalog.ssb.part(p_partkey);"
                + " ( `a` , b ) references admin.`dsp unit` ( x, `y` ) ;")
        #expect(parsed == [
            ForeignKey(columns: ["lo_custkey"], target: TableReference(table: "customer"), targetColumns: ["c_custkey"]),
            ForeignKey(columns: ["lo_partkey"], target: TableReference(database: "ssb", table: "part"), targetColumns: ["p_partkey"]),
            ForeignKey(columns: ["a", "b"], target: TableReference(database: "admin", table: "dsp unit"), targetColumns: ["x", "y"]),
        ])
    }

    @Test func malformedPartsAreSkipped() {
        let malformed = [
            "", ";", "(a) REFERENCES", "a REFERENCES b(c)", "(a, b) REFERENCES t(c)", "(a) REFERENCES t(c) extra",
            "((a)) REFERENCES t(c)", "(a) REFERENCES t.(c)", "(a) REFERENCES t()", "() REFERENCES t(c)",
            "(a) REFERENCES w.x.y.z(c)", "(a) REFERENCES t(c", "(a) REFERENCES `t(c)", "(a) KEY t(c)", "(``) REFERENCES t(c)",
            "(a) REFERENCES t(c) -- note", "(a,) REFERENCES t(c,)", "(a) REFERENCES 't'(c)",
        ]
        for text in malformed {
            #expect(ForeignKeyConstraintParser.foreignKeys(text).isEmpty, "\(text)")
        }
        #expect(ForeignKeyConstraintParser.foreignKeys("garbage; (a) REFERENCES t(b); (c REFERENCES")
            == [ForeignKey(columns: ["a"], target: TableReference(table: "t"), targetColumns: ["b"])])
    }

    @Test func uniqueKeysAreColumnGroups() {
        #expect(ForeignKeyConstraintParser.uniqueKeys("c1,c2;c3") == [["c1", "c2"], ["c3"]])
        #expect(ForeignKeyConstraintParser.uniqueKeys(" `c 1` , c2 ; ; default_catalog.db.t.c3 ") == [["c 1", "c2"], ["c3"]])
        #expect(ForeignKeyConstraintParser.uniqueKeys("a,,b;c;(d)") == [["c"]], "malformed groups are skipped")
        #expect(ForeignKeyConstraintParser.uniqueKeys("").isEmpty)
    }
}

// MARK: - Naming heuristics

@Suite("Knowledge inference: naming")
struct KnowledgeInferenceNamingTests {
    typealias F = KnowledgeInferenceFixtures

    private func edges(_ tables: [TableFacts], other: [String: [TableFacts]] = [:]) -> [String] {
        NamingHeuristics.relationships(tables: tables, otherDatabases: other, now: F.now).map(F.describe).sorted()
    }

    /// Naming scores by edge, for tests that compare the heuristics' weights.
    private func scores(_ tables: [TableFacts], other: [String: [TableFacts]] = [:]) -> [String: Int] {
        var scores: [String: Int] = [:]
        for relationship in NamingHeuristics.relationships(tables: tables, otherDatabases: other, now: F.now) {
            scores[F.describe(relationship)] = relationship.evidence.first?.score
        }
        return scores
    }

    @Test func entityNamesDropPrefixesSuffixesAndPlurals() {
        let cases: [(table: String, entities: [String])] = [
            ("dsp", ["dsp"]),
            ("dim_dsp", ["dsp"]),
            ("report_adx_hour", ["report_adx", "adx"]),
            ("report_adx_utce8", ["report_adx", "adx"]),
            ("ods_app_info_daily", ["app"]),
            ("t_user_v2", ["user"]),
            ("DimCampaigns", ["campaigns", "campaign"]),
            ("publisher_apps", ["publisher_apps", "publisher_app", "apps", "app"]),
            ("categories", ["categories", "category", "categorie"]),
            ("boxes", ["boxes", "box"]),
            ("statuses", ["statuses", "status"]),
            ("status", ["status"]), // no "statu"
            ("dim", ["dim"]), // a prefix alone is the name
            ("hour", ["hour"]), // a suffix alone is the name
            ("", []),
            ("__", []),
        ]
        for (table, entities) in cases {
            #expect(NamingHeuristics.entityNames(of: table) == entities, "\(table)")
        }
    }

    @Test func aReportColumnPointsAtItsDimensionTable() throws {
        let report = F.table("report_adx_hour", model: "AGG", [
            F.column("dt", "date", key: true), F.column("hour", "tinyint", key: true),
            F.column("dsp_id", "bigint", key: true, comment: "DSP id"), F.column("dsp_request", "bigint"),
        ])
        let dsp = F.table("dsp", model: "PK", primary: ["id"], [F.column("id", "bigint", key: true), F.column("name", "varchar(64)")])
        let relationships = NamingHeuristics.relationships(tables: [report, dsp], now: F.now)
        #expect(relationships.map(F.describe) == ["report_adx_hour(dsp_id)->dsp(id)"])
        let relationship = try #require(relationships.first)
        #expect(relationship.kind == .manyToOne)
        #expect(relationship.status == .inferred)
        #expect(relationship.id == Relationship.id(from: relationship.from, to: relationship.to))
        #expect(relationship.evidence == [Evidence(source: .naming, score: 70, at: F.now)])
        #expect(relationship.fingerprints == ["report_adx_hour": "fp-report_adx_hour", "dsp": "fp-dsp"])
    }

    // Types unknown and no keys: only the kind of match, the target column and the target's kind count.
    @Test func scoresWeighTheMatchAndTheTargetColumn() {
        let report = F.table("report", [F.column("dsp_id", "")])
        #expect(scores([report, F.table("dsp", [F.column("id", "")])]) == ["report(dsp_id)->dsp(id)": 70], "exact name 55 + id 15")
        #expect(scores([report, F.table("dim_dsp", [F.column("id", "")])]) == ["report(dsp_id)->dim_dsp(id)": 65], "entity 50 + id 15")
        #expect(scores([report, F.table("ad_dsp", [F.column("id", "")])]) == ["report(dsp_id)->ad_dsp(id)": 55], "last token 40 + id 15")
        #expect(scores([report, F.table("dsp", [F.column("dsp_id", "")])]) == ["report(dsp_id)->dsp(dsp_id)": 65], "exact 55 + same name 10")
        #expect(scores([report, F.table("dsp", kind: .view, [F.column("id", "")])]) == ["report(dsp_id)->dsp(id)": 65], "a view −5")
        #expect(scores([report, F.table("dsp", [F.column("id", "", key: true)])]) == ["report(dsp_id)->dsp(id)": 70], "capped at 70")
        let commented = F.table("report", [F.column("dsp_id", "", comment: "row of ad_dsp")])
        #expect(scores([commented, F.table("ad_dsp", [F.column("id", "")])]) == ["report(dsp_id)->ad_dsp(id)": 60], "comment +5")
        let typed = F.table("report", [F.column("dsp_id", "int")])
        #expect(scores([typed, F.table("ad_dsp", [F.column("id", "bigint(20)")])]) == ["report(dsp_id)->ad_dsp(id)": 60], "same family +5")
    }

    @Test func theExactTableBeatsPrefixedOnes() {
        let tables = [F.table("report", [F.column("dsp_id")]), F.table("dsp", [F.column("id")]), F.table("dim_dsp", [F.column("id")])]
        let relationships = NamingHeuristics.relationships(tables: tables, now: F.now)
        #expect(relationships.map(F.describe) == ["report(dsp_id)->dsp(id)"])
        #expect(relationships.first?.evidence.first?.rationale == nil, "not ambiguous")
        #expect(edges([F.table("report", [F.column("dsp_id")]), F.table("dim_dsp", [F.column("id")])]) == ["report(dsp_id)->dim_dsp(id)"])
    }

    @Test func pluralTableNamesMatchSingularColumns() {
        let report = F.table("report", [F.column("campaign_id"), F.column("category_id"), F.column("box_id")])
        let tables = [report, F.table("campaigns", [F.column("id")]), F.table("categories", [F.column("id")]), F.table("boxes", [F.column("id")])]
        #expect(edges(tables) == ["report(box_id)->boxes(id)", "report(campaign_id)->campaigns(id)", "report(category_id)->categories(id)"])
    }

    @Test func theLongestColumnStemWins() {
        let report = F.table("report", [F.column("publisher_app_id"), F.column("app_id")])
        let app = F.table("app", [F.column("id")])
        let publisherApp = F.table("publisher_app", [F.column("id")])
        #expect(edges([report, app, publisherApp]) == ["report(app_id)->app(id)", "report(publisher_app_id)->publisher_app(id)"])
        #expect(edges([report, app]) == ["report(app_id)->app(id)", "report(publisher_app_id)->app(id)"], "then its last token")
        let camel = F.table("report", [F.column("publisherAppId")])
        #expect(edges([camel, app, publisherApp]) == ["report(publisherAppId)->publisher_app(id)"])
    }

    @Test func incompatibleTypesRejectTheCandidate() {
        let dsp = F.table("dsp", [F.column("id", "bigint", key: true)])
        #expect(edges([F.table("report", [F.column("dsp_id", "varchar(32)")]), dsp]).isEmpty)
        #expect(edges([F.table("report", [F.column("dsp_id", "datetime")]), dsp]).isEmpty)
        #expect(edges([F.table("report", [F.column("dsp_id", "decimal(20,0)")]), dsp]) == ["report(dsp_id)->dsp(id)"], "integers and decimals")
    }

    @Test func noTargetTableMeansNoEdge() {
        #expect(edges([F.table("report", [F.column("foo_id"), F.column("id")]), F.table("dsp", [F.column("id")])]).isEmpty)
        #expect(edges([F.table("user", [F.column("id")]), F.table("orders", [F.column("id")])]).isEmpty, "no edge from `id`")
        #expect(edges([F.table("report", [F.column("dsp_id")]), F.table("dsp", [F.column("name", "varchar(64)")])]).isEmpty,
                "a target table without a target column")
    }

    @Test func equalTopCandidatesAreFlaggedAmbiguous() {
        let report = F.table("report", [F.column("dsp_id")])
        let dsp = F.table("dsp", [F.column("id", key: true)])
        let relationships = NamingHeuristics.relationships(tables: [report, dsp], otherDatabases: ["admin": [dsp]], now: F.now)
        #expect(relationships.map(F.describe).sorted() == ["report(dsp_id)->admin.dsp(id)", "report(dsp_id)->dsp(id)"])
        for relationship in relationships {
            #expect(relationship.evidence == [Evidence(source: .naming, score: 60, rationale: "ambiguous", at: F.now)])
        }
    }

    @Test func dimensionTablesInLinkedDatabasesCount() throws {
        let report = F.table("report", [F.column("app_id")])
        let relationships = NamingHeuristics.relationships(tables: [report], otherDatabases: ["admin": [F.table("app", [F.column("id")])]], now: F.now)
        #expect(relationships.map(F.describe) == ["report(app_id)->admin.app(id)"])
        #expect(try #require(relationships.first).fingerprints == ["report": "fp-report", "admin.app": "fp-app"])
    }

    @Test func selfReferencesOnlyThroughParentColumns() {
        let category = F.table("category", [F.column("id", key: true), F.column("parent_id"), F.column("name", "varchar(64)")])
        #expect(edges([category]) == ["category(parent_id)->category(id)"])
        #expect(NamingHeuristics.relationships(tables: [category], now: F.now).first?.fingerprints == ["category": "fp-category"])
        let tree = F.table("category", [F.column("id"), F.column("parent_category_id")])
        #expect(edges([tree]) == ["category(parent_category_id)->category(id)"])
        #expect(edges([F.table("dsp_hour", [F.column("id"), F.column("dsp_id")])]).isEmpty, "dsp_hour is no dsp table")
    }

    @Test func aKeyWithoutAnOwningTableIsShared() throws {
        let first = F.table("report_a", [F.column("dt", "date"), F.column("app_id")])
        let second = F.table("report_b", [F.column("dt", "date"), F.column("app_id")])
        let relationships = NamingHeuristics.relationships(tables: [second, first], now: F.now)
        #expect(relationships.map(F.describe) == ["report_a(app_id)->report_b(app_id)"])
        let shared = try #require(relationships.first)
        #expect(shared.kind == .sharedKey)
        #expect(shared.evidence == [Evidence(source: .naming, score: 30, at: F.now)])
        #expect(RelationshipConfidence.score(shared) == 30)
        // With a table that owns the key, both point at it instead.
        #expect(edges([first, second, F.table("app", [F.column("id")])]) == ["report_a(app_id)->app(id)", "report_b(app_id)->app(id)"])
        // Different type families are not the same key.
        #expect(edges([first, F.table("report_c", [F.column("app_id", "varchar(16)")])]).isEmpty)
        // A view re-exposes its base table's column: lineage, not a shared key.
        #expect(edges([first, F.table("v_report_a", kind: .view, [F.column("app_id")])]).isEmpty)
    }

    // A last-token match (`report_app_hour` for `app`) must offer an owning key, or every report table would be a
    // dimension of every other.
    @Test func factTablesAreNoDimensions() {
        let report = F.table("report", [F.column("app_id")])
        let hourly = F.table("report_app_hour", [F.column("dt", "date", key: true), F.column("app_id", key: true)])
        #expect(edges([report, hourly]) == ["report(app_id)->report_app_hour(app_id)"])
        #expect(NamingHeuristics.relationships(tables: [report, hourly], now: F.now).map(\.kind) == [.sharedKey])
    }

    @Test func droppedTablesAreIgnored() {
        #expect(edges([F.table("report", [F.column("dsp_id")]), F.table("dsp", state: .dropped, [F.column("id")])]).isEmpty)
    }

    @Test func outputIsDeterministic() {
        let tables = [
            F.table("report_adx_hour", [F.column("dsp_id"), F.column("app_id"), F.column("publisher_id")]),
            F.table("report_adx_day", [F.column("app_id"), F.column("publisher_id")]),
            F.table("dsp", [F.column("id")]), F.table("dim_app", [F.column("id")]),
        ]
        let forward = NamingHeuristics.relationships(tables: tables, now: F.now)
        #expect(forward == NamingHeuristics.relationships(tables: tables.reversed(), now: F.now))
        #expect(forward.map(\.id) == forward.map(\.id).sorted())
        #expect(forward.count == 4)
    }
}

// MARK: - Confidence

@Suite("Knowledge inference: confidence")
struct KnowledgeInferenceConfidenceTests {
    private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_000_000)

    private func relationship(_ evidence: [Evidence], kind: Relationship.Kind = .manyToOne, status: Relationship.Status = .inferred,
                              from: [String] = ["dsp_id"], to: [String] = ["id"]) -> Relationship {
        Relationship(from: .init(table: "report", columns: from), to: .init(table: "dsp", columns: to), kind: kind, status: status, evidence: evidence)
    }

    private func score(_ evidence: [Evidence], kind: Relationship.Kind = .manyToOne, from: [String] = ["dsp_id"], to: [String] = ["id"]) -> Int {
        RelationshipConfidence.score(relationship(evidence, kind: kind, from: from, to: to))
    }

    private func naming(_ score: Int?) -> Evidence { Evidence(source: .naming, score: score) }
    private func history(_ statements: Int) -> Evidence { Evidence(source: .history, statements: statements, count: statements) }
    private let declared = Evidence(source: .declared)
    private let code = Evidence(source: .code, project: "p1", path: "dao.go", line: 12, by: "ai:claude-code")
    private let definition = Evidence(source: .definition)

    @Test func eachSourceHasItsOwnConfidence() {
        #expect(score([naming(55)]) == 55)
        #expect(score([naming(90)]) == 70, "naming is capped at 70")
        #expect(score([naming(nil)]) == 30)
        #expect(score([declared]) == 95)
        #expect(score([definition]) == 85)
        #expect(score([code]) == 80)
        #expect(score([Evidence(source: .ai)]) == 50)
        #expect(score([Evidence(source: .ai, score: 80)]) == 50, "AI without evidence is capped at 50")
        #expect(score([Evidence(source: .ai, score: 20)]) == 20)
        #expect(score([]) == 0)
    }

    @Test func historyGrowsWithDistinctStatements() {
        #expect([1, 2, 4, 8, 11, 12, 1_000].map { score([history($0)]) } == [55, 65, 75, 85, 89, 90, 90])
        #expect(score([Evidence(source: .history, statements: 0, count: 0)]) == 0)
    }

    @Test func sourcesCombineByNoisyOr() {
        #expect(score([naming(50), history(1)]) == 78, "1 − 0.50 × 0.45")
        #expect(score([history(1), naming(50)]) == 78, "order does not matter")
        #expect(score([naming(40), naming(60)]) == 60, "one heuristic is one source")
        #expect(score([code]) == 80)
        #expect(score([code, code]) == 95, "code counts per evidence: 0.96, capped")
    }

    @Test func inferredConfidenceStopsAt95UnlessDeclared() {
        #expect(score([code, history(12), definition]) == 95)
        #expect(score([declared, code]) == 99)
        #expect(score([Evidence(source: .lineage)], kind: .lineage, from: [], to: []) == 100)
        #expect(score([Evidence(source: .lineage), code, code]) == 95, "lineage vouches only for lineage")
    }

    @Test func theUserHasTheLastWord() {
        let confirmed = relationship([Evidence(source: .ai, verdict: .reject, by: "ai:codex"), Evidence(source: .user, by: "user", at: earlier)])
        #expect(RelationshipConfidence.score(confirmed) == 100)
        #expect(RelationshipConfidence.status(confirmed) == .confirmed)
        let rejected = relationship([declared, history(12), Evidence(source: .user, verdict: .reject, by: "user", at: earlier)])
        #expect(RelationshipConfidence.score(rejected) == 0)
        #expect(RelationshipConfidence.status(rejected) == .rejected)
        let changedMind = relationship([Evidence(source: .user, verdict: .reject, by: "user", at: later), Evidence(source: .user, by: "user", at: earlier)])
        #expect(RelationshipConfidence.status(changedMind) == .rejected, "the latest verdict counts")
        #expect(RelationshipConfidence.score(changedMind) == 0)
        #expect(RelationshipConfidence.status(relationship([declared, history(3)])) == .inferred)
    }

    @Test func aiRejectionsLowerButNeverDecide() {
        let disputed = relationship([history(8), Evidence(source: .ai, verdict: .reject, by: "ai:codex")])
        #expect(RelationshipConfidence.score(disputed) == 43, "0.85 × (1 − 0.50)")
        #expect(RelationshipConfidence.status(disputed) == .inferred)
    }

    @Test func rejectedRelationshipsScoreZero() {
        #expect(RelationshipConfidence.score(relationship([history(12), code], status: .rejected)) == 0)
    }

    @Test func grainOnlyJoinsAreCapped() {
        #expect(score([history(12)], from: ["dt", "hour"], to: ["dt", "hour"]) == 35)
        #expect(score([history(12)], from: ["event_time"], to: ["log_date"]) == 35)
        #expect(score([history(12)], from: ["dt", "hour", "dsp_id"], to: ["dt", "hour", "id"]) == 90, "grain columns with a key pair")
        let created = relationship([history(12)], from: ["created"], to: ["created"])
        #expect(RelationshipConfidence.score(created) == 90)
        #expect(!RelationshipConfidence.isGrainJoin(created))
        let datetime = { (_: Relationship.End, _: String) -> String? in "datetime" }
        #expect(RelationshipConfidence.score(created, columnType: datetime) == 35, "time-like by type")
        #expect(RelationshipConfidence.isGrainJoin(created, columnType: datetime))
    }

    @Test func sharedKeysStayBelowTheJoinPathThreshold() {
        #expect(score([naming(30)], kind: .sharedKey) == 30)
        #expect(score([naming(60)], kind: .sharedKey) == 30)
        #expect(score([naming(30), history(4)], kind: .sharedKey) == 83, "real joins lift a shared key")
    }

    @Test func perEvidenceConfidence() {
        #expect(RelationshipConfidence.confidence(of: history(2)) == 65)
        #expect(RelationshipConfidence.confidence(of: Evidence(source: .user)) == 100)
        #expect(RelationshipConfidence.confidence(of: naming(-5)) == 0)
    }
}
