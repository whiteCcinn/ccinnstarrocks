import Foundation

/// Which sections to export. Profiles are always included; secrets only with a passphrase. Descriptions and mirrors
/// never show the passphrase.
public struct BackupExportOptions: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var includeKnowledge = true
    public var includeSettings = true
    public var includeHistory = false
    /// At least `BackupFormat.minimumPassphraseLength` characters. With it, passwords and SSH secrets are sealed into
    /// the file and the whole file is authenticated; without it they are never written.
    public var passphrase: String?

    public init() {}

    public var description: String {
        "BackupExportOptions(knowledge: \(includeKnowledge), settings: \(includeSettings), history: \(includeHistory), "
            + "passphrase: \(passphrase == nil ? "none" : "redacted"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["includeKnowledge": includeKnowledge, "includeSettings": includeSettings, "includeHistory": includeHistory,
                                "hasPassphrase": passphrase != nil])
    }

    /// Everything an import can change, without secrets: the automatic snapshot written before importing.
    public static var preImportSnapshot: BackupExportOptions {
        var options = BackupExportOptions()
        options.includeHistory = true
        return options
    }
}

/// A written-out backup and what could not be included.
public struct BackupExport: Sendable {
    public let data: Data
    public let warnings: [BackupWarning]
    /// Profiles whose password or SSH secret was sealed into the file.
    public let secretCount: Int
}

/// Builds a backup from this Mac's state. Profiles come from the caller (the app's ProfileStore); knowledge, history and
/// secrets are read from their stores. Paths under `home` are written `~/…`.
public struct BackupExporter {
    public var profiles: [ConnectionProfile]
    public var secretStore: any SecretStore
    public var knowledge: KnowledgeStore
    public var historyDirectory: URL
    /// From `BackupSettings.snapshot(reading:)`.
    public var settings: [String: BackupSettingValue]
    public var home: String

    public init(profiles: [ConnectionProfile], secretStore: any SecretStore, knowledge: KnowledgeStore = KnowledgeStore(),
                historyDirectory: URL = QueryHistoryStore.defaultDirectory, settings: [String: BackupSettingValue],
                home: String = NSHomeDirectory()) {
        self.profiles = profiles
        self.secretStore = secretStore
        self.knowledge = knowledge
        self.historyDirectory = historyDirectory
        self.settings = settings
        self.home = home
    }

    public func export(_ options: BackupExportOptions, appVersion: String = AppInfo.version, now: Date = Date()) throws -> BackupExport {
        try export(options, appVersion: appVersion, now: now, iterations: BackupCrypto.defaultIterations)
    }

    /// `iterations` lets tests derive keys quickly.
    func export(_ options: BackupExportOptions, appVersion: String, now: Date, iterations: Int) throws -> BackupExport {
        if let passphrase = options.passphrase, !BackupFormat.isAcceptablePassphrase(passphrase) { throw BackupError.passphraseTooShort }
        var warnings: [BackupWarning] = []
        var payload = BackupPayload(profiles: profiles.map { BackupImportPlanner.withPortablePaths($0, home: home) })
        if options.includeKnowledge { payload.knowledge = exportKnowledge(warnings: &warnings) }
        if options.includeSettings { payload.settings = settings.filter { BackupSettings.accepts($0.value, forKey: $0.key) } }
        if options.includeHistory { payload.history = exportHistory(warnings: &warnings) }
        let secrets = options.passphrase == nil ? [:] : exportSecrets(warnings: &warnings)
        let data = try BackupFormat.encode(payload, secrets: secrets, passphrase: options.passphrase, appVersion: appVersion, createdAt: now,
                                           iterations: iterations)
        // Never hand out a file the reader would refuse (an invalid name or path in this Mac's data); the error names it.
        _ = try BackupFormat.decode(data)
        return BackupExport(data: data, warnings: warnings, secretCount: secrets.count)
    }

    /// The index and every readable database file; a database that cannot be read is left out with a warning.
    private func exportKnowledge(warnings: inout [BackupWarning]) -> BackupKnowledge? {
        var index: KnowledgeIndex
        do {
            index = try knowledge.index()
        } catch {
            warnings.append(.knowledgeNotExported(error.localizedDescription))
            return nil
        }
        index.projects = index.projects.map { (project: KnowledgeIndex.Project) -> KnowledgeIndex.Project in
            var copy = project
            copy.path = BackupPaths.collapsingHome(project.path, home: home)
            return copy
        }
        var databases: [DatabaseKnowledge] = []
        for entry in index.databases {
            do {
                if let database = try knowledge.database(entry.key) { databases.append(database) }
            } catch {
                warnings.append(.databaseNotExported(entry.key))
            }
        }
        return BackupKnowledge(index: index, databases: databases)
    }

    /// History of the exported profiles, redacted again.
    private func exportHistory(warnings: inout [BackupWarning]) -> [BackupHistory] {
        var history: [BackupHistory] = []
        for profile in profiles {
            do {
                let entries = try BackupHistoryFiles.read(for: profile.id, in: historyDirectory)
                if !entries.isEmpty { history.append(BackupHistory(profile: profile.id, entries: entries.map(BackupHistoryFiles.sanitized))) }
            } catch {
                warnings.append(.historyNotExported(profile.displayName))
            }
        }
        return history
    }

    private func exportSecrets(warnings: inout [BackupWarning]) -> [UUID: BackupProfileSecrets] {
        var secrets: [UUID: BackupProfileSecrets] = [:]
        for profile in profiles {
            do {
                let password = try secretStore.secret(for: SecretKey(profileID: profile.id, kind: .password))
                let sshSecret = try secretStore.secret(for: SecretKey(profileID: profile.id, kind: .sshSecret))
                let value = BackupProfileSecrets(password: password, sshSecret: sshSecret)
                if !value.isEmpty { secrets[profile.id] = value }
            } catch {
                warnings.append(.secretNotExported(profile.displayName))
            }
        }
        return secrets
    }
}
