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
        #expect(report.snapshotURL != nil)
        #expect(target.profiles.count == 3)
        #expect(try target.knowledge.database(F.databaseKey)?.notes.count == 2)

        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(target.profiles.map(\.id) == [mine.id])
        #expect(target.settings == ["appearance": .string("Light")], "settings the import added are removed again")
        #expect(try target.knowledge.database(F.databaseKey)?.notes.map(\.id) == ["n9"])
        #expect(try target.knowledge.index().projects.isEmpty)
        #expect(try BackupHistoryFiles.read(for: mine.id, in: target.historyDirectory).map(\.sql) == ["SELECT 'mine'"])
    }

    // Restore undoes the import, not the work done since: a connection added afterwards and queries run afterwards stay.
    @Test func restoringKeepsWhatHappenedAfterTheImport() throws {
        let (source, plain, tunnelled) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        target.profiles = [plain]
        try BackupHistoryFiles.write([F.historyEntry("SELECT 'local'", at: 0)], for: plain.id, in: target.historyDirectory)

        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil))), now: F.date(100))
        #expect(report.succeeded, "\(report.failureMessage ?? "")")
        #expect(target.profiles.map(\.id) == [plain.id, tunnelled.id])
        #expect(try BackupHistoryFiles.read(for: plain.id, in: target.historyDirectory).map(\.sql) == ["SELECT 1", "SELECT 'local'"])

        let later = F.profile(name: "later", host: "fe.later")
        target.profiles.append(later)
        var history = try BackupHistoryFiles.read(for: plain.id, in: target.historyDirectory)
        history.insert(F.historyEntry("SELECT 'after'", at: 200), at: 0)
        try BackupHistoryFiles.write(history, for: plain.id, in: target.historyDirectory)

        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(target.profiles.map(\.id) == [plain.id, later.id], "only the profile the import added is removed")
        #expect(try BackupHistoryFiles.read(for: plain.id, in: target.historyDirectory).map(\.sql) == ["SELECT 'after'", "SELECT 'local'"],
                "only the entries the import added are removed")
    }

    @Test func restoringPutsBackAReplacedProfileAndDropsTheHistoryOfARemovedOne() throws {
        let (source, plain, tunnelled) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        var older = plain
        older.name = "prod (old name)"
        older.updatedAt = F.date(0)
        target.profiles = [older]
        try BackupHistoryFiles.write([F.historyEntry("SELECT 2", at: 3)], for: tunnelled.id, in: source.historyDirectory)

        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil))), now: F.date(100))
        #expect(target.profiles.first?.name == "prod", "the newer imported profile replaced the local one")
        #expect(try BackupHistoryFiles.read(for: tunnelled.id, in: target.historyDirectory).count == 1)

        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(target.profiles.map(\.name) == ["prod (old name)"])
        #expect(target.profiles.first?.updatedAt == F.date(0))
        #expect(!FileManager.default.fileExists(atPath: BackupHistoryFiles.fileURL(for: tunnelled.id, in: target.historyDirectory).path),
                "a profile that is gone again keeps no history")
    }

    // Review: a password the import filled in for an unchanged profile is the import's doing, and goes on restore.
    @Test func restoringRemovesPasswordsTheImportFilledInAndCanRunAgain() throws {
        let (source, plain, tunnelled) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        target.profiles = [plain]
        let plan = target.plan(try BackupFormat.decode(try exportAll(source), passphrase: F.passphrase))
        #expect(plan.profiles.first { $0.id == plain.id }?.status == .unchanged)
        let report = target.applier().apply(plan, now: F.date(100))
        #expect(try target.secrets.secret(for: SecretKey(profileID: plain.id, kind: .password)) == F.password, "filled in")

        for _ in 0..<2 {
            let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
            #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
            #expect(target.profiles.map(\.id) == [plain.id])
            #expect(try target.secrets.secret(for: SecretKey(profileID: plain.id, kind: .password)) == nil)
            #expect(try target.secrets.secret(for: SecretKey(profileID: tunnelled.id, kind: .sshSecret)) == nil)
        }
    }

    @Test func aRestoreAfterAFailedSecretsStepRemovesWhatWasWritten() throws {
        let (source, plain, _) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        let flaky = FlakySecretStore(base: target.secrets, failingWrite: 2)
        let report = target.applier(secretStore: flaky).apply(target.plan(try BackupFormat.decode(try exportAll(source), passphrase: F.passphrase)),
                                                              now: F.date(100))
        #expect(report.failedStep == .secrets)
        #expect(try target.secrets.secret(for: SecretKey(profileID: plain.id, kind: .password)) == F.password, "the first write landed")
        let restored = target.applier(secretStore: flaky).restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(try target.secrets.secret(for: SecretKey(profileID: plain.id, kind: .password)) == nil)
        #expect(target.profiles.isEmpty)
    }

    // Review: after a restore puts a profile back on its earlier server, the password stored for the imported server
    // must not follow it there.
    @Test func aProfileBackOnItsEarlierRouteLosesTheImportedPassword() throws {
        let id = UUID()
        let source = BackupTestMac(home: F.oldHome)
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        source.profiles = [F.profile(id: id, name: "prod", host: "fe.new", updatedAt: F.date(50))]
        try source.secrets.setSecret("new-password", for: SecretKey(profileID: id, kind: .password))
        target.profiles = [F.profile(id: id, name: "prod", host: "fe.prod", updatedAt: F.date(1))]
        try target.secrets.setSecret("old-password", for: SecretKey(profileID: id, kind: .password))

        let plan = target.plan(try BackupFormat.decode(try exportAll(source), passphrase: F.passphrase))
        #expect(plan.profiles.first?.resolution == .useImported)
        let report = target.applier().apply(plan, now: F.date(100))
        #expect(target.profiles.first?.host == "fe.new")
        #expect(try target.secrets.secret(for: SecretKey(profileID: id, kind: .password)) == "new-password")

        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(target.profiles.first?.host == "fe.prod")
        #expect(try target.secrets.secret(for: SecretKey(profileID: id, kind: .password)) == nil)
        #expect(restored.warnings.contains(.passwordRemoved("prod")))
    }

    @Test func aPasswordReplacedOnTheSameRouteStaysAndIsReported() throws {
        let id = UUID()
        let source = BackupTestMac(home: F.oldHome)
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        source.profiles = [F.profile(id: id, name: "prod", host: "fe.prod", port: 9030, updatedAt: F.date(50))]
        source.profiles[0].defaultDatabase = "adx"
        try source.secrets.setSecret("rotated", for: SecretKey(profileID: id, kind: .password))
        target.profiles = [F.profile(id: id, name: "prod", host: "fe.prod", updatedAt: F.date(1))]
        try target.secrets.setSecret("old-password", for: SecretKey(profileID: id, kind: .password))

        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source), passphrase: F.passphrase)), now: F.date(100))
        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded)
        #expect(target.profiles.first?.defaultDatabase == nil)
        #expect(try target.secrets.secret(for: SecretKey(profileID: id, kind: .password)) == "rotated")
        #expect(restored.warnings.contains(.passwordNotRestored("prod")))
    }

    @Test func aProfileEditedAfterTheImportIsLeftAlone() throws {
        let (source, plain, tunnelled) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        var older = plain
        older.name = "prod (old name)"
        older.updatedAt = F.date(0)
        target.profiles = [older]
        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil))), now: F.date(100))
        #expect(target.profiles.map(\.name) == ["prod", "tunnel"])
        target.profiles[0].port = 9031
        target.profiles[0].updatedAt = F.date(500)
        target.profiles[1].name = "tunnel (mine now)"
        target.profiles[1].updatedAt = F.date(500)

        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(target.profiles.map(\.id) == [plain.id, tunnelled.id])
        #expect(target.profiles.map(\.port) == [9031, tunnelled.port])
        #expect(restored.warnings.contains(.changedSinceImport("prod")) && restored.warnings.contains(.changedSinceImport("tunnel (mine now)")))
    }

    // Review: restore brings back only the entries the import's cap pushed out, never ones deleted since.
    @Test func historyComesBackOnlyWhereTheCapPushedItOut() throws {
        let (source, plain, _) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        target.profiles = [plain]
        let local = (0..<1_000).map { (index: Int) -> QueryHistoryEntry in F.historyEntry("SELECT \(index - 1_000)", at: Double(index - 1_000)) }
        try BackupHistoryFiles.write(local.reversed(), for: plain.id, in: target.historyDirectory)

        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil))), now: F.date(100))
        var history = try BackupHistoryFiles.read(for: plain.id, in: target.historyDirectory)
        #expect(history.count == 1_000 && history.first?.sql == "SELECT 1" && history.last?.sql == "SELECT -999")
        history.removeAll { $0.sql == "SELECT -1" }
        try BackupHistoryFiles.write(history, for: plain.id, in: target.historyDirectory)

        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        let after = try BackupHistoryFiles.read(for: plain.id, in: target.historyDirectory)
        #expect(after.count == 999)
        #expect(after.first?.sql == "SELECT -2" && after.last?.sql == "SELECT -1000", "the pushed-out entry is back, the deleted one is not")

        try BackupHistoryFiles.remove(for: plain.id, in: target.historyDirectory)
        _ = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(try BackupHistoryFiles.read(for: plain.id, in: target.historyDirectory).map(\.sql) == ["SELECT -1000"],
                "a history cleared after the import only gets back what the import pushed out")
    }

    @Test func restoringLeavesKnowledgeTheSnapshotNeverCapturedAndRemovesWhatTheImportCreated() throws {
        let (source, _, _) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        // A database file the index does not list: the export skips it, so the snapshot does not hold it.
        let unlisted = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe.other:9030"), catalog: "default_catalog", database: "ssp")
        var orphan = DatabaseKnowledge(key: unlisted)
        orphan.notes = [F.note("n7", text: "kept", at: 1)]
        try SecureFile.write(try KnowledgeStore.encoder.encode(orphan), to: target.knowledge.databaseURL(unlisted))

        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil))), now: F.date(100))
        #expect(try target.knowledge.database(F.databaseKey) != nil)
        let restored = target.applier().restore(report, restoreProfiles: target.restoreProfiles)
        #expect(restored.succeeded, "\(restored.failureMessage ?? "")")
        #expect(try target.knowledge.database(F.databaseKey) == nil, "the database the import created is gone")
        #expect(try target.knowledge.database(unlisted)?.notes.map(\.id) == ["n7"], "a file the snapshot never held is untouched")
        #expect(target.profiles.isEmpty && target.settings.isEmpty)
    }

    @Test func restoringNeverOverflowsARevision() throws {
        let target = BackupTestMac(home: F.newHome)
        defer { target.remove() }
        var index = KnowledgeIndex()
        index.revision = Int.max
        let data = try BackupFormat.encode(BackupPayload(profiles: [], knowledge: BackupKnowledge(index: index, databases: [])),
                                           appVersion: "1.4.0", createdAt: F.referenceDate)
        let url = target.snapshotDirectory.appendingPathComponent("pre-import-hostile.ccinnstarrocks-backup")
        try SecureFile.write(data, to: url)
        var importReport = BackupImportReport()
        importReport.snapshotURL = url
        importReport.changedKnowledgeIndex = true
        let restored = target.applier().restore(importReport) { (restore: BackupProfileRestore) throws -> BackupProfileRestore.Outcome in restore.apply(to: []) }
        #expect(restored.succeeded)
        #expect(try target.knowledge.index().revision == Int.max)
    }

    @Test func aStrayControlCharacterInHistoryStillExportsAndRestores() throws {
        let (source, plain, _) = try sourceMac()
        defer { source.remove() }
        try BackupHistoryFiles.write([F.historyEntry("SELECT 1 \u{1B}[0m\u{0B}", at: 2)], for: plain.id, in: source.historyDirectory)
        let bundle = try BackupFormat.decode(try exportAll(source, passphrase: nil))
        let entries = try #require(bundle.payload.history?.first { $0.profile == plain.id }).entries
        #expect(entries.map(\.sql) == ["SELECT 1 \u{FFFD}[0m\u{FFFD}"])
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

    @Test func upsertsReplaceByIDAndAppendNewOnes() {
        let first = F.profile(name: "a", host: "a.example")
        let second = F.profile(name: "b", host: "b.example")
        var renamed = first
        renamed.name = "a2"
        let added = F.profile(name: "c", host: "c.example")
        let result = BackupImportApplier.upserting([renamed, added], into: [first, second])
        #expect(result.map(\.name) == ["a2", "b", "c"])
    }

    @Test func theImportStampsTheProfilesItSaves() throws {
        let (source, plain, tunnelled) = try sourceMac()
        let target = BackupTestMac(home: F.newHome)
        defer { source.remove(); target.remove() }
        let report = target.applier().apply(target.plan(try BackupFormat.decode(try exportAll(source, passphrase: nil))), now: F.date(100))
        #expect(report.profileStamp == F.date(100))
        #expect(target.profiles.map(\.id) == [plain.id, tunnelled.id])
        let stamps: [Date?] = target.profiles.map(\.updatedAt)
        #expect(stamps == [F.date(100), F.date(100)])
    }
}
