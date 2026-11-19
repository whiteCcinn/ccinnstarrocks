import Foundation

/// What importing a backup would change, item by item, with the user's choices. Built by `BackupImportPlanner`, shown
/// as the preview, changed through `resolve`, `include(setting:_:)` and the remap operations, then applied by
/// `BackupImportApplier`. Everything it derives (`profileUpserts`, `secretWrites`, …) follows the current choices.
public struct BackupImportPlan: Sendable {
    /// Whether the passphrase proved the backup unmodified; otherwise the preview is untrusted.
    public let isAuthenticated: Bool
    public internal(set) var profiles: [BackupProfileItem]
    public internal(set) var knowledge: BackupKnowledgePlan?
    public internal(set) var settings: [BackupSettingItem]
    public internal(set) var history: [BackupHistoryItem]
    public internal(set) var warnings: [BackupWarning]
    /// Entry ids of each local profile's history, to count what an import adds.
    let localHistory: [UUID: Set<UUID>]

    /// Nothing would be written with the current choices.
    public var isUnchanged: Bool {
        let knowledgeUnchanged: Bool = knowledge?.isUnchanged ?? true
        let profilesUnchanged: Bool = profileUpserts.isEmpty && secretWrites.isEmpty
        let restUnchanged: Bool = settingChanges.isEmpty && historyChanges.isEmpty
        return profilesUnchanged && knowledgeUnchanged && restUnchanged
    }

    // MARK: Choices

    /// Sets how a conflicting profile is resolved; other items have nothing to choose.
    public mutating func resolve(_ profileID: UUID, as resolution: BackupProfileItem.Resolution) {
        guard let position = profiles.firstIndex(where: { $0.id == profileID }), profiles[position].status == .conflict else { return }
        profiles[position].resolution = resolution
    }

    /// Includes or leaves out one setting.
    public mutating func include(setting key: String, _ isIncluded: Bool) {
        guard let position = settings.firstIndex(where: { $0.key == key }) else { return }
        settings[position].isIncluded = isIncluded
    }

    /// Replaces a common prefix in every project path (`/Volumes/Work/code` → `~/code`) and checks the paths again.
    /// Returns how many projects changed.
    @discardableResult
    public mutating func remapProjects(fromPrefix: String, toPrefix: String, home: String, fileExists: (String) -> Bool) -> Int {
        guard var knowledge else { return 0 }
        let count = knowledge.remap(home: home, fileExists: fileExists) { (project: BackupProjectItem) -> String? in
            BackupPaths.replacingPrefix(fromPrefix, with: toPrefix, in: project.path, home: home)
        }
        self.knowledge = knowledge
        return count
    }

    /// Points one project at `path` (as chosen in an open panel). Returns whether the project exists and the path is
    /// acceptable.
    @discardableResult
    public mutating func remapProject(_ projectID: String, to path: String, home: String, fileExists: (String) -> Bool) -> Bool {
        let stored = BackupPaths.collapsingHome(path, home: home)
        guard var knowledge, knowledge.projects.contains(where: { $0.id == projectID }), BackupPaths.isAcceptable(stored) else { return false }
        knowledge.remap(home: home, fileExists: fileExists) { (project: BackupProjectItem) -> String? in
            project.id == projectID ? stored : nil
        }
        self.knowledge = knowledge
        return true
    }

    // MARK: Derived changes

    /// Each imported profile id → the local id its history and secrets land on.
    public var profileIDMapping: [UUID: UUID] {
        var mapping: [UUID: UUID] = [:]
        for item in profiles { mapping[item.id] = item.targetID }
        return mapping
    }

    /// Profiles to add or replace by id, for one batch save.
    public var profileUpserts: [ConnectionProfile] {
        profiles.compactMap(\.upsert)
    }

    public var secretWrites: [BackupSecretWrite] {
        profiles.flatMap(\.secretWrites)
    }

    public var settingChanges: [BackupSettingItem] {
        settings.filter { $0.isIncluded && !$0.isUnchanged }
    }

    /// Histories that gain entries, by the local profile id they land on.
    public var historyChanges: [BackupHistoryChange] {
        let mapping = profileIDMapping
        var changes: [BackupHistoryChange] = []
        for item in history {
            let target = mapping[item.profileID] ?? item.profileID
            let count = BackupHistoryFiles.newEntryCount(local: localHistory[target] ?? [], imported: item.entries)
            if count > 0 { changes.append(BackupHistoryChange(profileID: target, newEntries: count, entries: item.entries)) }
        }
        return changes
    }

    /// Whether the running `mcp` servers should be restarted: they read profiles once at startup.
    public var changesProfiles: Bool { !profileUpserts.isEmpty }
}

