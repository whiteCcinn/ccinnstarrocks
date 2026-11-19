import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private func temporaryStore() -> KnowledgeStore {
    KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-\(UUID().uuidString)", isDirectory: true))
}

private let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe.prod:9030"), catalog: "default_catalog", database: "adx")

@Suite("Knowledge identity")
struct KnowledgeIdentityTests {
    @Test func clusterKeysComeFromTheEndpoint() {
        #expect(ClusterKey(profile: ConnectionProfile(name: "a", host: " FE.Prod.example. ", port: 9030)).rawValue == "sr://fe.prod.example:9030")
        #expect(ClusterKey(profile: ConnectionProfile(name: "b", host: "fe.prod.example", port: 9030, username: "other")).rawValue
                == "sr://fe.prod.example:9030", "names and users do not matter")
        #expect(ClusterKey(profile: ConnectionProfile(host: "fe80::1", port: 9030)).rawValue == "sr://[fe80::1]:9030")
        var tunnelled = ConnectionProfile(host: "10.0.0.5", port: 9030)
        tunnelled.ssh = SSHTunnelConfiguration(host: "Bastion.Example", port: 22, username: "ops", authentication: .agent)
        #expect(ClusterKey(profile: tunnelled).rawValue == "sr+ssh://bastion.example:22/10.0.0.5:9030", "private addresses repeat across bastions")
    }

    @Test func databaseFileIDsAreStableAndDistinct() {
        #expect(key.fileID == DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe.prod:9030"), catalog: "default_catalog", database: "adx").fileID)
        #expect(key.fileID.count == 21 && key.fileID.hasPrefix("d"))
        #expect(key.fileID != DatabaseKey(cluster: key.cluster, catalog: "default_catalog", database: "ADX").fileID, "database names keep their case")
    }

    @Test func columnsAreStoredCompactly() throws {
        let column = ColumnFacts(name: "dsp_request", type: "bigint", isKey: false, isNullable: true, aggregation: "SUM", comment: "requests")
        let json = String(decoding: try JSONEncoder().encode(column), as: UTF8.self)
        #expect(json == #"["dsp_request","bigint","N,A:SUM","requests"]"#)
        #expect(try JSONDecoder().decode(ColumnFacts.self, from: Data(json.utf8)) == column)
    }

    @Test func relationshipIDsIgnoreCaseAndSource() {
        let lower = Relationship.id(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]))
        let upper = Relationship.id(from: .init(table: "REPORT_ADX_HOUR", columns: ["DSP_ID"]), to: .init(table: "Dsp", columns: ["ID"]))
        #expect(lower == upper)
        #expect(lower != Relationship.id(from: .init(table: "dsp", columns: ["id"]), to: .init(table: "report_adx_hour", columns: ["dsp_id"])))
    }
}

@Suite("Knowledge store", .serialized)
struct KnowledgeStoreTests {
    @Test func emptyUntilWritten() throws {
        let store = temporaryStore()
        #expect(try store.index().databases.isEmpty)
        #expect(try store.database(key) == nil)
    }

    @Test func updatesArePrivateRevisionedAndIndexed() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.updateDatabase(key) { $0.serverVersion = "3.3.22" }
        try store.updateDatabase(key) { $0.refreshedAt = Date(timeIntervalSince1970: 1_800_000_000) }
        let knowledge = try #require(try store.database(key))
        #expect(knowledge.revision == 2)
        #expect(knowledge.serverVersion == "3.3.22")
        let index = try store.index()
        #expect(index.databases.map(\.key) == [key])
        #expect(index.clusters.map(\.key) == [key.cluster])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.databaseURL(key).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    // The app and the `mcp` process write through separate stores; the lock keeps every update.
    @Test func concurrentWritersFromTwoStoresLoseNothing() throws {
        let first = temporaryStore()
        let second = KnowledgeStore(directory: first.directory)
        defer { try? FileManager.default.removeItem(at: first.directory) }
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            let store = index.isMultiple(of: 2) ? first : second
            try? store.updateDatabase(key) { knowledge in
                knowledge.notes.append(Note(id: "n\(index)", table: "t", column: nil, kind: .description, text: "\(index)", evidence: [],
                                            by: "user", at: Date(), fingerprint: nil))
            }
        }
        let knowledge = try #require(try first.database(key))
        #expect(knowledge.notes.count == 30)
        #expect(knowledge.revision == 30)
    }

    @Test func aNewerFormatIsReadButNeverRewritten() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.updateDatabase(key) { $0.serverVersion = "3.3" }
        var json = try String(contentsOf: store.databaseURL(key), encoding: .utf8)
        json = json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2, \"futureField\" : [1, 2]")
        try SecureFile.write(Data(json.utf8), to: store.databaseURL(key))
        #expect(try store.database(key)?.serverVersion == "3.3", "readable: unknown fields are ignored")
        #expect(throws: KnowledgeStore.Failure.newerFormat(key.fileID + ".json")) {
            try store.updateDatabase(key) { $0.serverVersion = "4.1" }
        }
        #expect(try String(contentsOf: store.databaseURL(key), encoding: .utf8).contains("futureField"), "left untouched")

        json = json.replacingOccurrences(of: "\"minReaderVersion\" : 1", with: "\"minReaderVersion\" : 2")
        try SecureFile.write(Data(json.utf8), to: store.databaseURL(key))
        #expect(throws: KnowledgeStore.Failure.newerFormat(key.fileID + ".json")) { try store.database(key) }
    }

    @Test func aFileNamedForAnotherDatabaseIsRefused() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let other = DatabaseKey(cluster: key.cluster, catalog: "default_catalog", database: "other")
        try store.updateDatabase(other) { $0.serverVersion = "x" }
        try SecureFile.write(try Data(contentsOf: store.databaseURL(other)), to: store.databaseURL(key))
        #expect(throws: KnowledgeStore.Failure.wrongFile(key.fileID + ".json")) { try store.database(key) }
    }
}
