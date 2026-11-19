import Foundation

/// What an import (or a restore) did. When a step fails, the steps before it stay applied and the rest never ran.
public struct BackupImportReport: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case snapshot, knowledge, history, secrets, profiles, settings
    }

    public internal(set) var completedSteps: [Step] = []
    public internal(set) var failedStep: Step?
    public internal(set) var failureMessage: String?
    /// The automatic pre-import snapshot, to offer "Restore pre-import snapshot".
    public internal(set) var snapshotURL: URL?
    public internal(set) var warnings: [BackupWarning] = []
    public internal(set) var profilesSaved = 0
    public internal(set) var secretsWritten = 0
    public internal(set) var databasesMerged = 0
    public internal(set) var historyEntriesAdded = 0
    public internal(set) var settingsChanged = 0

    public var succeeded: Bool { failedStep == nil }
    /// AI clients' `mcp` servers read profiles once at startup; they need a restart to see these changes.
    public var needsMCPRestart: Bool { profilesSaved > 0 }
}

/// Applies an import plan in a fixed order: a pre-import snapshot (no secrets, 0600, the last five kept), knowledge
/// under the knowledge lock, history files, Keychain items, profiles in one batch, settings. Profiles and settings go
/// through closures the app provides (its ProfileStore and UserDefaults), so they are saved the way every other change is.
///
/// Knowledge and history are merged again against what is on disk when applied, so writes made since the preview (by
/// the app or an `mcp` process) are kept.
public struct BackupImportApplier {
    public static let retainedSnapshots = 5
    static let snapshotPrefix = "pre-import-"

