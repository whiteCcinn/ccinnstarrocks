import CcinnStarRocksKit
import Foundation
import Testing
@testable import CcinnStarRocks

/// One Mac for the backup window: its own data directory, secrets, settings and file choices.
@MainActor
private final class TestMac {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-backup-\(UUID().uuidString)", isDirectory: true)
    let secrets = InMemorySecretStore()
    let suite = "ccinn-backup-test-\(UUID().uuidString)"
    let profiles: ProfileStore
    var exportURL: URL?
    var importURL: URL?
    var exportPanelShown = 0
    private(set) var center: BackupCenter!

    init(home: String) {
        profiles = ProfileStore(repository: ProfileRepository(directory: directory, secrets: secrets))
        let stores = BackupCenter.Stores(profiles: profiles, secretStore: secrets,
                                         knowledge: KnowledgeStore(directory: directory.appendingPathComponent("Knowledge", isDirectory: true)),
                                         historyDirectory: directory.appendingPathComponent("History", isDirectory: true),
                                         snapshotDirectory: directory.appendingPathComponent("Backups", isDirectory: true), defaultsSuite: suite, home: home)
        center = BackupCenter(stores: stores, panels: BackupCenter.Panels(
            chooseExportURL: { [unowned self] _ in exportPanelShown += 1; return exportURL },
            chooseImportURL: { [unowned self] in importURL },
            chooseDirectory: { _ in nil }))
    }

    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

private let passphrase = "correct horse battery staple"
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "sr://fe.prod:9030"), catalog: "default_catalog", database: "adx")

@Suite("Backup window", .serialized)
@MainActor
struct BackupCenterTests {
    @Test func theExportFormNeedsTheSamePassphraseTwice() async {
        let mac = TestMac(home: "/Users/old")
        defer { mac.remove() }
        mac.center.beginExport()
        mac.center.includePasswords = true
        mac.center.passphrase = "short"
        mac.center.passphraseConfirmation = "short"
        #expect(mac.center.exportProblem?.contains("12") == true)
        mac.center.passphrase = passphrase
        mac.center.passphraseConfirmation = passphrase + "!"
        #expect(mac.center.exportProblem == "The two passphrases differ.")
        await mac.center.export()
        #expect(mac.exportPanelShown == 0 && mac.center.stage == .exportForm, "nothing is asked or written while the form is invalid")
        mac.center.includePasswords = false
        #expect(mac.center.exportProblem == nil)
    }

    // Everything the user set up on one Mac arrives on another, the passphrase is checked, and Restore takes it back.
    @Test func aBackupMovesToAnotherMacAndCanBeTakenBack() async throws {
        let old = TestMac(home: "/Users/old")
        let new = TestMac(home: "/Users/new")
        defer { old.remove(); new.remove() }
        let profile = try old.profiles.save(ConnectionProfile(name: "prod", host: "fe.prod", port: 9030, username: "analyst"), password: "s3cret",
                                            sshSecret: nil)
        old.defaults.set(5000, forKey: "autoLimit")
        try old.center.stores.knowledge.updateDatabase(key) { (knowledge: inout DatabaseKnowledge) -> Void in
            knowledge.notes = [Note(id: "n1", table: "report_adx_hour", column: nil, kind: .description, text: "revenue in USD", evidence: [],
                                    by: "user", at: Date(timeIntervalSince1970: 1_800_000_000), fingerprint: nil)]
        }
        let file = old.directory.appendingPathComponent("move.\(BackupFormat.fileExtension)")
        old.exportURL = file

        old.center.beginExport()
        old.center.includePasswords = true
        old.center.passphrase = passphrase
        old.center.passphraseConfirmation = passphrase
        await old.center.export()
        #expect(old.center.stage == .exported)
        #expect(old.center.exportResult?.secretCount == 1)
        #expect(old.center.passphrase.isEmpty && old.center.passphraseConfirmation.isEmpty, "the passphrase is not kept")
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(!written.contains("s3cret") && !written.contains(passphrase))

        new.importURL = file
        await new.center.beginImport()
        #expect(new.center.stage == .passphrase)
        new.center.importPassphrase = "not the passphrase"
        await new.center.unlock()
        #expect(new.center.stage == .passphrase)
        #expect(new.center.passphraseMessage == BackupError.wrongPassphrase.localizedDescription)
        new.center.importPassphrase = passphrase
        await new.center.unlock()
        #expect(new.center.stage == .preview)
        let plan = try #require(new.center.plan)
        #expect(plan.isAuthenticated)
        #expect(plan.profiles.map(\.status) == [.new])
        #expect(plan.knowledge?.databases.map(\.status) == [.new])

        await new.center.performImport()
        #expect(new.center.stage == .report)
        let report = try #require(new.center.report)
        #expect(report.succeeded, "\(report.failureMessage ?? "")")
        #expect(report.needsMCPRestart)
        #expect(new.profiles.profiles.map(\.id) == [profile.id])
        #expect(try new.secrets.secret(for: SecretKey(profileID: profile.id, kind: .password)) == "s3cret")
        #expect(new.defaults.integer(forKey: "autoLimit") == 5000)
        #expect(try new.center.stores.knowledge.database(key)?.notes.map(\.text) == ["revenue in USD"])
        #expect(new.center.plan == nil, "decrypted secrets are not kept after the import")

        #expect(new.center.canRestore)
        await new.center.restoreSnapshot()
        #expect(new.center.report?.succeeded == true, "\(new.center.report?.failureMessage ?? "")")
        #expect(new.profiles.profiles.isEmpty)
        #expect(try new.secrets.secret(for: SecretKey(profileID: profile.id, kind: .password)) == nil, "the added profile's password goes too")
        #expect(new.defaults.object(forKey: "autoLimit") == nil)
        #expect(try new.center.stores.knowledge.database(key) == nil)
        #expect(!new.center.canRestore, "a restore is not restored")
    }