// MARK: - Profiles

public struct BackupProfileItem: Sendable, Identifiable {
    public enum Status: Sendable, Equatable {
        case new, unchanged, conflict
    }

    public enum Match: Sendable, Equatable {
        /// Same id.
        case id
        /// Same host (case-insensitive), port, user name and SSH host under another id.
        case endpoint
    }

    public enum Resolution: String, Sendable, CaseIterable, Identifiable {
        case keepMine, useImported, keepBoth
        public var id: String { rawValue }
    }

    /// Worth pointing out in the preview.
    public enum Flag: String, Sendable, CaseIterable {
        /// AI access (`mcpAccess`, the privileged opt-in) differs from the local profile, or is on for a new one.
        case aiAccessChanged
        /// The backup turns on the privileged-account opt-in, but is not authenticated, so it was turned off.
        case privilegedOptInReset
        /// Same id, another server or user: the local password would follow the profile to the new endpoint.
        case endpointChanged
        /// The imported profile allows sending the password in clear text; the local one does not.
        case cleartextPasswordEnabled
        /// The imported profile no longer asks before statements that change data; the local one does.
        case mutationConfirmationDisabled
        /// The SSH private key file does not exist on this Mac.
        case missingSSHKey
        /// The backup's password or SSH secret differs from the one stored here.
        case secretsDiffer
    }

    /// The id in the backup.
    public var id: UUID { imported.id }
    /// The imported profile as it would be saved: SSH key path `~/…`, privileged opt-in only from an authenticated
    /// backup (or kept from the local profile for the same account).
    public let imported: ConnectionProfile
    public let local: ConnectionProfile?
    public let match: Match?
    public let status: Status
    /// For a conflict: the newer `updatedAt` wins; either missing keeps the local profile. From an unauthenticated
    /// backup (whose `updatedAt` anyone could set) a change that weakens security also keeps the local profile: another
    /// endpoint, more AI access, cleartext passwords, no mutation confirmation.
    public let defaultResolution: Resolution
    public internal(set) var resolution: Resolution
    /// The id *Keep both* gives the copy.
    public let keepBothID: UUID
    public let flags: Set<Flag>
    /// The profiles are the same apart from ids and timestamps (they may still differ in secrets).
    let contentMatches: Bool
    let isAuthenticated: Bool
    let importedSecrets: BackupProfileSecrets
    /// `nil` when they could not be read.
    let localSecrets: BackupProfileSecrets?

    /// Whether the backup carries a password or SSH secret for this profile.
    public var includesSecrets: Bool { !importedSecrets.isEmpty }

    /// Where this profile's history and secrets land.
    public var targetID: UUID {
        guard let local, status != .new else { return imported.id }
        return status == .conflict && resolution == .keepBoth ? keepBothID : local.id
    }

    /// The profile to save, or `nil` when the local one stays as it is.
    public var upsert: ConnectionProfile? {
        guard let local, status != .new else { return imported }
        guard status == .conflict else { return nil }
        switch resolution {
        case .keepMine:
            return nil
        case .useImported:
            guard !contentMatches else { return nil }
            var profile = imported
            profile.id = local.id
            profile.createdAt = local.createdAt
            profile.lastConnectedAt = Self.later(local.lastConnectedAt, imported.lastConnectedAt)
            return profile
        case .keepBoth:
            var copy = imported
            copy.id = keepBothID
            copy.name = imported.displayName + " (imported)"
            if !isAuthenticated { copy.mcpAllowPrivilegedAccount = false }
            return copy
        }
    }

    /// New profiles and copies receive the imported secrets; *Use imported* replaces local ones; otherwise imported
    /// secrets only fill in what this Mac does not have.
    var secretWrites: [BackupSecretWrite] {
        let target = targetID
        var writes: [BackupSecretWrite] = []
        for kind in [SecretKey.Kind.password, .sshSecret] {
            guard let value = importedSecrets.value(for: kind) else { continue }
            let existing = localSecrets?.value(for: kind)
            let shouldWrite: Bool
            switch (status, resolution) {
            case (.new, _), (.conflict, .keepBoth):
                shouldWrite = true
            case (.conflict, .useImported):
                shouldWrite = localSecrets == nil || existing != value
            default:
                shouldWrite = localSecrets != nil && existing == nil
            }
            if shouldWrite { writes.append(BackupSecretWrite(key: SecretKey(profileID: target, kind: kind), value: value)) }
        }
        return writes
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }
}

