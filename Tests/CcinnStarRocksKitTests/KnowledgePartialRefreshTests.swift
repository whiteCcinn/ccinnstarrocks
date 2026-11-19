import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let later = Date(timeIntervalSince1970: 1_800_086_400)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe:9030"), catalog: "default_catalog", database: "adx")

private func object(_ name: String, _ kind: ObjectKind) -> DatabaseObject {
    DatabaseObject(catalog: "default_catalog", database: "adx", name: name, kind: kind)
}

private func column(_ name: String, _ ordinal: Int, _ type: String = "bigint", key: Bool = false) -> ColumnInfo {
    ColumnInfo(name: name, ordinal: ordinal, dataType: type, columnType: type, isNullable: !key, isKey: key)
}

/// What an administrator sees, and what an account with SELECT on `dsp` only sees: `information_schema` leaves out
/// `dsp_budget`, and the view's definition, which reads it.
private func schema(restricted: Bool) -> ExtractedSchema {
    var tables = [
        ExtractedTable(object: object("dsp", .table), columns: [column("id", 1, key: true), column("name", 2, "varchar(64)")], definition: nil),
        ExtractedTable(object: object("v_dsp_budget", .view), columns: [column("id", 1), column("amount", 2, "decimal(18,6)")],
                       definition: restricted ? nil : "SELECT d.id, b.amount FROM dsp d JOIN dsp_budget b ON b.dsp_id = d.id"),
    ]
    if !restricted {
        tables.append(ExtractedTable(object: object("dsp_budget", .table),
                                     columns: [column("id", 1, key: true), column("dsp_id", 2), column("amount", 3, "decimal(18,6)")], definition: nil))
    }
    return ExtractedSchema(database: "adx", serverVersion: "3.3.22", clusterHints: nil, tables: tables)
}

private func machine(_ schema: ExtractedSchema, _ knowledge: DatabaseKnowledge, at date: Date) -> [Relationship] {
    var preview = knowledge
    var report = KnowledgeRefresher.Report()
    KnowledgeRefresher.updateTables(schema, in: &preview, now: date, report: &report)
    return KnowledgeInference.machineRelationships(KnowledgeInferenceInput(schema: schema, knowledge: preview, history: [], now: date))
}

private func adminKnowledge() -> DatabaseKnowledge {
    var knowledge = DatabaseKnowledge(key: key)
    let admin = schema(restricted: false)
    KnowledgeRefresher.apply(admin, machineRelationships: machine(admin, knowledge, at: now), to: &knowledge, now: now)
    let fingerprint = knowledge.table(named: "dsp_budget")?.fingerprint
    knowledge.notes = [Note(id: "n1", table: "dsp_budget", column: nil, kind: .description, text: "daily cap per DSP", evidence: [], by: "user",
                            at: now, fingerprint: fingerprint)]
    return knowledge
}

@Suite("Knowledge: a refresh through an account that sees part of a database")
struct KnowledgePartialRefreshTests {
    @Test func theFixtureHasWhatTheAccountCannotSee() {
        let knowledge = adminKnowledge()
        #expect(knowledge.table(named: "dsp_budget") != nil)
        #expect(knowledge.relationships.contains { $0.from.table == "dsp_budget" && $0.to.table == "dsp" && $0.kind != .lineage })
        #expect(knowledge.relationships.contains { $0.from.table == "v_dsp_budget" && $0.kind == .lineage })
    }

    // An AI session's refresh never drops, changes or unlinks what its account cannot see.
    @Test func aPartialRefreshLeavesWhatTheAccountCannotSeeUntouched() {
        var knowledge = adminKnowledge()
        let before = knowledge
        let restricted = schema(restricted: true)
        let report = KnowledgeRefresher.apply(restricted, machineRelationships: machine(restricted, knowledge, at: later), to: &knowledge, now: later,
                                              partial: true)
        #expect(knowledge.table(named: "dsp_budget") == before.table(named: "dsp_budget"), "a table it cannot see is not dropped")
        #expect(knowledge.table(named: "v_dsp_budget") == before.table(named: "v_dsp_budget"), "an unreadable view definition is not a change")
        #expect(knowledge.relationships.map(\.id) == before.relationships.map(\.id), "relationships outside its view keep their evidence")
        #expect(!knowledge.notes.contains { KnowledgeFreshness.isStale($0, in: knowledge) })
        #expect(report.tables.dropped == 0 && report.possibleRenames.isEmpty && report.relationships.removed == 0)
        #expect(report.tables.total == 2, "it counts only what the account sees")
    }

    // A materialized view whose definition the account cannot read is left as it was too.
    @Test func anUnreadableMaterializedViewDefinitionIsNotAChange() {
        let withDefinition = ExtractedTable(object: object("mv_dsp_day", .asyncMaterializedView), columns: [column("dsp_id", 1)],
                                            definition: "SELECT dsp_id FROM dsp_budget")
        var unreadable = withDefinition
        unreadable.definition = nil
        let old = KnowledgeRefresher.tableFacts(withDefinition, database: "adx", previous: nil, now: now)
        #expect(!KnowledgeRefresher.isFullySeen(unreadable, comparedTo: old))
        #expect(KnowledgeRefresher.isFullySeen(withDefinition, comparedTo: old))
    }

    // The user's refresh in the app still marks tables that are gone.
    @Test func aFullRefreshStillDropsTables() {
        var knowledge = adminKnowledge()
        let restricted = schema(restricted: true)
        let report = KnowledgeRefresher.apply(restricted, machineRelationships: machine(restricted, knowledge, at: later), to: &knowledge, now: later)
        #expect(knowledge.table(named: "dsp_budget")?.state == .dropped)
        #expect(report.tables.dropped == 1)
    }

    // Through the service: the MCP tools refresh partially, the app fully.
    @Test func theServicePassesPartialThrough() async throws {
        let store = KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sr-partial-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.updateDatabase(key) { (database: inout DatabaseKnowledge) -> Void in database = adminKnowledge() }
        _ = try await KnowledgeService.refresh(key, source: FixedSchemaSource(schema: schema(restricted: true)), store: store, history: [],
                                               infer: KnowledgeInference.machineRelationships, now: later, partial: true)
        #expect(try store.database(key)?.table(named: "dsp_budget")?.state != .dropped)
        _ = try await KnowledgeService.refresh(key, source: FixedSchemaSource(schema: schema(restricted: true)), store: store, history: [],
                                               infer: KnowledgeInference.machineRelationships, now: later)
        #expect(try store.database(key)?.table(named: "dsp_budget")?.state == .dropped)
    }
}

/// Serves the tables of an `ExtractedSchema` as `information_schema` would.
private struct FixedSchemaSource: KnowledgeSchemaSource {
    let schema: ExtractedSchema
    var knowledgeServerVersion: String? { schema.serverVersion }

    func objects(catalog: String, database: String) async throws -> [DatabaseObject] { schema.tables.map(\.object) }

    func columnsByTable(database: String, tables: [String]?) async throws -> [String: [ColumnInfo]] {
        Dictionary(schema.tables.map { ($0.object.name, $0.columns) }, uniquingKeysWith: { first, _ in first })
    }

    func viewDefinitions(database: String) async throws -> [String: String] {
        var definitions: [String: String] = [:]
        for table in schema.tables {
            if let definition = table.definition { definitions[table.object.name] = definition }
        }
        return definitions
    }

    func clusterHints() async throws -> ClusterHints? { nil }
}
