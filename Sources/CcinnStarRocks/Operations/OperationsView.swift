import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

struct OperationsView: View {
    @Bindable var model: OperationsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.section {
                case .running: RunningNowView(model: model)
                case .sessions: SessionsView(model: model)
                case .loads: LoadsView(model: model)
                case .routineLoads: RoutineLoadsView(model: model)
                case .taskRuns: LoadableView(state: model.taskRuns, retry: model.refresh) { TaskRunTable(runs: $0, showsTaskName: true).padding(12) }
                case .schemaChanges: SchemaChangesView(model: model)
                case .cluster: ClusterView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(model.pendingAction?.title ?? "", isPresented: Binding(get: { model.pendingAction != nil }, set: { if !$0 { model.pendingAction = nil } }),
                            titleVisibility: .visible) {
            Button(model.pendingAction?.confirmLabel ?? "OK", role: .destructive) { model.runPendingAction() }
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
        } message: {
            Text(model.pendingAction?.message ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(Theme.accent)
                Text("Operations").font(.title2.weight(.semibold))
                Badge(text: model.workspace.versionLabel, color: Theme.accent)
                if let mode = model.workspace.serverInfo.runMode {
                    Badge(text: mode == "shared_data" ? "Shared-data" : "Shared-nothing", color: .teal)
                }
                Spacer()
                if [.loads, .routineLoads, .taskRuns, .schemaChanges].contains(model.section) {
                    Picker("Database", selection: $model.database) {
                        Text("All databases").tag(String?.none)
                        ForEach(model.workspace.databases, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .frame(maxWidth: 220)
                }
                Toggle("Auto-refresh", isOn: $model.autoRefresh)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Refresh every 5 seconds")
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
                if let refreshed = model.lastRefreshed {
                    Text(refreshed, style: .time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(spacing: 2) {
                ForEach(OperationsModel.Section.allCases) { section in
                    let selected = model.section == section
                    Button {
                        model.section = section
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
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Running now

private struct RunningNowView: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.activity, retry: model.refresh) { snapshot in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        tile("Queries", snapshot.queries.count, "play.circle", .blue, .sessions)
                        tile("Loads", snapshot.loads.count, "tray.and.arrow.down", .green, .loads)
                        tile("MV & task runs", snapshot.taskRuns.count, "checklist", .purple, .taskRuns)
                        tile("Routine loads", snapshot.routineLoads.count, "arrow.triangle.2.circlepath.circle", .teal, .routineLoads)
                        tile("Schema changes", snapshot.alterJobs.count, "hammer", .orange, .schemaChanges)
                    }
                    ForEach(snapshot.unavailable.sorted { $0.key < $1.key }, id: \.key) { name, reason in
                        NoticeBanner(message: "\(name): \(reason)", systemImage: "lock", color: .orange)
                    }
                    if snapshot.totalActive == 0 {
                        ContentUnavailableView("Nothing Running", systemImage: "moon.zzz",
                                               description: Text("No queries, loads, refreshes or schema changes are executing right now."))
                            .padding(.top, 40)
                    }
                    if !snapshot.queries.isEmpty {
                        Card(title: "Running queries", systemImage: "play.circle") {
                            ForEach(snapshot.queries) { process in
                                ActiveRow(title: process.statement ?? "", detail: "\(process.user ?? "?") · \(process.database ?? "no database") · connection \(process.connectionID)",
                                          trailing: "\(process.timeSeconds ?? 0)s", state: process.isPending == true ? "PENDING" : "RUNNING") {
                                    Button("Kill Query") { model.confirmKill(process, connection: false) }
                                }
                            }
                        }
                    }
                    if !snapshot.taskRuns.isEmpty {
                        Card(title: "Materialized view refreshes & tasks", systemImage: "arrow.triangle.2.circlepath") {
                            ForEach(snapshot.taskRuns) { run in
                                ActiveRow(title: run.taskName, detail: "\(run.database ?? "") · started \(run.createTime ?? "?")",
                                          trailing: run.progress ?? Format.duration(seconds: run.duration()), state: run.state) { EmptyView() }
                            }
                        }
                    }
                    if !snapshot.loads.isEmpty {
                        Card(title: "Loads in progress", systemImage: "tray.and.arrow.down") {
                            ForEach(snapshot.loads) { job in
                                ActiveRow(title: job.label, detail: "\(job.type ?? "LOAD") → \(job.database ?? "?").\(job.table ?? "?")",
                                          trailing: job.progress ?? "", state: job.state) {
                                    Button("Cancel") { model.confirmCancelLoad(job) }
                                }
                            }
                        }
                    }
                    if !snapshot.routineLoads.isEmpty {
                        Card(title: "Routine loads", systemImage: "arrow.triangle.2.circlepath.circle") {
                            ForEach(snapshot.routineLoads) { job in
                                ActiveRow(title: job.name, detail: "\(job.dataSourceType ?? "") → \(job.database ?? "?").\(job.table ?? "?")",
                                          trailing: "\(job.currentTaskCount ?? 0) tasks", state: job.state) {
                                    RoutineLoadActions(job: job, model: model)
                                }
                            }
                        }
                    }
                    if !snapshot.alterJobs.isEmpty {
                        Card(title: "Schema changes", systemImage: "hammer") {
                            ForEach(snapshot.alterJobs) { job in
                                ActiveRow(title: "\(job.database).\(job.table)", detail: "\(job.kind.displayName)\(job.indexName.map { " · \($0)" } ?? "")",
                                          trailing: job.progress ?? "", state: job.state) {
                                    Button("Cancel") { model.confirmCancel(job) }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private func tile(_ title: String, _ count: Int, _ icon: String, _ tint: Color, _ section: OperationsModel.Section) -> some View {
        Button {
            model.section = section
        } label: {
            StatTile(title: title, value: "\(count)", systemImage: icon, tint: count > 0 ? tint : .secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct ActiveRow<Actions: View>: View {
    let title: String
    let detail: String
    let trailing: String
    let state: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            StateBadge(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.monospacedSmall).lineLimit(2).textSelection(.enabled)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            actions.controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Sessions

private struct SessionsView: View {
    let model: OperationsModel
    @State private var activeOnly = false
    @State private var selection: SessionProcess.ID?

    var body: some View {
        LoadableView(state: model.sessions, retry: model.refresh) { processes in
            let shown = activeOnly ? processes.filter(\.isRunningStatement) : processes
            VStack(spacing: 0) {
                HStack {
                    Toggle("Only running statements", isOn: $activeOnly).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(shown.count) of \(processes.count) sessions").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Table(shown, selection: $selection) {
                    TableColumn("Id") { Text(String($0.connectionID)).monospacedDigit() }.width(80)
                    TableColumn("User") { Text($0.user ?? "") }.width(min: 60, ideal: 90)
                    TableColumn("Host") { Text($0.host ?? "").foregroundStyle(.secondary) }.width(min: 90, ideal: 130)
                    TableColumn("Database") { Text($0.database ?? "") }.width(min: 60, ideal: 90)
                    TableColumn("Command") { process in
                        Text(process.command ?? "").foregroundStyle(process.isRunningStatement ? Color.blue : Color.secondary)
                    }
                    .width(70)
                    TableColumn("Time") { Text("\($0.timeSeconds ?? 0)s").monospacedDigit() }.width(56)
                    TableColumn("State") { Text($0.state ?? "") }.width(60)
                    TableColumn("Statement") { Text($0.statement ?? "").font(Theme.monospacedSmall).lineLimit(1) }
                }
                .contextMenu(forSelectionType: SessionProcess.ID.self) { ids in
                    if let id = ids.first, let process = processes.first(where: { $0.id == id }) {
                        Button("Kill Query") { model.confirmKill(process, connection: false) }
                        Button("Kill Connection") { model.confirmKill(process, connection: true) }
                        Divider()
                        Button("Copy Statement") { Pasteboard.copy(process.statement ?? "") }
                            .disabled(process.statement == nil)
                    }
                }
            }
        }
    }
}

// MARK: - Loads

private struct LoadsView: View {
    let model: OperationsModel
    @State private var selection: LoadJob.ID?

    var body: some View {
        LoadableView(state: model.loads, retry: model.refresh) { jobs in
            VSplitView {
                Table(jobs, selection: $selection) {
                    TableColumn("State") { StateBadge(state: $0.state) }.width(90)
                    TableColumn("Label") { Text($0.label).font(Theme.monospacedSmall).lineLimit(1) }.width(min: 120, ideal: 220)
                    TableColumn("Type") { Text($0.type ?? "") }.width(70)
                    TableColumn("Target") { Text("\($0.database ?? "").\($0.table ?? "")") }.width(min: 100, ideal: 160)
                    TableColumn("Progress") { Text($0.progress ?? "").foregroundStyle(.secondary) }.width(min: 80, ideal: 130)
                    TableColumn("Rows") { Text(Format.count($0.sinkRows)).monospacedDigit() }.width(80)
                    TableColumn("Filtered") { job in
                        Text(Format.count(job.filteredRows)).monospacedDigit().foregroundStyle((job.filteredRows ?? 0) > 0 ? .orange : .secondary)
                    }
                    .width(64)
                    TableColumn("Created") { Text($0.createTime ?? "").monospacedDigit() }.width(min: 130, ideal: 150)
                    TableColumn("Finished") { Text($0.finishTime ?? "").monospacedDigit().foregroundStyle(.secondary) }.width(min: 130, ideal: 150)
                }
                .contextMenu(forSelectionType: LoadJob.ID.self) { ids in
                    if let id = ids.first, let job = jobs.first(where: { $0.id == id }) {
                        Button("Cancel Load") { model.confirmCancelLoad(job) }.disabled(!job.isActive)
                        Button("Copy Label") { Pasteboard.copy(job.label) }
                        if let sql = job.trackingSQL { Button("Open Error Tracking Query") { model.workspace.openSQL(text: sql, run: true) } }
                    }
                }
                .frame(minHeight: 200)
                if let job = jobs.first(where: { $0.id == selection }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let error = job.errorMessage { ErrorBanner(message: error) }
                            KeyValueList(items: [("Job ID", job.jobID), ("Label", job.label), ("User", job.user ?? "—"), ("Priority", job.priority ?? "—"),
                                                 ("Scanned rows", Format.count(job.scanRows)), ("Loaded rows", Format.count(job.sinkRows)),
                                                 ("Filtered rows", Format.count(job.filteredRows)), ("Started", job.startTime ?? "—"),
                                                 ("Warehouse", job.warehouse ?? "—")], monospacedValues: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120)
                }
            }
        }
    }
}

// MARK: - Routine loads

private struct RoutineLoadActions: View {
    let job: RoutineLoadJob
    let model: OperationsModel

    var body: some View {
        HStack(spacing: 4) {
            if job.isRunning { Button("Pause") { model.confirm(.pause, job) } }
            if job.isPaused { Button("Resume") { model.confirm(.resume, job) } }
            if !job.isFinished { Button("Stop", role: .destructive) { model.confirm(.stop, job) } }
        }
    }
}

private struct RoutineLoadsView: View {
    let model: OperationsModel
    @State private var selection: RoutineLoadJob.ID?

    var body: some View {
        LoadableView(state: model.routineLoads, retry: model.refresh) { jobs in
            if jobs.isEmpty {
                ContentUnavailableView("No Routine Loads", systemImage: "arrow.triangle.2.circlepath.circle",
                                       description: Text("Kafka and Pulsar routine load jobs appear here."))
            } else {
                VSplitView {
                    Table(jobs, selection: $selection) {
                        TableColumn("State") { StateBadge(state: $0.state) }.width(90)
                        TableColumn("Name") { Text($0.name).fontWeight(.medium) }.width(min: 100, ideal: 180)
                        TableColumn("Target") { Text("\($0.database ?? "").\($0.table ?? "")") }.width(min: 100, ideal: 160)
                        TableColumn("Source") { Text($0.dataSourceType ?? "") }.width(70)
                        TableColumn("Tasks") { Text("\($0.currentTaskCount ?? 0)").monospacedDigit() }.width(50)
                        TableColumn("Created") { Text($0.createTime ?? "").monospacedDigit() }.width(min: 130, ideal: 150)
                        TableColumn("Actions") { RoutineLoadActions(job: $0, model: model).controlSize(.small) }.width(min: 150, ideal: 170)
                    }
                    .frame(minHeight: 180)
                    if let job = jobs.first(where: { $0.id == selection }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if let reason = job.reasonOfStateChanged { NoticeBanner(message: reason, systemImage: "exclamationmark.circle", color: .orange) }
                                KeyValueList(items: [("Statistics", job.statistic ?? "—"), ("Progress", job.progress ?? "—"),
                                                     ("Error logs", job.errorLogURLs ?? "—"), ("Other", job.otherMessage ?? "—")], monospacedValues: true)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 120)
                    }
                }
            }
        }
    }
}

// MARK: - Schema changes

private struct SchemaChangesView: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.alterJobs, retry: model.refresh) { jobs in
            if jobs.isEmpty {
                ContentUnavailableView("No Schema Changes", systemImage: "hammer",
                                       description: Text("ALTER TABLE jobs, rollups and sync materialized view builds appear here."))
            } else {
                Table(jobs) {
                    TableColumn("State") { StateBadge(state: $0.state) }.width(90)
                    TableColumn("Kind") { Text($0.kind.displayName) }.width(min: 90, ideal: 120)
                    TableColumn("Table") { Text("\($0.database).\($0.table)").fontWeight(.medium) }.width(min: 120, ideal: 180)
                    TableColumn("Index") { Text($0.indexName ?? "") }.width(min: 90, ideal: 150)
                    TableColumn("Created") { Text($0.createTime ?? "").monospacedDigit() }.width(min: 130, ideal: 150)
                    TableColumn("Finished") { Text($0.finishTime ?? "").monospacedDigit().foregroundStyle(.secondary) }.width(min: 130, ideal: 150)
                    TableColumn("Progress / message") { Text($0.message ?? $0.progress ?? "").foregroundStyle(.secondary).lineLimit(1) }
                    TableColumn("") { job in
                        if job.isActive { Button("Cancel") { model.confirmCancel(job) }.controlSize(.small) }
                    }
                    .width(70)
                }
            }
        }
    }
}
