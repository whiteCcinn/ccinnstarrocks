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
        case knowledge(KnowledgeTabModel)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: WorkspaceTab, rhs: WorkspaceTab) -> Bool { lhs.id == rhs.id }

    @MainActor var title: String {
        switch kind {
        case let .object(model): model.object.name
        case let .sql(model): model.title
        case .operations: "Operations"
        case let .knowledge(model): model.title
        }
    }

    @MainActor var subtitle: String? {
        switch kind {
        case let .object(model): model.object.database
        case let .sql(model): model.database
        case .operations: nil
        case let .knowledge(model): model.key.database
        }
    }

    @MainActor var icon: String {
        switch kind {
        case let .object(model): Theme.icon(for: model.object.kind)
        case .sql: "chevron.left.forwardslash.chevron.right"
        case .operations: "waveform.path.ecg"
        case .knowledge: "books.vertical"
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
    private var columnMisses: [TableKey: Date] = [:]
    private var columnLoads: [String: Task<Void, Never>] = [:]
    private var objectLoads: [String: Task<Void, Never>] = [:]
    private var objectLoadGenerations: [String: UInt64] = [:]
    private var objectLoadGeneration: UInt64 = 0
    private var sqlTabCounter = 0
    private var toastTask: Task<Void, Never>?

    init(profile: ConnectionProfile, client: StarRocksClient) {
        self.profile = profile
        self.client = client
        let defaultCatalog = profile.defaultCatalog?.trimmingCharacters(in: .whitespaces) ?? ""
        selectedCatalog = defaultCatalog.isEmpty ? SQLText.defaultCatalog : defaultCatalog
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
        let catalog = selectedCatalog
        do {
            let names = try await client.databases(catalog: catalog)
            guard catalog == selectedCatalog else { return } // the user switched catalogs meanwhile
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
            guard catalog == selectedCatalog else { return }
            databasesError = describe(error)
        }
    }

    func refreshAll() {
        columnCache.removeAll()
        columnMisses.removeAll()
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
        objectLoadGeneration &+= 1
        let generation = objectLoadGeneration
        objectLoads[database]?.cancel()
        objectLoads[database] = Task {
            // Only the newest load for this database may publish its result or clear the slot.
            defer { if objectLoadGenerations[database] == generation { objectLoads[database] = nil } }
            do {
                let objects = try await client.objects(catalog: catalog, database: database)
                guard catalog == selectedCatalog, objectLoadGenerations[database] == generation else { return }
                databaseStates[database] = .loaded(objects)
            } catch {
                guard catalog == selectedCatalog, objectLoadGenerations[database] == generation, !Task.isCancelled else { return }
                databaseStates[database] = .failed(describe(error))
            }
        }
        objectLoadGenerations[database] = generation
    }

    func awaitObjects(database: String) async -> [DatabaseObject]? {
        if case let .loaded(objects)? = databaseStates[database] { return objects }
        loadObjects(database: database)
        while let task = objectLoads[database] {
            await task.value
            if objectLoads[database] == task { break }
        }
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

    /// Schema for completion in `catalog`. Sidebar metadata is only used when it belongs to that catalog.
    func completionSnapshot(currentDatabase: String?, catalog: String) -> SchemaSnapshot {
        guard catalog == selectedCatalog else {
            return SchemaSnapshot(currentCatalog: catalog, currentDatabase: currentDatabase, catalogs: catalogs.map(\.name))
        }
        var objectsByDatabase: [String: [SchemaSnapshot.ObjectEntry]] = [:]
        for (database, state) in databaseStates {
            if case let .loaded(objects) = state {
                objectsByDatabase[database] = objects.map { SchemaSnapshot.ObjectEntry(name: $0.name, kind: $0.kind) }
            }
        }
        return SchemaSnapshot(currentCatalog: selectedCatalog, currentDatabase: currentDatabase, catalogs: catalogs.map(\.name),
                              databases: databases, objectsByDatabase: objectsByDatabase, columnsByTable: columnCache)
    }

    /// Loads what completion reported as missing: object lists, and columns of the referenced tables.
    /// Tables that do not exist are remembered for a minute so typing does not re-query them.
    func ensureSchema(columns keys: [TableKey], databases missingDatabases: [String], catalog: String) async {
        // Object lists come from the sidebar's catalog; column lists from the internal information_schema.
        guard catalog == selectedCatalog else { return }
        for database in Set(missingDatabases) {
            _ = await awaitObjects(database: database)
        }
        guard catalog == SQLText.defaultCatalog else { return }
        let now = Date()
        let wanted = Set(keys).filter { key in
            columnCache[key] == nil && (columnMisses[key].map { now.timeIntervalSince($0) > 60 } ?? true)
        }
        for (database, group) in Dictionary(grouping: wanted, by: \.database) {
            let tables = group.map(\.table)
            let loadKey = database + "\u{1F}" + tables.sorted().joined(separator: ",")
            if let running = columnLoads[loadKey] {
                await running.value
                continue
            }
            let client = client
            let task = Task {
                guard let columns = try? await client.columnsByTable(database: database, tables: tables) else { return }
                var found = Set<TableKey>()
                for (table, list) in columns {
                    let key = TableKey(database: database, table: table)
                    columnCache[key] = list
                    found.insert(key)
                }
                for key in group where !found.contains(key) { columnMisses[key] = Date() }
            }
            columnLoads[loadKey] = task
            await task.value
            columnLoads[loadKey] = nil
        }
    }

    // MARK: Tabs

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var selectedSQL: SQLTabModel? {
        if case let .sql(model)? = selectedTab?.kind { return model }
        return nil
    }

    var selectedOperations: OperationsModel? {
        if case let .operations(model)? = selectedTab?.kind { return model }
        return nil
    }

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
    func openSQL(text: String = "", database: String? = nil, catalog: String? = nil, run: Bool = false) -> SQLTabModel {
        sqlTabCounter += 1
        let context = catalog.map { ($0, database) } ?? sidebarContextHint(database: database)
        let model = SQLTabModel(title: "Query \(sqlTabCounter)", text: text, database: context.1, catalog: context.0, workspace: self)
        let tab = WorkspaceTab(kind: .sql(model))
        tabs.append(tab)
        selectedTabID = tab.id
        if run { model.runAll() }
        return model
    }

    /// The knowledge tab of a database (one per database).
    func openKnowledge(database: String) {
        if let existing = tabs.first(where: { (tab: WorkspaceTab) -> Bool in
            if case let .knowledge(model) = tab.kind { return model.key.database == database }
            return false
        }) {
            selectedTabID = existing.id
            return
        }
        let tab = WorkspaceTab(kind: .knowledge(KnowledgeTabModel(workspace: self, database: database)))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openOperations(section: OperationsModel.Section = .running) {
        if let model = selectOperationsTab() {
            model.section = section
            return
        }
        addOperationsTab(OperationsModel(workspace: self, section: section))
    }

    /// Loads of one database and/or type (`STREAM_LOAD`, …); other filters are reset.
    func openLoads(database: String? = nil, type: String? = nil) {
        if let model = selectOperationsTab() {
            model.show(.loads, database: database, loadType: type, setsLoadScope: true)
            return
        }
        addOperationsTab(OperationsModel(workspace: self, section: .loads, database: database, loadFilter: LoadFilter(type: type)))
    }

    /// Selects the existing Operations tab (one per window) and returns its model.
    private func selectOperationsTab() -> OperationsModel? {
        for tab in tabs {
            if case let .operations(model) = tab.kind {
                selectedTabID = tab.id
                return model
            }
        }
        return nil
    }

    private func addOperationsTab(_ model: OperationsModel) {
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
        case let .operations(model): model.close()
        case let .knowledge(model): model.stopWatching()
        case .object: break
        }
    }

    /// Catalog and database for new SQL tabs: the open object's, the current tab's, or the sidebar's.
    private func sidebarContextHint(database: String?) -> (String, String?) {
        if let database { return (selectedCatalog, database) }
        if case let .object(model)? = selectedTab?.kind { return (model.object.catalog, model.object.database) }
        if case let .sql(model)? = selectedTab?.kind { return (model.catalog, model.database) }
        let preferred = profile.defaultDatabase.flatMap { name in databases.contains(name) ? name : nil }
        return (selectedCatalog, preferred ?? expandedDatabases.sorted().first)
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