    @Test func skippingThePassphraseImportsEverythingButPasswords() async throws {
        let old = TestMac(home: "/Users/old")
        let new = TestMac(home: "/Users/new")
        defer { old.remove(); new.remove() }
        let profile = try old.profiles.save(ConnectionProfile(name: "prod", host: "fe.prod"), password: "s3cret", sshSecret: nil)
        old.exportURL = old.directory.appendingPathComponent("move.\(BackupFormat.fileExtension)")
        old.center.beginExport()
        old.center.includePasswords = true
        old.center.passphrase = passphrase
        old.center.passphraseConfirmation = passphrase
        await old.center.export()

        await new.center.open(try #require(old.exportURL))
        #expect(new.center.stage == .passphrase)
        await new.center.continueWithoutPasswords()
        let plan = try #require(new.center.plan)
        #expect(!plan.isAuthenticated)
        await new.center.performImport()
        #expect(new.profiles.profiles.map(\.id) == [profile.id])
        #expect(try new.secrets.secret(for: SecretKey(profileID: profile.id, kind: .password)) == nil)
    }

    @Test func importingTheSameBackupTwiceChangesNothing() async throws {
        let mac = TestMac(home: "/Users/me")
        defer { mac.remove() }
        try mac.profiles.save(ConnectionProfile(name: "prod", host: "fe.prod"), password: nil, sshSecret: nil)
        mac.exportURL = mac.directory.appendingPathComponent("self.\(BackupFormat.fileExtension)")
        mac.center.beginExport()
        await mac.center.export()
        await mac.center.open(try #require(mac.exportURL))
        #expect(mac.center.stage == .preview)
        #expect(mac.center.plan?.isUnchanged == true)
        await mac.center.performImport()
        #expect(mac.center.stage == .preview, "a plan that changes nothing is not applied")
    }

    @Test func aFileThatIsNotABackupSaysSo() async throws {
        let mac = TestMac(home: "/Users/me")
        defer { mac.remove() }
        let file = mac.directory.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: mac.directory, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: file)
        await mac.center.open(file)
        #expect(mac.center.stage == .failed(BackupError.notABackup.localizedDescription))
    }

    @Test func missingProjectsSuggestACommonPrefix() async throws {
        let old = TestMac(home: "/Users/old")
        let new = TestMac(home: "/Users/new")
        defer { old.remove(); new.remove() }
        try old.center.stores.knowledge.updateIndex { (index: inout KnowledgeIndex) -> Void in
            index.projects = [KnowledgeIndex.Project(id: "p1", path: "/Volumes/Work/code/adx", name: "adx", gitRemote: nil, addedAt: Date(), addedBy: "user"),
                              KnowledgeIndex.Project(id: "p2", path: "/Volumes/Work/code/ssp", name: "ssp", gitRemote: nil, addedAt: Date(), addedBy: "user")]
        }
        old.exportURL = old.directory.appendingPathComponent("move.\(BackupFormat.fileExtension)")
        old.center.beginExport()
        await old.center.export()
        await new.center.open(try #require(old.exportURL))
        #expect(new.center.plan?.knowledge?.projects.allSatisfy(\.isMissing) == true)
        #expect(new.center.remapFrom == "/Volumes/Work/code")
        #expect(new.center.remapTo == "~/code")
        new.center.remapCommonPrefix()
        #expect(new.center.plan?.knowledge?.projects.map(\.path) == ["~/code/adx", "~/code/ssp"])
        #expect(new.center.remapMessage == "2 projects moved.")
    }

    // Review: a second flow started while one runs must be refused, not overwrite the first one's state.
    @Test func nothingStartsWhileAnOperationRuns() async throws {
        let mac = TestMac(home: "/Users/me")
        defer { mac.remove() }
        try mac.profiles.save(ConnectionProfile(name: "prod", host: "fe.prod"), password: nil, sshSecret: nil)
        let file = mac.directory.appendingPathComponent("busy.\(BackupFormat.fileExtension)")
        mac.exportURL = file
        mac.center.beginExport()
        let export = Task { await mac.center.export() }
        await Task.yield()
        #expect(mac.center.isBusy)
        await mac.center.open(file)
        mac.center.beginExport()
        mac.center.showHome()
        #expect(mac.center.importURL == nil && mac.center.isBusy, "every entry point is refused while busy")
        await export.value
        #expect(mac.center.stage == .exported)
    }

    // Review: a restore that stopped part-way can be run again once the cause is fixed.
    @Test func aFailedRestoreCanBeRetried() async throws {
        let old = TestMac(home: "/Users/old")
        let new = TestMac(home: "/Users/new")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: new.directory.path)
            old.remove()
            new.remove()
        }
        try old.profiles.save(ConnectionProfile(name: "prod", host: "fe.prod"), password: nil, sshSecret: nil)
        old.exportURL = old.directory.appendingPathComponent("move.\(BackupFormat.fileExtension)")
        old.center.beginExport()
        await old.center.export()
        await new.center.open(try #require(old.exportURL))
        await new.center.performImport()
        #expect(new.profiles.profiles.count == 1)

        // connections.json cannot be replaced while its folder is read-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: new.directory.path)
        await new.center.restoreSnapshot()
        #expect(new.center.report?.failedStep == .profiles)
        #expect(new.center.canRestore, "Restore is offered again")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: new.directory.path)
        await new.center.restoreSnapshot()
        #expect(new.center.report?.succeeded == true, "\(new.center.report?.failureMessage ?? "")")
        #expect(new.profiles.profiles.isEmpty)
        #expect(!new.center.canRestore)
    }

    // Review: closing the window drops a decrypted plan instead of keeping it until the next flow.
    @Test func closingTheWindowForgetsTheDecryptedPlan() async throws {
        let old = TestMac(home: "/Users/old")
        let new = TestMac(home: "/Users/new")
        defer { old.remove(); new.remove() }
        try old.profiles.save(ConnectionProfile(name: "prod", host: "fe.prod"), password: "s3cret", sshSecret: nil)
        old.exportURL = old.directory.appendingPathComponent("move.\(BackupFormat.fileExtension)")
        old.center.beginExport()
        old.center.includePasswords = true
        old.center.passphrase = passphrase
        old.center.passphraseConfirmation = passphrase
        await old.center.export()
        await new.center.open(try #require(old.exportURL))
        new.center.importPassphrase = passphrase
        await new.center.unlock()
        #expect(new.center.plan?.secretWrites.isEmpty == false)
        new.center.windowClosed()
        #expect(new.center.plan == nil && new.center.stage == .home)

        await new.center.open(try #require(old.exportURL))
        new.center.importPassphrase = ""
        await new.center.unlock()
        #expect(new.center.stage == .passphrase && new.center.passphraseMessage == nil, "an empty passphrase is not tried")
        new.center.beginExport()
        #expect(new.center.plan == nil)
    }

    @Test func profileEditsCountAsChangesForBackups() throws {
        let mac = TestMac(home: "/Users/me")
        defer { mac.remove() }
        var profile = try mac.profiles.save(ConnectionProfile(name: "prod", host: "fe.prod"), password: nil, sshSecret: nil)
        profile.updatedAt = Date(timeIntervalSince1970: 0)
        try mac.profiles.apply([profile])
        let before = try #require(mac.profiles.profiles.first?.updatedAt)
        mac.profiles.setMCPAccess(.readOnly, for: profile)
        #expect(try #require(mac.profiles.profiles.first?.updatedAt) > before, "a newer edit wins an import conflict")
    }
}
