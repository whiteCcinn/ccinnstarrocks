import AppKit
import CcinnStarRocksKit
import Foundation
import Observation
import StarRocksKit

/// One database's knowledge in a workspace tab: refresh, the user's verdicts on relationships, notes and glossary,
/// diagrams and linked projects. Reloads when another window or the `mcp` process writes.
@MainActor
@Observable
final class KnowledgeTabModel {
    enum Section: String, CaseIterable, Identifiable {
        case relationships = "Relationships"
        case notes = "Notes"
        case glossary = "Glossary"
        case diagram = "Diagram"
        case projects = "Projects"

        var id: String { rawValue }
    }

    enum RelationshipFilter: String, CaseIterable, Identifiable {
        case review = "To Review"
        case confirmed = "Confirmed"
        case rejected = "Rejected"
        case all = "All"

        var id: String { rawValue }
    }

    typealias Refresher = @Sendable () async throws -> KnowledgeRefresher.Report

    let key: DatabaseKey
    let store: KnowledgeStore
    let home: URL
    private let refresher: Refresher
    private let showToast: @MainActor (String, Bool) -> Void

    var knowledge: DatabaseKnowledge?
    var projects: [KnowledgeIndex.Project] = []
    var section: Section = .relationships
    var filter: RelationshipFilter = .review
    var isRefreshing = false
    var lastReport: KnowledgeRefresher.Report?
    var error: String?
    var diagramArea: String?
    var diagramText = ""

    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(key: DatabaseKey, store: KnowledgeStore = KnowledgeStore(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
         refresher: @escaping Refresher, showToast: @escaping @MainActor (String, Bool) -> Void = { _, _ in }) {
        self.key = key
        self.store = store
        self.home = home
        self.refresher = refresher
        self.showToast = showToast
    }

    /// The tab for `database` on the workspace's connection.
    convenience init(workspace: WorkspaceModel, database: String) {
        let key = DatabaseKey(cluster: ClusterKey(profile: workspace.profile), catalog: SQLText.defaultCatalog, database: database)
        let store = KnowledgeStore()
        let client = workspace.client
        let profiles = AppServices.shared.profiles.profiles
        let historyDirectory = AppServices.shared.historyDirectory
        self.init(key: key, store: store, refresher: {
            let history = await KnowledgeService.history(for: key.cluster, profiles: profiles, directory: historyDirectory, store: store)
            return try await KnowledgeService.refresh(key, source: client, store: store, history: history, infer: KnowledgeInference.machineRelationships,
                                                      now: Date())
        }, showToast: { [weak workspace] message, isError in workspace?.showToast(message, isError: isError) })
    }

    var title: String { "Knowledge" }

    // MARK: Loading

    func load() async {
        let (store, key) = (store, key)
        do {
            let (knowledge, index) = try await Task.detached(priority: .userInitiated) { () -> (DatabaseKnowledge?, KnowledgeIndex) in
                (try store.database(key), try store.index())
            }.value
            self.knowledge = knowledge
            let linked = Set(index.links.filter { $0.database == key.fileID }.map(\.project))
            projects = index.projects.filter { linked.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
            if diagramArea == nil { diagramArea = areas.first?.name }
            renderDiagram()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reloads when files in the knowledge folder change (the `mcp` process or another window wrote).
    func startWatching() {
        guard watcher == nil else { return }
        try? SecureFile.createDirectory(store.directory.appendingPathComponent("databases", isDirectory: true))
        let descriptor = open(store.directory.appendingPathComponent("databases").path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        reloadTask?.cancel()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let report = try await refresher()
            lastReport = report
            await load()
            showToast("Knowledge refreshed: \(report.tables.total) tables, \(report.relationships.added) new relationships", false)
        } catch {
            showToast("Refresh failed: \(error.localizedDescription)", true)
        }
    }

    // MARK: Derived

    var confidence: @Sendable (Relationship) -> Int { { RelationshipConfidence.score($0) } }

    var areas: [SubjectAreas.Area] {
        guard let knowledge else { return [] }
        return SubjectAreas.areas(in: knowledge, confidence: confidence).filter { $0.tables.count <= MermaidERDRenderer.hardLimit }
    }

    /// Relationships for the chosen filter, strongest first; lineage is shown in diagrams only.
    var relationships: [Relationship] {
        guard let knowledge else { return [] }
        let candidates = knowledge.relationships.filter { $0.kind != .lineage }
        let filtered = candidates.filter { (relationship: Relationship) -> Bool in
            let hasUserVerdict = relationship.evidence.contains { $0.source == .user }
            switch filter {
            case .review: return !hasUserVerdict && !relationship.evidence.contains { $0.source == .declared }
            case .confirmed: return relationship.status == .confirmed || relationship.evidence.contains { $0.source == .declared }
            case .rejected: return relationship.status == .rejected
            case .all: return true
            }
        }
        let score = confidence
        return filtered.sorted { (left: Relationship, right: Relationship) -> Bool in
            let leftScore = score(left)
            let rightScore = score(right)
            return leftScore != rightScore ? leftScore > rightScore : left.id < right.id
        }
    }

    func state(of relationship: Relationship) -> String {
        guard let knowledge else { return "" }
        if KnowledgeFreshness.isBroken(relationship, in: knowledge) { return "broken" }
        return KnowledgeFreshness.isStale(relationship, in: knowledge) ? "stale" : "fresh"
    }

    func isStale(_ note: Note) -> Bool {
        knowledge.map { KnowledgeFreshness.isStale(note, in: $0) } ?? false
    }

    func projectExists(_ project: KnowledgeIndex.Project) -> Bool {
        KnowledgeService.projectExists(project, home: home)
    }

    // MARK: The user's actions

    func decide(_ relationship: Relationship, accept: Bool) {
        update { try KnowledgeService.decide(relationship.id, accept: accept, in: &$0, now: Date()) }
    }

    func delete(_ id: String) {
        update { try KnowledgeService.delete(ids: [id], in: &$0, now: Date()) }
    }

    private func update(_ change: (inout DatabaseKnowledge) throws -> Void) {
        do {
            try store.updateDatabase(key, change)
            Task { await load() }
        } catch {
            showToast(error.localizedDescription, true)
        }
    }

    func link(path: String) {
        do {
            try KnowledgeService.linkProject(path: path, to: key, store: store, home: home, now: Date())
            Task { await load() }
        } catch {
            showToast(error.localizedDescription, true)
        }
    }

    func unlink(_ project: KnowledgeIndex.Project) {
        do {
            try KnowledgeService.unlinkProject(id: project.id, from: key, store: store)
            Task { await load() }
        } catch {
            showToast(error.localizedDescription, true)
        }
    }

    func remap(_ project: KnowledgeIndex.Project, to path: String) {
        do {
            try KnowledgeService.remapProject(id: project.id, to: path, store: store, home: home)
            Task { await load() }
        } catch {
            showToast(error.localizedDescription, true)
        }
    }

    /// Asks for a directory (link or remap).
    func chooseDirectory(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func renderDiagram() {
        guard let knowledge, let name = diagramArea, let area = areas.first(where: { $0.name == name }) else {
            diagramText = ""
            return
        }
        do {
            diagramText = try MermaidERDRenderer.render(tables: area.tables, in: knowledge, confidence: confidence, title: area.name,
                                                        maxTables: MermaidERDRenderer.hardLimit).mermaid
        } catch {
            diagramText = "%% " + (error.localizedDescription)
        }
    }
}