    public static var defaultSnapshotDirectory: URL {
        ProfileRepository.defaultDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    public var snapshotDirectory: URL
    /// A backup of the current state without secrets (`BackupExporter.export(.preImportSnapshot)`).
    public var makeSnapshot: () throws -> Data
    public var knowledge: KnowledgeStore
    public var historyDirectory: URL
    public var secretStore: any SecretStore
    /// Adds or replaces profiles by id and saves them once (`upserting(_:into:updatedAt:)` does the list part).
    public var applyProfiles: ([ConnectionProfile]) throws -> Void
    /// Stores a setting, or removes it for `nil` (used by `restore`).
    public var writeSetting: (String, BackupSettingValue?) throws -> Void

    public init(snapshotDirectory: URL = BackupImportApplier.defaultSnapshotDirectory, makeSnapshot: @escaping () throws -> Data,
                knowledge: KnowledgeStore = KnowledgeStore(), historyDirectory: URL = QueryHistoryStore.defaultDirectory,
                secretStore: any SecretStore, applyProfiles: @escaping ([ConnectionProfile]) throws -> Void,
                writeSetting: @escaping (String, BackupSettingValue?) throws -> Void) {
        self.snapshotDirectory = snapshotDirectory
        self.makeSnapshot = makeSnapshot
        self.knowledge = knowledge
        self.historyDirectory = historyDirectory
        self.secretStore = secretStore
        self.applyProfiles = applyProfiles
        self.writeSetting = writeSetting
    }

    // MARK: Applying

    /// Applies `plan`. A plan that changes nothing writes nothing, not even a snapshot.
    public func apply(_ plan: BackupImportPlan, now: Date = Date()) -> BackupImportReport {
        var report = BackupImportReport()
        report.warnings = plan.warnings
        guard !plan.isUnchanged else { return report }
        var step = BackupImportReport.Step.snapshot
        do {
            report.snapshotURL = try writeSnapshot(now: now)
            report.completedSteps.append(step)

            step = .knowledge
            if let knowledgePlan = plan.knowledge, !knowledgePlan.isUnchanged {
                report.databasesMerged = try applyKnowledge(knowledgePlan, warnings: &report.warnings)
            }
            report.completedSteps.append(step)

            step = .history
            report.historyEntriesAdded = try applyHistory(plan.historyChanges)
            report.completedSteps.append(step)

            step = .secrets
            for write in plan.secretWrites {
                try secretStore.setSecret(write.value, for: write.key)
                report.secretsWritten += 1
            }
            report.completedSteps.append(step)

            step = .profiles
            let upserts = plan.profileUpserts
            if !upserts.isEmpty { try applyProfiles(upserts) }
            report.profilesSaved = upserts.count
            report.completedSteps.append(step)

            step = .settings
            for item in plan.settingChanges {
                try writeSetting(item.key, item.imported)
                report.settingsChanged += 1
            }
            report.completedSteps.append(step)
        } catch {
            report.failedStep = step
            report.failureMessage = error.localizedDescription
        }
        return report
    }

    /// `profiles` with `changes` replacing those of the same id and the rest appended, each change stamped `updatedAt`.
    public static func upserting(_ changes: [ConnectionProfile], into profiles: [ConnectionProfile], updatedAt: Date) -> [ConnectionProfile] {
        var result = profiles
        var positions: [UUID: Int] = [:]
        for (position, profile) in result.enumerated() { positions[profile.id] = position }
        for change in changes {
            var stamped = change
            stamped.updatedAt = updatedAt
            if let position = positions[stamped.id] {
                result[position] = stamped
            } else {
                positions[stamped.id] = result.count
                result.append(stamped)
            }
        }
        return result
    }

    private func applyKnowledge(_ plan: BackupKnowledgePlan, warnings: inout [BackupWarning]) throws -> Int {
        var merged = 0
        for item in plan.databases where item.status == .new || item.status == .merged {
            guard let imported = plan.importedDatabases[item.key] else { continue }
            do {
                if let current = try knowledge.database(item.key), BackupKnowledgeMerge.merge(local: current, imported: imported).merged == current {
                    continue
                }
                try knowledge.updateDatabase(item.key) { (database: inout DatabaseKnowledge) -> Void in
                    database = BackupKnowledgeMerge.merge(local: database, imported: imported).merged
                }
                merged += 1
            } catch KnowledgeStore.Failure.newerFormat(_) {
                warnings.append(.localDatabaseNotWritable(item.key))
            }
        }
        let current = try knowledge.index()
        if plan.mergedIndex(into: current) != current {
            try knowledge.updateIndex { (index: inout KnowledgeIndex) -> Void in
                index = plan.mergedIndex(into: index)
            }
        }
        return merged
    }

    private func applyHistory(_ changes: [BackupHistoryChange]) throws -> Int {
        var added = 0
        for change in changes {
            let current = try BackupHistoryFiles.read(for: change.profileID, in: historyDirectory)
            let count = BackupHistoryFiles.newEntryCount(local: Set(current.map(\.id)), imported: change.entries)
            guard count > 0 else { continue }
            try BackupHistoryFiles.write(BackupHistoryFiles.merge(local: current, imported: change.entries), for: change.profileID,
                                         in: historyDirectory)
            added += count
        }
        return added
    }

    // MARK: Snapshots

    /// `<snapshot directory>/pre-import-<UTC timestamp>.ccinnstarrocks-backup`, 0600; older ones beyond five removed.
    func writeSnapshot(now: Date) throws -> URL {
        let data = try makeSnapshot()
        guard let newline = data.firstIndex(of: 0x0A),
              let header = try? BackupFormat.headerDecoder.decode(BackupHeader.self, from: data[data.startIndex..<newline]),
              header.secrets == nil else { throw BackupError.invalid("the pre-import snapshot must not contain secrets") }
        var date = now
        var url = snapshotURL(for: date)
        var attempts = 0
        while FileManager.default.fileExists(atPath: url.path), attempts < 1_000 {
            date = date.addingTimeInterval(0.001)
            url = snapshotURL(for: date)
            attempts += 1
        }
        try SecureFile.write(data, to: url)
        pruneSnapshots()
        return url
    }

    private func snapshotURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = Self.snapshotPrefix + formatter.string(from: date) + "." + BackupFormat.fileExtension
        return snapshotDirectory.appendingPathComponent(name)
    }

