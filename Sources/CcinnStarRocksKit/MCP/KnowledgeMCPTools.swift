import Foundation
import StarRocksKit

/// What an account can see, per profile and database, for five minutes: knowledge built through one account never
/// shows another account tables it cannot read.
public actor KnowledgeVisibilityCache {
    private var entries: [String: (at: ContinuousClock.Instant, tables: Set<String>?)] = [:]
    private let lifetime: Duration

    public init(lifetime: Duration = .seconds(300)) {
        self.lifetime = lifetime
    }

    func tables(profile: UUID, database: String, load: () async throws -> Set<String>?) async throws -> Set<String>? {
        let key = profile.uuidString + "\u{1F}" + database
        if let entry = entries[key], ContinuousClock.now - entry.at < lifetime { return entry.tables }
        let tables = try await load()
        entries[key] = (ContinuousClock.now, tables)
        return tables
    }
}

extension StarRocksMCPTools {
    func knowledgeCall(_ name: String, _ args: Arguments, _ client: StarRocksClient, _ profile: ConnectionProfile, _ context: CallContext,
                       _ settings: KnowledgeToolSettings) async throws -> JSONValue {
        let by = "ai:" + (context.client ?? "unknown")
        if KnowledgeMCP.writeTools.contains(name) {
            guard !settings.writesDisabled, profile.mcpKnowledgeWrites else {
                throw MCPToolError("AI may not write knowledge for “\(profile.displayName)”. Turn on “AI may write knowledge” in CcinnStarRocks → Settings → MCP, or start the server without --no-knowledge-writes.")
            }
        }
        if name == "list_knowledge" { return try await listKnowledge(args, client, profile, settings) }
        let key = try knowledgeKey(args, profile, settings)
        context.detail = key.database
        switch name {
        case "refresh_knowledge":
            _ = try await visible(key.database, client, profile, settings)
            let report = try await refreshKnowledge(key, client, settings, mineHistory: args.bool("mine_history") ?? true)
            return try KnowledgeMCP.encode(report)
        case "link_project":
            _ = try await visible(key.database, client, profile, settings)
            return try linkProject(args, key: key, by: by, settings: settings, context: context)
        default:
            break
        }
        let knowledge = try await visibleKnowledge(key, client, profile, settings)
        let confidence = settings.confidence
        switch name {
        case "knowledge_overview":
            return overview(knowledge, limit: args.int("area_limit", default: 20, range: 1...50), confidence: confidence)
        case "search_knowledge":
            let scopes = (args.values["scope"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(KnowledgeSearch.Scope.init(rawValue:)) }
            let (hits, truncated) = KnowledgeSearch.search(try args.required("query"), in: knowledge,
                                                           scopes: scopes.isEmpty ? Set(KnowledgeSearch.Scope.allCases) : Set(scopes),
                                                           limit: args.int("limit", default: 20, range: 1...50))
            return ["column_format": ["type", "name", "why", "score"],
                    "results": .array(hits.map { [.string($0.type), .string($0.name), .string($0.why), .int(Int64($0.score))] }),
                    "truncated": .bool(truncated), "untrusted": .string(KnowledgeMCP.untrusted)]
        case "explain_table":
            let table = try args.required("table")
            let index = try settings.store.index()
            guard let explanation = TableExplanation.explain(table: table, in: knowledge, confidence: confidence, projects: index.projects) else {
                throw MCPToolError("No table “\(table)” in the knowledge of \(key.database) (or this account cannot see it). Use search_knowledge, or refresh_knowledge if it is new.")
            }
            guard case var .object(payload) = try KnowledgeMCP.encode(explanation) else { return .null }
            if args.bool("verify") ?? true { payload["verified"] = try await verify(explanation, key: key, client: client) }
            payload["untrusted"] = .string(KnowledgeMCP.untrusted)
            return .object(payload)
        case "find_join_path":
            let through = (args.values["through"]?.arrayValue ?? []).compactMap(\.stringValue)
            let result = JoinPathFinder.find(from: try args.required("from"), to: try args.required("to"), through: Array(through.prefix(4)), in: knowledge,
                                             confidence: confidence, maxHops: args.int("max_hops", default: 4, range: 1...6),
                                             minConfidence: args.int("min_confidence", default: 40, range: 0...100),
                                             alternatives: args.int("alternatives", default: 2, range: 1...3))
            return try KnowledgeMCP.encode(result)
        case "er_diagram":
            return try diagram(args, knowledge, confidence: confidence)
        case "add_notes":
            let items = args.values["items"]?.arrayValue ?? []
            let projects = try settings.store.index().projects
            var probe = knowledge
            _ = try KnowledgeMCP.addNotes(items, to: &probe, by: by, now: settings.now(), projects: projects, home: settings.home)
            let ids = try settings.store.updateDatabase(key) { stored in
                try KnowledgeMCP.addNotes(items, to: &stored, by: by, now: settings.now(), projects: projects, home: settings.home)
            }
            context.detail = "\(key.database): \(ids.count) note(s) " + ids.joined(separator: ", ")
            return ["added": .array(ids.map(JSONValue.string))]
        case "add_relationships":
            let items = args.values["items"]?.arrayValue ?? []
            let projects = try settings.store.index().projects
            let others = try await otherDatabaseTables(items, key: key, client: client, profile: profile, settings: settings)
            var probe = knowledge
            _ = try KnowledgeMCP.addRelationships(items, to: &probe, by: by, now: settings.now(), projects: projects, home: settings.home, otherTables: others)
            let ids = try settings.store.updateDatabase(key) { stored in
                try KnowledgeMCP.addRelationships(items, to: &stored, by: by, now: settings.now(), projects: projects, home: settings.home, otherTables: others)
            }
            context.detail = "\(key.database): \(ids.count) relationship(s) " + ids.joined(separator: ", ")
            let stored = try settings.store.database(key)
            let scores: [JSONValue] = ids.map { (id: String) -> JSONValue in
                let relationship = stored?.relationships.first { $0.id == id }
                return ["id": .string(id), "confidence": .int(Int64(relationship.map(confidence) ?? 0)),
                        "status": .string(relationship.map { KnowledgeRules.isRejected($0) ? "rejected" : $0.status.rawValue } ?? "unknown")]
            }
            return ["relationships": .array(scores)]
        case "define_terms":
            let items = args.values["items"]?.arrayValue ?? []
            var probe = knowledge
            _ = try KnowledgeMCP.defineTerms(items, in: &probe, by: by, now: settings.now())
            let ids = try settings.store.updateDatabase(key) { stored in try KnowledgeMCP.defineTerms(items, in: &stored, by: by, now: settings.now()) }
            context.detail = "\(key.database): \(ids.count) term(s)"
            return ["terms": .array(ids.map(JSONValue.string))]
        case "define_subject_area":
            let tables = (args.values["tables"]?.arrayValue ?? []).compactMap(\.stringValue)
            let name = try args.required("name")
            let remove = args.bool("remove") ?? false
            var probe = knowledge
            _ = try KnowledgeMCP.defineArea(name: name, tables: tables, description: args.string("description"), remove: remove, in: &probe, by: by, now: settings.now())
            let id = try settings.store.updateDatabase(key) { stored in
                try KnowledgeMCP.defineArea(name: name, tables: tables, description: args.string("description"), remove: remove, in: &stored, by: by, now: settings.now())
            }
            context.detail = "\(key.database): area \(name)\(remove ? " removed" : "")"
            return remove ? ["removed": .string(name)] : ["area": .string(id ?? "")]
        case "remove_knowledge":
            let ids = (args.values["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
            var probe = knowledge
            _ = try KnowledgeMCP.remove(ids: ids, from: &probe, by: by, now: settings.now())
            let removed = try settings.store.updateDatabase(key) { stored in try KnowledgeMCP.remove(ids: ids, from: &stored, by: by, now: settings.now()) }
            context.detail = "\(key.database): removed " + removed.joined(separator: ", ")
            return ["removed": .array(removed.map(JSONValue.string))]
        default:
            throw MCPToolError("Unknown tool “\(name)”.")
        }
    }

    // MARK: Identity and visibility

    /// The database's key, through a cluster alias the user declared ("same cluster as …") when there is one.
    func knowledgeKey(_ args: Arguments, _ profile: ConnectionProfile, _ settings: KnowledgeToolSettings) throws -> DatabaseKey {
        let catalog = args.string("catalog") ?? SQLText.defaultCatalog
        guard catalog == SQLText.defaultCatalog else { throw MCPToolError("Knowledge covers default_catalog in this version.") }
        return DatabaseKey(cluster: try clusterKey(profile, settings), catalog: catalog, database: try args.required("database"))
    }

    func clusterKey(_ profile: ConnectionProfile, _ settings: KnowledgeToolSettings) throws -> ClusterKey {
        let derived = ClusterKey(profile: profile)
        let index = try settings.store.index()
        return index.clusters.first { $0.key == derived || $0.aliases.contains(derived) }?.key ?? derived
    }

    func visible(_ database: String, _ client: StarRocksClient, _ profile: ConnectionProfile, _ settings: KnowledgeToolSettings) async throws -> Set<String> {
        let tables = try await visibilityCache.tables(profile: profile.id, database: database) { try await settings.visibleTables(client, database) }
        guard let tables else {
            throw MCPToolError("Database “\(database)” does not exist on this connection, or its account cannot see it.")
        }
        return tables
    }

    /// The stored knowledge (built on first use), limited to what this connection's account can see.
    func visibleKnowledge(_ key: DatabaseKey, _ client: StarRocksClient, _ profile: ConnectionProfile,
                          _ settings: KnowledgeToolSettings) async throws -> DatabaseKnowledge {
        let tables = try await visible(key.database, client, profile, settings)
        if try settings.store.database(key) == nil {
            _ = try await refreshKnowledge(key, client, settings, mineHistory: true)
        }
        guard let stored = try settings.store.database(key) else { throw MCPToolError("No knowledge could be built for \(key.database).") }
        var visibleOther: [String: Set<String>] = [:]
        let others = Set(stored.relationships.flatMap { [$0.from.database, $0.to.database].compactMap { $0 } })
        for database in others.sorted() {
            visibleOther[database] = (try? await visible(database, client, profile, settings)) ?? []
        }
        return KnowledgeMCP.filter(stored, visible: tables, visibleOther: visibleOther)
    }

    func otherDatabaseTables(_ items: [JSONValue], key: DatabaseKey, client: StarRocksClient, profile: ConnectionProfile,
                             settings: KnowledgeToolSettings) async throws -> [String: [TableFacts]] {
        var result: [String: [TableFacts]] = [:]
        let databases = Set(items.compactMap { $0.objectValue?["to_database"]?.stringValue }.filter { $0 != key.database })
        for database in databases.sorted() {
            let otherKey = DatabaseKey(cluster: key.cluster, catalog: key.catalog, database: database)
            let tables = try await visible(database, client, profile, settings)
            if try settings.store.database(otherKey) == nil { _ = try await refreshKnowledge(otherKey, client, settings, mineHistory: false) }
            result[database] = (try settings.store.database(otherKey)?.tables ?? []).filter { tables.contains($0.name) }
        }
        return result
    }

    // MARK: Refresh

    func refreshKnowledge(_ key: DatabaseKey, _ client: StarRocksClient, _ settings: KnowledgeToolSettings,
                          mineHistory: Bool) async throws -> KnowledgeRefresher.Report {
        let schema = try await KnowledgeExtractor.extract(database: key.database, from: client)
        let history = mineHistory ? await historyEntries(cluster: key.cluster, settings: settings) : []
        let now = settings.now()
        // Inference reads this extraction's table facts.
        var preview = try settings.store.database(key) ?? DatabaseKnowledge(key: key)
        var scratch = KnowledgeRefresher.Report()
        KnowledgeRefresher.updateTables(schema, in: &preview, now: now, report: &scratch)
        let machine = settings.infer(KnowledgeInferenceInput(schema: schema, knowledge: preview, history: history, now: now))
        let report = try settings.store.updateDatabase(key) { knowledge in
            KnowledgeRefresher.apply(schema, machineRelationships: machine, to: &knowledge, now: now)
        }
        if let hints = schema.clusterHints, let clusterID = hints.clusterID {
            try settings.store.updateIndex { index in
                if let position = index.clusters.firstIndex(where: { $0.key == key.cluster }) { index.clusters[position].starrocksClusterID = clusterID }
            }
        }
        return report
    }

    /// Editor history of every saved profile that reaches the cluster (structure only is ever kept from it).
    func historyEntries(cluster: ClusterKey, settings: KnowledgeToolSettings) async -> [QueryHistoryEntry] {
        let aliases = Set(((try? settings.store.index().clusters.first { $0.key == cluster }?.aliases) ?? nil) ?? [])
        var entries: [QueryHistoryEntry] = []
        for profile in resolver.profiles {
            let key = ClusterKey(profile: profile)
            guard key == cluster || aliases.contains(key) else { continue }
            entries += await QueryHistoryStore(directory: settings.historyDirectory, profileID: profile.id).all()
        }
        return entries
    }

    // MARK: Payloads

    func listKnowledge(_ args: Arguments, _ client: StarRocksClient, _ profile: ConnectionProfile, _ settings: KnowledgeToolSettings) async throws -> JSONValue {
        let index = try settings.store.index()
        let cluster = try clusterKey(profile, settings)
        var entries = index.databases.filter { $0.key.cluster == cluster }
        var projectPayload: JSONValue = .null
        if let path = args.string("project_path") {
            let target = KnowledgeMCP.expand(path, home: settings.home)
            let project = index.projects.first { (candidate: KnowledgeIndex.Project) -> Bool in
                let root = KnowledgeMCP.expand(candidate.path, home: settings.home)
                return target == root || target.hasPrefix(root + "/")
            }
            if let project {
                let linked = Set(index.links.filter { $0.project == project.id }.map(\.database))
                entries = entries.filter { linked.contains($0.id) }
                projectPayload = ["name": .string(project.name), "path": .string(project.path), "git_remote": JSONValue(project.gitRemote)]
            } else {
                entries = []
                projectPayload = ["path": .string(path), "linked": false]
            }
        }
        var rows: [JSONValue] = []
        var hidden = 0
        for entry in entries.sorted(by: { $0.key.database < $1.key.database }) {
            guard let tables = try? await visible(entry.key.database, client, profile, settings),
                  let stored = try settings.store.database(entry.key) else {
                hidden += 1
                continue
            }
            let knowledge = KnowledgeMCP.filter(stored, visible: tables)
            let live = knowledge.tables.filter { $0.state != .dropped }
            rows.append(["database": .string(entry.key.database), "catalog": .string(entry.key.catalog), "tables": .int(Int64(live.count)),
                         "changed": .int(Int64(live.filter { $0.state == .changed }.count)),
                         "relationships": .int(Int64(knowledge.relationships.filter { $0.kind != .lineage }.count)),
                         "notes": .int(Int64(knowledge.notes.count)), "terms": .int(Int64(knowledge.terms.count)),
                         "refreshed_at": JSONValue(knowledge.refreshedAt.map { ISO8601DateFormatter().string(from: $0) })])
        }
        var payload: [String: JSONValue] = ["cluster": .string(cluster.rawValue), "project": projectPayload, "databases": .array(rows),
                                            "hidden": .int(Int64(hidden))]
        if rows.isEmpty {
            payload["hint"] = "No knowledge yet. Call knowledge_overview (it builds knowledge on first use) or refresh_knowledge with a database, and link_project to link this project."
        }
        return .object(payload)
    }

    func overview(_ knowledge: DatabaseKnowledge, limit: Int, confidence: @Sendable (Relationship) -> Int) -> JSONValue {
        let live = knowledge.tables.filter { $0.state != .dropped }
        let noted = Set(knowledge.notes.map(\.table))
        let withoutNotes = live.filter { !noted.contains($0.name) && $0.kind != .systemView }.map(\.name)
        let staleNotes = knowledge.notes.filter { KnowledgeFreshness.isStale($0, in: knowledge) }.count
        let weak = knowledge.relationships.filter { (relationship: Relationship) -> Bool in
            relationship.kind != .lineage && !KnowledgeRules.isRejected(relationship) && confidence(relationship) < 60
        }
        let areas = SubjectAreas.areas(in: knowledge, confidence: confidence).prefix(limit).map { (area: SubjectAreas.Area) -> JSONValue in
            ["name": .string(area.name), "source": .string(area.source), "tables": .array(area.tables.prefix(60).map(JSONValue.string))]
        }
        return [
            "database": .string(knowledge.key.database), "tables": .int(Int64(live.count)),
            "changed": .int(Int64(live.filter { $0.state == .changed }.count)),
            "dropped": .int(Int64(knowledge.tables.count - live.count)),
            "refreshed_at": JSONValue(knowledge.refreshedAt.map { ISO8601DateFormatter().string(from: $0) }),
            "server_version": JSONValue(knowledge.serverVersion),
            "areas": .array(Array(areas)),
            "terms": .array(knowledge.terms.map { ["term": .string($0.term), "definition": .string(String($0.definition.prefix(200)))] }),
            "todo": ["tables_without_notes": .int(Int64(withoutNotes.count)), "stale_notes": .int(Int64(staleNotes)),
                     "low_confidence_relationships": .int(Int64(weak.count)), "sample": .array(withoutNotes.prefix(20).map(JSONValue.string))],
            "untrusted": .string(KnowledgeMCP.untrusted),
        ]
    }

    func verify(_ explanation: TableExplanation, key: DatabaseKey, client: StarRocksClient) async throws -> JSONValue {
        let live = try await client.columnsByTable(database: key.database, tables: [explanation.table])[explanation.table] ?? []
        let stored = explanation.columns.map { $0[0].lowercased() + " " + $0[1].lowercased() }
        let current = live.sorted { $0.ordinal < $1.ordinal }.map { (column: ColumnInfo) -> String in
            column.name.lowercased() + " " + (column.columnType.isEmpty ? column.dataType : column.columnType).lowercased()
        }
        if live.isEmpty { return ["ok": false, "note": "The table is not on the server any more; call refresh_knowledge."] }
        return stored == current ? ["ok": true] : ["ok": false, "note": "The columns on the server differ from the knowledge; call refresh_knowledge."]
    }

    func diagram(_ args: Arguments, _ knowledge: DatabaseKnowledge, confidence: @escaping @Sendable (Relationship) -> Int) throws -> JSONValue {
        let minConfidence = args.int("min_confidence", default: 40, range: 0...100)
        let areas = SubjectAreas.areas(in: knowledge, confidence: confidence)
        let live = knowledge.tables.filter { $0.state != .dropped }.map(\.name)
        var title: String
        var tables: [String]
        if let name = args.string("subject_area") {
            guard let area = areas.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw MCPToolError("No subject area “\(name)”. Areas: \(areas.prefix(20).map(\.name).joined(separator: ", ")).")
            }
            title = area.name
            tables = area.tables
        } else if let listed = args.values["tables"]?.arrayValue {
            tables = listed.compactMap(\.stringValue)
            title = "selected tables"
        } else if let center = args.string("around") {
            let depth = args.int("depth", default: 1, range: 0...2)
            tables = neighbourhood(of: center, depth: depth, in: knowledge, confidence: confidence, minConfidence: minConfidence)
            title = "around \(center)"
        } else if let prefix = args.string("prefix") {
            tables = live.filter { $0.hasPrefix(prefix) }
            title = prefix + "*"
        } else {
            throw MCPToolError("Pass one of subject_area, tables, around or prefix. Areas: \(areas.prefix(20).map(\.name).joined(separator: ", ")).")
        }
        let columns = args.string("columns").flatMap(MermaidERDRenderer.Columns.init(rawValue:)) ?? .keys
        do {
            let diagram = try MermaidERDRenderer.render(tables: tables, in: knowledge, confidence: confidence, columns: columns, minConfidence: minConfidence,
                                                        title: title, maxTables: args.int("max_tables", default: 25, range: 1...60))
            return try KnowledgeMCP.encode(diagram)
        } catch let failure as MermaidERDRenderer.Failure {
            let smaller = areas.filter { $0.tables.count <= 25 }.prefix(10).map(\.name).joined(separator: ", ")
            throw MCPToolError((failure.errorDescription ?? "Too many tables.") + (smaller.isEmpty ? "" : " Smaller areas: \(smaller)."))
        }
    }

    func neighbourhood(of center: String, depth: Int, in knowledge: DatabaseKnowledge, confidence: (Relationship) -> Int, minConfidence: Int) -> [String] {
        var seen: [String] = [center]
        var frontier: Set<String> = [center]
        for _ in 0..<depth {
            var next: Set<String> = []
            for relationship in knowledge.relationships where relationship.from.database == nil && relationship.to.database == nil {
                guard !KnowledgeRules.isRejected(relationship), relationship.kind == .lineage || confidence(relationship) >= minConfidence else { continue }
                if frontier.contains(relationship.from.table) { next.insert(relationship.to.table) }
                if frontier.contains(relationship.to.table) { next.insert(relationship.from.table) }
            }
            let fresh = next.subtracting(seen).sorted()
            seen += fresh
            frontier = Set(fresh)
        }
        return seen
    }

    func linkProject(_ args: Arguments, key: DatabaseKey, by: String, settings: KnowledgeToolSettings, context: CallContext) throws -> JSONValue {
        let path = try KnowledgeMCP.projectPath(try args.required("project_path"), home: settings.home) { (candidate: String) -> Bool in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let unlink = args.bool("unlink") ?? false
        let databaseID = key.fileID
        let projectID = KnowledgeMCP.projectID(path: path)
        let now = settings.now()
        try settings.store.updateIndex { index in
            if !index.databases.contains(where: { $0.key == key }) { index.databases.append(KnowledgeIndex.DatabaseEntry(key: key)) }
            if !index.clusters.contains(where: { $0.key == key.cluster || $0.aliases.contains(key.cluster) }) {
                index.clusters.append(KnowledgeIndex.ClusterEntry(key: key.cluster))
            }
            if unlink {
                index.links.removeAll { $0.project == projectID && $0.database == databaseID }
                return
            }
            if !index.projects.contains(where: { $0.id == projectID }) {
                let expanded = KnowledgeMCP.expand(path, home: settings.home)
                let name = args.string("name").map { KnowledgeMCP.clean($0, limit: 120) } ?? URL(fileURLWithPath: expanded).lastPathComponent
                index.projects.append(KnowledgeIndex.Project(id: projectID, path: path, name: name, gitRemote: KnowledgeMCP.gitRemote(of: expanded),
                                                             addedAt: now, addedBy: by))
            }
            if !index.links.contains(where: { $0.project == projectID && $0.database == databaseID }) {
                index.links.append(KnowledgeIndex.Link(project: projectID, database: databaseID, addedAt: now, addedBy: by))
            }
        }
        context.detail = "\(key.database) \(unlink ? "unlinked from" : "linked to") \(path)"
        return ["project": .string(path), "database": .string(key.database), "linked": .bool(!unlink)]
    }
}
