import Foundation
import StarRocksKit
import Testing
@testable import CcinnStarRocksKit

private typealias F = BackupFixtures

/// A Mac with two profiles, their secrets, knowledge, history and settings under a temporary data directory.
private struct SourceMac {
    let directory = F.temporaryDirectory()
    let secrets = InMemorySecretStore()
    let plain = F.profile(name: "prod", host: "fe.prod")
    let tunnelled = F.tunnelledProfile(name: "tunnel", keyPath: "/Users/old/.ssh/id_ed25519")

    var knowledge: KnowledgeStore { KnowledgeStore(directory: directory.appendingPathComponent("Knowledge", isDirectory: true)) }
    var historyDirectory: URL { directory.appendingPathComponent("History", isDirectory: true) }

    init() throws {
        try secrets.setSecret(F.password, for: SecretKey(profileID: plain.id, kind: .password))
        try secrets.setSecret(F.sshSecret, for: SecretKey(profileID: tunnelled.id, kind: .sshSecret))
        try knowledge.updateDatabase(F.databaseKey) { $0.notes = [F.note("n1", text: "revenue in USD", at: 10)] }
        try knowledge.updateIndex { index in
            index.projects = [F.project("p1", path: "/Users/old/code/adx", remote: "github.com/org/adx"),
                              F.project("p2", path: "/Volumes/Work/ssp")]
        }
        let entries = [F.historyEntry("CREATE USER bob IDENTIFIED BY 'leaked-pw'", at: 2), F.historyEntry("SELECT 1", at: 1)]
        try BackupHistoryFiles.write(entries, for: plain.id, in: historyDirectory)
    }