    /// Best effort: a snapshot that cannot be removed never fails the import.
    private func pruneSnapshots() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshotDirectory.path)) ?? []
        let snapshots = names.filter { $0.hasPrefix(Self.snapshotPrefix) && $0.hasSuffix("." + BackupFormat.fileExtension) }.sorted()
        guard snapshots.count > Self.retainedSnapshots else { return }
        for name in snapshots.dropLast(Self.retainedSnapshots) {
            try? FileManager.default.removeItem(at: snapshotDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Restoring

    /// Puts back what a pre-import snapshot holds: knowledge (database files the snapshot lacks are removed), history of
    /// its profiles, the profile list (through `replaceProfiles`) and the whitelisted settings. Secrets are never in a
    /// snapshot: ones the import added stay, ones it replaced cannot be restored.
    public func restore(from url: URL, replaceProfiles: ([ConnectionProfile]) throws -> Void) -> BackupImportReport {
        var report = BackupImportReport()
        report.snapshotURL = url
        var step = BackupImportReport.Step.snapshot
        do {
            let snapshot = try BackupFormat.read(contentsOf: url).payload
            report.completedSteps.append(step)

            step = .knowledge
            if let section = snapshot.knowledge { try restoreKnowledge(section) }
            report.completedSteps.append(step)

            step = .history
            if let history = snapshot.history { try restoreHistory(history, profiles: snapshot.profiles) }
            report.completedSteps.append(step)

            step = .profiles
            try replaceProfiles(snapshot.profiles)
            report.profilesSaved = snapshot.profiles.count
            report.completedSteps.append(step)

            step = .settings
            if let settings = snapshot.settings {
                for key in BackupSettings.keys {
                    try writeSetting(key, settings[key])
                    report.settingsChanged += 1
                }
            }
            report.completedSteps.append(step)
        } catch {
            report.failedStep = step
            report.failureMessage = error.localizedDescription
        }
        return report
    }

    /// Replaces the knowledge files under the lock, with revisions above the current ones so caches reload.
    private func restoreKnowledge(_ section: BackupKnowledge) throws {
        try SecureFile.createDirectory(knowledge.directory)
        try FileLock.withLock(at: knowledge.lockURL) {
            let encoder = KnowledgeStore.encoder
            let databasesDirectory = knowledge.directory.appendingPathComponent("databases", isDirectory: true)
            let kept = Set(section.databases.map { $0.key.fileID + ".json" })
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: databasesDirectory.path)) ?? []
            for name in existing where name.hasSuffix(".json") && !kept.contains(name) {
                try FileManager.default.removeItem(at: databasesDirectory.appendingPathComponent(name))
            }
            for database in section.databases {
                var restored = database
                let currentRevision = (try? knowledge.database(database.key))?.revision ?? 0
                restored.revision = max(currentRevision, database.revision) + 1
                try SecureFile.write(try encoder.encode(restored), to: knowledge.databaseURL(database.key))
            }
            var index = section.index
            let currentRevision = (try? knowledge.index())?.revision ?? 0
            index.revision = max(currentRevision, index.revision) + 1
            index.updatedAt = Date()
            try SecureFile.write(try encoder.encode(index), to: knowledge.indexURL)
        }
    }

    /// Writes each snapshot profile's history; a readable file of a profile that had none then is removed (the import
    /// created it). An unreadable file is left alone: the import never writes over one.
    private func restoreHistory(_ history: [BackupHistory], profiles: [ConnectionProfile]) throws {
        var groups: [UUID: [QueryHistoryEntry]] = [:]
        for group in history where groups[group.profile] == nil { groups[group.profile] = group.entries }
        for profile in profiles {
            if let entries = groups[profile.id] {
                try BackupHistoryFiles.write(entries, for: profile.id, in: historyDirectory)
            } else if (try? BackupHistoryFiles.read(for: profile.id, in: historyDirectory)) != nil {
                try BackupHistoryFiles.remove(for: profile.id, in: historyDirectory)
            }
        }
    }
}
