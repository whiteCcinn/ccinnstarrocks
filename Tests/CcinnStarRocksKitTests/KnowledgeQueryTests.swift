import Foundation
import Testing
@testable import CcinnStarRocksKit

// The query engine over one database's knowledge: search, explanations, join paths, subject areas and diagrams.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func table(_ name: String, _ columns: [(String, String, Bool)], kind: TableFacts.Kind = .table, model: String? = "DUP", comment: String? = nil,
                   partition: [String] = [], primary: [String] = [], lineage: [TableReference] = [], state: TableFacts.State = .fresh) -> TableFacts {
    TableFacts(name: name, kind: kind, model: model, comment: comment, keys: .init(primary: primary, partition: partition),
               columns: columns.map { ColumnFacts(name: $0.0, type: $0.1, isKey: $0.2, isNullable: !$0.2) }, lineage: lineage,
               fingerprint: "fp-" + name, state: state, firstSeen: now)
}

private func link(_ from: String, _ fromColumns: [String], _ to: String, _ toColumns: [String], score: Int, kind: Relationship.Kind = .manyToOne,
                  source: Evidence.Source = .naming, verdict: Evidence.Verdict = .assert, fingerprints: [String: String]? = nil) -> Relationship {
    Relationship(from: .init(table: from, columns: fromColumns), to: .init(table: to, columns: toColumns), kind: kind,
                 evidence: [Evidence(source: source, verdict: verdict, score: score, project: source == .code ? "p1" : nil,
                                     path: source == .code ? "internal/report/dao.go" : nil,
                                     line: source == .code ? 120 : nil, symbol: source == .code ? "ReportDAO.ByDSP" : nil,
                                     by: source == .code ? "ai:claude-code" : nil, at: now)],
                 fingerprints: fingerprints ?? [from: "fp-" + from, to: "fp-" + to])
}

/// Confidence for tests: the highest evidence score; a user reject is 0.
private let confidence: @Sendable (Relationship) -> Int = { relationship in
    if relationship.evidence.contains(where: { $0.source == .user && $0.verdict == .reject }) { return 0 }
    return relationship.evidence.compactMap(\.score).max() ?? 80
}

