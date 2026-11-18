import Charts
import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

struct ObjectDetailView: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        VStack(spacing: 0) {
            ObjectHeader(model: model)
            SectionBar(model: model)
            Divider()
            Group {
                switch model.section {
                case .overview: OverviewSection(model: model)
                case .refreshes: RefreshHistorySection(model: model)
                case .columns: ColumnsSection(model: model)
                case .partitions: PartitionsSection(model: model)
                case .tablets: TabletsSection(model: model)
                case .ddl: DDLSection(model: model)
                case .data: DataSection(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $model.inspected) { ValueInspectorView(value: $0) }
    }
}

// MARK: - Header

private struct ObjectHeader: View {
    let model: ObjectDetailModel

    var body: some View {
        let object = model.object
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: Theme.icon(for: object.kind))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.color(for: object.kind))
                .frame(width: 44, height: 44)
                .background(Theme.color(for: object.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(object.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let model = object.model { ModelBadge(model: model) }
                    if let health = model.mvStatus?.health, object.kind.isMaterializedView {
                        Badge(text: Theme.label(for: health), color: Theme.color(for: health))
                    }
                }
                HStack(spacing: 6) {
                    Text(object.kind.displayName)
                    Text("·")
                    Text(object.catalog == SQLText.defaultCatalog ? object.database : "\(object.catalog).\(object.database)")
                    if let base = object.baseTable {
                        Text("· on \(base)")
                    }
                    if let comment = object.comment, !comment.isEmpty {
                        Text("· \(comment)").lineLimit(1)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if object.kind != .syncMaterializedView {
                Button {
                    model.openQuery()
                } label: {
                    Label("Query", systemImage: "play.rectangle")
                }
                .help("Open a SQL editor with SELECT * FROM \(object.name)")
            }
            Button {
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Reload this object's details")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SectionBar: View {
    let model: ObjectDetailModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.availableSections) { section in
                let selected = model.section == section
                Button {
                    model.select(section)
                } label: {
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                        .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// Shows loading / error / content for a `Loadable`.
struct LoadableView<Value, Content: View>: View {
    let state: Loadable<Value>
    var retry: (() -> Void)?
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                ErrorBanner(message: message)
                if let retry { Button("Try Again", action: retry) }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(value):
            content(value)
        }
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        let object = model.object
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if object.kind.hasNativeStorage { statTiles }
                if object.kind == .asyncMaterializedView { MaterializedViewCard(model: model) }
                if object.kind == .syncMaterializedView { syncCard }
                HStack(alignment: .top, spacing: 14) {
                    designCard
                    if !object.properties.isEmpty {
                        Card(title: "Properties", systemImage: "slider.horizontal.3") {
                            KeyValueList(items: object.properties.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, monospacedValues: true)
                        }
                    }
                }
                if object.kind.hasNativeStorage { storageCard }
                if !model.rollups.isEmpty { rollupCard }
            }
            .padding(18)
        }
    }

    private var statTiles: some View {
        let partitions = model.partitions.value
        // Partition figures include sync-MV indexes; the base index from SHOW DATA is the table itself.
        let base = model.storage.value?.first { $0.indexName == model.object.name }
        let indexes = model.storage.value ?? []
        let totalRows = base?.rowCount ?? partitions?.reduce(Int64(0)) { $0 &+ ($1.rowCount ?? 0) }
        let totalSize = base?.size ?? partitions?.reduce(Int64(0)) { $0 &+ ($1.dataSize ?? 0) }
        let rollupSize = indexes.filter { $0.indexName != model.object.name }.reduce(Int64(0)) { $0 &+ ($1.size ?? 0) }
        return HStack(spacing: 12) {
            StatTile(title: "Rows", value: Format.count(totalRows ?? model.object.rowCount), systemImage: "number")
            StatTile(title: rollupSize > 0 ? "Data size (+\(Format.bytes(rollupSize)) in sync MVs)" : "Data size",
                     value: Format.bytes(totalSize ?? model.object.dataLength), systemImage: "internaldrive")
            StatTile(title: "Partitions", value: partitions.map { Format.count($0.count) } ?? "—", systemImage: "square.split.bottomrightquarter")
            StatTile(title: "Buckets", value: model.object.buckets.map(String.init) ?? "—", systemImage: "square.grid.3x3")
        }
    }

    private var designCard: some View {
        let object = model.object
        var items: [(String, String)] = []
        if let tableModel = object.model { items.append(("Model", tableModel.displayName)) }
        if let key = object.primaryKey, !key.isEmpty { items.append((object.model == .unique ? "Unique key" : "Primary key", key)) }
        if let sort = object.sortKey, !sort.isEmpty { items.append(("Sort key", sort)) }
        if let key = object.distributionKey, !key.isEmpty {
            let type = object.distributionType ?? "HASH"
            items.append(("Distribution", "\(type)(\(key)) BUCKETS \(object.buckets.map(String.init) ?? "AUTO")"))
        } else if let type = object.distributionType, !type.isEmpty {
            items.append(("Distribution", "\(type) BUCKETS \(object.buckets.map(String.init) ?? "AUTO")"))
        }
        if let partition = object.partitionKey, !partition.isEmpty {
            var text = partition
            if let partitions = model.partitions.value, let first = partitions.first?.bounds.lower, let last = partitions.last?.bounds.upper {
                text += " · \(first) → \(last)"
            }
            items.append(("Partitioned by", text))
        } else if object.kind.hasNativeStorage {
            items.append(("Partitioning", "Unpartitioned"))
        }
        if let engine = object.engine { items.append(("Engine", engine)) }
        if let created = object.createTime { items.append(("Created", created)) }
        if let updated = object.updateTime { items.append(("Updated", updated)) }
        return Card(title: object.kind.isMaterializedView ? "Design" : "Table design", systemImage: "square.3.layers.3d") {
            if items.isEmpty {
                Text("No storage metadata for this object.").foregroundStyle(.secondary)
            } else {
                KeyValueList(items: items)
            }
        }
    }

    private var storageCard: some View {
        Card(title: "Storage by index", systemImage: "internaldrive") {
            switch model.storage {
            case let .loaded(indexes):
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Index"); Text("Size"); Text("Rows"); Text("Replicas")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(indexes) { index in
                        GridRow {
                            HStack(spacing: 6) {
                                Image(systemName: index.indexName == model.object.name ? "tablecells" : Theme.icon(for: .syncMaterializedView))
                                    .foregroundStyle(index.indexName == model.object.name ? Theme.color(for: .table) : Theme.color(for: .syncMaterializedView))
                                Text(index.indexName)
                            }
                            Text(Format.bytes(index.size)).monospacedDigit()
                            Text(Format.count(index.rowCount)).monospacedDigit()
                            Text(Format.count(index.replicaCount)).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            case let .failed(message):
                Text(message).foregroundStyle(.secondary).font(.callout)
            default:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var rollupCard: some View {
        Card(title: "Synchronous materialized views", systemImage: Theme.icon(for: .syncMaterializedView)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.rollups) { rollup in
                    Button {
                        model.workspace.openObject(rollup)
                    } label: {
                        HStack {
                            ObjectIcon(kind: rollup.kind)
                            Text(rollup.name)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Maintained synchronously with every load into \(model.object.name); the optimizer rewrites matching queries to use them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncCard: some View {
        Card(title: "Synchronous materialized view", systemImage: Theme.icon(for: .syncMaterializedView)) {
            VStack(alignment: .leading, spacing: 10) {
                if let base = model.baseTableObject {
                    Button {
                        model.workspace.openObject(base)
                    } label: {
                        Label("Base table: \(base.name)", systemImage: "tablecells")
                    }
                    .buttonStyle(.link)
                }
                Text("Stored as a rollup index of its base table and updated in the same transaction as every load. Queries on the base table are rewritten to it automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let definition = model.mvStatus?.definition {
                    Text(definition)
                        .font(Theme.monospacedSmall)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

/// Refresh state and actions of an async materialized view.
private struct MaterializedViewCard: View {
    let model: ObjectDetailModel

    var body: some View {
        let status = model.mvStatus ?? MaterializedViewStatus(refreshType: "ASYNC", isActive: true)
        Card(title: "Refresh status", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(Theme.color(for: status.health)).frame(width: 10, height: 10)
                    Text(Theme.label(for: status.health)).font(.headline)
                    if let state = status.lastRefreshState { StateBadge(state: state) }
                    Spacer()
                    if model.actionInFlight { ProgressView().controlSize(.small) }
                    if !status.isActive {
                        Button("Activate") { model.activate() }
                    }
                    if status.health == .refreshing {
                        Button("Cancel Refresh", role: .destructive) { model.cancelRefresh() }
                    }
                    Menu {
                        Button("Refresh changed partitions") { model.refreshMaterializedView(force: false) }
                        Button("Force full refresh") { model.refreshMaterializedView(force: true) }
                    } label: {
                        Label("Refresh Now", systemImage: "arrow.clockwise")
                    } primaryAction: {
                        model.refreshMaterializedView(force: false)
                    }
                    .fixedSize()
                    .disabled(model.actionInFlight)
                }
                KeyValueList(items: Self.details(of: status))
                if let error = status.lastRefreshError {
                    ErrorBanner(message: error)
                }
            }
        }
    }
}

extension MaterializedViewCard {
    static func details(of status: MaterializedViewStatus) -> [(String, String)] {
        var items: [(String, String)] = [("Refresh type", status.refreshType)]
        if let policy = status.refreshPolicy { items.append(("Schedule", policy)) }
        if let start = status.lastRefreshStart { items.append(("Last refresh started", start)) }
        if let finish = status.lastRefreshFinish { items.append(("Last refresh finished", finish)) }
        if let duration = status.lastRefreshDurationSeconds { items.append(("Duration", Format.duration(seconds: duration))) }
        if let partitionType = status.partitionType { items.append(("Partitioning", partitionType)) }
        if let rewrite = status.rewriteStatus { items.append(("Query rewrite", rewrite)) }
        if let task = status.taskName { items.append(("Task", task)) }
        if let reason = status.inactiveReason { items.append(("Inactive because", reason)) }
        return items
    }
}

// MARK: - Columns

private struct ColumnsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.columns, retry: model.loadColumns) { columns in
            Table(columns) {
                TableColumn("#") { Text("\($0.ordinal)").foregroundStyle(.tertiary).monospacedDigit() }
                    .width(32)
                TableColumn("Name") { column in
                    HStack(spacing: 5) {
                        if column.isKey { Image(systemName: "key.fill").foregroundStyle(.orange).imageScale(.small).help("Key column") }
                        Text(column.name).font(.body.weight(column.isKey ? .semibold : .regular)).textSelection(.enabled)
                    }
                }
                .width(min: 120, ideal: 200)
                TableColumn("Type") { Text($0.columnType).font(Theme.monospacedSmall).foregroundStyle(Color(nsColor: .syntaxKeyword)) }
                    .width(min: 90, ideal: 140)
                TableColumn("Nullable") { Text($0.isNullable ? "YES" : "NO").foregroundStyle($0.isNullable ? .secondary : .primary) }
                    .width(64)
                TableColumn("Aggregation") { Text($0.aggregation ?? "").foregroundStyle(.orange) }
                    .width(90)
                TableColumn("Default") { Text($0.defaultValue ?? "").font(Theme.monospacedSmall).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 90)
                TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
    }
}

// MARK: - Partitions

private struct PartitionsSection: View {
    let model: ObjectDetailModel
    @State private var metric = Metric.size
    @State private var search = ""

    enum Metric: String, CaseIterable, Identifiable {
        case size = "Data size"
        case rows = "Rows"
        var id: String { rawValue }
    }

    var body: some View {
        LoadableView(state: model.partitions, retry: model.loadPartitions) { partitions in
            if partitions.isEmpty {
                ContentUnavailableView("No Partitions", systemImage: "square.split.bottomrightquarter")
            } else {
                content(partitions)
            }
        }
    }

    private func content(_ partitions: [PartitionInfo]) -> some View {
        let totalSize = partitions.reduce(Int64(0)) { $0 &+ ($1.dataSize ?? 0) }
        let totalRows = partitions.reduce(Int64(0)) { $0 &+ ($1.rowCount ?? 0) }
        let largest = partitions.max { ($0.dataSize ?? 0) < ($1.dataSize ?? 0) }
        let filtered = search.isEmpty ? partitions : partitions.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.bounds.summary.localizedCaseInsensitiveContains(search) }
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Partitions", value: Format.count(partitions.count), systemImage: "square.split.bottomrightquarter")
                StatTile(title: "Total size", value: Format.bytes(totalSize), systemImage: "internaldrive")
                StatTile(title: model.rollups.isEmpty ? "Total rows" : "Rows (incl. sync MVs)", value: Format.count(totalRows), systemImage: "number")
                StatTile(title: "Largest", value: largest.map { "\($0.name) · \(Format.bytes($0.dataSize))" } ?? "—", systemImage: "arrow.up.right")
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Distribution across partitions").font(.headline)
                        Spacer()
                        Picker("", selection: $metric) {
                            ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    Chart(partitions) { partition in
                        BarMark(x: .value("Partition", partition.name),
                                y: .value(metric.rawValue, metric == .size ? Double(partition.dataSize ?? 0) : Double(partition.rowCount ?? 0)))
                            .foregroundStyle(Theme.accent.gradient)
                            .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(metric == .size ? Format.bytes(Format.int64(number)) : Format.int64(number).formatted(.number.notation(.compactName)))
                                }
                            }
                        }
                    }
                    .chartScrollableAxes(partitions.count > 48 ? .horizontal : [])
                    .chartXVisibleDomain(length: min(max(partitions.count, 1), 48))
                    .frame(height: 180)
                }
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter partitions", text: $search).textFieldStyle(.plain)
            }
            .padding(7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            Table(filtered) {
                TableColumn("Partition") { partition in
                    HStack(spacing: 5) {
                        Text(partition.name).fontWeight(.medium)
                        if partition.isTemporary { Badge(text: "TEMP", color: .orange) }
                    }
                }
                .width(min: 90, ideal: 120)
                TableColumn("Range / values") { Text($0.bounds.summary).font(Theme.monospacedSmall).textSelection(.enabled) }
                    .width(min: 140, ideal: 220)
                TableColumn("Rows") { Text(Format.count($0.rowCount)).monospacedDigit() }.width(80)
                TableColumn("Size") { Text(Format.bytes($0.dataSize)).monospacedDigit() }.width(80)
                TableColumn("Buckets") { Text($0.buckets.map(String.init) ?? "—").monospacedDigit() }.width(56)
                TableColumn("Replicas") { Text($0.replicationNum.map(String.init) ?? "—").monospacedDigit() }.width(56)
                TableColumn("State") { StateBadge(state: $0.state ?? "—") }.width(80)
                TableColumn("Medium") { Text($0.storageMedium ?? "—") }.width(60)
                TableColumn("Last visible version") { Text($0.visibleVersionTime ?? "—").foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: PartitionInfo.ID.self) { ids in
                if let id = ids.first, let partition = partitions.first(where: { $0.id == id }) {
                    Button("Show Tablets") { model.showTablets(partition: partition.name) }
                    Button("Copy Name") { Pasteboard.copy(partition.name) }
                }
            }
            .frame(minHeight: 240)
        }
        .padding(16)
    }
}

// MARK: - Tablets

private struct TabletsSection: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Partition", selection: $model.tabletPartition) {
                    Text("All partitions").tag(String?.none)
                    ForEach(model.partitions.value ?? []) { partition in
                        Text(partition.name).tag(String?.some(partition.name))
                    }
                }
                .frame(maxWidth: 260)
                if !model.rollups.isEmpty {
                    Picker("Index", selection: $model.tabletIndex) {
                        Text(model.object.name + " (base)").tag(String?.none)
                        ForEach(model.rollups) { Text($0.name).tag(String?.some($0.name)) }
                    }
                    .frame(maxWidth: 300)
                }
                Spacer()
            }
            LoadableView(state: model.tablets, retry: model.loadTablets) { replicas in
                if let report = model.skew, !report.entries.isEmpty {
                    TabletReport(report: report, replicas: replicas, distribution: model.distribution)
                } else {
                    ContentUnavailableView("No Tablets", systemImage: "square.grid.3x3")
                }
            }
        }
        .padding(16)
    }
}

struct TabletReport: View {
    let report: SkewReport
    let replicas: [TabletReplica]
    let distribution: Loadable<[ReplicaShare]>

    var body: some View {
        let metricName = report.metric == .dataSize ? "Data size" : "Rows"
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Tablets", value: Format.count(report.entries.count), systemImage: "square.grid.3x3")
                StatTile(title: "Average \(report.metric == .dataSize ? "size" : "rows")",
                         value: report.metric == .dataSize ? Format.bytes(Format.int64(report.average)) : Format.count(Format.int64(report.average)), systemImage: "equal")
                StatTile(title: "Largest vs. average", value: String(format: "%.2f×", report.maxRatio), systemImage: "arrow.up.right",
                         tint: report.isSkewed ? .orange : .green)
                StatTile(title: report.isSkewed ? "Skewed tablets" : "Skew", value: report.isSkewed ? "\(report.skewedCount)" : "Balanced",
                         systemImage: report.isSkewed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill", tint: report.isSkewed ? .orange : .green)
            }
            if report.isSkewed {
                NoticeBanner(message: "\(report.skewedCount) tablet\(report.skewedCount == 1 ? " holds" : "s hold") more than \(String(format: "%.1f", report.threshold))× the average \(metricName.lowercased()). Consider a distribution key with more distinct values or more buckets.",
                             systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(metricName) per tablet").font(.headline)
                    Chart {
                        ForEach(report.entries) { entry in
                            BarMark(x: .value("Tablet", entry.tabletID),
                                    y: .value(metricName, report.metric == .dataSize ? Double(entry.dataSize) : Double(entry.rowCount)))
                                .foregroundStyle(entry.isSkewed ? Color.orange.gradient : Theme.accent.gradient)
                                .cornerRadius(2)
                        }
                        RuleMark(y: .value("Average", report.average))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) { Text("average").font(.caption2).foregroundStyle(.secondary) }
                        RuleMark(y: .value("Threshold", report.average * report.threshold))
                            .foregroundStyle(.orange.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("\(String(format: "%.1f", report.threshold))× average").font(.caption2).foregroundStyle(.orange)
                            }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(report.metric == .dataSize ? Format.bytes(Format.int64(number)) : Format.int64(number).formatted(.number.notation(.compactName)))
                                }
                            }
                        }
                    }
                    .chartXAxis(report.entries.count > 40 ? .hidden : .automatic)
                    .chartScrollableAxes(report.entries.count > 120 ? .horizontal : [])
                    .chartXVisibleDomain(length: min(max(report.entries.count, 1), 120))
                    .frame(height: 170)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Table(report.entries.sorted { $0.ratio > $1.ratio }) {
                    TableColumn("Tablet") { Text($0.tabletID).font(Theme.monospacedSmall).textSelection(.enabled) }
                    TableColumn("Size") { Text(Format.bytes($0.dataSize)).monospacedDigit() }.width(90)
                    TableColumn("Rows") { Text(Format.count($0.rowCount)).monospacedDigit() }.width(90)
                    TableColumn("vs. average") { entry in
                        Text(String(format: "%.2f×", entry.ratio))
                            .monospacedDigit()
                            .foregroundStyle(entry.isSkewed ? .orange : .primary)
                            .fontWeight(entry.isSkewed ? .semibold : .regular)
                    }
                    .width(90)
                }
                .frame(minHeight: 200)
                Card(title: "Replicas per backend", systemImage: "server.rack") {
                    switch distribution {
                    case let .loaded(shares):
                        // One row per BE, scrolled: a list as tall as the cluster made the tab, and with it the
                        // window, taller than the screen once replicas spread over a few dozen BEs.
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(shares) { share in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text("BE \(share.backendID)").font(.callout.weight(.medium))
                                            Spacer()
                                            Text("\(share.replicaCount.formatted()) replicas").font(.caption).foregroundStyle(.secondary)
                                        }
                                        ProgressView(value: min(100, max(0, share.percent ?? 0)), total: 100)
                                            .tint(Theme.accent)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    case let .failed(message):
                        Text("Unavailable: \(message)").font(.caption).foregroundStyle(.secondary)
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 260)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Refresh history

private struct RefreshHistorySection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.taskRuns, retry: model.loadTaskRuns) { runs in
            if runs.isEmpty {
                ContentUnavailableView("No Refreshes Yet", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("Task runs of this materialized view appear here."))
            } else {
                TaskRunTable(runs: runs)
                    .padding(12)
            }
        }
    }
}

/// Task runs (MV refreshes, submitted tasks) with state, timing and errors.
struct TaskRunTable: View {
    let runs: [TaskRun]
    var showsTaskName = false
    @State private var selection: TaskRun.ID?

    var body: some View {
        VSplitView {
            Table(runs, selection: $selection) {
                TableColumn("State") { StateBadge(state: $0.state) }.width(90)
                // Conditional table columns need macOS 14.4, so the task column is always present.
                TableColumn("Task") { run in
                    Text(showsTaskName ? "\(run.database.map { "\($0) · " } ?? "")\(run.taskName)" : run.taskName)
                        .font(Theme.monospacedSmall)
                }
                .width(min: 90, ideal: showsTaskName ? 180 : 110)
                TableColumn("Started") { Text($0.createTime ?? "—").monospacedDigit() }.width(min: 130, ideal: 150)
                TableColumn("Finished") { Text($0.finishTime ?? "—").monospacedDigit().foregroundStyle(.secondary) }.width(min: 130, ideal: 150)
                TableColumn("Duration") { Text(Format.duration(seconds: $0.duration())).monospacedDigit() }.width(80)
                TableColumn("Progress") { Text($0.progress ?? "—") }.width(70)
                TableColumn("Error") { Text($0.errorMessage ?? "").foregroundStyle(.red).lineLimit(1) }
            }
            .frame(minHeight: 160)
            if let run = runs.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = run.errorMessage { ErrorBanner(message: error) }
                        KeyValueList(items: [("Query ID", run.queryID), ("Task", run.taskName)], monospacedValues: true)
                        if let definition = run.definition {
                            Text(definition).font(Theme.monospacedSmall).textSelection(.enabled)
                        }
                        if let extra = run.extraMessage {
                            Text(extra).font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120)
            }
        }
    }
}

// MARK: - DDL and data

private struct DDLSection: View {
    let model: ObjectDetailModel
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        LoadableView(state: model.ddl, retry: model.loadDDL) { ddl in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        Pasteboard.copy(ddl)
                        model.workspace.showToast("DDL copied")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.workspace.openSQL(text: ddl, database: model.object.database, catalog: model.object.catalog)
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                SQLEditor(text: .constant(ddl), selection: $selection, isEditable: false, highlightsCurrentStatement: false)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

private struct DataSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.preview, retry: model.loadPreview) { result in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("First \(Format.count(result.rows.count)) rows").font(.callout.weight(.semibold))
                    Spacer()
                    Button {
                        model.loadPreview()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    Button {
                        model.openQuery()
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                ResultGrid(resultID: model.previewID, columns: result.columns, rows: result.rows,
                           insertTableName: model.object.qualifiedName, onInspect: { model.inspected = $0 })
            }
        }
    }
}
