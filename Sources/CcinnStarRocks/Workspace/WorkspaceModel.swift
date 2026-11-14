import CcinnStarRocksKit
import Foundation
import Observation
import StarRocksKit

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// One tab in the workspace.
struct WorkspaceTab: Identifiable, Equatable {
    enum Kind {
        case object(ObjectDetailModel)
        case sql(SQLTabModel)
        case operations(OperationsModel)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: WorkspaceTab, rhs: WorkspaceTab) -> Bool { lhs.id == rhs.id }

    @MainActor var title: String {
        switch kind {
        case let .object(model): model.object.name
        case let .sql(model): model.title
        case .operations: "Operations"
        }
    }

    @MainActor var subtitle: String? {
        switch kind {
        case let .object(model): model.object.database
        case let .sql(model): model.database
        case .operations: nil
        }
    }

    @MainActor var icon: String {
        switch kind {
        case let .object(model): Theme.icon(for: model.object.kind)
        case .sql: "chevron.left.forwardslash.chevron.right"
        case .operations: "waveform.path.ecg"
        }
    }
}

/// Everything a connected window shows: catalog tree, open tabs, and caches shared by tabs.
@MainActor
@Observable
final class WorkspaceModel {
    enum DatabaseState {
        case loading
        case loaded([DatabaseObject])
        case failed(String)
    }

    let profile: ConnectionProfile
    let client: StarRocksClient
    let history: QueryHistoryStore

    var catalogs: [CatalogInfo] = [CatalogInfo(name: SQLText.defaultCatalog, type: "Internal")]
    private(set) var selectedCatalog = SQLText.defaultCatalog
    var databases: [String] = []
    var isLoadingDatabases = false
    var databasesError: String?
    var databaseStates: [String: DatabaseState] = [:]
    var expandedDatabases: Set<String> = []
    var sidebarFilter = ""
    var sidebarSelection: String?

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var toast: Toast?

    /// Columns per table for completion and previews.
    private var columnCache: [TableKey: [ColumnInfo]] = [:]
    private var columnLoads: [String: Task<Void, Never>] = [:]
    private var objectLoads: [String: Task<Void, Never>] = [:]
    private var sqlTabCounter = 0
    private var toastTask: Task<Void, Never>?

    init(profile: ConnectionProfile, client: StarRocksClient) {
        self.profile = profile
        self.client = client
        history = QueryHistoryStore(directory: AppServices.shared.historyDirectory, profileID: profile.id)
    }

    var serverInfo: ServerInfo { client.serverInfo }

    var versionLabel: String {
        serverInfo.version.map { "StarRocks \($0.shortDescription)" } ?? serverInfo.versionString
    }

    // MARK: Lifecycle

    func start() {
        Task { await loadCatalogs() }
        Task { await reloadDatabases() }
    }

    func shutdown() {
        for tab in tabs { closeResources(of: tab) }
        tabs.removeAll()
        let client = client
        Task.detached { await client.close() }
    }

    // MARK: Catalog tree

    func loadCatalogs() async {
        if let catalogs = try? await client.catalogs(), !catalogs.isEmpty { self.catalogs = catalogs }
    }

    func selectCatalog(_ name: String) {
        guard name != selectedCatalog else { return }
        selectedCatalog = name
        databaseStates.removeAll()
        expandedDatabases.removeAll()
        databases = []
        Task { await reloadDatabases() }
    }

    func reloadDatabases() async {
        isLoadingDatabases = true
        defer { isLoadingDatabases = false }
        do {
            let names = try await client.databases(catalog: selectedCatalog)
            databases = names
            databasesError = nil
            if expandedDatabases.isEmpty {
                let preferred = profile.defaultDatabase.flatMap { name in names.first { $0 == name } }
                    ?? names.first { !["_statistics_", "information_schema", "sys"].contains($0) }
                if let preferred { setExpanded(preferred, true) }
            }
            for database in expandedDatabases where databases.contains(database) {
                loadObjects(database: database, force: true)
            }
        } catch {
            databasesError = describe(error)
        }
    }

    func refreshAll() {
        columnCache.removeAll()
        Task {
            await loadCatalogs()
            await reloadDatabases()
        }
    }

    func setExpanded(_ database: String, _ expanded: Bool) {
        if expanded {
            expandedDatabases.insert(database)
            if databaseStates[database] == nil { loadObjects(database: database) }
        } else {
            expandedDatabases.remove(database)
        }
    }

