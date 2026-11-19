import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private typealias F = BackupFixtures

/// The source Mac of the migration tests: two profiles with secrets, knowledge with a project, history and a setting.
private func sourceMac() throws -> (BackupTestMac, ConnectionProfile, ConnectionProfile) {
    let mac = BackupTestMac(home: F.oldHome)
    let plain = F.profile(name: "prod", host: "fe.prod", updatedAt: F.date(1))
    var tunnelled = F.tunnelledProfile(name: "tunnel", keyPath: "/Users/old/.ssh/id_ed25519")
    tunnelled.updatedAt = F.date(1)
    mac.profiles = [plain, tunnelled]
    mac.settings = ["autoLimit": .int(5000), "appearance": .string("Dark")]
    try mac.secrets.setSecret(F.password, for: SecretKey(profileID: plain.id, kind: .password))
    try mac.secrets.setSecret(F.sshSecret, for: SecretKey(profileID: tunnelled.id, kind: .sshSecret))
    try mac.knowledge.updateDatabase(F.databaseKey) { $0.notes = [F.note("n1", text: "revenue in USD", at: 10)] }
    try mac.knowledge.updateIndex { index in
        index.projects = [F.project("p1", path: "/Users/old/code/adx")]
        index.links = [KnowledgeIndex.Link(project: "p1", database: F.databaseKey.fileID, addedAt: F.referenceDate, addedBy: "user")]
    }
    try BackupHistoryFiles.write([F.historyEntry("SELECT 1", at: 1)], for: plain.id, in: mac.historyDirectory)
    return (mac, plain, tunnelled)
}

private func exportAll(_ mac: BackupTestMac, passphrase: String? = F.passphrase) throws -> Data {
    var options = BackupExportOptions()
    options.includeHistory = true
    options.passphrase = passphrase
    return try mac.exporter().export(options, appVersion: "1.4.0", now: F.referenceDate, iterations: F.testIterations).data
}

private func snapshots(_ mac: BackupTestMac) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: mac.snapshotDirectory.path)) ?? []).sorted()
}

@Suite("Backup import apply", .serialized)
struct BackupImportApplierTests {
    @Test func aNewMacReceivesEverythingAndASecondImportChangesNothing() throws {
        let (source, plain, tunnelled) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }

        let bundle = try BackupFormat.decode(try exportAll(source), passphrase: F.passphrase)
        let plan = target.plan(bundle)
        #expect(plan.profiles.map(\.status) == [.new, .new])
        let report = target.applier().apply(plan, now: F.date(100))
        #expect(report.succeeded, "\(report.failureMessage ?? "")")
        #expect(report.completedSteps == [.snapshot, .knowledge, .history, .secrets, .profiles, .settings])
        #expect(report.needsMCPRestart)

        #expect(target.profiles.map(\.id) == [plain.id, tunnelled.id])
        #expect(target.profiles.last?.ssh?.privateKeyPath == "~/.ssh/id_ed25519")
        #expect(try target.secrets.secret(for: SecretKey(profileID: plain.id, kind: .password)) == F.password)
        #expect(try target.secrets.secret(for: SecretKey(profileID: tunnelled.id, kind: .sshSecret)) == F.sshSecret)
        #expect(try target.knowledge.database(F.databaseKey)?.notes.map(\.text) == ["revenue in USD"])
        let index = try target.knowledge.index()
        #expect(index.projects.map(\.path) == ["~/code/adx"] && index.links.count == 1)
        #expect(try BackupHistoryFiles.read(for: plain.id, in: target.historyDirectory).map(\.sql) == ["SELECT 1"])
        #expect(target.settings == ["autoLimit": .int(5000), "appearance": .string("Dark")])

