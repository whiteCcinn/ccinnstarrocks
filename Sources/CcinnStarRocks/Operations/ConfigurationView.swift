import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

/// Variables, FE configuration and BE configuration with search, a modified-only filter, per-node values
/// and pre-filled edit statements.
struct ConfigurationView: View {
    @Bindable var model: OperationsModel
    @State private var selection: ConfigItem.ID?

    private var scope: ConfigItem.Scope { model.configurationScope }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            LoadableView(state: model.configuration[scope] ?? .loading, retry: { model.refresh() }) { items in
                let shown = items.filter(isShown)
                if shown.isEmpty {
                    ContentUnavailableView.search(text: model.configurationSearch)
                } else {
                    VSplitView {
                        table(shown)
                            .frame(minHeight: 200)
                        if let item = shown.first(where: { $0.id == selection }) {
                            ConfigDetail(item: item, model: model)
                                .frame(minHeight: 120)
                        }
                    }
                }
            }
        }
        .onChange(of: model.configurationScope) { selection = nil }
    }

    private func isShown(_ item: ConfigItem) -> Bool {
        guard item.matches(model.configurationSearch) else { return false }
        // Frontends report no defaults, so "Modified only" does not apply there.
        return !model.configurationModifiedOnly || scope == .frontend || item.isModified == true || item.differsAcrossNodes
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Scope", selection: $model.configurationScope) {
                ForEach(ConfigItem.Scope.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name, value or comment", text: $model.configurationSearch).textFieldStyle(.plain)
                if !model.configurationSearch.isEmpty {
                    Button {
                        model.configurationSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(.separator))
            .frame(minWidth: 200, maxWidth: 340)
            if scope != .frontend {
                Toggle("Modified only", isOn: $model.configurationModifiedOnly)
                    .toggleStyle(.checkbox)
                    .help("Only settings that differ from their default\(scope == .backend ? " or between nodes" : "")")
            }
            Spacer(minLength: 8)
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var caption: String {
        guard let items = model.configuration[scope]?.value else { return "" }
        let shown = items.filter(isShown).count
        let count = shown == items.count ? "\(items.count.formatted())" : "\(shown.formatted()) of \(items.count.formatted())"
        switch scope {
        case .variables: return "\(count) variables · global values"
        case .frontend: return "\(count) items · \(model.client.configuration.endpoint.host)"
        case .backend:
            let nodes = Set(items.flatMap { $0.nodes.map(\.nodeID) }).count
            return "\(count) items · \(nodes) node\(nodes == 1 ? "" : "s")"
        }
    }

    private func table(_ items: [ConfigItem]) -> some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.isModified == true ? Color.orange : .clear)
                        .frame(width: 6, height: 6)
                        .help(item.isModified == true ? "Differs from the default" : "")
                    Text(item.name).font(Theme.monospacedSmall).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Value") { item in
                HStack(spacing: 5) {
                    ConfigValueText(value: item.value)
                    if item.differsAcrossNodes {
                        Badge(text: "differs", color: .orange, systemImage: "exclamationmark.triangle").help("Nodes report different values")
                    }
                }
            }
            .width(min: 100, ideal: 220)
            TableColumn("Default") { ConfigValueText(value: $0.defaultValue, placeholder: "—").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 160)
            TableColumn("Type") { Text($0.type ?? "").foregroundStyle(.secondary) }.width(min: 50, ideal: 70)
            TableColumn("Mutable") { item in
                switch item.isMutable {
                case true?: Image(systemName: "checkmark").foregroundStyle(.green)
                case false?: Image(systemName: "lock").foregroundStyle(.secondary).help("Read-only at runtime: change the .conf file and restart")
                case nil: Text("")
                }
            }
            .width(56)
            TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary).lineLimit(1) }
        }
        .contextMenu(forSelectionType: ConfigItem.ID.self) { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                ConfigActions(item: item, model: model)
            }
        }
    }
}

private struct ConfigValueText: View {
    let value: String?
    var placeholder = "NULL"

    var body: some View {
        if let value, !value.isEmpty {
            Text(value).font(Theme.monospacedSmall).lineLimit(1).textSelection(.enabled)
        } else {
            Text(value == nil ? placeholder : "(empty)").foregroundStyle(.tertiary)
        }
    }
}

private struct ConfigActions: View {
    let item: ConfigItem
    let model: OperationsModel

    var body: some View {
        Button("Edit in SQL Editor…") { model.editInSQLEditor(item) }
            .disabled(ConfigStatement.edit(for: item) == nil)
        Divider()
        Button("Copy Name") { Pasteboard.copy(item.name) }
        Button("Copy Value") { Pasteboard.copy(item.value ?? "") }
    }
}

private struct ConfigDetail: View {
    let item: ConfigItem
    let model: OperationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(item.name).font(Theme.monospaced.weight(.semibold)).textSelection(.enabled)
                    if item.isModified == true { Badge(text: "Modified", color: .orange) }
                    if item.differsAcrossNodes { Badge(text: "Differs across nodes", color: .orange, systemImage: "exclamationmark.triangle") }
                    if item.isMutable == false { Badge(text: "Read-only", color: .secondary, systemImage: "lock") }
                    Spacer()
                    Button("Edit in SQL Editor…") { model.editInSQLEditor(item) }
                        .disabled(ConfigStatement.edit(for: item) == nil)
                        .help(ConfigStatement.edit(for: item) == nil
                              ? "This setting cannot be changed at runtime."
                              : "Opens a pre-filled statement in a new query tab. Nothing runs until you run it.")
                    Button("Copy Value") { Pasteboard.copy(item.value ?? "") }
                }
                .controlSize(.small)
                KeyValueList(items: [
                    ("Value", item.value.map { $0.isEmpty ? "(empty)" : $0 } ?? "NULL"),
                    ("Default", item.defaultValue ?? "—"),
                    ("Type", item.type ?? "—"),
                    ("Mutable", item.isMutable.map { $0 ? "Yes" : "No" } ?? "—"),
                    ("Aliases", item.aliases.isEmpty ? "—" : item.aliases.joined(separator: ", ")),
                ], monospacedValues: true)
                if let comment = item.comment {
                    Text(comment).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !item.nodes.isEmpty {
                    Divider()
                    Text("Per node").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(Array(item.nodes.enumerated()), id: \.offset) { _, node in
                            let differs = item.value.map { !ConfigValue.equivalent(node.value, $0) } ?? false
                            GridRow {
                                Text(node.nodeID).monospacedDigit().foregroundStyle(.secondary)
                                Text(node.host ?? "—")
                                Text(node.value.isEmpty ? "(empty)" : node.value)
                                    .font(Theme.monospacedSmall)
                                    .foregroundStyle(differs ? Color.orange : Color.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
