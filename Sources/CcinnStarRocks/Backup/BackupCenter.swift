import AppKit
import CcinnStarRocksKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Export and import of connections, knowledge, settings and history: the state behind the Backup window. Slow work
/// (key derivation, Keychain reads, merging files) runs off the main actor; profiles and settings change on it.
/// Passphrases and decrypted secrets are dropped as soon as they have been used.
@MainActor
@Observable
final class BackupCenter {
    enum Stage: Equatable {
        case home
        case exportForm
        case working(String)
        case exported
        case passphrase
        case preview
        case report
        case failed(String)
    }

    /// What a backup reads and changes. Tests use temporary directories, an in-memory secret store and a defaults suite.
    struct Stores: Sendable {
        var profiles: ProfileStore
        var secretStore: any SecretStore
        var knowledge: KnowledgeStore
        var historyDirectory: URL
        var snapshotDirectory: URL
        /// `nil` for `UserDefaults.standard`.
        var defaultsSuite: String?
        var home: String

        @MainActor
        static func live(profiles: ProfileStore, historyDirectory: URL) -> Stores {
            Stores(profiles: profiles, secretStore: KeychainSecretStore(), knowledge: KnowledgeStore(), historyDirectory: historyDirectory,
                   snapshotDirectory: BackupImportApplier.defaultSnapshotDirectory, defaultsSuite: nil, home: NSHomeDirectory())
        }

        var defaults: UserDefaults { defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    }

    /// How files and folders are chosen; tests answer without panels.
    struct Panels {
        var chooseExportURL: @MainActor (_ suggestedName: String) -> URL?
        var chooseImportURL: @MainActor () -> URL?
        var chooseDirectory: @MainActor (_ prompt: String) -> String?
    }

    struct ExportResult: Equatable {
        let url: URL
        let profileCount: Int
        let secretCount: Int
        /// Made with a passphrase (authenticated), whether or not any password was found to include.
        let isPassphraseProtected: Bool
        let warnings: [String]
    }

    let stores: Stores
    private let panels: Panels
    private let fileExists: @Sendable (String) -> Bool

    private(set) var stage: Stage = .home

    // Export form
    var includeKnowledge = true
    var includeSettings = true
    var includeHistory = false
    var includePasswords = false
    var passphrase = ""
    var passphraseConfirmation = ""
    private(set) var exportResult: ExportResult?

    // Import
    private(set) var importURL: URL?
    private(set) var header: BackupHeader?
    /// Decoded without the passphrase, waiting for it.
    private var lockedBundle: BackupBundle?
    var importPassphrase = ""
    private(set) var passphraseMessage: String?
    /// The passphrase was right but the file was changed after it was made: its passwords are refused.
    private(set) var secretsRefused = false
    private(set) var plan: BackupImportPlan?
    private(set) var report: BackupImportReport?
    private(set) var reportIsRestore = false
    var remapFrom = ""
    var remapTo = ""
    private(set) var remapMessage: String?

    init(stores: Stores, panels: Panels = .live, fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.stores = stores
        self.panels = panels
        self.fileExists = fileExists
    }

    func showHome() {
        forgetSecrets()
        plan = nil
        stage = .home
    }

    // MARK: Export

    /// Why the form cannot be exported yet, or `nil`.
    var exportProblem: String? {
        guard includePasswords else { return nil }
        if !BackupFormat.isAcceptablePassphrase(passphrase) {
            return "The passphrase needs at least \(BackupFormat.minimumPassphraseLength) characters."
        }
        return passphrase == passphraseConfirmation ? nil : "The two passphrases differ."
    }

    func beginExport() {
        forgetSecrets()
        exportResult = nil
        stage = .exportForm
    }

    static func suggestedFileName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "CcinnStarRocks \(formatter.string(from: now)).\(BackupFormat.fileExtension)"
    }

    func export() async {
        guard stage == .exportForm, exportProblem == nil else { return }
        guard let url = panels.chooseExportURL(Self.suggestedFileName(now: Date())) else { return }
        var options = BackupExportOptions()
        options.includeKnowledge = includeKnowledge
        options.includeSettings = includeSettings
        options.includeHistory = includeHistory
        options.passphrase = includePasswords ? passphrase : nil
        passphrase = ""
        passphraseConfirmation = ""
        let stores = stores
        let profiles = stores.profiles.profiles
        let settings = settingsSnapshot()
        stage = .working(options.passphrase == nil ? "Exporting…" : "Reading passwords from the Keychain and encrypting them…")
        do {
            let export = try await Task.detached(priority: .userInitiated) { () throws -> BackupExport in
                let exporter = BackupExporter(profiles: profiles, secretStore: stores.secretStore, knowledge: stores.knowledge,
                                              historyDirectory: stores.historyDirectory, settings: settings, home: stores.home)
                let export = try exporter.export(options)
                try BackupFormat.write(export.data, to: url)
                return export
            }.value
            exportResult = ExportResult(url: url, profileCount: profiles.count, secretCount: export.secretCount,
                                        isPassphraseProtected: options.passphrase != nil, warnings: export.warnings.map(\.description))
            stage = .exported
        } catch {
            stage = .failed("The backup was not written: \(error.localizedDescription)")
        }
    }

