import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

/// Load jobs of every type with server-side search, type/state filters and optional history.
struct LoadsView: View {
    @Bindable var model: OperationsModel
    @State private var selection: LoadJob.ID?

    var body: some View {
        VStack(spacing: 0) {
            LoadFilterBar(model: model)
            Divider()
            LoadableView(state: model.loads, retry: { model.refresh() }) { result in
                // The server already filtered; filtering again shows a new keyword at once while its query runs.
                let filter = model.effectiveLoadFilter
                let jobs = result.jobs.filter(filter.matches)
                VStack(spacing: 0) {
                    notices(for: result)
                    if jobs.isEmpty {
                        emptyState(filter: filter)
                    } else {
                        VSplitView {
                            table(jobs)
                                .frame(minHeight: 200)
                            if let job = jobs.first(where: { $0.id == selection }) {
                                LoadDetail(job: job, model: model)
                                    .frame(minHeight: 140)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notices(for result: LoadSearchResult) -> some View {
        if result.filteredOnClient || result.historyError != nil {
            VStack(spacing: 6) {
                if result.filteredOnClient {
                    NoticeBanner(message: "The server could not apply the search, so only the newest \(model.loadFilter.clampedLimit.formatted()) jobs were searched.",
                                 systemImage: "line.3.horizontal.decrease.circle", color: .orange)
                }
                if let historyError = result.historyError {
                    NoticeBanner(message: "Load history is unavailable: \(historyError)", systemImage: "clock.badge.exclamationmark", color: .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func emptyState(filter: LoadFilter) -> some View {
        if filter.hasRefinements || filter.state != .all {
            ContentUnavailableView {
                Label("No Matching Loads", systemImage: "magnifyingglass")
            } description: {
                Text(model.includeLoadHistory
                     ? "Nothing matches in memory or in _statistics_.loads_history."
                     : "Frontends forget finished loads after label_keep_max_second (3 days by default). Include history to also search _statistics_.loads_history.")
            } actions: {
                if !model.includeLoadHistory { Button("Include History") { model.includeLoadHistory = true } }
            }
        } else {
            ContentUnavailableView("No Loads", systemImage: "tray.and.arrow.down",
                                   description: Text("Stream Load, Broker Load, INSERT and Spark Load jobs appear here."))
        }
    }

    private func table(_ jobs: [LoadJob]) -> some View {
        Table(jobs, selection: $selection) {
            TableColumn("State") { StateBadge(state: $0.state) }.width(90)
            TableColumn("Label") { job in
                HStack(spacing: 4) {
                    if job.source == .history {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).help("From _statistics_.loads_history")
                    }
                    Text(job.label).font(Theme.monospacedSmall).lineLimit(1)
                }
            }
            .width(min: 120, ideal: 220)
            TableColumn("Type") { Text(LoadJob.displayName(forType: $0.type)) }.width(min: 70, ideal: 90)
            TableColumn("Target") { Text("\($0.database ?? "").\($0.table ?? "")") }.width(min: 100, ideal: 160)
            TableColumn("Progress") { Text($0.progress ?? "").foregroundStyle(.secondary).help($0.progress ?? "") }.width(min: 60, ideal: 80)
            TableColumn("Rows") { Text(Format.count($0.sinkRows)).monospacedDigit() }.width(80)
            TableColumn("Filtered") { job in
                Text(Format.count(job.filteredRows)).monospacedDigit().foregroundStyle((job.filteredRows ?? 0) > 0 ? .orange : .secondary)
            }
            .width(64)
            TableColumn("Error") { Text($0.errorMessage ?? "").foregroundStyle(.red).lineLimit(1).help($0.errorMessage ?? "") }
                .width(min: 80, ideal: 180)
            TableColumn("Created") { Text($0.createTime ?? "").monospacedDigit() }.width(min: 130, ideal: 150)
            TableColumn("Finished") { Text($0.finishTime ?? "").monospacedDigit().foregroundStyle(.secondary) }.width(min: 130, ideal: 150)
        }
        .contextMenu(forSelectionType: LoadJob.ID.self) { ids in
            if let id = ids.first, let job = jobs.first(where: { $0.id == id }) {
                LoadActions(job: job, model: model)
            }
        }
    }
}

/// Search box with field scope, type and state filters, the history toggle and the result summary.
private struct LoadFilterBar: View {
    @Bindable var model: OperationsModel

    /// Common types first; any other type the server reported is appended.
    private static let knownTypes = ["STREAM_LOAD", "BROKER", "INSERT", "SPARK", "ROUTINE_LOAD"]

    var body: some View {
        HStack(spacing: 10) {
            searchField
            Picker("Type", selection: $model.loadFilter.type) {
                Text("All types").tag(String?.none)
                Divider()
                ForEach(types, id: \.self) { Text(LoadJob.displayName(forType: $0)).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Load type")
            Picker("State", selection: $model.loadFilter.state) {
                ForEach(LoadFilter.StateFilter.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Job state")
            Toggle("Include history", isOn: $model.includeLoadHistory)
                .toggleStyle(.checkbox)
                .help("Also search _statistics_.loads_history for jobs the frontends no longer keep in memory. Auto-refresh pauses meanwhile.")
            Spacer(minLength: 8)
            if model.isRefreshing { ProgressView().controlSize(.small) }
            summary
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(model.loadFilter.field == .any ? "Search loads" : "Search \(model.loadFilter.field.displayName.lowercased())",
                      text: $model.loadFilter.keyword)
                .textFieldStyle(.plain)
                .onSubmit { model.refresh() }
            if !model.loadFilter.keyword.isEmpty {
                Button {
                    model.loadFilter.keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            Divider().frame(height: 14)
            Picker("Search in", selection: $model.loadFilter.field) {
                ForEach(LoadFilter.Field.allCases) { field in
                    Text(field.displayName).tag(field)
                    if field == .any { Divider() }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Field to search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(.separator))
        .frame(minWidth: 220, maxWidth: 400)
    }

    private var types: [String] {
        let seen = model.loads.value?.jobs.compactMap { $0.type?.uppercased() } ?? []
        var types = Self.knownTypes
        for type in seen where !types.contains(type) { types.append(type) }
        if let selected = model.loadFilter.type, !types.contains(selected) { types.append(selected) }
        return types
    }

    @ViewBuilder
    private var summary: some View {
        if let result = model.loads.value {
            let shown = result.jobs.filter(model.effectiveLoadFilter.matches).count
            let limit = model.loadFilter.clampedLimit
            Text(result.reachedLimit ? "\(shown.formatted()) jobs · newest \(limit.formatted())" : "\(shown.formatted()) jobs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(result.reachedLimit ? "More jobs match. Narrow the search to see older ones." : "")
        }
    }
}

private struct LoadActions: View {
    let job: LoadJob
    let model: OperationsModel

    var body: some View {
        Button("Cancel Load") { model.confirmCancelLoad(job) }
            .disabled(!job.canCancel)
        Divider()
        Button("Copy Label") { Pasteboard.copy(job.label) }
        if !job.jobID.isEmpty { Button("Copy Job ID") { Pasteboard.copy(job.jobID) } }
        if let sql = job.trackingSQL {
            Button("Open Error Tracking Query") { model.workspace.openSQL(text: sql, run: true) }
        }
    }
}

/// Everything known about one load: counters, timings, runtime details (client IP, transaction) and properties.
private struct LoadDetail: View {
    let job: LoadJob
    let model: OperationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StateBadge(state: job.state)
                    Text(job.label).font(Theme.monospaced.weight(.semibold)).textSelection(.enabled).lineLimit(1)
                    if job.source == .history { Badge(text: "History", color: .secondary, systemImage: "clock.arrow.circlepath") }
                    Spacer()
                    if let sql = job.trackingSQL {
                        Button("Error Tracking Query") { model.workspace.openSQL(text: sql, run: true) }
                            .help("Rejected rows and their reasons (information_schema.load_tracking_logs)")
                    }
                    if job.canCancel { Button("Cancel Load", role: .destructive) { model.confirmCancelLoad(job) } }
                }
                .controlSize(.small)
                if let error = job.errorMessage { ErrorBanner(message: error) }
                HStack(alignment: .top, spacing: 28) {
                    KeyValueList(items: [
                        ("Job ID", job.jobID.isEmpty ? "—" : job.jobID), ("Type", LoadJob.displayName(forType: job.type).nonEmpty ?? "—"),
                        ("Target", "\(job.database ?? "?").\(job.table ?? "?")"), ("User", job.user ?? "—"),
                        ("Priority", job.priority ?? "—"), ("Warehouse", job.warehouse ?? "—"), ("Progress", job.progress ?? "—"),
                    ], monospacedValues: true)
                    KeyValueList(items: [
                        ("Scanned rows", Format.count(job.scanRows)), ("Scanned bytes", Format.bytes(job.scanBytes)),
                        ("Loaded rows", Format.count(job.sinkRows)), ("Filtered rows", Format.count(job.filteredRows)),
                        ("Unselected rows", Format.count(job.unselectedRows)),
                    ], monospacedValues: true)
                    KeyValueList(items: [
                        ("Created", job.createTime ?? "—"), ("Started", job.startTime ?? "—"),
                        ("Committed", job.commitTime ?? "—"), ("Finished", job.finishTime ?? "—"),
                    ], monospacedValues: true)
                }
                let runtime = LoadJob.keyValues(json: job.runtimeDetails)
                let properties = LoadJob.keyValues(json: job.properties)
                if !runtime.isEmpty || !properties.isEmpty || job.rejectedRecordPath != nil || job.profileID != nil {
                    Divider()
                    HStack(alignment: .top, spacing: 28) {
                        if !runtime.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Runtime details").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                KeyValueList(items: runtime.map { ($0.key, $0.value) }, monospacedValues: true)
                            }
                        }
                        let extra = properties.map { ($0.key, $0.value) }
                            + [job.rejectedRecordPath.map { ("Rejected records", $0) }, job.profileID.map { ("Profile ID", $0) }].compactMap { $0 }
                        if !extra.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Properties").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                KeyValueList(items: extra, monospacedValues: true)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension String {
    /// `nil` for an empty string.
    var nonEmpty: String? { isEmpty ? nil : self }
}
