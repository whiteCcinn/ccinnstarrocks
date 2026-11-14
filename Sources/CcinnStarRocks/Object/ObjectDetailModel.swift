import CcinnStarRocksKit
import Foundation
import Observation
import StarRocksKit

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// State of one table / view / materialized view tab. Sections load lazily and independently.
@MainActor
@Observable
final class ObjectDetailModel {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case refreshes = "Refreshes"
        case columns = "Columns"
        case partitions = "Partitions"
        case tablets = "Tablets"
        case ddl = "DDL"
        case data = "Data"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: "info.circle"
            case .refreshes: "arrow.triangle.2.circlepath"
            case .columns: "list.bullet.rectangle"
            case .partitions: "square.split.bottomrightquarter"
            case .tablets: "square.grid.3x3"
            case .ddl: "doc.plaintext"
            case .data: "tablecells"
            }
        }
    }

    private(set) var object: DatabaseObject
    unowned let workspace: WorkspaceModel
    private(set) var section: Section = .overview

    var columns: Loadable<[ColumnInfo]> = .idle
    var partitions: Loadable<[PartitionInfo]> = .idle
    var storage: Loadable<[IndexStorage]> = .idle
    var tablets: Loadable<[TabletReplica]> = .idle
    var skew: SkewReport?
    var distribution: Loadable<[ReplicaShare]> = .idle
    var tabletPartition: String? { didSet { if tabletPartition != oldValue { loadTablets() } } }
    var tabletIndex: String? { didSet { if tabletIndex != oldValue { loadTablets() } } }
    var ddl: Loadable<String> = .idle
    var preview: Loadable<ResultSet> = .idle
    var previewID = UUID()
    var taskRuns: Loadable<[TaskRun]> = .idle
    var mvStatus: MaterializedViewStatus?
    var actionInFlight = false
    var inspected: InspectedValue?
    private var pollTask: Task<Void, Never>?

    init(object: DatabaseObject, workspace: WorkspaceModel) {
        self.object = object
        self.workspace = workspace
        mvStatus = object.materializedView
        load(.overview)
    }

    var client: StarRocksClient { workspace.client }

    var availableSections: [Section] {
        switch object.kind {
        case .table: [.overview, .columns, .partitions, .tablets, .ddl, .data]
        case .asyncMaterializedView: [.overview, .refreshes, .columns, .partitions, .tablets, .ddl, .data]
        case .syncMaterializedView: [.overview, .columns, .ddl]
        case .view, .systemView, .externalTable: [.overview, .columns, .ddl, .data]
        }
    }

    /// Sync MVs (rollups) built on this table.
    var rollups: [DatabaseObject] {
        guard object.kind == .table else { return [] }
        return (workspace.objects(in: object.database) ?? []).filter { $0.kind == .syncMaterializedView && $0.baseTable == object.name }
    }

    var baseTableObject: DatabaseObject? {
        object.baseTable.flatMap { workspace.object(database: object.database, name: $0) }
    }

    func select(_ section: Section) {
        guard availableSections.contains(section) else { return }
        self.section = section
        load(section)
    }

    func reload() {
        columns = .idle
        partitions = .idle
        storage = .idle
        tablets = .idle
        distribution = .idle
        ddl = .idle
        preview = .idle
        taskRuns = .idle
        if let refreshed = workspace.object(database: object.database, name: object.name) { object = refreshed }
        load(section)
    }

    func load(_ section: Section) {
        switch section {
        case .overview:
            if object.kind.hasNativeStorage {
                loadPartitions()
                if case .idle = storage { loadStorage() }
            }
            if object.kind == .asyncMaterializedView { refreshStatus() }
        case .refreshes:
            loadTaskRuns()
        case .columns:
            if case .idle = columns { loadColumns() }
        case .partitions:
            loadPartitions()
        case .tablets:
            if case .idle = partitions { loadPartitions() }
            if case .idle = tablets { loadTablets() }
            if case .idle = distribution { loadDistribution() }
        case .ddl:
            if case .idle = ddl { loadDDL() }
        case .data:
            if case .idle = preview { loadPreview() }
        }
    }

    // MARK: Loaders

    private func run<Value>(_ assign: @escaping (Loadable<Value>) -> Void, _ body: @escaping @MainActor () async throws -> Value) {
        assign(.loading)
        Task {
            do {
                assign(.loaded(try await body()))
            } catch {
                assign(.failed(describe(error)))
            }
        }
    }

    func loadColumns() {
        let object = object
        run({ self.columns = $0 }) { try await self.client.columns(of: object) }
    }

    func loadPartitions() {
        guard object.kind.hasNativeStorage, !partitions.isLoading else { return }
        let object = object
        run({ self.partitions = $0 }) { try await self.client.partitions(database: object.database, table: object.name) }
    }

    func loadStorage() {
        let object = object
        run({ self.storage = $0 }) { try await self.client.storage(database: object.database, table: object.name) }
    }

    private var tabletGeneration: UInt64 = 0

    func loadTablets() {
        guard object.kind.hasNativeStorage else { return }
        let (object, partition, index) = (object, tabletPartition, tabletIndex)
        tabletGeneration &+= 1
        let generation = tabletGeneration
        skew = nil
        run({ [weak self] state in
            // A slower earlier request (other partition/index) must not overwrite the current one.
            guard let self, self.tabletGeneration == generation else { return }
            self.tablets = state
            if case let .loaded(replicas) = state { self.skew = SkewAnalyzer.analyze(replicas) }
        }) { try await self.client.tablets(database: object.database, table: object.name, partition: partition, index: index) }
    }

    func loadDistribution() {
        let object = object
        run({ self.distribution = $0 }) { try await self.client.replicaDistribution(database: object.database, table: object.name) }
    }

    func loadDDL() {
        let object = object
        run({ self.ddl = $0 }) { try await self.client.ddl(of: object) }
    }

    func loadPreview() {
        let sql = "SELECT * FROM \(object.qualifiedName) LIMIT 200"
        run({ [weak self] state in
            self?.preview = state
            self?.previewID = UUID()
        }) {
            guard let result = try await self.client.query(sql, limits: RowLimits(maxRows: 200), timeout: 60).last else {
                throw StarRocksError(.protocolViolation, "No result")
            }
            return result
        }
    }

    func loadTaskRuns() {
        guard let taskName = mvStatus?.taskName else {
            taskRuns = .loaded([])
            return
        }
        run({ [weak self] state in
            self?.taskRuns = state
            self?.schedulePollingIfRefreshing()
        }) { try await self.client.taskRuns(taskName: taskName, limit: 100) }
    }

    // MARK: Materialized view actions

    func refreshStatus() {
        let object = object
        Task {
            if let status = try? await client.materializedViewStatus(database: object.database, name: object.name) {
                mvStatus = status
                schedulePollingIfRefreshing()
            }
        }
    }

    func refreshMaterializedView(force: Bool) {
        perform(force ? "Forced refresh started" : "Refresh started") { client, object in
            try await client.refreshMaterializedView(database: object.database, name: object.name, force: force)
        }
    }

    func cancelRefresh() {
        perform("Refresh cancelled") { client, object in
            try await client.cancelMaterializedViewRefresh(database: object.database, name: object.name)
        }
    }

    func activate() {
        perform("Materialized view activated") { client, object in
            try await client.activateMaterializedView(database: object.database, name: object.name)
        }
    }

    private func perform(_ success: String, _ action: @escaping @Sendable (StarRocksClient, DatabaseObject) async throws -> Void) {
        actionInFlight = true
        let (client, object) = (client, object)
        Task {
            defer { actionInFlight = false }
            do {
                try await action(client, object)
                workspace.showToast(success)
                try? await Task.sleep(for: .milliseconds(600))
                refreshStatus()
                loadTaskRuns()
                workspace.loadObjects(database: object.database, force: true)
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    /// While a refresh runs, poll status and runs every 3 s (stops when the tab section changes or it finishes).
    private func schedulePollingIfRefreshing() {
        let refreshing = mvStatus?.health == .refreshing || (taskRuns.value?.contains { $0.isActive } ?? false)
        guard refreshing, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.pollTask = nil
            self.refreshStatus()
            if self.section == .refreshes { self.loadTaskRuns() }
        }
    }

    // MARK: Shortcuts

    func openQuery() {
        workspace.openSQL(text: "SELECT *\nFROM \(object.qualifiedName)\nLIMIT 100;", database: object.database, catalog: object.catalog, run: true)
    }

    func showTablets(partition: String?) {
        tabletPartition = partition
        select(.tablets)
    }
}
