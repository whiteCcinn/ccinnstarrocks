import CryptoKit
import Foundation
import StarRocksKit
@testable import CcinnStarRocksKit

/// Shared values and builders for the backup tests.
enum BackupFixtures {
    static let password = "Hunter2-Very-Secret-Pa55word"
    static let sshSecret = "ssh-key-passphrase-7777"
    static let passphrase = "correct horse battery staple"
    /// Fast key derivation for tests; one test uses the real count.
    static let testIterations = 10_000
    static let oldHome = "/Users/old"
    static let newHome = "/Users/new"
    static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    static func date(_ offset: TimeInterval) -> Date {
        referenceDate.addingTimeInterval(offset)
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-backup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func profile(id: UUID = UUID(), name: String, host: String, port: Int = 9030, username: String = "analyst",
                        updatedAt: Date? = nil) -> ConnectionProfile {
        var profile = ConnectionProfile(id: id, name: name, host: host, port: port, username: username, createdAt: referenceDate)
        profile.updatedAt = updatedAt
        return profile
    }

    static func tunnelledProfile(name: String, keyPath: String) -> ConnectionProfile {
        var profile = profile(name: name, host: "10.0.0.5")
        profile.ssh = SSHTunnelConfiguration(host: "bastion.example", port: 22, username: "ops", authentication: .privateKey, privateKeyPath: keyPath)
        return profile
    }

    static let databaseKey = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe.prod:9030"), catalog: "default_catalog", database: "adx")

    static func note(_ id: String, text: String, at offset: TimeInterval) -> Note {
        Note(id: id, table: "report", column: nil, kind: .description, text: text, evidence: [], by: "user", at: date(offset), fingerprint: nil)
    }

    static func table(_ name: String, fingerprint: String = "fp1") -> TableFacts {
        TableFacts(name: name, kind: .table, columns: [ColumnFacts(name: "id", type: "bigint", isKey: true, isNullable: false, comment: "row id")],
                   fingerprint: fingerprint, state: .fresh, firstSeen: referenceDate)
    }

    static func knowledge(notes: [Note] = [], tables: [TableFacts] = [], refreshedAt: Date? = nil) -> DatabaseKnowledge {
        var knowledge = DatabaseKnowledge(key: databaseKey)
        knowledge.notes = notes
        knowledge.tables = tables
        knowledge.refreshedAt = refreshedAt
        return knowledge
    }

    static func project(_ id: String, path: String, remote: String? = nil) -> KnowledgeIndex.Project {
        KnowledgeIndex.Project(id: id, path: path, name: (path as NSString).lastPathComponent, gitRemote: remote, addedAt: referenceDate,
                               addedBy: "user")
    }

    static func index(projects: [KnowledgeIndex.Project] = [], linkedTo database: DatabaseKey? = databaseKey) -> KnowledgeIndex {
        var index = KnowledgeIndex()
        if let database {
            index.databases = [KnowledgeIndex.DatabaseEntry(key: database)]
            index.clusters = [KnowledgeIndex.ClusterEntry(key: database.cluster)]
            index.links = projects.map { (project: KnowledgeIndex.Project) -> KnowledgeIndex.Link in
                KnowledgeIndex.Link(project: project.id, database: database.fileID, addedAt: referenceDate, addedBy: "user")
            }
        }
        index.projects = projects
        return index
    }

    static func historyEntry(_ sql: String, at offset: TimeInterval, id: UUID = UUID()) -> QueryHistoryEntry {
        QueryHistoryEntry(id: id, sql: sql, database: "adx", executedAt: date(offset), durationMilliseconds: 12)
    }

    /// A bundle as the reader would return it.
    static func bundle(_ payload: BackupPayload, secrets: [UUID: BackupProfileSecrets] = [:], authenticated: Bool = false) -> BackupBundle {
        let header = BackupHeader(createdAt: referenceDate, appVersion: "1.4.0", sections: payload.sections.map(\.rawValue), payloadBytes: 0,
                                  payloadSHA256: String(repeating: "0", count: 64), secrets: nil)
        return BackupBundle(header: header, payload: payload, secrets: secrets, isAuthenticated: authenticated, warnings: [])
    }

    static func localState(profiles: [ConnectionProfile] = [], index: KnowledgeIndex = KnowledgeIndex(), databases: [DatabaseKnowledge] = [],
                           settings: [String: BackupSettingValue] = [:], history: [UUID: [QueryHistoryEntry]] = [:],
                           secrets: [UUID: BackupProfileSecrets] = [:]) -> BackupLocalState {
        var byKey: [DatabaseKey: DatabaseKnowledge] = [:]
        for database in databases { byKey[database.key] = database }
        return BackupLocalState(profiles: profiles, knowledgeIndex: index, knowledgeDatabases: byKey, settings: settings, history: history,
                                secrets: secrets)
    }

    static func plan(_ bundle: BackupBundle, local: BackupLocalState, home: String = newHome, existing: Set<String> = []) -> BackupImportPlan {
        BackupImportPlanner.plan(bundle, local: local, home: home, fileExists: { (path: String) -> Bool in existing.contains(path) })
    }

    // MARK: Hand-made files

    /// A file around `payloadJSON` with a correct length and hash, as a newer or hostile writer could make it.
    static func file(payloadJSON: String, formatVersion: Int = 1, sections: [String] = ["profiles"]) -> Data {
        let payload = Data(payloadJSON.utf8)
        var header: [String: Any] = [:]
        header["format"] = "ccinnstarrocks-backup"
        header["format_version"] = formatVersion
        header["created_at"] = "2026-11-19T00:00:00Z"
        header["app_version"] = "1.4.0"
        header["sections"] = sections
        header["payload_bytes"] = payload.count
        header["payload_sha256"] = sha256Hex(payload)
        let headerData = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data()
        return headerData + Data("\n".utf8) + payload + Data("\n".utf8)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The two lines of a file (the trailing newline dropped).
    static func lines(_ data: Data) -> (header: Data, payload: Data)? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        var payload = Data(data[data.index(after: newline)...])
        if payload.last == 0x0A { payload.removeLast() }
        return (Data(data[data.startIndex..<newline]), payload)
    }

    /// Replaces the payload and rewrites the header's length and hash, as an attacker who edits the file would.
    static func replacingPayload(of data: Data, _ change: (String) -> String) throws -> Data {
        let parts = try requireLines(data)
        let payload = Data(change(String(decoding: parts.payload, as: UTF8.self)).utf8)
        var header = try JSONSerialization.jsonObject(with: parts.header) as? [String: Any] ?? [:]
        header["payload_bytes"] = payload.count
        header["payload_sha256"] = sha256Hex(payload)
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        return headerData + Data("\n".utf8) + payload + Data("\n".utf8)
    }

    /// Rewrites the header's JSON object.
    static func replacingHeader(of data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        let parts = try requireLines(data)
        var header = try JSONSerialization.jsonObject(with: parts.header) as? [String: Any] ?? [:]
        change(&header)
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        return headerData + Data("\n".utf8) + parts.payload + Data("\n".utf8)
    }

    static func requireLines(_ data: Data) throws -> (header: Data, payload: Data) {
        guard let parts = lines(data) else { throw CocoaError(.fileReadCorruptFile) }
        return parts
    }
}

extension Data {
    func contains(_ text: String) -> Bool {
        range(of: Data(text.utf8)) != nil
    }
}

/// A secret store that fails every write, to test partial imports.
final class FailingSecretStore: SecretStore {
    func secret(for key: SecretKey) throws -> String? { nil }