    func exporter(settings: [String: BackupSettingValue] = ["appearance": .string("Dark")]) -> BackupExporter {
        BackupExporter(profiles: [plain, tunnelled], secretStore: secrets, knowledge: knowledge, historyDirectory: historyDirectory,
                       settings: settings, home: F.oldHome)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func export(_ exporter: BackupExporter, _ options: BackupExportOptions) throws -> (BackupExport, BackupBundle) {
    let export = try exporter.export(options, appVersion: "1.4.0", now: F.referenceDate, iterations: F.testIterations)
    return (export, try BackupFormat.decode(export.data, passphrase: options.passphrase))
}

@Suite("Backup export", .serialized)
struct BackupExporterTests {
    @Test func defaultsAreProfilesKnowledgeAndSettings() throws {
        let mac = try SourceMac()
        defer { mac.remove() }
        let (export, bundle) = try export(mac.exporter(), BackupExportOptions())
        #expect(bundle.header.sections == ["profiles", "knowledge", "settings"])
        #expect(bundle.payload.profiles.map(\.id) == [mac.plain.id, mac.tunnelled.id])
        #expect(bundle.payload.knowledge?.databases.first?.notes.map(\.id) == ["n1"])
        #expect(bundle.payload.settings == ["appearance": .string("Dark")])
        #expect(bundle.payload.history == nil, "history is off by default")
        #expect(bundle.header.secrets == nil, "secrets need a passphrase")
        #expect(export.secretCount == 0)
        #expect(!export.data.contains(F.password))
        #expect(!export.data.contains(F.sshSecret))
    }

    @Test func pathsUnderHomeBecomeTildeRelative() throws {
        let mac = try SourceMac()
        defer { mac.remove() }
        let (_, bundle) = try export(mac.exporter(), BackupExportOptions())
        let tunnel = try #require(bundle.payload.profiles.first { $0.id == mac.tunnelled.id })
        #expect(tunnel.ssh?.privateKeyPath == "~/.ssh/id_ed25519")
        let paths = bundle.payload.knowledge?.index.projects.map(\.path)
        #expect(paths == ["~/code/adx", "/Volumes/Work/ssp"], "paths outside home stay as they are")
    }

    @Test func secretsAreSealedOnlyWithAPassphrase() throws {
        let mac = try SourceMac()
        defer { mac.remove() }
        var options = BackupExportOptions()
        options.passphrase = F.passphrase
        let (export, bundle) = try export(mac.exporter(), options)
        #expect(export.secretCount == 2)
        #expect(bundle.secrets[mac.plain.id] == BackupProfileSecrets(password: F.password, sshSecret: nil))
        #expect(bundle.secrets[mac.tunnelled.id] == BackupProfileSecrets(password: nil, sshSecret: F.sshSecret))
        #expect(!export.data.contains(F.password))
        #expect(!export.data.contains(F.sshSecret))
        #expect(!export.data.contains(F.passphrase))
    }

    @Test func historyIsIncludedOnRequestAndRedacted() throws {
        let mac = try SourceMac()
        defer { mac.remove() }
        var options = BackupExportOptions()
        options.includeHistory = true
        options.includeKnowledge = false
        options.includeSettings = false
        let (export, bundle) = try export(mac.exporter(), options)
        #expect(bundle.header.sections == ["profiles", "history"])
        let entries = try #require(bundle.payload.history?.first { $0.profile == mac.plain.id }).entries
        #expect(entries.map(\.sql) == ["CREATE USER bob IDENTIFIED BY '***'", "SELECT 1"])
        #expect(!export.data.contains("leaked-pw"))
    }

    @Test func settingsAreReadThroughTheWhitelist() {
        var stored: [String: Any] = [:]
        stored["appearance"] = "Light"
        stored["autoLimit"] = 5000
        stored["sqlFormatKeywordCase"] = "lower"
        stored["sqlFormatIndent"] = 4
        stored["updates.automaticallyCheck"] = false
        stored["settingsTab"] = "general"
        stored["updates.lastCheck"] = Date()
        stored["updates.skippedVersion"] = "9.9.9"
        stored["NSQuitAlwaysKeepsWindows"] = true
        let snapshot = BackupSettings.snapshot { (key: String) -> Any? in stored[key] }
        var expected: [String: BackupSettingValue] = [:]
        expected["appearance"] = .string("Light")
        expected["autoLimit"] = .int(5000)
        expected["sqlFormatKeywordCase"] = .string("lower")
        expected["sqlFormatIndent"] = .int(4)
        expected["updates.automaticallyCheck"] = .bool(false)
        #expect(snapshot == expected)
        var invalid: [String: Any] = [:]
        invalid["appearance"] = "Neon"
        invalid["autoLimit"] = -1
        invalid["sqlFormatIndent"] = "4"
        invalid["updates.automaticallyCheck"] = "yes"
        let rejected = BackupSettings.snapshot { (key: String) -> Any? in invalid[key] }
        #expect(rejected.isEmpty, "values out of range or of the wrong type are left out")
    }

    @Test func writtenFilesArePrivate() throws {
        let mac = try SourceMac()
        defer { mac.remove() }
        var options = BackupExportOptions()
        options.passphrase = F.passphrase
        let url = mac.directory.appendingPathComponent("out/settings.ccinnstarrocks-backup")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let export = try mac.exporter().export(options, appVersion: "1.4.0", now: F.referenceDate, iterations: F.testIterations)
        try BackupFormat.write(export.data, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let bytes = try Data(contentsOf: url)
        #expect(!bytes.contains(F.password))
        #expect(!bytes.contains(F.sshSecret))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["settings.ccinnstarrocks-backup"], "no temporary files stay behind")
    }

    @Test func writingLeavesTheChosenFolderAsItWas() throws {
        let mac = try SourceMac()
        defer { mac.remove() }
        let folder = mac.directory.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let url = folder.appendingPathComponent("settings.ccinnstarrocks-backup")
        try BackupFormat.write(try mac.exporter().export(BackupExportOptions(), appVersion: "1.4.0", now: F.referenceDate).data, to: url)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func optionsNeverShowThePassphrase() {
        var options = BackupExportOptions()
        options.passphrase = F.passphrase
        #expect(!String(describing: options).contains(F.passphrase))
        #expect(!String(reflecting: options).contains(F.passphrase))
        var dumped = ""
        dump(options, to: &dumped)
        #expect(!dumped.contains(F.passphrase))
    }

    @Test func unreadableSecretsAreReportedNotFatal() throws {
        let mac = try SourceMac()
        defer { mac.remove() }
        var options = BackupExportOptions()
        options.passphrase = F.passphrase
        let exporter = BackupExporter(profiles: [mac.plain], secretStore: UnreadableSecretStore(), knowledge: mac.knowledge,
                                      historyDirectory: mac.historyDirectory, settings: [:], home: F.oldHome)
        let export = try exporter.export(options, appVersion: "1.4.0", now: F.referenceDate, iterations: F.testIterations)
        #expect(export.warnings == [.secretNotExported("prod")])
        #expect(export.secretCount == 0)
    }
}

private final class UnreadableSecretStore: SecretStore {
    func secret(for key: SecretKey) throws -> String? {
        throw SecretStoreError(message: "Keychain read failed (-128)")
    }

    func setSecret(_ value: String?, for key: SecretKey) throws {}
}