        let again = target.plan(try BackupFormat.decode(try exportAll(source), passphrase: F.passphrase))
        #expect(again.isUnchanged, "re-importing the same backup changes nothing")
        let roundTrip = target.plan(try BackupFormat.decode(try exportAll(target), passphrase: F.passphrase))
        #expect(roundTrip.isUnchanged, "and the new Mac's own export matches what it holds")
    }

    @Test func anUnchangedPlanWritesNothing() throws {
        let (source, _, _) = try sourceMac()
        defer { source.remove() }
        let plan = source.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil)))
        #expect(plan.isUnchanged)
        let report = source.applier().apply(plan, now: F.date(100))
        #expect(report.succeeded && report.completedSteps.isEmpty && report.snapshotURL == nil)
        #expect(snapshots(source).isEmpty)
    }

    @Test func aPrivateSnapshotComesFirstAndOnlyTheLastFiveAreKept() throws {
        let (source, _, _) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        try target.secrets.setSecret("target-only-secret", for: SecretKey(profileID: UUID(), kind: .password))
        for round in 0..<7 {
            source.profiles.append(F.profile(name: "extra \(round)", host: "fe\(round).example"))
            let plan = target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil)))
            let report = target.applier().apply(plan, now: F.date(Double(round) * 60))
            #expect(report.succeeded)
            let snapshot = try #require(report.snapshotURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(snapshot.lastPathComponent.hasPrefix("pre-import-") && snapshot.pathExtension == "ccinnstarrocks-backup")
        }
        let kept = snapshots(target)
        #expect(kept.count == 5)
        #expect(kept.first == "pre-import-20270115-080200-000.ccinnstarrocks-backup", "the oldest two were removed")
        for name in kept {
            let bytes = try Data(contentsOf: target.snapshotDirectory.appendingPathComponent(name))
            #expect(!bytes.contains("target-only-secret"), "snapshots never hold secrets")
            #expect(!bytes.contains(F.password))
            #expect(try BackupFormat.decode(bytes).header.secrets == nil)
        }
    }

    @Test func aFailingStepStopsTheImportAndSaysWhatWasApplied() throws {
        let (source, _, _) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        let bundle = try BackupFormat.decode(try exportAll(source), passphrase: F.passphrase)

        target.failProfiles = true
        let report = target.applier().apply(target.plan(bundle), now: F.date(100))
        #expect(!report.succeeded)
        #expect(report.completedSteps == [.snapshot, .knowledge, .history, .secrets])
        #expect(report.failedStep == .profiles)
        #expect(report.failureMessage?.isEmpty == false)
        #expect(report.snapshotURL != nil)
        #expect(target.settings.isEmpty, "later steps do not run")

        let keychain = BackupTestMac(home: F.newHome)
        defer { keychain.remove() }
        let locked = keychain.applier(secretStore: FailingSecretStore()).apply(keychain.plan(bundle), now: F.date(100))
        #expect(locked.completedSteps == [.snapshot, .knowledge, .history] && locked.failedStep == .secrets)
        #expect(locked.failureMessage?.contains(F.password) == false)
        #expect(keychain.profiles.isEmpty)
    }

    @Test func restoringTheSnapshotUndoesTheImport() throws {
        let (source, _, _) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        let mine = F.profile(name: "mine", host: "fe.mine")
        target.profiles = [mine]
        target.settings = ["appearance": .string("Light")]
        try target.knowledge.updateDatabase(F.databaseKey) { $0.notes = [F.note("n9", text: "mine", at: 1)] }
        try BackupHistoryFiles.write([F.historyEntry("SELECT 'mine'", at: 1)], for: mine.id, in: target.historyDirectory)

        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil))), now: F.date(100))
        let snapshot = try #require(report.snapshotURL)
        #expect(target.profiles.count == 3)
        #expect(try target.knowledge.database(F.databaseKey)?.notes.count == 2)

        let restored = target.applier().restore(from: snapshot) { (profiles: [ConnectionProfile]) throws -> Void in target.profiles = profiles }
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(target.profiles.map(\.id) == [mine.id])
        #expect(target.settings == ["appearance": .string("Light")], "settings the import added are removed again")
        #expect(try target.knowledge.database(F.databaseKey)?.notes.map(\.id) == ["n9"])
        #expect(try target.knowledge.index().projects.isEmpty)
        #expect(try BackupHistoryFiles.read(for: mine.id, in: target.historyDirectory).map(\.sql) == ["SELECT 'mine'"])
    }

    @Test func historyFilesStayReadableByTheHistoryStore() async throws {
        let directory = F.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let entries = [F.historyEntry("SELECT 2", at: 2), F.historyEntry("SELECT 1", at: 1)]
        try BackupHistoryFiles.write(entries, for: profileID, in: directory)
        let store = QueryHistoryStore(directory: directory, profileID: profileID)
        #expect(await store.all() == entries)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func upsertsReplaceByIDAppendNewOnesAndStampTheSave() {
        let first = F.profile(name: "a", host: "a.example")
        let second = F.profile(name: "b", host: "b.example")
        var renamed = first
        renamed.name = "a2"
        let added = F.profile(name: "c", host: "c.example")
        let result = BackupImportApplier.upserting([renamed, added], into: [first, second], updatedAt: F.date(9))
        #expect(result.map(\.name) == ["a2", "b", "c"])
        let stamps: [Date?] = result.map(\.updatedAt)
        let expected: [Date?] = [F.date(9), nil, F.date(9)]
        #expect(stamps == expected)
    }
}