    func setSecret(_ value: String?, for key: SecretKey) throws {
        throw SecretStoreError(message: "Keychain write failed (-25308)")
    }
}

/// One Mac's stores under a temporary data directory, with the closures the app would give the applier.
final class BackupTestMac {
    let directory = BackupFixtures.temporaryDirectory()
    let home: String
    let secrets = InMemorySecretStore()
    var profiles: [ConnectionProfile] = []
    var settings: [String: BackupSettingValue] = [:]
    var failProfiles = false

    init(home: String) {
        self.home = home
    }

    var knowledge: KnowledgeStore { KnowledgeStore(directory: directory.appendingPathComponent("Knowledge", isDirectory: true)) }
    var historyDirectory: URL { directory.appendingPathComponent("History", isDirectory: true) }
    var snapshotDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    func exporter() -> BackupExporter {
        BackupExporter(profiles: profiles, secretStore: secrets, knowledge: knowledge, historyDirectory: historyDirectory, settings: settings,
                       home: home)
    }

    func applier(secretStore: (any SecretStore)? = nil) -> BackupImportApplier {
        BackupImportApplier(
            snapshotDirectory: snapshotDirectory,
            makeSnapshot: { [unowned self] () throws -> Data in
                try self.exporter().export(.preImportSnapshot, appVersion: "1.4.0", now: BackupFixtures.referenceDate).data
            },
            knowledge: knowledge, historyDirectory: historyDirectory, secretStore: secretStore ?? secrets,
            applyProfiles: { [unowned self] (upserts: [ConnectionProfile]) throws -> Void in
                if self.failProfiles { throw CocoaError(.fileWriteNoPermission) }
                self.profiles = BackupImportApplier.upserting(upserts, into: self.profiles, updatedAt: BackupFixtures.referenceDate)
            },
            writeSetting: { [unowned self] (key: String, value: BackupSettingValue?) throws -> Void in
                self.settings[key] = value
            })
    }

    func restoreProfiles(_ restored: [ConnectionProfile], removing removed: [UUID]) throws {
        profiles = BackupImportApplier.restoring(restored, removing: removed, in: profiles)
    }

    func localState(for bundle: BackupBundle) -> BackupLocalState {
        BackupLocalState.load(for: bundle, profiles: profiles, knowledge: knowledge, historyDirectory: historyDirectory, settings: settings,
                              secretStore: secrets)
    }

    func plan(_ bundle: BackupBundle, existing: Set<String> = []) -> BackupImportPlan {
        BackupImportPlanner.plan(bundle, local: localState(for: bundle), home: home,
                                 fileExists: { (path: String) -> Bool in existing.contains(path) })
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
