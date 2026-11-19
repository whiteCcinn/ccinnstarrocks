import Foundation

/// What this Mac holds of what a backup covers, as the planner compares against it.
public struct BackupLocalState: Sendable {
    public var profiles: [ConnectionProfile]
    public var knowledgeIndex: KnowledgeIndex
    public var knowledgeDatabases: [DatabaseKey: DatabaseKnowledge]
    /// Databases whose local file this version cannot rewrite (a newer schema, or unreadable).
    public var unwritableDatabases: Set<DatabaseKey>
    /// `false` when the local index was written by a newer version or cannot be read.
    public var isKnowledgeWritable = true
    public var settings: [String: BackupSettingValue]
    public var history: [UUID: [QueryHistoryEntry]]
    /// Secrets of matched profiles, read only when the backup carries secrets.
    public var secrets: [UUID: BackupProfileSecrets]
    /// Profiles whose secrets could not be read; imported ones never silently replace them.
    public var unreadableSecrets: Set<UUID> = []
    public var warnings: [BackupWarning] = []

    public init(profiles: [ConnectionProfile], knowledgeIndex: KnowledgeIndex = KnowledgeIndex(),
                knowledgeDatabases: [DatabaseKey: DatabaseKnowledge] = [:], unwritableDatabases: Set<DatabaseKey> = [],
                settings: [String: BackupSettingValue] = [:], history: [UUID: [QueryHistoryEntry]] = [:],
                secrets: [UUID: BackupProfileSecrets] = [:]) {
        self.profiles = profiles
        self.knowledgeIndex = knowledgeIndex
        self.knowledgeDatabases = knowledgeDatabases
        self.unwritableDatabases = unwritableDatabases
        self.settings = settings
        self.history = history
        self.secrets = secrets
    }

    /// Reads only what `bundle` needs: knowledge of its databases, history and secrets of the profiles it matches.
    /// Secrets are read only when the backup carries some (each read may ask for Keychain access).
    public static func load(for bundle: BackupBundle, profiles: [ConnectionProfile], knowledge: KnowledgeStore, historyDirectory: URL,
                            settings: [String: BackupSettingValue], secretStore: any SecretStore) -> BackupLocalState {
        var state = BackupLocalState(profiles: profiles, settings: settings)
        let matches = BackupImportPlanner.matches(imported: bundle.payload.profiles, local: profiles)
        if let section = bundle.payload.knowledge {
            state.loadKnowledge(section, from: knowledge)
        }
        if bundle.payload.history != nil {
            for match in matches.values {
                state.history[match.profile.id] = (try? BackupHistoryFiles.read(for: match.profile.id, in: historyDirectory)) ?? []
            }
        }
        for (importedID, match) in matches where bundle.secrets[importedID]?.isEmpty == false {
            state.loadSecrets(of: match.profile.id, from: secretStore)
        }
        if !state.unreadableSecrets.isEmpty { state.warnings.append(.secretsNotChecked) }
        return state
    }

    private mutating func loadKnowledge(_ section: BackupKnowledge, from store: KnowledgeStore) {
        do {
            knowledgeIndex = try store.index()
            isKnowledgeWritable = knowledgeIndex.schemaVersion <= KnowledgeStore.schemaVersion
        } catch {
            isKnowledgeWritable = false
        }
        for database in section.databases {
            do {
                guard let local = try store.database(database.key) else { continue }
                if local.schemaVersion > KnowledgeStore.schemaVersion {
                    unwritableDatabases.insert(database.key)
                } else {
                    knowledgeDatabases[database.key] = local
                }
            } catch {
                unwritableDatabases.insert(database.key)
            }
        }
    }

    private mutating func loadSecrets(of profileID: UUID, from store: any SecretStore) {
        do {
            let password = try store.secret(for: SecretKey(profileID: profileID, kind: .password))
            let sshSecret = try store.secret(for: SecretKey(profileID: profileID, kind: .sshSecret))
            secrets[profileID] = BackupProfileSecrets(password: password, sshSecret: sshSecret)
        } catch {
            unreadableSecrets.insert(profileID)
        }
    }
}

