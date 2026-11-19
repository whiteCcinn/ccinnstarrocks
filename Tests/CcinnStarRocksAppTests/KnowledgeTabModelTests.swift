import Foundation
import Testing
@testable import CcinnStarRocks
@testable import CcinnStarRocksKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe:9030"), catalog: "default_catalog", database: "adx")

private func seeded(_ knowledge: inout DatabaseKnowledge) {
    knowledge.tables = [
        TableFacts(name: "report_adx_hour", kind: .table, columns: [ColumnFacts(name: "dsp_id", type: "bigint", isKey: true)], fingerprint: "f1", state: .fresh, firstSeen: now),
        TableFacts(name: "dsp", kind: .table, keys: .init(primary: ["id"]), columns: [ColumnFacts(name: "id", type: "bigint", isKey: true)], fingerprint: "f2",
                   state: .fresh, firstSeen: now),
    ]
    knowledge.relationships = [Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                            evidence: [Evidence(source: .naming, score: 60, at: now)], fingerprints: ["report_adx_hour": "f1", "dsp": "f2"])]
    knowledge.notes = [Note(id: "n1", table: "dsp", column: nil, kind: .description, text: "DSP partners", evidence: [], by: "ai:codex", at: now, fingerprint: "f2")]
    knowledge.refreshedAt = now
}

@Suite("Knowledge tab", .serialized)
@MainActor
struct KnowledgeTabModelTests {
    private func model() -> (KnowledgeTabModel, KnowledgeStore) {
        let store = KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-\(UUID().uuidString)", isDirectory: true))
        let model = KnowledgeTabModel(key: key, store: store, refresher: {
            try store.updateDatabase(key) { seeded(&$0) }
            var report = KnowledgeRefresher.Report()
            report.tables.total = 2
            return report
        })
        return (model, store)
    }

    @Test func refreshLoadsAndReports() async throws {
        let (model, store) = model()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await model.load()
        #expect(model.knowledge == nil)
        await model.refresh()
        #expect(model.knowledge?.tables.count == 2)
        #expect(model.lastReport?.tables.total == 2)
        #expect(model.relationships.count == 1, "the inferred relationship waits for review")
    }

    @Test func verdictsMoveRelationshipsBetweenFilters() async throws {
        let (model, store) = model()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await model.refresh()
        let relationship = try #require(model.relationships.first)
        model.decide(relationship, accept: true)
        await model.load()
        #expect(model.relationships.isEmpty, "nothing left to review")
        model.filter = .confirmed
        #expect(model.relationships.map(\.id) == [relationship.id])
        model.decide(relationship, accept: false)
        await model.load()
        model.filter = .rejected
        #expect(model.relationships.map(\.id) == [relationship.id])
        #expect(try store.database(key)?.relationships.first?.evidence.filter { $0.source == .user }.count == 1)
    }

    @Test func notesProjectsAndDiagram() async throws {
        let (model, store) = model()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await model.refresh()
        model.delete("n1")
        await model.load()
        #expect(model.knowledge?.notes.isEmpty == true)
        #expect(model.knowledge?.tombstones.map(\.id) == ["n1"])

        let project = FileManager.default.temporaryDirectory.appendingPathComponent("adx-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        model.link(path: project.path)
        await model.load()
        #expect(model.projects.map(\.name) == [project.lastPathComponent])
        #expect(model.projects.first.map(model.projectExists) == true)
        try FileManager.default.removeItem(at: project)
        #expect(model.projects.first.map(model.projectExists) == false, "a project not on this Mac is flagged")
        if let linked = model.projects.first { model.unlink(linked) }
        await model.load()
        #expect(model.projects.isEmpty)

        #expect(model.diagramArea != nil)
        #expect(model.diagramText.hasPrefix("erDiagram"))
        #expect(model.diagramText.contains("report_adx_hour"))
    }
}
