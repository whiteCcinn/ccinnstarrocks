import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let later = Date(timeIntervalSince1970: 1_800_086_400)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe:9030"), catalog: "default_catalog", database: "adx")

private func object(_ name: String, _ kind: ObjectKind, model: TableModel? = nil, comment: String? = nil, sortKey: String? = nil,
                    partitionKey: String? = nil, distributionKey: String? = nil, baseTable: String? = nil) -> DatabaseObject {
    var object = DatabaseObject(catalog: "default_catalog", database: "adx", name: name, kind: kind)
    object.model = model
    object.comment = comment
    object.sortKey = sortKey
    object.partitionKey = partitionKey
    object.distributionKey = distributionKey
    object.baseTable = baseTable
    return object
}

private func column(_ name: String, _ ordinal: Int, _ type: String, key: Bool = false, aggregation: String? = nil, comment: String? = nil) -> ColumnInfo {
    ColumnInfo(name: name, ordinal: ordinal, dataType: type, columnType: type, isNullable: !key, isKey: key, aggregation: aggregation, comment: comment)
}

private func schema(dspIDType: String = "bigint", reportComment: String = "hourly report", viewDefinition: String? = nil,
                    extraTables: [ExtractedTable] = [], dropping: Set<String> = []) -> ExtractedSchema {
    var tables = [
        ExtractedTable(object: object("report_adx_hour", .table, model: .aggregate, comment: reportComment, sortKey: "dt, hour, dsp_id",
                                      partitionKey: "`dt`", distributionKey: "dsp_id"),
                       columns: [column("hour", 2, "tinyint", key: true), column("dt", 1, "date", key: true),
                                 column("dsp_id", 3, dspIDType, key: true, comment: "DSP"),
                                 column("dsp_request", 4, "bigint", aggregation: "SUM")],
                       definition: nil),
        ExtractedTable(object: object("dsp", .table, model: .primary), columns: [column("id", 1, "bigint", key: true), column("name", 2, "varchar(64)")],
                       definition: nil),
        ExtractedTable(object: object("v_dsp_report", .view),
                       columns: [column("dt", 1, "date"), column("dsp_name", 2, "varchar(64)")],
                       definition: viewDefinition ?? "SELECT r.dt, d.name AS dsp_name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt > '2026-01-01'"),
    ] + extraTables
    tables.removeAll { dropping.contains($0.object.name) }
    return ExtractedSchema(database: "adx", serverVersion: "3.3.22", clusterHints: nil, tables: tables)
}

@Suite("Schema fingerprints")
struct SchemaFingerprintTests {
    private func facts(_ schema: ExtractedSchema, _ name: String) throws -> TableFacts {
        let table = try #require(schema.tables.first { $0.object.name == name })
        return KnowledgeRefresher.tableFacts(table, database: "adx", previous: nil, now: now)
    }

    @Test func factsFollowTheServerInOrdinalOrder() throws {
        let report = try facts(schema(), "report_adx_hour")
        #expect(report.columns.map(\.name) == ["dt", "hour", "dsp_id", "dsp_request"])
        #expect(report.model == "AGG")
        #expect(report.keys.sort == ["dt", "hour", "dsp_id"])
        #expect(report.keys.partition == ["dt"])
        #expect(report.columns.last?.aggregation == "SUM")
        #expect(report.state == .new && report.firstSeen == now)
        let view = try facts(schema(), "v_dsp_report")
        #expect(view.kind == .view)
        #expect(view.lineage == [TableReference(table: "dsp"), TableReference(table: "report_adx_hour")])
    }

    @Test func commentsDoNotChangeTheStructureFingerprint() throws {
        let original = try facts(schema(), "report_adx_hour")
        let recommented = try facts(schema(reportComment: "per hour"), "report_adx_hour")
        #expect(original.fingerprint == recommented.fingerprint)
        #expect(original.commentFingerprint != recommented.commentFingerprint)
        let retyped = try facts(schema(dspIDType: "varchar(32)"), "report_adx_hour")
        #expect(original.fingerprint != retyped.fingerprint)
    }

