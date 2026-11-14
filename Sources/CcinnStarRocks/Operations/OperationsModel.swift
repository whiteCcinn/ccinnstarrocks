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
            }
        }
    }

    unowned let workspace: WorkspaceModel
    var section: Section { didSet { if section != oldValue { refresh() } } }
    /// Database filter for loads, routine loads, task runs and schema changes (`nil` = all).
    var database: String? { didSet { if database != oldValue { refresh() } } }
    var autoRefresh = true { didSet { autoRefresh ? startAutoRefresh() : stopAutoRefresh() } }
    var lastRefreshed: Date?

    var activity: Loadable<ActivitySnapshot> = .idle
    var sessions: Loadable<[SessionProcess]> = .idle
    var loads: Loadable<[LoadJob]> = .idle
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

    init(workspace: WorkspaceModel, section: Section) {
        self.workspace = workspace
        self.section = section
        refresh()
        startAutoRefresh()
    }

    var client: StarRocksClient { workspace.client }

    private var userDatabases: [String] {
        if let database { return [database] }
        return workspace.databases.filter { !["_statistics_", "information_schema", "sys"].contains($0) }
    }

    // MARK: Refresh

    func refresh() {
        refreshTask?.cancel()
        let section = section
        refreshTask = Task {
            switch section {
            case .running:
                if activity.value == nil { activity = .loading }
                let snapshot = await client.activity(databases: userDatabases)
                guard !Task.isCancelled else { return }
                activity = .loaded(snapshot)
            case .sessions:
                await load({ self.sessions = $0 }, keep: sessions.value) { try await self.client.processList() }
            case .loads:
                let database = database
                await load({ self.loads = $0 }, keep: loads.value) { try await self.client.loads(database: database, limit: 500) }
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

    func startAutoRefresh() {
        guard autoRefresh, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.autoRefresh else { return }
                self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: Actions

    func confirmKill(_ process: SessionProcess, connection: Bool) {
        let id = process.connectionID
        pendingAction = PendingAction(
            title: connection ? "Kill connection \(id)?" : "Stop the query on connection \(id)?",
            message: process.statement.map { String($0.prefix(300)) } ?? "\(process.user ?? "") @ \(process.host ?? "")",
            confirmLabel: connection ? "Kill Connection" : "Kill Query") { [client] in
                if connection { try await client.killConnection(id) } else { try await client.killQuery(connectionID: id) }
            }
    }

    func confirmCancelLoad(_ job: LoadJob) {
        guard let database = job.database else { return }
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