/// Plans an import: pure, from a decoded backup, this Mac's state, its home directory and a file-existence check.
public enum BackupImportPlanner {
    public static func plan(_ bundle: BackupBundle, local: BackupLocalState, home: String, fileExists: (String) -> Bool,
                            makeID: () -> UUID = UUID.init) -> BackupImportPlan {
        var warnings = bundle.warnings + local.warnings
        let profiles = planProfiles(bundle, local: local, home: home, fileExists: fileExists, makeID: makeID)
        let knowledge = bundle.payload.knowledge.map { (section: BackupKnowledge) -> BackupKnowledgePlan in
            planKnowledge(section, profiles: bundle.payload.profiles, local: local, home: home, fileExists: fileExists, warnings: &warnings)
        }
        let settings = planSettings(bundle.payload.settings ?? [:], local: local.settings, warnings: &warnings)
        let history = (bundle.payload.history ?? []).map { (group: BackupHistory) -> BackupHistoryItem in
            BackupHistoryItem(profileID: group.profile, entries: group.entries.map(BackupHistoryFiles.sanitized))
        }
        return BackupImportPlan(isAuthenticated: bundle.isAuthenticated, profiles: profiles, knowledge: knowledge, settings: settings,
                                history: history, warnings: warnings, localHistory: local.history)
    }

    // MARK: Profiles

    struct ProfileMatch {
        let profile: ConnectionProfile
        let kind: BackupProfileItem.Match
    }

    /// Imported id → the local profile it matches: by id first, then by endpoint. Each local profile matches once.
    static func matches(imported: [ConnectionProfile], local: [ConnectionProfile]) -> [UUID: ProfileMatch] {
        var byID: [UUID: ConnectionProfile] = [:]
        var byEndpoint: [EndpointKey: [ConnectionProfile]] = [:]
        for profile in local {
            if byID[profile.id] == nil { byID[profile.id] = profile }
            byEndpoint[EndpointKey(profile), default: []].append(profile)
        }
        var result: [UUID: ProfileMatch] = [:]
        var used = Set<UUID>()
        for profile in imported {
            guard let match = byID[profile.id] else { continue }
            result[profile.id] = ProfileMatch(profile: match, kind: .id)
            used.insert(match.id)
        }
        for profile in imported where result[profile.id] == nil {
            let candidates = byEndpoint[EndpointKey(profile)] ?? []
            guard let match = candidates.first(where: { !used.contains($0.id) }) else { continue }
            result[profile.id] = ProfileMatch(profile: match, kind: .endpoint)
            used.insert(match.id)
        }
        return result
    }

    /// Where a profile's credentials go: the endpoint plus the SSH port, user and authentication. A change sends the
    /// stored password, or the SSH secret as a password, somewhere it was not given for.
    struct RouteKey: Hashable {
        let endpoint: EndpointKey
        let sshPort: Int?
        let sshUsername: String?
        let sshAuthentication: String?

        init(_ profile: ConnectionProfile) {
            endpoint = EndpointKey(profile)
            sshPort = profile.ssh?.port
            sshUsername = profile.ssh.map { $0.username.trimmingCharacters(in: .whitespaces) }
            sshAuthentication = profile.ssh?.authentication.rawValue
        }
    }

    /// Host (normalized like `ClusterKey`), port, user name and SSH host: what makes two profiles the same account.
    struct EndpointKey: Hashable {
        let host: String
        let port: Int
        let username: String
        let sshHost: String?

        init(_ profile: ConnectionProfile) {
            host = ClusterKey.normalized(profile.host)
            port = profile.port
            username = profile.username.trimmingCharacters(in: .whitespaces)
            sshHost = profile.ssh.map { ClusterKey.normalized($0.host) }
        }
    }