    @Test func literalOnlyChangesInAViewDefinitionKeepTheFingerprint() throws {
        let original = try facts(schema(), "v_dsp_report")
        let otherDate = try facts(schema(viewDefinition: "SELECT r.dt, d.name AS dsp_name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt > '2026-06-01'"),
                                  "v_dsp_report")
        #expect(original.fingerprint == otherDate.fingerprint)
        let otherJoin = try facts(schema(viewDefinition: "SELECT r.dt, d.name AS dsp_name FROM report_adx_hour r JOIN dsp d ON r.hour = d.id"), "v_dsp_report")
        #expect(original.fingerprint != otherJoin.fingerprint)
    }
}

@Suite("Knowledge refresh")
struct KnowledgeRefreshTests {
    private func refreshed(_ schemas: [ExtractedSchema], machine: [[Relationship]] = []) -> (DatabaseKnowledge, KnowledgeRefresher.Report) {
        var knowledge = DatabaseKnowledge(key: key)
        var report = KnowledgeRefresher.Report()
        for (index, schema) in schemas.enumerated() {
            report = KnowledgeRefresher.apply(schema, machineRelationships: index < machine.count ? machine[index] : [], to: &knowledge,
                                              now: index == 0 ? now : later)
        }
        return (knowledge, report)
    }

    @Test func tableStatesAcrossRefreshes() {
        let renamed = ExtractedTable(object: object("dsp_v2", .table, model: .primary), columns: [column("id", 1, "bigint", key: true), column("name", 2, "varchar(64)")],
                                     definition: nil)
        let (knowledge, report) = refreshed([schema(), schema(dspIDType: "varchar(32)", extraTables: [renamed], dropping: ["dsp"])])
        #expect(knowledge.table(named: "report_adx_hour")?.state == .changed)
        #expect(knowledge.table(named: "report_adx_hour")?.changedAt == later)
        #expect(knowledge.table(named: "dsp")?.state == .dropped, "kept until the user prunes it")
        #expect(knowledge.table(named: "dsp_v2")?.state == .new)
        #expect(knowledge.table(named: "v_dsp_report")?.state == .fresh)
        #expect(report.tables == .init(total: 3, new: 1, changed: 1, dropped: 1))
        #expect(report.possibleRenames == [["dsp", "dsp_v2"]], "same structure, never moved automatically")
        #expect(knowledge.serverVersion == "3.3.22")
    }

    @Test func lineageBecomesRelationshipsThatNeverJoin() {
        let (knowledge, _) = refreshed([schema()])
        let lineage = knowledge.relationships.filter { $0.kind == .lineage }
        #expect(Set(lineage.map(\.to.table)) == ["dsp", "report_adx_hour"])
        #expect(lineage.allSatisfy { $0.from.table == "v_dsp_report" && $0.evidence.map(\.source) == [.lineage] })
    }

