import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

/// Catalog → database → objects, grouped by kind (tables, materialized views, views, external),
/// with model badges, MV health dots, filtering and context actions.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            List(selection: $workspace.sidebarSelection) {
                if let error = workspace.databasesError {
                    ErrorBanner(message: error).listRowSeparator(.hidden)
                }
                ForEach(visibleDatabases, id: \.self) { database in
                    DatabaseRow(workspace: workspace, database: database, filter: filter)
                }
                if workspace.isLoadingDatabases, workspace.databases.isEmpty {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: workspace.sidebarSelection) { _, id in
                guard let id, let object = findObject(id) else { return }
                workspace.openObject(object)
            }
        }
        .placedBelowWindowToolbar()
    }

    private var filter: String { workspace.sidebarFilter.trimmingCharacters(in: .whitespaces) }

    private var controls: some View {
        VStack(spacing: 8) {
            if workspace.catalogs.count > 1 {
                Menu {
                    ForEach(workspace.catalogs) { catalog in
                        Button {
                            workspace.selectCatalog(catalog.name)
                        } label: {
                            if catalog.name == workspace.selectedCatalog {
                                Label(catalog.name, systemImage: "checkmark")
                            } else {
                                Text("\(catalog.name)  ·  \(catalog.type)")
                            }
                        }
                    }
                } label: {
                    Label(workspace.selectedCatalog, systemImage: "books.vertical")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .help("Catalog")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tables and views", text: $workspace.sidebarFilter)
                    .textFieldStyle(.plain)
                if !workspace.sidebarFilter.isEmpty {
                    Button { workspace.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var visibleDatabases: [String] {
        guard !filter.isEmpty else { return workspace.databases }
        return workspace.databases.filter { database in
            database.localizedCaseInsensitiveContains(filter)
                || (workspace.objects(in: database)?.contains { $0.name.localizedCaseInsensitiveContains(filter) } ?? false)
        }
    }

    private func findObject(_ id: String) -> DatabaseObject? {
        for database in workspace.expandedDatabases {
            if let object = workspace.objects(in: database)?.first(where: { $0.id == id }) { return object }
        }
        return nil
    }
}

private struct DatabaseRow: View {
    let workspace: WorkspaceModel
    let database: String
    let filter: String

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { workspace.expandedDatabases.contains(database) || (!filter.isEmpty && hasMatches) },
                                            set: { workspace.setExpanded(database, $0) })) {
            content
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSystem ? "cylinder.split.1x2" : "cylinder")
                    .foregroundStyle(isSystem ? Color.secondary : Color.teal)
                Text(database).lineLimit(1)
                Spacer()
                if let count = workspace.objects(in: database)?.count {
                    Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .contextMenu {
                Button("New Query") { workspace.openSQL(database: database, catalog: workspace.selectedCatalog) }
                Button("Refresh") { workspace.loadObjects(database: database, force: true) }
                if workspace.selectedCatalog == SQLText.defaultCatalog {
                    Button("Knowledge") { workspace.openKnowledge(database: database) }
                }
                Divider()
                Button("Loads") { workspace.openLoads(database: database) }
                Button("Schema Changes") { workspace.openOperations(section: .schemaChanges) }
                Divider()
                Button("Copy Name") { Pasteboard.copy(database) }
            }
        }
    }

    private var isSystem: Bool { ["_statistics_", "information_schema", "sys"].contains(database) }

    private var hasMatches: Bool {
        workspace.objects(in: database)?.contains { $0.name.localizedCaseInsensitiveContains(filter) } ?? false
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.databaseStates[database] {
        case nil, .loading?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message)?:
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { workspace.loadObjects(database: database, force: true) }.buttonStyle(.link).font(.caption)
            }
        case let .loaded(objects)?:
            let shown = filter.isEmpty ? objects : objects.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            if shown.isEmpty {
                Text(filter.isEmpty ? "No tables" : "No matches").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(groups(shown), id: \.title) { group in
                Text("\(group.title.uppercased())  \(group.objects.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .selectionDisabled()
                ForEach(group.objects) { object in
                    ObjectRow(object: object, workspace: workspace)
                        .tag(object.id)
                }
            }
        }
    }

    private func groups(_ objects: [DatabaseObject]) -> [(title: String, objects: [DatabaseObject])] {
        var order: [String] = []
        var grouped: [String: [DatabaseObject]] = [:]
        for object in objects {
            let title = object.kind.groupTitle
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(object)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

private struct ObjectRow: View {
    let object: DatabaseObject
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            ObjectIcon(kind: object.kind, health: object.materializedView?.health)
            Text(object.name).lineLimit(1).truncationMode(.middle)
            if let model = object.model, object.kind == .table { ModelBadge(model: model) }
            if object.kind == .syncMaterializedView, let base = object.baseTable {
                Text("on \(base)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let rows = object.rowCount, rows > 0 {
                Text(rows.formatted(.number.notation(.compactName))).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .help(help)
        .contextMenu {
            Button("Open") { workspace.openObject(object) }
            if object.kind != .syncMaterializedView {
                Button("Query in New Tab") {
                    workspace.openSQL(text: "SELECT *\nFROM \(object.qualifiedName)\nLIMIT 100;", database: object.database, catalog: object.catalog, run: true)
                }
            }
            if object.kind.hasNativeStorage {
                Button("Partitions") { workspace.openObject(object, section: .partitions) }
                Button("Tablets & Skew") { workspace.openObject(object, section: .tablets) }
            }
            if object.kind == .asyncMaterializedView {
                Button("Refresh History") { workspace.openObject(object, section: .refreshes) }
            }
            Button("DDL") { workspace.openObject(object, section: .ddl) }
            Divider()
            Button("Copy Name") { Pasteboard.copy(object.name) }
            Button("Copy Qualified Name") { Pasteboard.copy(object.qualifiedName) }
        }
    }

    private var help: String {
        var parts = [object.kind.displayName]
        if let model = object.model { parts.append(model.displayName) }
        if let health = object.materializedView?.health, object.kind == .asyncMaterializedView { parts.append(Theme.label(for: health)) }
        if let comment = object.comment, !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " · ")
    }
}