    // MARK: Import

    func beginImport() async {
        guard let url = chooseImportFile() else { return }
        await open(url)
    }

    func chooseImportFile() -> URL? { panels.chooseImportURL() }

    /// Reads `url`; asks for the passphrase when it holds passwords, otherwise goes straight to the preview.
    func open(_ url: URL) async {
        forgetSecrets()
        plan = nil
        report = nil
        importURL = url
        header = nil
        stage = .working("Reading the backup…")
        do {
            let bundle = try await Task.detached(priority: .userInitiated) { try BackupFormat.read(contentsOf: url) }.value
            header = bundle.header
            if bundle.header.secrets != nil {
                lockedBundle = bundle
                stage = .passphrase
            } else {
                await prepare(bundle)
            }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func unlock() async {
        guard stage == .passphrase, !secretsRefused, let url = importURL else { return }
        let passphrase = importPassphrase
        importPassphrase = ""
        stage = .working("Checking the passphrase…")
        do {
            let bundle = try await Task.detached(priority: .userInitiated) { try BackupFormat.read(contentsOf: url, passphrase: passphrase) }.value
            lockedBundle = nil
            await prepare(bundle)
        } catch BackupError.modified {
            secretsRefused = true
            passphraseMessage = "The passphrase is right, but the file was changed after it was made, so its passwords are refused. "
                + "You can import the rest; check the preview carefully."
            stage = .passphrase
        } catch {
            passphraseMessage = error.localizedDescription
            stage = .passphrase
        }
    }

    /// Imports everything but the passwords.
    func continueWithoutPasswords() async {
        guard stage == .passphrase, let bundle = lockedBundle else { return }
        lockedBundle = nil
        importPassphrase = ""
        await prepare(bundle)
    }

    private func prepare(_ bundle: BackupBundle) async {
        stage = .working("Comparing with this Mac…")
        let stores = stores
        let profiles = stores.profiles.profiles
        let settings = settingsSnapshot()
        let fileExists = fileExists
        let plan = await Task.detached(priority: .userInitiated) { () -> BackupImportPlan in
            let local = BackupLocalState.load(for: bundle, profiles: profiles, knowledge: stores.knowledge, historyDirectory: stores.historyDirectory,
                                              settings: settings, secretStore: stores.secretStore)
            return BackupImportPlanner.plan(bundle, local: local, home: stores.home, fileExists: fileExists)
        }.value
        self.plan = plan
        suggestRemap()
        stage = .preview
    }

    // MARK: Preview choices

    func resolve(_ profileID: UUID, as resolution: BackupProfileItem.Resolution) {
        plan?.resolve(profileID, as: resolution)
    }

    func include(setting key: String, _ isIncluded: Bool) {
        plan?.include(setting: key, isIncluded)
    }

    func remapCommonPrefix() {
        let from = remapFrom.trimmingCharacters(in: .whitespaces)
        let to = remapTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty, plan != nil else { return }
        let changed = plan?.remapProjects(fromPrefix: from, toPrefix: to, home: stores.home, fileExists: fileExists) ?? 0
        remapMessage = changed == 1 ? "1 project moved." : "\(changed) projects moved."
    }

    func remapProject(_ projectID: String) {
        guard let path = panels.chooseDirectory("Use") else { return }
        if plan?.remapProject(projectID, to: path, home: stores.home, fileExists: fileExists) == false {
            remapMessage = "That folder cannot be used for a project."
        }
    }

    /// Prefills the common-prefix remap with the folder the missing projects share.
    private func suggestRemap() {
        remapMessage = nil
        let missing = plan?.knowledge?.projects.filter(\.isMissing).map(\.path) ?? []
        guard let first = missing.first else {
            remapFrom = ""
            remapTo = ""
            return
        }
        var common = (first as NSString).deletingLastPathComponent.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for path in missing.dropFirst() {
            let parts = (path as NSString).deletingLastPathComponent.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        let prefix = common.joined(separator: "/")
        remapFrom = prefix
        // `/Volumes/Work/code` suggests `~/code`; a folder already under home is left for the user to choose.
        remapTo = prefix.isEmpty || prefix.hasPrefix("~") ? "" : "~/" + (prefix as NSString).lastPathComponent
    }

    /// Display names of the profiles a history change lands on.
    func profileName(_ id: UUID) -> String {
        if let item = plan?.profiles.first(where: { $0.targetID == id }) { return item.upsert?.displayName ?? item.local?.displayName ?? item.imported.displayName }
        return stores.profiles.profile(id: id)?.displayName ?? id.uuidString
    }

    // MARK: Apply and restore

    func performImport() async {
        guard stage == .preview, let plan, !plan.isUnchanged else { return }
        stage = .working("Importing…")
        let stores = stores
        let profiles = stores.profiles.profiles
        let settings = settingsSnapshot()
        let report = await Task.detached(priority: .userInitiated) { () -> BackupImportReport in
            Self.applier(stores, profiles: profiles, settings: settings).apply(plan)
        }.value
        self.plan = nil
        self.report = report
        reportIsRestore = false
        stage = .report
    }

    /// Offered on the report of the import just made: undoes what it wrote (see `BackupImportApplier.restore`).
    var canRestore: Bool { !reportIsRestore && report?.snapshotURL != nil }

    func restoreSnapshot() async {
        guard canRestore, let importReport = report else { return }
        stage = .working("Restoring the pre-import snapshot…")
        let stores = stores
        let profiles = stores.profiles.profiles
        let settings = settingsSnapshot()
        let restored = await Task.detached(priority: .userInitiated) { () -> BackupImportReport in
            Self.applier(stores, profiles: profiles, settings: settings).restore(importReport) { (restored: [ConnectionProfile], removed: [UUID]) throws -> Void in
                try onMainActor { try stores.profiles.restore(restored, removing: removed) }
            }
        }.value
        report = restored
        reportIsRestore = true
        stage = .report
    }

    private nonisolated static func applier(_ stores: Stores, profiles: [ConnectionProfile], settings: [String: BackupSettingValue]) -> BackupImportApplier {
        let exporter = BackupExporter(profiles: profiles, secretStore: stores.secretStore, knowledge: stores.knowledge,
                                      historyDirectory: stores.historyDirectory, settings: settings, home: stores.home)
        return BackupImportApplier(
            snapshotDirectory: stores.snapshotDirectory,
            makeSnapshot: { () throws -> Data in try exporter.export(.preImportSnapshot).data },
            knowledge: stores.knowledge, historyDirectory: stores.historyDirectory, secretStore: stores.secretStore,
            applyProfiles: { (upserts: [ConnectionProfile]) throws -> Void in
                try onMainActor { try stores.profiles.apply(upserts) }
            },
            writeSetting: { (key: String, value: BackupSettingValue?) throws -> Void in
                onMainActor {
                    if let stored = value?.propertyListValue {
                        stores.defaults.set(stored, forKey: key)
                    } else {
                        stores.defaults.removeObject(forKey: key)
                    }
                }
            })
    }

    // MARK: Helpers

    private func settingsSnapshot() -> [String: BackupSettingValue] {
        let defaults = stores.defaults
        return BackupSettings.snapshot { defaults.object(forKey: $0) }
    }

    private func forgetSecrets() {
        passphrase = ""
        passphraseConfirmation = ""
        importPassphrase = ""
        lockedBundle = nil
        passphraseMessage = nil
        secretsRefused = false
    }
}

/// Runs `work` on the main actor and waits for it: the applier changes profiles and settings synchronously from a
/// background thread. Runs in place when already on the main thread, so it never waits on itself.
nonisolated func onMainActor(_ work: @MainActor () throws -> Void) rethrows {
    if Thread.isMainThread {
        try MainActor.assumeIsolated(work)
    } else {
        try DispatchQueue.main.sync { try MainActor.assumeIsolated(work) }
    }
}

extension BackupCenter.Panels {
    static var live: BackupCenter.Panels {
        BackupCenter.Panels(
            chooseExportURL: { suggestedName in
                let panel = NSSavePanel()
                panel.title = "Export Settings and Knowledge"
                panel.nameFieldStringValue = suggestedName
                panel.allowedContentTypes = [BackupCenter.contentType]
                panel.canCreateDirectories = true
                return panel.runModal() == .OK ? panel.url : nil
            },
            chooseImportURL: {
                let panel = NSOpenPanel()
                panel.title = "Import Settings and Knowledge"
                panel.allowedContentTypes = [BackupCenter.contentType]
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                return panel.runModal() == .OK ? panel.url : nil
            },
            chooseDirectory: { prompt in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = prompt
                return panel.runModal() == .OK ? panel.url?.path : nil
            })
    }
}

extension BackupCenter {
    static var contentType: UTType { UTType(filenameExtension: BackupFormat.fileExtension) ?? .data }
}
