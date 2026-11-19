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
    /// Restore only: Keychain items it removed.
    public internal(set) var secretsRemoved = 0
    // What the import wrote, so `restore` undoes exactly that and nothing else.
    var writtenDatabases: [DatabaseKey] = []
    var createdDatabases: [DatabaseKey] = []
    var changedKnowledgeIndex = false
    var changedHistory: [UUID] = []
    /// The history entries the import added, and the local ones the 1,000-entry cap pushed out, per local profile id.
    var addedHistory: [UUID: Set<UUID>] = [:]
    var displacedHistory: [UUID: Set<UUID>] = [:]
    var changedSettings: [String] = []
    /// The profiles the import added or replaced, and the `updatedAt` it gave them.
    var savedProfileIDs: [UUID] = []
    var profileStamp: Date?
    /// Keychain items the import wrote (recorded before each write), and whether a value may have been there before.
    var writtenSecrets: [SecretKey: Bool] = [:]

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
                report.writtenSecrets[write.key] = (report.writtenSecrets[write.key] ?? false) || write.replacesExisting
                try secretStore.setSecret(write.value, for: write.key)
                report.secretsWritten += 1
            }
            report.completedSteps.append(step)

            step = .profiles
            // Stamped here, so restore can tell a profile edited since the import from the one it saved.
            let upserts = plan.profileUpserts.map { (profile: ConnectionProfile) -> ConnectionProfile in
                var stamped = profile
                stamped.updatedAt = now
                return stamped
            }
            report.savedProfileIDs = upserts.map(\.id)
            report.profileStamp = upserts.isEmpty ? nil : now
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

    /// `profiles` with `changes` replacing those of the same id and the rest appended. The applier has already
    /// stamped each change's `updatedAt`.
    public static func upserting(_ changes: [ConnectionProfile], into profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        var result = profiles
        var positions: [UUID: Int] = [:]
        for (position, profile) in result.enumerated() { positions[profile.id] = position }
        for change in changes {
            if let position = positions[change.id] {
                result[position] = change
            } else {
                positions[change.id] = result.count
                result.append(change)
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
            try QueryHistoryStore.withFileLock(in: historyDirectory) { () throws -> Void in
                let current = try BackupHistoryFiles.read(for: change.profileID, in: historyDirectory)
                let count = BackupHistoryFiles.addedEntryCount(local: current, imported: change.entries)
                guard count > 0 else { return }
                let merged = BackupHistoryFiles.merge(local: current, imported: change.entries)
                let localIDs = Set(current.map(\.id))
                let mergedIDs = Set(merged.map(\.id))
                report.changedHistory.append(change.profileID)
                report.addedHistory[change.profileID] = mergedIDs.subtracting(localIDs)
                report.displacedHistory[change.profileID] = localIDs.subtracting(mergedIDs)
                try BackupHistoryFiles.write(merged, for: change.profileID, in: historyDirectory)
                report.historyEntriesAdded += count
            }
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
    /// - the profiles it added or replaced, through `restoreProfiles` (see `BackupProfileRestore`): replaced ones go back
    ///   to their snapshot version, added ones are removed, and one edited since the import stays as it is;
    /// - the Keychain items it added; a password it replaced cannot be put back, and is removed when its profile goes
    ///   back to another server or SSH route, so it never follows the profile there;
    /// - the history entries it added (queries run since stay; entries the cap pushed out come back);
    /// - the settings it changed.
    /// Every step can run again, so a restore that stopped part-way can be retried.
    public func restore(_ importReport: BackupImportReport,
                        restoreProfiles: (BackupProfileRestore) throws -> BackupProfileRestore.Outcome) -> BackupImportReport {
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

            step = .profiles
            let snapshotProfiles = Dictionary(snapshot.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var outcome = BackupProfileRestore.Outcome(profiles: [], removed: [], kept: [], routeChanged: [])
            if !importReport.savedProfileIDs.isEmpty {
                let restore = BackupProfileRestore(restored: importReport.savedProfileIDs.compactMap { snapshotProfiles[$0] },
                                                   removed: importReport.savedProfileIDs.filter { snapshotProfiles[$0] == nil },
                                                   importStamp: importReport.profileStamp)
                outcome = try restoreProfiles(restore)
                report.profilesSaved = importReport.savedProfileIDs.count - outcome.kept.count
                for profile in outcome.kept { report.warnings.append(.changedSinceImport(profile.displayName)) }
            }
            report.completedSteps.append(step)

            step = .secrets
            try restoreSecrets(after: importReport, outcome: outcome, names: snapshotProfiles, report: &report)
            report.completedSteps.append(step)

            step = .history
            try restoreHistory(snapshot.history ?? [], after: importReport, removedProfiles: Set(outcome.removed))
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

    /// Removes the Keychain items the import added, except for profiles kept because they were edited since. A
    /// password it replaced stays (the old one is gone) unless its profile went back to another route.
    private func restoreSecrets(after importReport: BackupImportReport, outcome: BackupProfileRestore.Outcome,
                                names: [UUID: ConnectionProfile], report: inout BackupImportReport) throws {
        let kept = Set(outcome.kept.map(\.id))
        var removedFor: Set<UUID> = []
        var notRestored: Set<UUID> = []
        for (key, replacedExisting) in importReport.writtenSecrets.sorted(by: { $0.key.account < $1.key.account }) where !kept.contains(key.profileID) {
            if replacedExisting, !outcome.routeChanged.contains(key.profileID) {
                notRestored.insert(key.profileID)
                continue
            }
            try secretStore.setSecret(nil, for: key)
            report.secretsRemoved += 1
            if replacedExisting { removedFor.insert(key.profileID) }
        }
        func name(_ id: UUID) -> String { names[id]?.displayName ?? id.uuidString }
        for id in removedFor.sorted(by: { name($0) < name($1) }) { report.warnings.append(.passwordRemoved(name(id))) }
        for id in notRestored.sorted(by: { name($0) < name($1) }) { report.warnings.append(.passwordNotRestored(name(id))) }
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

    /// Takes the entries the import added out of each history it extended and puts back the ones its cap pushed out
    /// (and only those: entries deleted since stay deleted); a profile the restore removed keeps no history.
    private func restoreHistory(_ history: [BackupHistory], after importReport: BackupImportReport, removedProfiles: Set<UUID>) throws {
        var groups: [UUID: [QueryHistoryEntry]] = [:]
        for group in history where groups[group.profile] == nil { groups[group.profile] = group.entries }
        for profileID in importReport.changedHistory {
            let added = importReport.addedHistory[profileID] ?? []
            let displaced = importReport.displacedHistory[profileID] ?? []
            try QueryHistoryStore.withFileLock(in: historyDirectory) { () throws -> Void in
                let current = try BackupHistoryFiles.read(for: profileID, in: historyDirectory)
                let remaining = current.filter { !added.contains($0.id) }
                let pushedOut = (groups[profileID] ?? []).filter { displaced.contains($0.id) }
                let restored = BackupHistoryFiles.merge(local: remaining, imported: pushedOut)
                if restored.isEmpty || removedProfiles.contains(profileID) {
                    try BackupHistoryFiles.remove(for: profileID, in: historyDirectory)
                } else if restored != current {
                    try BackupHistoryFiles.write(restored, for: profileID, in: historyDirectory)
                }
            }
        }
    }
}

/// What a restore does to the profile list. Pure; the app applies the outcome to its ProfileStore.
public struct BackupProfileRestore: Sendable, Equatable {
    /// The snapshot versions of the profiles the import replaced.
    public let restored: [ConnectionProfile]
    /// The profiles the import added.
    public let removed: [UUID]
    /// The `updatedAt` the import gave the profiles it saved: a profile with another one was edited since.
    public let importStamp: Date?

    public struct Outcome: Sendable, Equatable {
        /// The whole new list.
        public let profiles: [ConnectionProfile]
        /// Ids taken out (also ones the import recorded but never saved), whose Keychain items go too.
        public let removed: [UUID]
        /// Profiles left as they are because they were edited after the import.
        public let kept: [ConnectionProfile]
        /// Restored profiles whose server or SSH route differs from the version the import saved.
        public let routeChanged: Set<UUID>

        public init(profiles: [ConnectionProfile], removed: [UUID], kept: [ConnectionProfile], routeChanged: Set<UUID>) {
            self.profiles = profiles
            self.removed = removed
            self.kept = kept
            self.routeChanged = routeChanged
        }
    }

    public init(restored: [ConnectionProfile], removed: [UUID], importStamp: Date?) {
        self.restored = restored
        self.removed = removed
        self.importStamp = importStamp
    }

    /// Applies the restore to `profiles`. Profiles created after the import are never touched; a profile the import
    /// replaced and the user deleted since comes back.
    public func apply(to profiles: [ConnectionProfile]) -> Outcome {
        var result = profiles
        var positions: [UUID: Int] = [:]
        for (position, profile) in result.enumerated() { positions[profile.id] = position }
        var kept: [ConnectionProfile] = []
        var removedIDs: Set<UUID> = []
        var routeChanged: Set<UUID> = []
        func editedSinceImport(_ profile: ConnectionProfile) -> Bool { profile.updatedAt != importStamp }

        for id in removed {
            if let position = positions[id], editedSinceImport(result[position]) {
                kept.append(result[position])
            } else {
                removedIDs.insert(id)
            }
        }
        for profile in restored {
            guard let position = positions[profile.id] else {
                positions[profile.id] = result.count
                result.append(profile)
                continue
            }
            let current = result[position]
            if editedSinceImport(current) {
                kept.append(current)
                continue
            }
            if BackupImportPlanner.RouteKey(current) != BackupImportPlanner.RouteKey(profile) { routeChanged.insert(profile.id) }
            result[position] = profile
        }
        result.removeAll { removedIDs.contains($0.id) }
        return Outcome(profiles: result, removed: removed.filter { removedIDs.contains($0) }, kept: kept, routeChanged: routeChanged)
    }
}
