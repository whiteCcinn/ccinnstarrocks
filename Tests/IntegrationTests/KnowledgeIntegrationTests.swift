import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

/// Knowledge built from a real cluster (scripts/seed-knowledge.sql, applied by scripts/sr-up.sh): every inference source
/// on StarRocks 3.3 and 4.1.
@Suite("Knowledge on StarRocks", .enabled(if: IntegrationEnvironment.isEnabled), .serialized)
struct KnowledgeIntegrationTests {
    // An AI session's account may read part of a database: its refresh must not drop what information_schema hides
    // from it.
    @Test(arguments: IntegrationEnvironment.targets)
    func aRestrictedAccountsRefreshKeepsWhatItCannotSee(target: IntegrationEnvironment.Target) async throws {
        let admin = try await IntegrationEnvironment.client(target)
        defer { Task { await admin.close() } }
        let store = KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-it-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://it:\(target.label)"), catalog: SQLText.defaultCatalog, database: "kb_demo")
        _ = try await KnowledgeService.refresh(key, source: admin, store: store, history: [], infer: KnowledgeInference.machineRelationships, now: Date())
        let full = try #require(try store.database(key))
        let reader = "ccinn_it_kb_\(String(UInt32.random(in: 0...UInt32.max), radix: 36))"
        _ = try await admin.execute("CREATE USER '\(reader)'@'%'")
        do {
            _ = try await admin.execute("GRANT SELECT ON TABLE kb_demo.dsp TO USER '\(reader)'@'%'")
            let restricted = try await IntegrationEnvironment.client(target, user: reader)
            let visible = try await restricted.objects(catalog: SQLText.defaultCatalog, database: "kb_demo")
            #expect(visible.count < full.tables.count, "information_schema shows the account part of the database: \(visible.map(\.name))")
            let report = try await KnowledgeService.refresh(key, source: restricted, store: store, history: [],
                                                            infer: KnowledgeInference.machineRelationships, now: Date(), partial: true)
            await restricted.close()
            let after = try #require(try store.database(key))
            #expect(after.tables.map(\.name) == full.tables.map(\.name) && after.tables.allSatisfy { $0.state != .dropped })
            #expect(after.tables.map(\.fingerprint) == full.tables.map(\.fingerprint))
            #expect(Set(full.relationships.map(\.id)).isSubset(of: Set(after.relationships.map(\.id))), "relationships it cannot see stay")
            #expect(report.tables.dropped == 0 && report.relationships.removed == 0)
        } catch {
            _ = try? await admin.execute("DROP USER '\(reader)'@'%'")
            throw error
        }
        _ = try? await admin.execute("DROP USER '\(reader)'@'%'")
    }

    @Test(arguments: IntegrationEnvironment.targets)
    func refreshInfersAndAnswers(target: IntegrationEnvironment.Target) async throws {
        let client = try await IntegrationEnvironment.client(target)
        let store = KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-it-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://it:\(target.label)"), catalog: SQLText.defaultCatalog, database: "kb_demo")
        let history = [QueryHistoryEntry(sql: "SELECT a.name, SUM(r.dsp_fill) FROM report_adx_hour r JOIN app a ON r.app_id = a.id GROUP BY a.name",
                                         database: "kb_demo", durationMilliseconds: 12)]
        let report = try await KnowledgeService.refresh(key, source: client, store: store, history: history,
                                                        infer: KnowledgeInference.machineRelationships, now: Date())
        #expect(report.tables.total == 5)
        let knowledge = try #require(try store.database(key))

        let hourly = try #require(knowledge.table(named: "report_adx_hour"))
        #expect(hourly.model == "AGG")
        #expect(hourly.keys.partition == ["dt"])
        #expect(hourly.column(named: "dsp_id")?.comment == "DSP, 0 = house ads")
        // information_schema.columns does not say a value column's aggregation (EXTRA is empty on 3.3 and 4.1); the AGG
        // model hint covers it without one DESC per table.
        #expect(hourly.column(named: "dt")?.isKey == true)
        #expect(knowledge.table(named: "v_dsp_report")?.lineage.map(\.table) == ["dsp", "report_adx_hour"])

        func relationship(_ from: String, _ fromColumn: String, _ to: String, _ toColumn: String) -> Relationship? {
            knowledge.relationships.first { (candidate: Relationship) -> Bool in
                let forward = candidate.from.table == from && candidate.from.columns == [fromColumn] && candidate.to.table == to && candidate.to.columns == [toColumn]
                let backward = candidate.to.table == from && candidate.to.columns == [fromColumn] && candidate.from.table == to && candidate.from.columns == [toColumn]
                return forward || backward
            }
        }
        let declared = try #require(relationship("report_adx_hour", "app_id", "app", "id"))
        #expect(Set(declared.evidence.map(\.source)).isSuperset(of: [.declared, .history]), "\(declared.evidence.map(\.source))")
        let toDSP = try #require(relationship("report_adx_hour", "dsp_id", "dsp", "id"))
        #expect(Set(toDSP.evidence.map(\.source)).isSuperset(of: [.naming, .definition]), "\(toDSP.evidence.map(\.source))")
        #expect(relationship("app", "publisher_id", "publisher", "id") != nil)

        let path = JoinPathFinder.find(from: "report_adx_hour", to: "publisher", in: knowledge, confidence: { RelationshipConfidence.score($0) })
        #expect(path.paths.first?.steps.map(\.join) == ["app", "publisher"])
        let diagram = try MermaidERDRenderer.render(tables: ["report_adx_hour", "dsp", "app", "publisher"], in: knowledge,
                                                    confidence: { RelationshipConfidence.score($0) }, title: "ADX")
        #expect(diagram.mermaid.contains("report_adx_hour }o--|| dsp"))
        #expect(diagram.mermaid.contains("report_adx_hour }o--|| app"))
        #expect(try await KnowledgeMCP.liveVisibility(client, "kb_demo")?.contains("report_adx_hour") == true)
        #expect(try await KnowledgeMCP.liveVisibility(client, "no_such_db") == nil)
        await client.close()
    }
}