    private static func planProfiles(_ bundle: BackupBundle, local: BackupLocalState, home: String, fileExists: (String) -> Bool,
                                     makeID: () -> UUID) -> [BackupProfileItem] {
        let matches = matches(imported: bundle.payload.profiles, local: local.profiles)
        return bundle.payload.profiles.map { (raw: ConnectionProfile) -> BackupProfileItem in
            let match = matches[raw.id]
            let localProfile = match?.profile
            var candidate = withPortablePaths(raw, home: home)
            if !bundle.isAuthenticated {
                candidate.mcpAllowPrivilegedAccount = false
                if let localProfile { candidate = candidate.keepingPrivilegedOptIn(from: localProfile) }
            }
            let importedSecrets = bundle.secrets[raw.id] ?? BackupProfileSecrets()
            let localSecrets = localProfile.flatMap { (profile: ConnectionProfile) -> BackupProfileSecrets? in
                local.unreadableSecrets.contains(profile.id) ? nil : (local.secrets[profile.id] ?? BackupProfileSecrets())
            }
            let contentMatches = localProfile.map { sameContent(candidate, withPortablePaths($0, home: home)) } ?? false
            let secretsDiffer = localSecrets.map { secretsConflict(importedSecrets, $0) } ?? false

            var flags = Set<BackupProfileItem.Flag>()
            if raw.mcpAllowPrivilegedAccount && !candidate.mcpAllowPrivilegedAccount { flags.insert(.privilegedOptInReset) }
            if aiAccessDiffers(candidate, localProfile) { flags.insert(.aiAccessChanged) }
            if secretsDiffer { flags.insert(.secretsDiffer) }
            if isKeyMissing(candidate, home: home, fileExists: fileExists) { flags.insert(.missingSSHKey) }
            if let localProfile {
                if RouteKey(candidate) != RouteKey(localProfile) { flags.insert(.endpointChanged) }
                if candidate.allowCleartextPassword && !localProfile.allowCleartextPassword { flags.insert(.cleartextPasswordEnabled) }
                if localProfile.confirmMutations && !candidate.confirmMutations { flags.insert(.mutationConfirmationDisabled) }
            }

            let status: BackupProfileItem.Status
            if localProfile == nil {
                status = .new
            } else if contentMatches && !secretsDiffer {
                status = .unchanged
            } else {
                status = .conflict
            }
            let weakens = localProfile.map { weakensSecurity(candidate, over: $0, flags: flags) } ?? false
            let resolution = defaultResolution(status: status, imported: candidate, local: localProfile, weakensSecurity: weakens,
                                               isAuthenticated: bundle.isAuthenticated)
            return BackupProfileItem(imported: candidate, local: localProfile, match: match?.kind, status: status, defaultResolution: resolution,
                                     resolution: resolution, keepBothID: makeID(), flags: flags, contentMatches: contentMatches,
                                     isAuthenticated: bundle.isAuthenticated, importedSecrets: importedSecrets, localSecrets: localSecrets)
        }
    }

    private static func defaultResolution(status: BackupProfileItem.Status, imported: ConnectionProfile, local: ConnectionProfile?,
                                          weakensSecurity: Bool, isAuthenticated: Bool) -> BackupProfileItem.Resolution {
        switch status {
        case .new: return .useImported
        case .unchanged: return .keepMine
        case .conflict:
            // Anyone could have written an unauthenticated backup, its `updatedAt` included: it never wins by default
            // when it would send the local password elsewhere or loosen a safeguard.
            if weakensSecurity && !isAuthenticated { return .keepMine }
            guard let importedDate = imported.updatedAt, let localDate = local?.updatedAt else { return .keepMine }
            return importedDate > localDate ? .useImported : .keepMine
        }
    }

    /// Another endpoint, more AI access, the privileged opt-in, cleartext passwords or no mutation confirmation.
    private static func weakensSecurity(_ imported: ConnectionProfile, over local: ConnectionProfile, flags: Set<BackupProfileItem.Flag>) -> Bool {
        let flagged: Bool = flags.contains(.endpointChanged) || flags.contains(.cleartextPasswordEnabled) || flags.contains(.mutationConfirmationDisabled)
        let moreAccess: Bool = accessRank(imported.mcpAccess) > accessRank(local.mcpAccess)
        let optIn: Bool = imported.mcpAllowPrivilegedAccount && !local.mcpAllowPrivilegedAccount
        return flagged || moreAccess || optIn
    }

    private static func accessRank(_ access: MCPAccess) -> Int {
        switch access {
        case .disabled: 0
        case .readOnly: 1
        case .readWrite: 2
        }
    }

    /// The SSH key path written `~/…` under this Mac's home.
    static func withPortablePaths(_ profile: ConnectionProfile, home: String) -> ConnectionProfile {
        guard let path = profile.ssh?.privateKeyPath, !path.isEmpty else { return profile }
        var copy = profile
        copy.ssh?.privateKeyPath = BackupPaths.collapsingHome(path, home: home)
        return copy
    }

    /// Equal apart from id and timestamps (created, last connected, saved), which differ between Macs and with use.
    static func sameContent(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        var other = rhs
        other.id = lhs.id
        other.createdAt = lhs.createdAt
        other.lastConnectedAt = lhs.lastConnectedAt
        other.updatedAt = lhs.updatedAt
        return lhs == other
    }

    /// Both sides have a secret of the same kind and they differ. A secret missing here is filled in, not a conflict.
    private static func secretsConflict(_ imported: BackupProfileSecrets, _ local: BackupProfileSecrets) -> Bool {
        for kind in [SecretKey.Kind.password, .sshSecret] {
            guard let importedValue = imported.value(for: kind), let localValue = local.value(for: kind) else { continue }
            if importedValue != localValue { return true }
        }
        return false
    }