/// A secret to store in the Keychain. Descriptions and mirrors never show the value.
public struct BackupSecretWrite: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let key: SecretKey
    let value: String

    init(key: SecretKey, value: String) {
        self.key = key
        self.value = value
    }

    public var description: String { "BackupSecretWrite(\(key.profileID.uuidString).\(key.kind.rawValue), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["key": key]) }
}

// MARK: - Settings and history

public struct BackupSettingItem: Sendable, Identifiable, Equatable {
    public var id: String { key }
    public let key: String
    /// `nil` when not set on this Mac.
    public let current: BackupSettingValue?
    public let imported: BackupSettingValue
    public internal(set) var isIncluded = true

    public var isUnchanged: Bool { current == imported }
}

public struct BackupHistoryItem: Sendable {
    /// The id in the backup.
    public let profileID: UUID
    /// Redacted again, newest first.
    public let entries: [QueryHistoryEntry]
}

public struct BackupHistoryChange: Sendable, Equatable {
    /// The local profile id the entries land on.
    public let profileID: UUID
    public let newEntries: Int
    let entries: [QueryHistoryEntry]
}

// MARK: - Knowledge

public struct BackupKnowledgePlan: Sendable {
    public internal(set) var databases: [BackupDatabaseItem]
    public internal(set) var projects: [BackupProjectItem]
    /// Whether the index (clusters, databases, projects, links, tombstones) would change.
    public internal(set) var indexChanges: Bool
    let importedIndex: KnowledgeIndex
    /// The databases to merge, by key (skipped ones are left out).
    let importedDatabases: [DatabaseKey: DatabaseKnowledge]
    let localIndex: KnowledgeIndex

    public var isUnchanged: Bool {
        !indexChanges && databases.allSatisfy { $0.status == .unchanged || $0.status == .skipped }
    }

    /// `local` with the imported clusters, databases, projects (mapped onto matching local ones), links and tombstones.
    public func mergedIndex(into local: KnowledgeIndex) -> KnowledgeIndex {
        var merged = local
        mergeClusters(into: &merged)
        mergeDatabaseEntries(into: &merged)
        merged.tombstones = BackupKnowledgeMerge.mergeTombstones(local.tombstones, importedIndex.tombstones)
        let deleted = Set(merged.tombstones.map(\.id))
        let mapping = mergeProjects(into: &merged, deleted: deleted)
        mergeLinks(into: &merged, mapping: mapping, deleted: deleted)
        return merged
    }

    private func mergeClusters(into merged: inout KnowledgeIndex) {
        for cluster in importedIndex.clusters {
            if let position = merged.clusters.firstIndex(where: { $0.key == cluster.key }) {
                var entry = merged.clusters[position]
                for alias in cluster.aliases where alias != entry.key && !entry.aliases.contains(alias) {
                    entry.aliases.append(alias)
                }
                if entry.label == nil { entry.label = cluster.label }
                if entry.starrocksClusterID == nil { entry.starrocksClusterID = cluster.starrocksClusterID }
                merged.clusters[position] = entry
            } else if !merged.clusters.contains(where: { $0.aliases.contains(cluster.key) }) {
                merged.clusters.append(cluster)
            }
        }
    }

    private func mergeDatabaseEntries(into merged: inout KnowledgeIndex) {
        let skipped = Set(databases.filter { $0.status == .skipped }.map(\.key))
        var known = Set(merged.databases.map(\.id))
        let keys = importedIndex.databases.map(\.key) + importedDatabases.keys.sorted { $0.fileID < $1.fileID }
        for key in keys where !skipped.contains(key) && known.insert(key.fileID).inserted {
            merged.databases.append(KnowledgeIndex.DatabaseEntry(key: key))
            let clusterKnown = merged.clusters.contains { $0.key == key.cluster || $0.aliases.contains(key.cluster) }
            if !clusterKnown { merged.clusters.append(KnowledgeIndex.ClusterEntry(key: key.cluster)) }
        }
    }

    /// Imported project id → local project id.
    private func mergeProjects(into merged: inout KnowledgeIndex, deleted: Set<String>) -> [String: String] {
        merged.projects.removeAll { deleted.contains($0.id) }
        var existing = Set(merged.projects.map(\.id))
        var mapping: [String: String] = [:]
        for item in projects where !deleted.contains(item.id) {
            if let match = item.localMatch, existing.contains(match) {
                mapping[item.id] = match
                continue
            }
            mapping[item.id] = item.id
            guard existing.insert(item.id).inserted else { continue }
            let source = item.source
            merged.projects.append(KnowledgeIndex.Project(id: item.id, path: item.path, name: source.name, gitRemote: source.gitRemote,
                                                          addedAt: source.addedAt, addedBy: source.addedBy))
        }
        return mapping
    }