private let knowledge: DatabaseKnowledge = {
    var knowledge = DatabaseKnowledge(key: DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe:9030"), catalog: "default_catalog", database: "adx"))
    knowledge.tables = [
        table("report_adx_hour", [("dt", "date", true), ("hour", "tinyint", true), ("dsp_id", "bigint", true), ("app_id", "bigint", true),
                                  ("dsp_request", "bigint", false)], model: "AGG", comment: "ADX 小时报表", partition: ["dt"]),
        table("dsp", [("id", "bigint", true), ("name", "varchar(64)", false)], model: "PK", primary: ["id"]),
        table("app", [("id", "bigint", true), ("publisher_id", "bigint", false), ("name", "varchar(64)", false)], model: "PK", primary: ["id"]),
        table("publisher", [("id", "bigint", true), ("name", "varchar(64)", false)], model: "PK", primary: ["id"]),
        table("report_app_day", [("dt", "date", true), ("app_id", "bigint", true), ("revenue", "decimal(18,6)", false)], model: "AGG"),
        table("mv_report_adx_day", [("dt", "date", true), ("dsp_id", "bigint", true)], kind: .materializedView,
              lineage: [TableReference(table: "report_adx_hour")]),
        table("adx_audit_log", [("id", "bigint", true)]),
        table("adx_audit_detail", [("id", "bigint", true)]),
        table("adx_audit_rule", [("id", "bigint", true)]),
        table("old_report", [("id", "bigint", true)], state: .dropped),
    ]
    knowledge.relationships = [
        link("report_adx_hour", ["dsp_id"], "dsp", ["id"], score: 85, source: .code),
        link("report_adx_hour", ["app_id"], "app", ["id"], score: 70),
        link("app", ["publisher_id"], "publisher", ["id"], score: 60),
        link("report_app_day", ["app_id"], "app", ["id"], score: 65),
        link("report_adx_hour", ["hour"], "dsp", ["id"], score: 90, source: .user, verdict: .reject),
        link("report_app_day", ["dt"], "publisher", ["id"], score: 20),
        link("mv_report_adx_day", [], "report_adx_hour", [], score: 100, kind: .lineage, source: .lineage),
        link("dsp", ["name"], "app", ["name"], score: 75, kind: .manyToMany, fingerprints: ["dsp": "fp-old", "app": "fp-app"]),
    ]
    knowledge.notes = [Note(id: "n1", table: "report_adx_hour", column: "dsp_id", kind: .caveat, text: "0 表示自有广告 (house ads)", evidence: [],
                            by: "ai:codex", at: now, fingerprint: "fp-report_adx_hour")]
    knowledge.terms = [Term(id: "g1", term: "fill rate", synonyms: ["填充率"], definition: "Filled DSP requests over all requests",
                            mapsTo: [.init(table: "report_adx_hour", expression: "SUM(dsp_fill) / SUM(dsp_request)")], by: "user", at: now)]
    return knowledge
}()

@Suite("Knowledge search")
struct KnowledgeSearchTests {
    @Test func namesRankAboveColumnsAboveComments() {
        let (hits, _) = KnowledgeSearch.search("dsp", in: knowledge)
        #expect(hits.first == KnowledgeSearch.Hit(type: "table", name: "dsp", why: "name", score: 100))
        #expect(hits.contains { $0.type == "column" && $0.name == "report_adx_hour.dsp_id" })
        #expect(!hits.contains { $0.name == "old_report" }, "dropped tables are not results")
    }

    @Test func glossaryAndChineseText() {
        #expect(KnowledgeSearch.search("填充率", in: knowledge).hits.first?.name == "report_adx_hour")
        #expect(KnowledgeSearch.search("fill rate", in: knowledge).hits.first?.why == "term: fill rate")
        #expect(KnowledgeSearch.search("小时报表", in: knowledge).hits.first?.name == "report_adx_hour", "CJK matches comment substrings")
        #expect(KnowledgeSearch.search("自有广告", in: knowledge).hits.contains { $0.type == "note" })
    }

    @Test func tokensAndLimits() {
        #expect(KnowledgeSearch.search("reportAdxHour", in: knowledge).hits.first?.name == "report_adx_hour", "camelCase splits into tokens")
        let (hits, truncated) = KnowledgeSearch.search("id", in: knowledge, limit: 3)
        #expect(hits.count == 3 && truncated)
        #expect(KnowledgeSearch.search("audit", in: knowledge, scopes: [.columns]).hits.isEmpty)
    }
}

@Suite("Table explanations")
struct TableExplanationTests {
    @Test func relationshipsNotesAndHints() throws {
        let explanation = try #require(TableExplanation.explain(table: "report_adx_hour", in: knowledge, confidence: confidence,
                                                                projects: [.init(id: "p1", path: "~/code/adx-server", name: "adx-server", gitRemote: nil,
                                                                                 addedAt: now, addedBy: "user")]))
        #expect(explanation.model == "AGG")
        #expect(explanation.columns.first == ["dt", "date", "K", ""])
        let toDSP = try #require(explanation.relationships.first { $0.other == "dsp" && $0.on == "report_adx_hour.dsp_id = dsp.id" })
        #expect(toDSP.direction == "out" && toDSP.cardinality == "n:1" && toDSP.confidence == 85 && toDSP.sources == ["code"])
        #expect(!explanation.relationships.contains { $0.on == "report_adx_hour.hour = dsp.id" }, "rejected relationships are not shown")
        #expect(explanation.relationships.contains { $0.other == "mv_report_adx_day" && $0.cardinality == "lineage" && $0.direction == "in" })
        #expect(explanation.notes.map(\.id) == ["n1"])
        #expect(explanation.terms.first?.term == "fill rate")
        #expect(explanation.usedBy == [TableExplanation.Usage(project: "adx-server", path: "internal/report/dao.go", line: 120, symbol: "ReportDAO.ByDSP")])
        #expect(explanation.hints.contains { $0.contains("partition key `dt`") })
        #expect(explanation.hints.contains { $0.contains("AGG") })
        #expect(explanation.hints.contains { $0.contains("mv_report_adx_day") })
        #expect(TableExplanation.explain(table: "nope", in: knowledge, confidence: confidence, projects: []) == nil)
    }

    @Test func staleRelationshipsAreMarked() throws {
        let dsp = try #require(TableExplanation.explain(table: "dsp", in: knowledge, confidence: confidence, projects: []))
        #expect(dsp.relationships.first { $0.other == "app" }?.state == "stale")
    }
}

