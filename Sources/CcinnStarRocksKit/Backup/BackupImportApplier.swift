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
    // What the import wrote, so `restore` undoes exactly that and nothing else.
    var writtenDatabases: [DatabaseKey] = []
    var createdDatabases: [DatabaseKey] = []
    var changedKnowledgeIndex = false
    var changedHistory: [UUID] = []
    /// The history entries the import added, per local profile id.
    var addedHistory: [UUID: Set<UUID>] = [:]
    var changedSettings: [String] = []
    /// The profiles the import added or replaced.
    var savedProfileIDs: [UUID] = []

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
                try applyKnowledge(knowledgePlan, report: &report)
            }
            report.completedSteps.append(step)

            step = .history
            try applyHistory(plan.historyChanges, report: &report)
            report.completedSteps.append(step)

            step = .secrets
            for write in plan.secretWrites {
                try secretStore.setSecret(write.value, for: write.key)
                report.secretsWritten += 1
            }
            report.completedSteps.append(step)

            step = .profiles
            let upserts = plan.profileUpserts
            report.savedProfileIDs = upserts.map(\.id)
            if !upserts.isEmpty { try applyProfiles(upserts) }
            report.profilesSaved = upserts.count
            report.completedSteps.append(step)

            step = .settings
            for item in plan.settingChanges {
                report.changedSettings.append(item.key)
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

    /// `profiles` with `restored` put back by id (re-added when deleted since) and `removed` taken out; every other
    /// profile, including ones created after the import, stays as it is.
    public static func restoring(_ restored: [ConnectionProfile], removing removed: [UUID], in profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        let removedIDs = Set(removed)
        var result = profiles.filter { !removedIDs.contains($0.id) }
        var positions: [UUID: Int] = [:]
        for (position, profile) in result.enumerated() { positions[profile.id] = position }
        for profile in restored where !removedIDs.contains(profile.id) {
            if let position = positions[profile.id] {
                result[position] = profile
            } else {
                positions[profile.id] = result.count
                result.append(profile)
            }
        }
        return result
    }

    private func applyKnowledge(_ plan: BackupKnowledgePlan, report: inout BackupImportReport) throws {
        for item in plan.databases where item.status == .new || item.status == .merged {
            guard let imported = plan.importedDatabases[item.key] else { continue }
            do {
                let current = try knowledge.database(item.key)
                if let current, BackupKnowledgeMerge.merge(local: current, imported: imported).merged == current { continue }
                // Recorded first: a write that fails halfway may still have created the file.
                report.writtenDatabases.append(item.key)
                if current == nil {
                    report.createdDatabases.append(item.key)
                    report.changedKnowledgeIndex = true
                }
                try knowledge.updateDatabase(item.key) { (database: inout DatabaseKnowledge) -> Void in
                    database = BackupKnowledgeMerge.merge(local: database, imported: imported).merged
                }
                report.databasesMerged += 1
            } catch KnowledgeStore.Failure.newerFormat(_) {
                report.warnings.append(.localDatabaseNotWritable(item.key))
            }
        }
        let current = try knowledge.index()
        if plan.mergedIndex(into: current) != current {
            report.changedKnowledgeIndex = true
            try knowledge.updateIndex { (index: inout KnowledgeIndex) -> Void in
                index = plan.mergedIndex(into: index)
            }
        }
    }

    private func applyHistory(_ changes: [BackupHistoryChange], report: inout BackupImportReport) throws {
        for change in changes {
            let current = try BackupHistoryFiles.read(for: change.profileID, in: historyDirectory)
            let count = BackupHistoryFiles.addedEntryCount(local: current, imported: change.entries)
            guard count > 0 else { continue }
            let merged = BackupHistoryFiles.merge(local: current, imported: change.entries)
            let localIDs = Set(current.map(\.id))
            report.changedHistory.append(change.profileID)
            report.addedHistory[change.profileID] = Set(merged.lazy.map(\.id).filter { !localIDs.contains($0) })
            try BackupHistoryFiles.write(merged, for: change.profileID, in: historyDirectory)
            report.historyEntriesAdded += count
        }
    }

    // MARK: Snapshots

    /// `<snapshot directory>/pre-import-<UTC timestamp>.ccinnstarrocks-backup`, 0600; older ones beyond five removed.
    func writeSnapshot(now: Date) throws -> URL {
        let data = try makeSnapshot()
        // A snapshot that cannot be read back could not be restored: refuse to import rather than find out later.
        let snapshot = try BackupFormat.decode(data)
        guard snapshot.header.secrets == nil else { throw BackupError.invalid("the pre-import snapshot must not contain secrets") }
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

    /// Undoes what the import behind `importReport` wrote, from its pre-import snapshot, and nothing else:
    /// - the knowledge files it changed (files it created are removed; files it never touched stay as they are) and the index;
    /// - the history entries it added (queries run since stay; entries the import pushed past the cap come back);
    /// - the profiles it added or replaced, through `restoreProfiles(restored, removed)`: replaced ones go back to their
    ///   snapshot version, added ones are removed (the app also removes their Keychain items), others stay;
    /// - the settings it changed.
    /// Secrets are never in a snapshot: ones the import replaced cannot be restored.
    public func restore(_ importReport: BackupImportReport,
                        restoreProfiles: (_ restored: [ConnectionProfile], _ removed: [UUID]) throws -> Void) -> BackupImportReport {
        var report = BackupImportReport()
        report.snapshotURL = importReport.snapshotURL
        var step = BackupImportReport.Step.snapshot
        do {
            guard let url = importReport.snapshotURL else { throw BackupError.invalid("this import has no pre-import snapshot") }
            let snapshot = try BackupFormat.read(contentsOf: url).payload
            report.completedSteps.append(step)

            step = .knowledge
            let touchedKnowledge = importReport.changedKnowledgeIndex || !importReport.writtenDatabases.isEmpty
            if touchedKnowledge {
                if let section = snapshot.knowledge {
                    try restoreKnowledge(section, after: importReport, warnings: &report.warnings)
                } else {
                    report.warnings.append(.notRestored("knowledge"))
                }
            }
            report.completedSteps.append(step)

            let snapshotProfiles = Dictionary(snapshot.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let removedProfiles = importReport.savedProfileIDs.filter { snapshotProfiles[$0] == nil }

            step = .history
            try restoreHistory(snapshot.history ?? [], after: importReport, removedProfiles: Set(removedProfiles))
            report.completedSteps.append(step)

            step = .profiles
            if !importReport.savedProfileIDs.isEmpty {
                let restored = importReport.savedProfileIDs.compactMap { snapshotProfiles[$0] }
                try restoreProfiles(restored, removedProfiles)
                report.profilesSaved = restored.count + removedProfiles.count
            }
            report.completedSteps.append(step)

            step = .settings
            if !importReport.changedSettings.isEmpty {
                if let settings = snapshot.settings {
                    for key in importReport.changedSettings {
                        try writeSetting(key, settings[key])
                        report.settingsChanged += 1
                    }
                } else {
                    report.warnings.append(.notRestored("settings"))
                }
            }
            report.completedSteps.append(step)
        } catch {
            report.failedStep = step
            report.failureMessage = error.localizedDescription
        }
        return report
    }

    /// Under the knowledge lock, with revisions above the current ones so caches reload.
    private func restoreKnowledge(_ section: BackupKnowledge, after importReport: BackupImportReport, warnings: inout [BackupWarning]) throws {
        try SecureFile.createDirectory(knowledge.directory)
        try FileLock.withLock(at: knowledge.lockURL) {
            let encoder = KnowledgeStore.encoder
            var snapshotDatabases: [DatabaseKey: DatabaseKnowledge] = [:]
            for database in section.databases { snapshotDatabases[database.key] = database }
            let created = Set(importReport.createdDatabases)
            for key in importReport.writtenDatabases {
                let url = knowledge.databaseURL(key)
                if created.contains(key) {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } else if var restored = snapshotDatabases[key] {
                    let currentRevision = (try? knowledge.database(key))?.revision ?? 0
                    restored.revision = Self.nextRevision(after: max(currentRevision, restored.revision))
                    try SecureFile.write(try encoder.encode(restored), to: url)
                } else {
                    warnings.append(.notRestored(key.description))
                }
            }
            guard importReport.changedKnowledgeIndex else { return }
            var index = section.index
            let currentRevision = (try? knowledge.index())?.revision ?? 0
            index.revision = Self.nextRevision(after: max(currentRevision, index.revision))
            index.updatedAt = Date()
            try SecureFile.write(try encoder.encode(index), to: knowledge.indexURL)
        }
    }

    static func nextRevision(after revision: Int) -> Int {
        revision < Int.max ? revision + 1 : Int.max
    }

    /// Takes the entries the import added out of each history it extended and puts back what the cap pushed out; a
    /// profile the restore removes keeps no history.
    private func restoreHistory(_ history: [BackupHistory], after importReport: BackupImportReport, removedProfiles: Set<UUID>) throws {
        var groups: [UUID: [QueryHistoryEntry]] = [:]
        for group in history where groups[group.profile] == nil { groups[group.profile] = group.entries }
        for profileID in importReport.changedHistory {
            let added = importReport.addedHistory[profileID] ?? []
            let current = try BackupHistoryFiles.read(for: profileID, in: historyDirectory)
            let remaining = current.filter { !added.contains($0.id) }
            let restored = BackupHistoryFiles.merge(local: remaining, imported: groups[profileID] ?? [])
            if restored.isEmpty || removedProfiles.contains(profileID) {
                try BackupHistoryFiles.remove(for: profileID, in: historyDirectory)
            } else {
                try BackupHistoryFiles.write(restored, for: profileID, in: historyDirectory)
            }
        }
    }
}