    private func mergeLinks(into merged: inout KnowledgeIndex, mapping: [String: String], deleted: Set<String>) {
        merged.links.removeAll { deleted.contains($0.project) }
        let databaseIDs = Set(merged.databases.map(\.id))
        var existing = Set(merged.links.map { LinkKey(project: $0.project, database: $0.database) })
        for link in importedIndex.links {
            guard let project = mapping[link.project], databaseIDs.contains(link.database) else { continue }
            guard existing.insert(LinkKey(project: project, database: link.database)).inserted else { continue }
            merged.links.append(KnowledgeIndex.Link(project: project, database: link.database, addedAt: link.addedAt, addedBy: link.addedBy))
        }
    }

    private struct LinkKey: Hashable {
        let project: String
        let database: String
    }

    /// Applies `newPath` to the projects it returns a path for and checks them again.
    @discardableResult
    mutating func remap(home: String, fileExists: (String) -> Bool, _ newPath: (BackupProjectItem) -> String?) -> Int {
        var count = 0
        for position in projects.indices {
            guard let path = newPath(projects[position]), path != projects[position].path, BackupPaths.isAcceptable(path) else { continue }
            projects[position].path = path
            projects[position].refresh(localProjects: localIndex.projects, home: home, fileExists: fileExists)
            count += 1
        }
        indexChanges = mergedIndex(into: localIndex) != localIndex
        return count
    }
}

public struct BackupDatabaseItem: Sendable, Identifiable {
    public enum Status: Sendable, Equatable {
        case new, merged, unchanged
        /// Not imported: this Mac's copy was written by a newer version (see the plan's warnings).
        case skipped
    }

    public var id: DatabaseKey { key }
    public let key: DatabaseKey
    public let status: Status
    public let changes: BackupKnowledgeChanges
    /// Whether a profile (local or imported) reaches the cluster; otherwise the preview offers to attach one.
    public let hasMatchingConnection: Bool
}

public struct BackupProjectItem: Sendable, Identifiable {
    /// The id in the backup.
    public var id: String { source.id }
    public var name: String { source.name }
    /// Shown to help recognise the project.
    public var gitRemote: String? { source.gitRemote }
    /// The path as stored in the backup.
    public var originalPath: String { source.path }
    /// The path to store (`~/…` under home), after any remapping.
    public internal(set) var path: String
    /// `path` under this Mac's home.
    public internal(set) var expandedPath: String
    /// No local project matches and nothing exists at `expandedPath`. The project and its links are imported anyway.
    public internal(set) var isMissing: Bool
    /// The local project it merges into (same id, path or git remote).
    public internal(set) var localMatch: String?
    let source: KnowledgeIndex.Project

    init(source: KnowledgeIndex.Project, localProjects: [KnowledgeIndex.Project], home: String, fileExists: (String) -> Bool) {
        self.source = source
        path = BackupPaths.collapsingHome(BackupPaths.expandingHome(source.path, home: home), home: home)
        expandedPath = ""
        isMissing = false
        localMatch = nil
        refresh(localProjects: localProjects, home: home, fileExists: fileExists)
    }

    mutating func refresh(localProjects: [KnowledgeIndex.Project], home: String, fileExists: (String) -> Bool) {
        expandedPath = BackupPaths.expandingHome(path, home: home)
        localMatch = Self.match(id: source.id, expandedPath: expandedPath, remote: source.gitRemote, in: localProjects, home: home)
        isMissing = localMatch == nil && !fileExists(expandedPath)
    }

    private static func match(id: String, expandedPath: String, remote: String?, in projects: [KnowledgeIndex.Project], home: String) -> String? {
        if let same = projects.first(where: { $0.id == id }) { return same.id }
        if let samePath = projects.first(where: { BackupPaths.expandingHome($0.path, home: home) == expandedPath }) { return samePath.id }
        guard let remote = normalizedRemote(remote) else { return nil }
        return projects.first { normalizedRemote($0.gitRemote) == remote }?.id
    }

    /// `https://user@GitHub.com/org/repo.git`, `git@github.com:org/repo` and `github.com/org/repo` compare equal.
    static func normalizedRemote(_ remote: String?) -> String? {
        guard var text = remote?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return nil }
        var hadScheme = false
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            hadScheme = true
        }
        let hostEnd = text.firstIndex(of: "/") ?? text.endIndex
        if let at = text[..<hostEnd].lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if !hadScheme, let colon = text.firstIndex(of: ":"), colon < (text.firstIndex(of: "/") ?? text.endIndex) {
            text.replaceSubrange(colon...colon, with: "/")
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text.isEmpty ? nil : text
    }
}
