import Foundation
import StarRocksKit

/// What the app and the `mcp` process both do with knowledge: refresh a database through one pipeline, and the user's
/// own actions (verdicts on relationships, deletions, project links).
public enum KnowledgeService {
    public enum Failure: Error, Equatable, LocalizedError {
        case unknownItem(String)
        case unknownProject(String)

        public var errorDescription: String? {
            switch self {
            case let .unknownItem(id): "No note, term, area or relationship has id \(id)."
            case let .unknownProject(id): "No linked project has id \(id)."
            }
        }
    }

    // MARK: Refresh

    /// Extracts the database, infers machine relationships from this extraction's tables and the history, and saves the
    /// merged knowledge under the lock. `partial` (the MCP tools): the account may see part of the database, so what it
    /// does not see is left as it was (`KnowledgeRefresher.apply`); the app's refresh is full.
    public static func refresh(_ key: DatabaseKey, source: some KnowledgeSchemaSource, store: KnowledgeStore, history: [QueryHistoryEntry],
                               infer: KnowledgeToolSettings.Inference, now: Date, partial: Bool = false) async throws -> KnowledgeRefresher.Report {
        let schema = try await KnowledgeExtractor.extract(database: key.database, from: source)
        var preview = try store.database(key) ?? DatabaseKnowledge(key: key)
        var scratch = KnowledgeRefresher.Report()
        KnowledgeRefresher.updateTables(schema, in: &preview, now: now, report: &scratch, partial: partial)
        let machine = infer(KnowledgeInferenceInput(schema: schema, knowledge: preview, history: history, now: now))
        let report = try store.updateDatabase(key) { knowledge in
            KnowledgeRefresher.apply(schema, machineRelationships: machine, to: &knowledge, now: now, partial: partial)
        }
        if let clusterID = schema.clusterHints?.clusterID {
            try store.updateIndex { index in
                if let position = index.clusters.firstIndex(where: { $0.key == key.cluster }) { index.clusters[position].starrocksClusterID = clusterID }
            }
        }
        return report
    }

    /// Editor history of every saved profile that reaches the cluster, directly or through an alias the user declared.
    public static func history(for cluster: ClusterKey, profiles: [ConnectionProfile], directory: URL, store: KnowledgeStore) async -> [QueryHistoryEntry] {
        let aliases = Set(((try? store.index())?.clusters.first { $0.key == cluster }?.aliases) ?? [])
        var entries: [QueryHistoryEntry] = []
        for profile in profiles {
            let key = ClusterKey(profile: profile)
            guard key == cluster || aliases.contains(key) else { continue }
            entries += await QueryHistoryStore(directory: directory, profileID: profile.id).all()
        }
        return entries
    }

    // MARK: The user's actions

    /// Confirms or rejects a relationship with one `user` evidence item (replacing an earlier verdict) and re-binds it to
    /// the tables' current structure.
    public static func decide(_ id: String, accept: Bool, in knowledge: inout DatabaseKnowledge, now: Date) throws {
        guard let index = knowledge.relationships.firstIndex(where: { $0.id == id }) else { throw Failure.unknownItem(id) }
        var relationship = knowledge.relationships[index]
        relationship.evidence.removeAll { $0.source == .user }
        relationship.evidence.append(Evidence(source: .user, verdict: accept ? .assert : .reject, by: "user", at: now))
        relationship.status = accept ? .confirmed : .rejected
        for end in [relationship.from, relationship.to] where end.database == nil {
            if let table = knowledge.table(named: end.table) { relationship.fingerprints[end.table] = table.fingerprint }
        }
        knowledge.relationships[index] = relationship
        knowledge.tombstones.removeAll { $0.id == id }
    }

    /// Deletes notes, terms, areas or relationships, whoever wrote them, leaving tombstones so merges and refreshes do
    /// not bring them back.
    public static func delete(ids: [String], in knowledge: inout DatabaseKnowledge, now: Date) throws {
        for id in ids {
            let before = knowledge.notes.count + knowledge.terms.count + knowledge.areas.count + knowledge.relationships.count
            knowledge.notes.removeAll { $0.id == id }
            knowledge.terms.removeAll { $0.id == id }
            knowledge.areas.removeAll { $0.id == id }
            knowledge.relationships.removeAll { $0.id == id }
            let after = knowledge.notes.count + knowledge.terms.count + knowledge.areas.count + knowledge.relationships.count
            guard after < before else { throw Failure.unknownItem(id) }
            knowledge.tombstones.append(Tombstone(id: id, deletedAt: now, by: "user"))
        }
    }

    /// Links a project directory (as the user chose it) to a database; returns the project's id.
    @discardableResult
    public static func linkProject(path: String, to key: DatabaseKey, store: KnowledgeStore, home: URL, now: Date) throws -> String {
        let stored = try KnowledgeMCP.projectPath(path, home: home, isDirectory: isDirectory)
        let id = KnowledgeMCP.projectID(path: stored)
        let expanded = KnowledgeMCP.expand(stored, home: home)
        let remote = KnowledgeMCP.gitRemote(of: expanded) // outside the lock: a slow disk never holds other writers up
        try store.updateIndex { index in
            if !index.databases.contains(where: { $0.key == key }) { index.databases.append(KnowledgeIndex.DatabaseEntry(key: key)) }
            if !index.clusters.contains(where: { $0.key == key.cluster || $0.aliases.contains(key.cluster) }) {
                index.clusters.append(KnowledgeIndex.ClusterEntry(key: key.cluster))
            }
            if !index.projects.contains(where: { $0.id == id }) {
                index.projects.append(KnowledgeIndex.Project(id: id, path: stored, name: URL(fileURLWithPath: expanded).lastPathComponent,
                                                             gitRemote: remote, addedAt: now, addedBy: "user"))
            }
            if !index.links.contains(where: { $0.project == id && $0.database == key.fileID }) {
                index.links.append(KnowledgeIndex.Link(project: id, database: key.fileID, addedAt: now, addedBy: "user"))
            }
        }
        return id
    }

    public static func unlinkProject(id: String, from key: DatabaseKey, store: KnowledgeStore) throws {
        try store.updateIndex { index in index.links.removeAll { $0.project == id && $0.database == key.fileID } }
    }

    /// Points a project at its new location (another Mac, a moved checkout); its links stay.
    public static func remapProject(id: String, to path: String, store: KnowledgeStore, home: URL) throws {
        let stored = try KnowledgeMCP.projectPath(path, home: home, isDirectory: isDirectory)
        let remote = KnowledgeMCP.gitRemote(of: KnowledgeMCP.expand(stored, home: home))
        try store.updateIndex { index in
            guard let position = index.projects.firstIndex(where: { $0.id == id }) else { throw Failure.unknownProject(id) }
            index.projects[position].path = stored
            index.projects[position].gitRemote = remote ?? index.projects[position].gitRemote
        }
    }

    /// Whether a linked project's directory is on this Mac.
    public static func projectExists(_ project: KnowledgeIndex.Project, home: URL) -> Bool {
        isDirectory(KnowledgeMCP.expand(project.path, home: home))
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

extension KnowledgeStore {
    /// Deletes a database's knowledge file, its index entry and its links (tombstoned in the index).
    public func removeDatabase(_ key: DatabaseKey) throws {
        try SecureFile.createDirectory(directory)
        try FileLock.withLock(at: lockURL) {
            let url = databaseURL(key)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try updateIndex { index in
            index.databases.removeAll { $0.key == key }
            index.links.removeAll { $0.database == key.fileID }
            index.tombstones.append(Tombstone(id: key.fileID, deletedAt: Date(), by: "user"))
        }
    }
}
