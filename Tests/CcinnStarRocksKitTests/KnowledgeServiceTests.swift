import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe:9030"), catalog: "default_catalog", database: "adx")

private func temporaryStore() -> KnowledgeStore {
    KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-\(UUID().uuidString)", isDirectory: true))
}

private func sample() -> DatabaseKnowledge {
    var knowledge = DatabaseKnowledge(key: key)
    knowledge.tables = [TableFacts(name: "report", kind: .table, columns: [ColumnFacts(name: "dsp_id", type: "bigint")], fingerprint: "f1", state: .fresh, firstSeen: now),
                        TableFacts(name: "dsp", kind: .table, columns: [ColumnFacts(name: "id", type: "bigint", isKey: true)], fingerprint: "f2", state: .fresh, firstSeen: now)]
    knowledge.relationships = [Relationship(from: .init(table: "report", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                            evidence: [Evidence(source: .naming, score: 55, at: now)], fingerprints: ["report": "old", "dsp": "f2"])]
    knowledge.notes = [Note(id: "n1", table: "report", column: nil, kind: .usage, text: "x", evidence: [], by: "ai:codex", at: now, fingerprint: nil)]
    return knowledge
}

@Suite("Knowledge service")
struct KnowledgeServiceTests {
    @Test func theUsersVerdictIsEvidenceThatWins() throws {
        var knowledge = sample()
        let id = knowledge.relationships[0].id
        try KnowledgeService.decide(id, accept: true, in: &knowledge, now: now)
        #expect(knowledge.relationships[0].status == .confirmed)
        #expect(knowledge.relationships[0].evidence.filter { $0.source == .user }.count == 1)
        #expect(knowledge.relationships[0].fingerprints == ["report": "f1", "dsp": "f2"], "confirming re-binds it to the current structure")
        try KnowledgeService.decide(id, accept: false, in: &knowledge, now: now)
        #expect(knowledge.relationships[0].status == .rejected)
        #expect(knowledge.relationships[0].evidence.filter { $0.source == .user }.map(\.verdict) == [.reject], "one user verdict, the latest")
        #expect(throws: KnowledgeService.Failure.self) { try KnowledgeService.decide("nope", accept: true, in: &knowledge, now: now) }
    }

    @Test func theUserDeletesAnythingWithATombstone() throws {
        var knowledge = sample()
        let relationship = knowledge.relationships[0].id
        try KnowledgeService.delete(ids: ["n1", relationship], in: &knowledge, now: now)
        #expect(knowledge.notes.isEmpty && knowledge.relationships.isEmpty)
        #expect(Set(knowledge.tombstones.map(\.id)) == ["n1", relationship])
        #expect(knowledge.tombstones.allSatisfy { $0.by == "user" })
    }

    @Test func projectsLinkUnlinkAndRemap() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent("code/adx", isDirectory: true)
        let moved = home.appendingPathComponent("work/adx", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let id = try KnowledgeService.linkProject(path: project.path, to: key, store: store, home: home, now: now)
        var index = try store.index()
        #expect(index.projects.map(\.path) == ["~/code/adx"] && index.projects.first?.addedBy == "user")
        #expect(index.links.map(\.database) == [key.fileID])
        #expect(index.databases.map(\.key) == [key])

        try KnowledgeService.remapProject(id: id, to: moved.path, store: store, home: home)
        index = try store.index()
        #expect(index.projects.map(\.path) == ["~/work/adx"])
        #expect(index.links.count == 1, "links follow the project")

        try KnowledgeService.unlinkProject(id: id, from: key, store: store)
        #expect(try store.index().links.isEmpty)
    }

    @Test func deletingADatabasesKnowledgeRemovesItsFileAndLinks() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.updateDatabase(key) { $0 = sample() }
        try store.updateIndex { $0.links.append(KnowledgeIndex.Link(project: "p1", database: key.fileID, addedAt: now, addedBy: "user")) }
        try store.removeDatabase(key)
        #expect(try store.database(key) == nil)
        let index = try store.index()
        #expect(index.databases.isEmpty && index.links.isEmpty)
        #expect(index.tombstones.map(\.id) == [key.fileID])
    }

    // The app and `mcp` refresh through the same pipeline.
    @Test func refreshExtractsInfersAndSaves() async throws {
        struct Source: KnowledgeSchemaSource {
            let knowledgeServerVersion: String? = "3.3"
            func objects(catalog: String, database: String) async throws -> [DatabaseObject] {
                [DatabaseObject(catalog: catalog, database: database, name: "report", kind: .table), DatabaseObject(catalog: catalog, database: database, name: "dsp", kind: .table)]
            }
            func columnsByTable(database: String, tables: [String]?) async throws -> [String: [ColumnInfo]] {
                ["report": [ColumnInfo(name: "dsp_id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: true, isKey: false)],
                 "dsp": [ColumnInfo(name: "id", ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: false, isKey: true)]]
            }
            func viewDefinitions(database: String) async throws -> [String: String] { [:] }
            func clusterHints() async throws -> ClusterHints? { nil }
        }
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let infer: KnowledgeToolSettings.Inference = { (input: KnowledgeInferenceInput) -> [Relationship] in
            #expect(input.knowledge.tables.map(\.name) == ["dsp", "report"], "inference sees this extraction's tables")
            return [Relationship(from: .init(table: "report", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                 evidence: [Evidence(source: .naming, score: 55, at: input.now)])]
        }
        let report = try await KnowledgeService.refresh(key, source: Source(), store: store, history: [], infer: infer, now: now)
        #expect(report.tables.total == 2 && report.relationships.added == 1)
        #expect(try store.database(key)?.relationships.first?.fingerprints["report"] != nil)
    }
}

@Suite("Knowledge inference wiring")
struct KnowledgeInferenceWiringTests {
    @Test func everyMachineSourceContributes() throws {
        func object(_ name: String, _ kind: ObjectKind, properties: [String: String] = [:]) -> DatabaseObject {
            var object = DatabaseObject(catalog: "default_catalog", database: "adx", name: name, kind: kind)
            object.properties = properties
            return object
        }
        func column(_ name: String, key: Bool = false) -> ColumnInfo {
            ColumnInfo(name: name, ordinal: 1, dataType: "bigint", columnType: "bigint", isNullable: !key, isKey: key)
        }
        let schema = ExtractedSchema(database: "adx", serverVersion: nil, clusterHints: nil, tables: [
            ExtractedTable(object: object("report_adx_hour", .table, properties: ["foreign_key_constraints": "(app_id) REFERENCES app(id)"]),
                           columns: [column("dsp_id"), column("app_id")], definition: nil),
            ExtractedTable(object: object("dsp", .table), columns: [column("id", key: true)], definition: nil),
            ExtractedTable(object: object("app", .table), columns: [column("id", key: true)], definition: nil),
            ExtractedTable(object: object("v_report", .view), columns: [column("dsp_id")],
                           definition: "SELECT r.dsp_id FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id"),
        ])
        var knowledge = DatabaseKnowledge(key: key)
        var report = KnowledgeRefresher.Report()
        KnowledgeRefresher.updateTables(schema, in: &knowledge, now: now, report: &report)
        let history = [QueryHistoryEntry(id: UUID(), sql: "SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = '2026-11-19'",
                                         database: "adx", executedAt: now, durationMilliseconds: 10, rowCount: 1, affectedRows: nil, errorMessage: nil)]
        let machine = KnowledgeInference.machineRelationships(KnowledgeInferenceInput(schema: schema, knowledge: knowledge, history: history, now: now))
        let sources = Set(machine.flatMap { $0.evidence.map(\.source) })
        #expect(sources.isSuperset(of: [.declared, .naming, .history, .definition]), "\(sources)")
        let declared = try #require(machine.first { $0.evidence.contains { $0.source == .declared } })
        #expect(declared.from.table == "report_adx_hour" && declared.to.table == "app" && declared.to.columns == ["id"])
    }
}

@Suite("Join extraction from server-printed definitions")
struct ServerPrintedDefinitionTests {
    // StarRocks 3.3's information_schema.views prints `db`.`alias`.`column`.
    @Test func databaseQualifiedAliases() {
        let definition = """
        SELECT `kb_demo`.`r`.`dt`, `kb_demo`.`d`.`name` AS `dsp_name` FROM `kb_demo`.`report_adx_hour` AS `r` \
        INNER JOIN `kb_demo`.`dsp` AS `d` ON `kb_demo`.`r`.`dsp_id` = `kb_demo`.`d`.`id` GROUP BY `kb_demo`.`r`.`dt`, `kb_demo`.`d`.`name`
        """
        let joins = SQLJoinExtractor.joins(in: definition) { _ in nil }
        #expect(joins.count == 1)
        let pair = joins.first
        let tables = Set([pair?.left.table, pair?.right.table].compactMap { $0 })
        #expect(tables == ["report_adx_hour", "dsp"])
    }
}
