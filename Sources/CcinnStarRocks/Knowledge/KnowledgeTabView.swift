import CcinnStarRocksKit
import SwiftUI

/// A database's knowledge: what the app inferred, what AI sessions added, and the user's verdicts.
struct KnowledgeTabView: View {
    @Bindable var model: KnowledgeTabModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if model.knowledge == nil {
                    ContentUnavailableView {
                        Label("No knowledge yet", systemImage: "books.vertical")
                    } description: {
                        Text("Refresh reads the structure of \(model.key.database) (metadata only) and infers relationships from names, constraints, view definitions and your query history. AI clients connected over MCP build it on first use too.")
                    } actions: {
                        Button("Refresh") { Task { await model.refresh() } }.disabled(model.isRefreshing)
                    }
                } else {
                    switch model.section {
                    case .relationships: relationships
                    case .notes: notes
                    case .glossary: glossary
                    case .diagram: diagram
                    case .projects: projects
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            model.startWatching()
            await model.load()
        }
        .onDisappear { model.stopWatching() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.key.database).font(.title3.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.section) {
                ForEach(KnowledgeTabModel.Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(model.isRefreshing)
            .help("Re-read the structure and recompute inferred relationships")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: String {
        guard let knowledge = model.knowledge else { return model.error ?? "Not built yet" }
        let live = knowledge.tables.filter { $0.state != .dropped }
        let changed = live.filter { $0.state == .changed }.count
        let refreshed = knowledge.refreshedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
        return "\(live.count) tables\(changed > 0 ? ", \(changed) changed" : "") · \(knowledge.relationships.filter { $0.kind != .lineage }.count) relationships · \(knowledge.notes.count) notes · refreshed \(refreshed)"
    }

    // MARK: Sections

    private var relationships: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $model.filter) {
                ForEach(KnowledgeTabModel.RelationshipFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding([.horizontal, .top], 16)
            Table(model.relationships) {
                TableColumn("From") { Text(end($0.from)).font(Theme.monospacedSmall).textSelection(.enabled) }
                TableColumn("To") { Text(end($0.to)).font(Theme.monospacedSmall).textSelection(.enabled) }
                TableColumn("Confidence") { relationship in
                    Text("\(model.confidence(relationship))%").monospacedDigit()
                }
                .width(80)
                TableColumn("Evidence") { relationship in
                    Text(Set(relationship.evidence.map(\.source.rawValue)).sorted().joined(separator: ", ")).font(.caption)
                }
                TableColumn("State") { relationship in
                    let state = model.state(of: relationship)
                    Text(state).font(.caption).foregroundStyle(state == "fresh" ? Color.secondary : Color.orange)
                }
                .width(60)
                TableColumn("") { relationship in
                    HStack(spacing: 6) {
                        Button("Confirm") { model.decide(relationship, accept: true) }
                            .disabled(relationship.status == .confirmed)
                        Button("Reject") { model.decide(relationship, accept: false) }
                            .disabled(relationship.status == .rejected)
                    }
                    .controlSize(.small)
                }
                .width(150)
            }
        }
    }

    private func end(_ end: Relationship.End) -> String {
        (end.database.map { $0 + "." } ?? "") + end.table + "(" + end.columns.joined(separator: ", ") + ")"
    }

    private var notes: some View {
        List {
            ForEach(model.knowledge?.notes ?? [], id: \.id) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(note.table + (note.column.map { "." + $0 } ?? "")).font(Theme.monospacedSmall.weight(.semibold))
                        Badge(text: note.kind.rawValue, color: .secondary)
                        if model.isStale(note) { Badge(text: "Stale", color: .orange, systemImage: "exclamationmark.triangle") }
                        Spacer()
                        Text("\(note.by) · \(note.at.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) { model.delete(note.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this note")
                    }
                    Text(note.text).font(.callout).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
        .overlay {
            if model.knowledge?.notes.isEmpty ?? true {
                ContentUnavailableView("No notes", systemImage: "note.text", description: Text("AI sessions add notes with add_notes; ask one to run the build_knowledge prompt."))
            }
        }
    }

    private var glossary: some View {
        List {
            ForEach(model.knowledge?.terms ?? [], id: \.id) { term in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(term.term).font(.headline)
                        if !term.synonyms.isEmpty { Text(term.synonyms.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(term.by).font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) { model.delete(term.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    Text(term.definition).font(.callout).textSelection(.enabled)
                    ForEach(Array(term.mapsTo.enumerated()), id: \.offset) { _, mapping in
                        Text("→ \(mapping.table)\(mapping.column.map { "." + $0 } ?? "")\(mapping.expression.map { ": " + $0 } ?? "")")
                            .font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .overlay {
            if model.knowledge?.terms.isEmpty ?? true {
                ContentUnavailableView("No glossary terms", systemImage: "character.book.closed")
            }
        }
    }

    private var diagram: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Subject area", selection: Binding(get: { model.diagramArea ?? "" }, set: { model.diagramArea = $0; model.renderDiagram() })) {
                    ForEach(model.areas, id: \.name) { area in Text("\(area.name) · \(area.tables.count)").tag(area.name) }
                }
                .frame(maxWidth: 420)
                Spacer()
                Button("Copy Mermaid") { Pasteboard.copy(model.diagramText) }.disabled(model.diagramText.isEmpty)
            }
            ScrollView {
                Text(model.diagramText.isEmpty ? "No subject areas yet: they appear once relationships connect tables, or when a name prefix groups three or more." : model.diagramText)
                    .font(Theme.monospacedSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text("Mermaid text renders in GitHub, Notion, VS Code and most Markdown viewers. Solid lines: confirmed, declared or ≥ 70% confidence; dashed: inferred below 70%, stale, or a view reading a table.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local projects linked to \(model.key.database). AI sessions started in one of them find this knowledge with list_knowledge.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Link Project…") {
                    if let path = model.chooseDirectory(prompt: "Link") { model.link(path: path) }
                }
            }
            List(model.projects, id: \.id) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(project.name).font(.headline)
                            if !model.projectExists(project) { Badge(text: "Missing on this Mac", color: .orange, systemImage: "questionmark.folder") }
                        }
                        Text(project.path).font(Theme.monospacedSmall).foregroundStyle(.secondary)
                        if let remote = project.gitRemote { Text(remote).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Remap…") {
                        if let path = model.chooseDirectory(prompt: "Use") { model.remap(project, to: path) }
                    }
                    Button("Unlink") { model.unlink(project) }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}