@Suite("Join paths")
struct JoinPathTests {
    @Test func shortestPathWithConditionsAndSQL() throws {
        let result = JoinPathFinder.find(from: "report_adx_hour", to: "publisher", in: knowledge, confidence: confidence)
        let best = try #require(result.paths.first)
        #expect(best.steps.map(\.join) == ["app", "publisher"])
        #expect(best.steps.map(\.on) == ["report_adx_hour.app_id = app.id", "app.publisher_id = publisher.id"])
        #expect(best.minConfidence == 60)
        #expect(best.sql == "FROM report_adx_hour\nJOIN app ON report_adx_hour.app_id = app.id\nJOIN publisher ON app.publisher_id = publisher.id")
        #expect(result.excluded.belowMinimum == 1, "the 20% grain guess is not a path")
        #expect(result.excluded.stale == 1)
    }

    @Test func fanOutIsWarned() throws {
        let result = JoinPathFinder.find(from: "report_adx_hour", to: "report_app_day", in: knowledge, confidence: confidence)
        let best = try #require(result.paths.first)
        #expect(best.steps.map(\.join) == ["app", "report_app_day"])
        #expect(best.warnings.contains { $0.contains("aggregate each side") })
    }

    @Test func throughAndAlternativesAndNoPath() throws {
        let through = JoinPathFinder.find(from: "report_adx_hour", to: "publisher", through: ["app"], in: knowledge, confidence: confidence)
        #expect(through.paths.first?.steps.map(\.join) == ["app", "publisher"])
        let none = JoinPathFinder.find(from: "dsp", to: "adx_audit_log", in: knowledge, confidence: confidence)
        #expect(none.paths.isEmpty)
        #expect(none.nearest?.from.contains("report_adx_hour") == true)
        let low = JoinPathFinder.find(from: "report_app_day", to: "publisher", in: knowledge, confidence: confidence, minConfidence: 10, alternatives: 3)
        #expect(low.paths.count == 2, "the direct grain guess and the path through app")
        #expect(low.paths[0].minConfidence >= low.paths[1].minConfidence || low.paths[0].steps.count < low.paths[1].steps.count)
    }
}

@Suite("Subject areas and diagrams")
struct KnowledgeDiagramTests {
    @Test func connectedComponentsAndPrefixClusters() {
        let areas = SubjectAreas.areas(in: knowledge, confidence: confidence)
        let connected = areas.filter { $0.source == "connected" }
        #expect(connected.contains { Set($0.tables) == ["report_adx_hour", "dsp", "app", "publisher", "report_app_day"] })
        #expect(areas.contains { $0.source == "prefix" && $0.name == "adx_*" && $0.tables == ["adx_audit_detail", "adx_audit_log", "adx_audit_rule"] })
    }

    @Test func mermaidWithKeysCardinalityAndConfidenceStyle() throws {
        let diagram = try MermaidERDRenderer.render(tables: ["report_adx_hour", "dsp", "app"], in: knowledge, confidence: confidence, title: "ADX")
        #expect(diagram.mermaid.hasPrefix("erDiagram\n"))
        #expect(diagram.mermaid.contains("report_adx_hour }o--|| dsp : \"dsp_id 85%\""))
        #expect(diagram.mermaid.contains("report_adx_hour }o--|| app : \"app_id 70%\""))
        #expect(diagram.mermaid.contains("bigint dsp_id FK"))
        #expect(diagram.mermaid.contains("bigint id PK"))
        #expect(!diagram.mermaid.contains("hour 90%"), "rejected relationships are not drawn")
        let dashed = try MermaidERDRenderer.render(tables: ["app", "publisher"], in: knowledge, confidence: confidence, title: "x")
        #expect(dashed.mermaid.contains("app }o..|| publisher"), "below 70% is drawn dashed")
    }

    @Test func namesAndLabelsCannotInjectMermaid() throws {
        var hostile = knowledge
        hostile.tables.append(table("x\" } %%{init: {}}%% click", [("a\nb", "decimal(12,2)", true)]))
        hostile.relationships.append(link("x\" } %%{init: {}}%% click", ["a\nb"], "dsp", ["id"], score: 90))
        let diagram = try MermaidERDRenderer.render(tables: ["x\" } %%{init: {}}%% click", "dsp"], in: hostile, confidence: confidence, title: "t")
        let body = diagram.mermaid.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%%") }.joined(separator: "\n")
        #expect(!body.contains("%%{"))
        #expect(!body.contains("click"))
        #expect(diagram.mermaid.contains("decimal_12_2"))
    }

    @Test func largeDiagramsAreRefusedWithSuggestions() {
        var many = knowledge
        many.tables += (1...61).map { table("t\($0)", [("id", "bigint", true)]) }
        #expect(throws: MermaidERDRenderer.Failure.self) {
            try MermaidERDRenderer.render(tables: (1...61).map { "t\($0)" }, in: many, confidence: confidence, title: "all", maxTables: 60)
        }
    }
}