    func loadObjects(database: String, force: Bool = false) {
        if !force, let state = databaseStates[database], case .loaded = state { return }
        if objectLoads[database] != nil, !force { return }
        if databaseStates[database] == nil { databaseStates[database] = .loading }
        let catalog = selectedCatalog
        objectLoads[database] = Task {
            defer { objectLoads[database] = nil }
            do {
                let objects = try await client.objects(catalog: catalog, database: database)
                guard catalog == selectedCatalog else { return }
                databaseStates[database] = .loaded(objects)
            } catch {
                guard catalog == selectedCatalog else { return }
                databaseStates[database] = .failed(describe(error))
            }
        }
    }

    func awaitObjects(database: String) async -> [DatabaseObject]? {
        if case let .loaded(objects)? = databaseStates[database] { return objects }
        loadObjects(database: database)
        await objectLoads[database]?.value
        if case let .loaded(objects)? = databaseStates[database] { return objects }
        return nil
    }

    func objects(in database: String) -> [DatabaseObject]? {
        if case let .loaded(objects)? = databaseStates[database] { return objects }
        return nil
    }

    func object(database: String, name: String) -> DatabaseObject? {
        objects(in: database)?.first { $0.name == name }
    }

    // MARK: Completion schema

    func completionSnapshot(currentDatabase: String?) -> SchemaSnapshot {
        var objectsByDatabase: [String: [SchemaSnapshot.ObjectEntry]] = [:]
        for (database, state) in databaseStates {
            if case let .loaded(objects) = state {
                objectsByDatabase[database] = objects.map { SchemaSnapshot.ObjectEntry(name: $0.name, kind: $0.kind) }
            }
        }
        return SchemaSnapshot(currentCatalog: selectedCatalog, currentDatabase: currentDatabase, catalogs: catalogs.map(\.name),
                              databases: databases, objectsByDatabase: objectsByDatabase, columnsByTable: columnCache)
    }

    /// Loads what completion reported as missing: object lists and (whole-database) column lists.
    func ensureSchema(columns keys: [TableKey], databases missingDatabases: [String]) async {
        for database in Set(missingDatabases) {
            _ = await awaitObjects(database: database)
        }
        for database in Set(keys.map(\.database)) {
            if let running = columnLoads[database] {
                await running.value
                continue
            }
            let client = client
            let task = Task {
                if let columns = try? await client.columnsByTable(database: database) {
                    for (table, list) in columns { columnCache[TableKey(database: database, table: table)] = list }
                }
            }
            columnLoads[database] = task
            await task.value
            columnLoads[database] = nil
        }
    }

    // MARK: Tabs

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    func openObject(_ object: DatabaseObject, section: ObjectDetailModel.Section? = nil) {
        if let existing = tabs.first(where: { if case let .object(model) = $0.kind { model.object.id == object.id } else { false } }) {
            selectedTabID = existing.id
            if let section, case let .object(model) = existing.kind { model.select(section) }
            return
        }
        let model = ObjectDetailModel(object: object, workspace: self)
        if let section { model.select(section) }
        let tab = WorkspaceTab(kind: .object(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    @discardableResult
    func openSQL(text: String = "", database: String? = nil, run: Bool = false) -> SQLTabModel {
        sqlTabCounter += 1
        let defaultDatabase = database ?? sidebarDatabaseHint
        let model = SQLTabModel(title: "Query \(sqlTabCounter)", text: text, database: defaultDatabase, workspace: self)
        let tab = WorkspaceTab(kind: .sql(model))
        tabs.append(tab)
        selectedTabID = tab.id
        if run { model.runAll() }
        return model
    }

    func openOperations(section: OperationsModel.Section = .running) {
        if let existing = tabs.first(where: { if case .operations = $0.kind { true } else { false } }) {
            selectedTabID = existing.id
            if case let .operations(model) = existing.kind { model.section = section }
            return
        }
        let model = OperationsModel(workspace: self, section: section)
        let tab = WorkspaceTab(kind: .operations(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        closeResources(of: tab)
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func closeSelectedTab() {
        if let selectedTab { close(selectedTab) }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to target: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    private func closeResources(of tab: WorkspaceTab) {
        switch tab.kind {
        case let .sql(model): model.close()
        case let .operations(model): model.stopAutoRefresh()
        case .object: break
        }
    }

    /// Database for new SQL tabs: the open object's, the expanded one, or the profile default.
    private var sidebarDatabaseHint: String? {
        if case let .object(model)? = selectedTab?.kind { return model.object.database }
        if case let .sql(model)? = selectedTab?.kind { return model.database }
        return profile.defaultDatabase ?? expandedDatabases.sorted().first
    }

    // MARK: Feedback

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