    // Machine evidence is recomputed on every refresh; what the user and the AI added stays.
    @Test func machineEvidenceIsReplacedCuratedEvidenceKept() throws {
        let from = Relationship.End(table: "report_adx_hour", columns: ["dsp_id"])
        let to = Relationship.End(table: "dsp", columns: ["id"])
        let naming = Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .naming, score: 55, at: now)])
        let gone = Relationship(from: .init(table: "report_adx_hour", columns: ["hour"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                evidence: [Evidence(source: .naming, score: 30, at: now)])
        var (knowledge, _) = refreshed([schema()], machine: [[naming, gone]])
        let id = naming.id
        let index = try #require(knowledge.relationships.firstIndex { $0.id == id })
        knowledge.relationships[index].evidence.append(Evidence(source: .code, path: "dao.go", line: 12, by: "ai:claude-code", at: now))
        let rerun = Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .naming, score: 60, at: later)])
        let report = KnowledgeRefresher.apply(schema(), machineRelationships: [rerun], to: &knowledge, now: later)
        let kept = try #require(knowledge.relationships.first { $0.id == id })
        #expect(kept.evidence.map(\.source).sorted { $0.rawValue < $1.rawValue } == [.code, .naming])
        #expect(kept.evidence.first { $0.source == .naming }?.score == 60)
        #expect(!knowledge.relationships.contains { $0.id == gone.id }, "machine-only evidence that is gone takes the relationship with it")
        #expect(report.relationships.removed == 1)
    }

    @Test func tombstonedRelationshipsAreNotInferredAgain() {
        let naming = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                  evidence: [Evidence(source: .naming, score: 55, at: now)])
        var knowledge = DatabaseKnowledge(key: key)
        knowledge.tombstones = [Tombstone(id: naming.id, deletedAt: now, by: "user")]
        _ = KnowledgeRefresher.apply(schema(), machineRelationships: [naming], to: &knowledge, now: now)
        #expect(!knowledge.relationships.contains { $0.id == naming.id })
    }

    @Test func notesAndRelationshipsGoStaleWhenTheirTableChanges() throws {
        var (knowledge, _) = refreshed([schema()])
        let report = try #require(knowledge.table(named: "report_adx_hour"))
        knowledge.notes.append(Note(id: "n1", table: "report_adx_hour", column: "dsp_id", kind: .caveat, text: "0 means house ads", evidence: [],
                                    by: "ai:codex", at: now, fingerprint: report.fingerprint))
        let curated = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                   evidence: [Evidence(source: .ai, by: "ai:codex", at: now)],
                                   fingerprints: ["report_adx_hour": report.fingerprint, "dsp": knowledge.table(named: "dsp")?.fingerprint ?? ""])
        knowledge.relationships.append(curated)
        #expect(!KnowledgeFreshness.isStale(knowledge.notes[0], in: knowledge))
        #expect(!KnowledgeFreshness.isStale(curated, in: knowledge))

        let refresh = KnowledgeRefresher.apply(schema(dspIDType: "varchar(32)"), machineRelationships: [], to: &knowledge, now: later)
        #expect(KnowledgeFreshness.isStale(knowledge.notes[0], in: knowledge))
        #expect(KnowledgeFreshness.isStale(try #require(knowledge.relationships.first { $0.id == curated.id }), in: knowledge))
        #expect(refresh.notesStale == 1)
        #expect(refresh.relationships.nowStale == 1)
    }

    @Test func relationshipsToMissingColumnsAreBroken() {
        let (knowledge, _) = refreshed([schema()])
        let broken = Relationship(from: .init(table: "report_adx_hour", columns: ["app_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                  evidence: [Evidence(source: .ai, at: now)])
        #expect(KnowledgeFreshness.isBroken(broken, in: knowledge))
        let fine = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                evidence: [Evidence(source: .ai, at: now)])
        #expect(!KnowledgeFreshness.isBroken(fine, in: knowledge))
        let otherDatabase = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(database: "admin", table: "dsp", columns: ["id"]),
                                         kind: .manyToOne, evidence: [Evidence(source: .ai, at: now)])
        #expect(!KnowledgeFreshness.isBroken(otherDatabase, in: knowledge), "another database's columns are checked against its own knowledge")
    }
}

@Suite("Knowledge extraction")
struct KnowledgeExtractionTests {
    private struct FakeSource: KnowledgeSchemaSource {
        let knowledgeServerVersion: String? = "4.1.0"
        func objects(catalog: String, database: String) async throws -> [DatabaseObject] {
            [object("report_adx_hour", .table, model: .aggregate), object("v_x", .view), object("mv_x", .asyncMaterializedView),
             object("sys_x", .systemView)]
        }
        func columnsByTable(database: String, tables: [String]?) async throws -> [String: [ColumnInfo]] {
            ["report_adx_hour": [column("dt", 1, "date", key: true)], "v_x": [column("dt", 1, "date")]]
        }
        func viewDefinitions(database: String) async throws -> [String: String] { ["v_x": "SELECT dt FROM report_adx_hour"] }
        func clusterHints() async throws -> ClusterHints? { ClusterHints(clusterID: "42", frontendHosts: ["10.0.0.5"]) }
    }

    @Test func oneDatabaseInAHandfulOfQueries() async throws {
        let schema = try await KnowledgeExtractor.extract(database: "adx", from: FakeSource())
        #expect(schema.tables.map(\.object.name) == ["report_adx_hour", "v_x", "mv_x"], "system views are not knowledge")
        #expect(schema.tables.first { $0.object.name == "v_x" }?.definition == "SELECT dt FROM report_adx_hour")
        #expect(schema.serverVersion == "4.1.0")
        #expect(schema.clusterHints?.clusterID == "42")
    }
}