    private static func aiAccessDiffers(_ imported: ConnectionProfile, _ local: ConnectionProfile?) -> Bool {
        guard let local else { return imported.mcpAccess != .disabled || imported.mcpAllowPrivilegedAccount }
        return imported.mcpAccess != local.mcpAccess || imported.mcpAllowPrivilegedAccount != local.mcpAllowPrivilegedAccount
    }

    private static func isKeyMissing(_ profile: ConnectionProfile, home: String, fileExists: (String) -> Bool) -> Bool {
        guard let ssh = profile.ssh, ssh.authentication == .privateKey, let path = ssh.privateKeyPath, !path.isEmpty else { return false }
        return !fileExists(BackupPaths.expandingHome(path, home: home))
    }

    // MARK: Knowledge

    private static func planKnowledge(_ section: BackupKnowledge, profiles: [ConnectionProfile], local: BackupLocalState, home: String,
                                      fileExists: (String) -> Bool, warnings: inout [BackupWarning]) -> BackupKnowledgePlan {
        if !local.isKnowledgeWritable { warnings.append(.localKnowledgeNotWritable) }
        let reachable = reachableClusters(local.profiles + profiles, index: section.index, localIndex: local.knowledgeIndex)
        var databases: [BackupDatabaseItem] = []
        var importable: [DatabaseKey: DatabaseKnowledge] = [:]
        for imported in section.databases {
            let key = imported.key
            let isReachable = reachable.contains(key.cluster)
            guard local.isKnowledgeWritable, !local.unwritableDatabases.contains(key) else {
                if local.isKnowledgeWritable { warnings.append(.localDatabaseNotWritable(key)) }
                databases.append(BackupDatabaseItem(key: key, status: .skipped, changes: BackupKnowledgeChanges(), hasMatchingConnection: isReachable))
                continue
            }
            let existing = local.knowledgeDatabases[key]
            let (merged, changes) = BackupKnowledgeMerge.merge(local: existing, imported: imported)
            let status: BackupDatabaseItem.Status
            if existing == nil {
                status = .new
            } else if merged == existing {
                status = .unchanged
            } else {
                status = .merged
            }
            importable[key] = imported
            databases.append(BackupDatabaseItem(key: key, status: status, changes: changes, hasMatchingConnection: isReachable))
        }
        let deletedLocally = Set(local.knowledgeIndex.tombstones.map(\.id))
        let projects = section.index.projects.filter { !deletedLocally.contains($0.id) }.map { (project: KnowledgeIndex.Project) -> BackupProjectItem in
            BackupProjectItem(source: project, localProjects: local.knowledgeIndex.projects, home: home, fileExists: fileExists)
        }
        var plan = BackupKnowledgePlan(databases: databases, projects: projects, indexChanges: false, importedIndex: section.index,
                                       importedDatabases: importable, localIndex: local.knowledgeIndex)
        if local.isKnowledgeWritable {
            plan.indexChanges = plan.mergedIndex(into: local.knowledgeIndex) != local.knowledgeIndex
        }
        return plan
    }

    /// Clusters some profile reaches, with the aliases either index declares for them.
    private static func reachableClusters(_ profiles: [ConnectionProfile], index: KnowledgeIndex, localIndex: KnowledgeIndex) -> Set<ClusterKey> {
        var reachable = Set(profiles.map { ClusterKey(profile: $0) })
        for cluster in index.clusters + localIndex.clusters {
            let group = [cluster.key] + cluster.aliases
            if group.contains(where: { reachable.contains($0) }) { reachable.formUnion(group) }
        }
        return reachable
    }

    // MARK: Settings

    private static func planSettings(_ imported: [String: BackupSettingValue], local: [String: BackupSettingValue],
                                     warnings: inout [BackupWarning]) -> [BackupSettingItem] {
        var items: [BackupSettingItem] = []
        for key in BackupSettings.keys {
            guard let value = imported[key] else { continue }
            guard BackupSettings.accepts(value, forKey: key) else {
                warnings.append(.invalidSetting(key))
                continue
            }
            items.append(BackupSettingItem(key: key, current: local[key], imported: value))
        }
        for key in imported.keys.sorted() where !BackupSettings.isWhitelisted(key) {
            warnings.append(.unsupportedSetting(key))
        }
        return items
    }
}
