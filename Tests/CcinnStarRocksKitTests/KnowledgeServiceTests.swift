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
