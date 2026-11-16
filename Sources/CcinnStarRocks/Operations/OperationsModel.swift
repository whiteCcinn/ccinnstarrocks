import CcinnStarRocksKit
import Foundation
import Observation
import StarRocksKit

/// Cluster operations: what is running now, sessions, loads, routine loads, task runs, schema
/// changes and nodes. Refreshes the visible section periodically while auto-refresh is on.
@MainActor
@Observable
final class OperationsModel {
    enum Section: String, CaseIterable, Identifiable {
        case running = "Running Now"
        case sessions = "Sessions"
        case loads = "Loads"
        case routineLoads = "Routine Loads"
        case taskRuns = "Task Runs"
        case schemaChanges = "Schema Changes"
        case cluster = "Cluster"
        case configuration = "Configuration"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .running: "bolt.horizontal.circle"
            case .sessions: "person.2"
            case .loads: "tray.and.arrow.down"
            case .routineLoads: "arrow.triangle.2.circlepath.circle"
            case .taskRuns: "checklist"
            case .schemaChanges: "hammer"
            case .cluster: "server.rack"
            case .configuration: "slider.horizontal.3"
            }
        }
    }

    unowned let workspace: WorkspaceModel
    var section: Section { didSet { if section != oldValue { refreshUnlessBatching() } } }
    /// Database filter for loads, routine loads, task runs and schema changes (`nil` = all; for loads, all user databases).
    var database: String? { didSet { if database != oldValue { refreshUnlessBatching() } } }
    var autoRefresh = true { didSet { autoRefresh ? startAutoRefresh() : stopAutoRefresh() } }
    var lastRefreshed: Date?
    private(set) var isRefreshing = false

    /// Keyword, field, type and state of the Loads list; `database` above completes it.
    var loadFilter = LoadFilter() { didSet { loadFilterChanged(from: oldValue) } }
    /// Also search `_statistics_.loads_history` (not auto-refreshed: the table can be large).
    var includeLoadHistory = false { didSet { if includeLoadHistory != oldValue { refreshUnlessBatching() } } }
    var configurationScope: ConfigItem.Scope = .variables { didSet { if configurationScope != oldValue { refreshUnlessBatching() } } }
    var configurationSearch = ""
    var configurationModifiedOnly = false

    var activity: Loadable<ActivitySnapshot> = .idle
    var sessions: Loadable<[SessionProcess]> = .idle
    var loads: Loadable<LoadSearchResult> = .idle
    var configuration: [ConfigItem.Scope: Loadable<[ConfigItem]>] = [:]
    var routineLoads: Loadable<[RoutineLoadJob]> = .idle
    var taskRuns: Loadable<[TaskRun]> = .idle
    var alterJobs: Loadable<[AlterJob]> = .idle
    var nodes: Loadable<[ClusterNode]> = .idle
    var pendingAction: PendingAction?

    struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let run: @MainActor () async throws -> Void
    }

    private var refreshTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var keywordDebounce: Task<Void, Never>?
    private var isBatching = false

    init(workspace: WorkspaceModel, section: Section, database: String? = nil, loadFilter: LoadFilter = LoadFilter()) {
        self.workspace = workspace
        // `section` is the last property without a default: assigned after it, the others would already go through
        // their observers and refresh several times.
        self.database = database
        self.loadFilter = loadFilter
        self.section = section
        refresh()
        startAutoRefresh()
    }

    var client: StarRocksClient { workspace.client }

    /// The Loads filter as sent to the server (the shared database picker included).
    var effectiveLoadFilter: LoadFilter {
        var filter = loadFilter
        filter.database = database
        return filter
    }

    /// Switches section and, for Loads, the database and type in one step, so only one refresh is sent
    /// (a superseded refresh would be cancelled mid-query and cost a `KILL QUERY`).
    func show(_ section: Section, database: String? = nil, loadType: String? = nil, setsLoadScope: Bool = false) {
        isBatching = true
        self.section = section
        if setsLoadScope {
            self.database = database
            loadFilter = LoadFilter(field: loadFilter.field, type: loadType)
        }
        isBatching = false
        refresh()
    }

    private func refreshUnlessBatching() {
        if !isBatching { refresh() }
    }

    /// Typing refreshes after a pause (the view filters the rows it has meanwhile); pickers refresh at once. Changes
    /// that leave the query as it was (the field scope of an empty search) send nothing.
    private func loadFilterChanged(from old: LoadFilter) {
        guard loadFilter != old, !isBatching, section == .loads else { return }
        var previous = old
        previous.database = database
        guard effectiveLoadFilter.sql(from: "information_schema.loads") != previous.sql(from: "information_schema.loads") else { return }
        keywordDebounce?.cancel()
        guard loadFilter.normalizedKeyword != old.normalizedKeyword else {
            refresh()
            return
        }
        keywordDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private var userDatabases: [String] {
        if let database { return [database] }
        return workspace.databases.filter { !["_statistics_", "information_schema", "sys"].contains($0) }
    }

    // MARK: Refresh

    /// `fromTimer` refreshes are skipped while one is still running, so slow clusters are never
    /// interrupted half-way (which would leave the view loading forever).
    func refresh(fromTimer: Bool = false) {
        if fromTimer, isRefreshing || !refreshesOnTimer { return }
        refreshTask?.cancel()
        keywordDebounce?.cancel()
        let section = section
        isRefreshing = true
        refreshTask = Task {
            defer { if !Task.isCancelled { isRefreshing = false } }
            switch section {
            case .running:
                if activity.value == nil { activity = .loading }
                let snapshot = await client.activity(databases: userDatabases)
                guard !Task.isCancelled else { return }
                activity = .loaded(snapshot)
            case .sessions:
                await load({ self.sessions = $0 }, keep: sessions.value) { try await self.client.processList() }
            case .loads:
                let (filter, includeHistory) = (effectiveLoadFilter, includeLoadHistory)
                await load({ self.loads = $0 }, keep: loads.value) { try await self.client.searchLoads(filter, includeHistory: includeHistory) }
            case .routineLoads:
                let database = database
                await load({ self.routineLoads = $0 }, keep: routineLoads.value) { try await self.client.routineLoads(database: database) }
            case .taskRuns:
                let database = database
                await load({ self.taskRuns = $0 }, keep: taskRuns.value) { try await self.client.taskRuns(database: database, limit: 300) }
            case .schemaChanges:
                let databases = userDatabases
                await load({ self.alterJobs = $0 }, keep: alterJobs.value) {
                    var jobs: [AlterJob] = []
                    for database in databases.prefix(64) { jobs += try await self.client.alterJobs(database: database) }
                    return jobs.sorted { ($0.createTime ?? "") > ($1.createTime ?? "") }
                }
            case .cluster:
                await load({ self.nodes = $0 }, keep: nodes.value) { try await self.client.nodes() }
            case .configuration:
                let scope = configurationScope
                await load({ self.configuration[scope] = $0 }, keep: configuration[scope]?.value) {
                    switch scope {
                    case .variables: try await self.client.variables()
                    case .frontend: try await self.client.frontendConfig()
                    case .backend: try await self.client.backendConfig()
                    }
                }
            }
            if !Task.isCancelled { lastRefreshed = Date() }
        }
    }

    /// Shows a spinner only on the first load; later refreshes swap data in place.
    private func load<Value>(_ assign: (Loadable<Value>) -> Void, keep current: Value?, _ body: () async throws -> Value) async {
        if current == nil { assign(.loading) }
        do {
            let value = try await body()
            guard !Task.isCancelled else { return }
            assign(.loaded(value))
        } catch {
            guard !Task.isCancelled else { return }
            assign(.failed(describe(error)))
        }
    }

    /// Settings rarely change and history scans a table, so neither is polled.
    var refreshesOnTimer: Bool {
        switch section {
        case .configuration: false
        case .loads: !includeLoadHistory
        default: true
        }
    }

    func startAutoRefresh() {
        guard autoRefresh, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.autoRefresh else { return }
                self.refresh(fromTimer: true)
            }
        }
    }

    func stopAutoRefresh() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Stops everything when the tab closes.
    func close() {
        stopAutoRefresh()
        refreshTask?.cancel()
        keywordDebounce?.cancel()
    }

    // MARK: Actions

    func confirmKill(_ process: SessionProcess, connection: Bool) {
        let id = process.connectionID
        pendingAction = PendingAction(
            title: (connection ? "Kill connection \(id)" : "Stop the query on connection \(id)") + (process.frontend.map { " on \($0)?" } ?? "?"),
            message: process.statement.map { String($0.prefix(300)) } ?? "\(process.user ?? "") @ \(process.host ?? "")",
            confirmLabel: connection ? "Kill Connection" : "Kill Query") { [client] in
                if connection {
                    try await client.killConnection(id, frontend: process.frontend)
                } else {
                    try await client.killQuery(connectionID: id, frontend: process.frontend)
                }
            }
    }

    func confirmCancelLoad(_ job: LoadJob) {
        guard job.canCancel, let database = job.database else { return }
        pendingAction = PendingAction(title: "Cancel load \(job.label)?", message: "The load job is aborted and its data is not committed.",
                                      confirmLabel: "Cancel Load") { [client] in
            try await client.cancelLoad(database: database, label: job.label)
        }
    }

    func confirm(_ action: RoutineLoadAction, _ job: RoutineLoadJob) {
        guard let database = job.database else { return }
        let message = switch action {
        case .pause: "Consumption pauses until the job is resumed."
        case .resume: "The job resumes consuming from its saved offsets."
        case .stop: "A stopped routine load cannot be resumed."
        }
        pendingAction = PendingAction(title: "\(action.rawValue.capitalized) routine load \(job.name)?", message: message,
                                      confirmLabel: action.rawValue.capitalized) { [client] in
            try await client.perform(action, routineLoad: job.name, database: database)
        }
    }

    func confirmCancel(_ job: AlterJob) {
        pendingAction = PendingAction(title: "Cancel \(job.kind.displayName.lowercased()) on \(job.table)?",
                                      message: "The job is rolled back; the table keeps its current schema.", confirmLabel: "Cancel Job") { [client] in
            try await client.cancelAlterJob(job)
        }
    }

    /// Opens a pre-filled statement that changes `item` in a new query tab; it is never run here.
    func editInSQLEditor(_ item: ConfigItem) {
        guard let statement = ConfigStatement.edit(for: item) else { return }
        workspace.openSQL(text: statement)
    }

    func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task {
            do {
                try await action.run()
                workspace.showToast("Done")
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
        }
    }
}
