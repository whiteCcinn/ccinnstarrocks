import AppKit
import CcinnStarRocksKit
import SwiftUI

/// File ▸ Export / Import Settings and Knowledge: one window that walks through the export form, the passphrase, the
/// import preview and the report.
struct BackupWindow: View {
    static let id = "backup"

    @Bindable var center: BackupCenter

    var body: some View {
        Group {
            switch center.stage {
            case .home: home
            case .exportForm: BackupExportForm(center: center)
            case let .working(message): working(message)
            case .exported: exported
            case .passphrase: BackupPassphraseView(center: center)
            case .preview: BackupPreview(center: center)
            case .report: BackupReportView(center: center)
            case let .failed(message): failed(message)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 640)
        .onDisappear { center.windowClosed() }
    }

    private var home: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.timemachine").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Move your setup to another Mac").font(.title2.weight(.semibold))
            Text("A backup holds your connections, the knowledge AI built about your databases and the projects linked to them, and your settings. Passwords are included only when you protect them with a passphrase.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack {
                Button("Export…") { center.beginExport() }
                Button("Import…") { Task { await center.beginImport() } }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func working(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var exported: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Backup written", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.green)
            if let result = center.exportResult {
                Text(result.url.path).font(Theme.monospacedSmall).textSelection(.enabled)
                Text(summary(result))
                if !result.warnings.isEmpty { BackupWarningList(warnings: result.warnings) }
                Text("Keep this file somewhere safe: it describes how to reach your clusters. On the other Mac choose File ▸ Import Settings and Knowledge…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Show in Finder") {
                    if let url = center.exportResult?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("Done") { center.showHome() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func summary(_ result: BackupCenter.ExportResult) -> String {
        let connections = result.profileCount == 1 ? "1 connection" : "\(result.profileCount) connections"
        if result.secretCount > 0 { return "\(connections); the passwords of \(result.secretCount) are encrypted with your passphrase." }
        if result.isPassphraseProtected { return "\(connections). None has a saved password; the file is sealed with your passphrase." }
        return "\(connections), without passwords."
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 480)
            Button("OK") { center.showHome() }.keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Export

private struct BackupExportForm: View {
    @Bindable var center: BackupCenter

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: .constant(true)) {
                        Text("Connections")
                        Text("\(center.stores.profiles.profiles.count) saved. Host, port, user, SSH route and AI access; never the SSH key files.")
                    }
                    .accessibilityLabel("Connections")
                    .disabled(true)
                    Toggle(isOn: $center.includeKnowledge) {
                        Text("Knowledge and linked projects")
                        Text("Relationships, notes, glossary and subject areas, and which local projects each database is linked to.")
                    }
                    .accessibilityLabel("Knowledge and linked projects")
                    Toggle(isOn: $center.includeSettings) {
                        Text("App settings")
                        Text("Appearance, automatic LIMIT, SQL formatting, update checks.")
                    }
                    .accessibilityLabel("App settings")
                    Toggle(isOn: $center.includeHistory) {
                        Text("Query history")
                        Text("Statements you ran, with passwords in them removed. They may still name tables and contain literal values.")
                    }
                    .accessibilityLabel("Query history")
                } header: {
                    Text("Include")
                }
                Section {
                    Toggle(isOn: $center.includePasswords) {
                        Text("Include passwords and SSH secrets")
                        Text("Encrypted with a passphrase you choose (AES-256-GCM). It is never stored: without it the passwords cannot be recovered.")
                    }
                    .accessibilityLabel("Include passwords and SSH secrets")
                    if center.includePasswords {
                        SecureField("Passphrase", text: $center.passphrase, prompt: Text("At least \(BackupFormat.minimumPassphraseLength) characters"))
                        SecureField("Repeat passphrase", text: $center.passphraseConfirmation)
                        if let problem = center.exportProblem, !center.passphrase.isEmpty {
                            Text(problem).font(.callout).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Passwords")
                } footer: {
                    if !center.includePasswords {
                        Text("Without passwords you enter them again on the other Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { center.showHome() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { Task { await center.export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(center.exportProblem != nil)
            }
            .padding(16)
        }
        .navigationTitle("Export Settings and Knowledge")
    }
}

// MARK: - Passphrase

private struct BackupPassphraseView: View {
    @Bindable var center: BackupCenter
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("This backup is protected with a passphrase", systemImage: "lock.fill").font(.title2.weight(.semibold))
            if let url = center.importURL { Text(url.lastPathComponent).font(Theme.monospacedSmall).foregroundStyle(.secondary) }
            if center.secretsRefused {
                Label(center.passphraseMessage ?? "", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enter the passphrase it was made with: it opens the passwords inside and proves the file was not changed since. Without it everything except the passwords can still be imported.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Passphrase", text: $center.importPassphrase)
                    .focused($focused)
                    .onSubmit { Task { await center.unlock() } }
                    .frame(maxWidth: 360)
                if let message = center.passphraseMessage { Text(message).font(.callout).foregroundStyle(.red) }
            }
            Spacer()
            HStack {
                Button("Cancel") { center.showHome() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import Without Passwords") { Task { await center.continueWithoutPasswords() } }
                if !center.secretsRefused {
                    Button("Unlock") { Task { await center.unlock() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(center.importPassphrase.isEmpty)
                }
            }
        }
        .padding(24)
        .onAppear { focused = true }
    }
}

// MARK: - Preview

private struct BackupPreview: View {
    @Bindable var center: BackupCenter

    var body: some View {
        VStack(spacing: 0) {
            if let plan = center.plan {
                Form {
                    origin(plan)
                    if !plan.warnings.isEmpty {
                        Section("Notes") { BackupWarningList(warnings: plan.warnings.map(\.description)) }
                    }
                    connections(plan)
                    if let knowledge = plan.knowledge { self.knowledge(knowledge) }
                    if !plan.settings.isEmpty { settings(plan) }
                    if !plan.historyChanges.isEmpty { history(plan) }
                }
                .formStyle(.grouped)
                Divider()
                footer(plan)
            }
        }
        .navigationTitle("Import Settings and Knowledge")
    }

    private func origin(_ plan: BackupImportPlan) -> some View {
        Section {
            if let header = center.header {
                LabeledContent("Made", value: "\(header.createdAt.formatted(date: .abbreviated, time: .shortened)) by CcinnStarRocks \(header.appVersion)")
            }
            LabeledContent("Imports into") {
                Text(ProfileRepository.defaultDirectory.path).font(Theme.monospacedSmall).textSelection(.enabled)
            }
            if plan.isAuthenticated {
                Label("Verified with the passphrase: the file is unchanged since it was made.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Not verified: without a passphrase anyone could have written this file. Changes that weaken security (another server, more AI access, clear-text passwords, no confirmation before changes) keep your current settings unless you choose otherwise.",
                      systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(center.importURL?.lastPathComponent ?? "Backup")
        }
    }

    private func connections(_ plan: BackupImportPlan) -> some View {
        Section {
            ForEach(plan.profiles) { item in
                BackupProfileRow(item: item) { resolution in center.resolve(item.id, as: resolution) }
            }
        } header: {
            Text("Connections · \(plan.profiles.count)")
        }
    }

    private func knowledge(_ knowledge: BackupKnowledgePlan) -> some View {
        Section {
            ForEach(knowledge.databases) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.key.database).font(.body.weight(.medium))
                        Text(item.key.cluster.rawValue).font(Theme.monospacedSmall).foregroundStyle(.secondary)
                        if !item.hasMatchingConnection {
                            Text("No connection reaches this cluster yet; it is used once one does.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(Self.describe(item.changes)).font(.caption).foregroundStyle(.secondary)
                    BackupStatusBadge(databaseStatus: item.status)
                }
            }
            ForEach(knowledge.projects) { project in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(project.name).font(.body.weight(.medium))
                            if project.isMissing { Badge(text: "Not on this Mac", color: .orange, systemImage: "questionmark.folder") }
                            if project.localMatch != nil { Badge(text: "Already linked", color: .secondary) }
                        }
                        Text(project.path).font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled)
                        if project.path != project.originalPath {
                            Text("was \(project.originalPath)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let remote = project.gitRemote { Text(remote).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Choose Folder…") { center.remapProject(project.id) }.controlSize(.small)
                }
            }
            if knowledge.projects.contains(where: \.isMissing) {
                HStack {
                    Text("Move projects from")
                    TextField("", text: $center.remapFrom, prompt: Text("/Volumes/Work/code")).font(Theme.monospacedSmall)
                    Text("to")
                    TextField("", text: $center.remapTo, prompt: Text("~/code")).font(Theme.monospacedSmall)
                    Button("Apply") { center.remapCommonPrefix() }
                        .disabled(center.remapFrom.trimmingCharacters(in: .whitespaces).isEmpty || center.remapTo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
            if let message = center.remapMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Knowledge · \(knowledge.databases.count) databases · \(knowledge.projects.count) projects")
        } footer: {
            Text("Knowledge merges item by item: nothing on this Mac is lost, deletions in the backup are applied, and the newer copy of a note wins.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func describe(_ changes: BackupKnowledgeChanges) -> String {
        if changes.isEmpty { return "" }
        var parts: [String] = []
        func add(_ count: Int, _ noun: String) { if count > 0 { parts.append("\(count) \(noun)") } }
        add(changes.tablesAdded + changes.tablesUpdated, "tables")
        add(changes.relationshipsAdded + changes.relationshipsUpdated, "relationships")
        add(changes.notesAdded + changes.notesUpdated, "notes")
        add(changes.termsAdded + changes.termsUpdated, "terms")
        add(changes.areasAdded + changes.areasUpdated, "areas")
        add(changes.removed, "removed")
        return parts.joined(separator: " · ")
    }

    private func settings(_ plan: BackupImportPlan) -> some View {
        Section("Settings") {
            ForEach(plan.settings) { item in
                Toggle(isOn: Binding(get: { item.isIncluded && !item.isUnchanged }, set: { center.include(setting: item.key, $0) })) {
                    HStack {
                        Text(Self.settingName(item.key))
                        Spacer()
                        if item.isUnchanged {
                            Text("unchanged").foregroundStyle(.secondary)
                        } else {
                            Text("\(item.current?.displayValue ?? "default") → \(item.imported.displayValue)").monospacedDigit()
                        }
                    }
                }
                .disabled(item.isUnchanged)
                .accessibilityLabel(Self.settingName(item.key))
            }
        }
    }

    private static func settingName(_ key: String) -> String {
        switch key {
        case "appearance": "Appearance"
        case "autoLimit": "Automatic LIMIT"
        case "sqlFormatKeywordCase": "Format SQL: keyword case"
        case "sqlFormatIndent": "Format SQL: indent"
        case "updates.automaticallyCheck": "Check for updates automatically"
        default: key
        }
    }

    private func history(_ plan: BackupImportPlan) -> some View {
        Section("Query history") {
            ForEach(plan.historyChanges, id: \.profileID) { change in
                LabeledContent(center.profileName(change.profileID), value: change.newEntries == 1 ? "1 statement" : "\(change.newEntries) statements")
            }
        }
    }

    private func footer(_ plan: BackupImportPlan) -> some View {
        HStack {
            Button("Cancel") { center.showHome() }.keyboardShortcut(.cancelAction)
            Spacer()
            if plan.isUnchanged {
                Text("Everything in this backup is already on this Mac.").foregroundStyle(.secondary)
            } else {
                Text("Your current setup is saved first, so the import can be undone.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Import") { Task { await center.performImport() } }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isUnchanged)
        }
        .padding(16)
    }
}

private struct BackupProfileRow: View {
    let item: BackupProfileItem
    let resolve: (BackupProfileItem.Resolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.imported.displayName).font(.body.weight(.medium))
                    Text(endpoint).font(Theme.monospacedSmall).foregroundStyle(.secondary)
                }
                Spacer()
                if item.includesSecrets { Badge(text: "Password", color: .secondary, systemImage: "key.fill") }
                BackupStatusBadge(profileStatus: item.status)
            }
            if !item.flags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(BackupProfileItem.Flag.allCases.filter { item.flags.contains($0) }, id: \.self) { flag in
                        Badge(text: Self.label(flag), color: Self.isSecurity(flag) ? .orange : .secondary, systemImage: Self.symbol(flag))
                    }
                }
            }
            if item.status == .conflict {
                Picker("", selection: Binding(get: { item.resolution }, set: { resolve($0) })) {
                    ForEach(BackupProfileItem.Resolution.allCases) { resolution in
                        Text(Self.label(resolution, suggested: resolution == item.defaultResolution)).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private var endpoint: String {
        let profile = item.imported
        var text = "\(profile.username)@\(profile.host):\(profile.port)"
        if let ssh = profile.ssh { text += " via \(ssh.username)@\(ssh.host)" }
        return text
    }

    private static func label(_ resolution: BackupProfileItem.Resolution, suggested: Bool) -> String {
        let text = switch resolution {
        case .keepMine: "Keep mine"
        case .useImported: "Use imported"
        case .keepBoth: "Keep both"
        }
        return suggested ? text + " (suggested)" : text
    }

    private static func label(_ flag: BackupProfileItem.Flag) -> String {
        switch flag {
        case .aiAccessChanged: "AI access differs"
        case .privilegedOptInReset: "Admin-account AI opt-in turned off"
        case .endpointChanged: "Different server or SSH route"
        case .cleartextPasswordEnabled: "Sends password in clear text"
        case .mutationConfirmationDisabled: "No confirmation before changes"
        case .missingSSHKey: "SSH key not on this Mac"
        case .secretsDiffer: "Password differs"
        }
    }

    private static func symbol(_ flag: BackupProfileItem.Flag) -> String {
        switch flag {
        case .aiAccessChanged, .privilegedOptInReset: "sparkles"
        case .endpointChanged: "arrow.triangle.branch"
        case .cleartextPasswordEnabled, .secretsDiffer: "key"
        case .mutationConfirmationDisabled: "exclamationmark.triangle"
        case .missingSSHKey: "questionmark.folder"
        }
    }

    private static func isSecurity(_ flag: BackupProfileItem.Flag) -> Bool {
        flag != .missingSSHKey && flag != .secretsDiffer
    }
}

private struct BackupStatusBadge: View {
    let text: String
    let color: Color

    init(profileStatus: BackupProfileItem.Status) {
        switch profileStatus {
        case .new: (text, color) = ("New", .green)
        case .unchanged: (text, color) = ("Unchanged", .secondary)
        case .conflict: (text, color) = ("Differs", .orange)
        }
    }

    init(databaseStatus: BackupDatabaseItem.Status) {
        switch databaseStatus {
        case .new: (text, color) = ("New", .green)
        case .merged: (text, color) = ("Merge", .blue)
        case .unchanged: (text, color) = ("Unchanged", .secondary)
        case .skipped: (text, color) = ("Skipped", .orange)
        }
    }

    var body: some View { Badge(text: text, color: color) }
}

private struct BackupWarningList: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Report

private struct BackupReportView: View {
    @Bindable var center: BackupCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let report = center.report {
                headline(report)
                counts(report)
                if !report.warnings.isEmpty { BackupWarningList(warnings: report.warnings.map(\.description)) }
                if report.needsMCPRestart {
                    Label("Restart the MCP server in your AI clients (for example /mcp in Claude Code) so they see the connections.",
                          systemImage: "sparkles")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let snapshot = report.snapshotURL, center.canRestore {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your setup before the import was saved to").font(.callout).foregroundStyle(.secondary)
                        Text(snapshot.path).font(Theme.monospacedSmall).textSelection(.enabled)
                        Text("Restore undoes what this import wrote: connections it added or replaced (unless you changed them since), the passwords it added, knowledge, history and settings. Passwords it replaced cannot be put back.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
            HStack {
                if center.canRestore {
                    Button("Restore Pre-Import Snapshot") { Task { await center.restoreSnapshot() } }
                }
                Spacer()
                Button("Done") { center.showHome() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func headline(_ report: BackupImportReport) -> some View {
        let action = center.reportIsRestore ? "Restore" : "Import"
        if report.succeeded {
            Label("\(action) complete", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.green)
        } else {
            Label("\(action) stopped at \(report.failedStep?.rawValue ?? "a step")", systemImage: "xmark.octagon.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(.red)
            Text(report.failureMessage ?? "").textSelection(.enabled)
            Text("Done before it: \(report.completedSteps.map(\.rawValue).joined(separator: ", ")).").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func counts(_ report: BackupImportReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row(center.reportIsRestore ? "Connections put back or removed" : "Connections saved", report.profilesSaved)
            if center.reportIsRestore {
                row("Passwords removed from the Keychain", report.secretsRemoved)
            } else {
                row("Passwords stored in the Keychain", report.secretsWritten)
            }
            if !center.reportIsRestore { row("Knowledge databases merged", report.databasesMerged) }
            if !center.reportIsRestore { row("History statements added", report.historyEntriesAdded) }
            row("Settings changed", report.settingsChanged)
        }
    }

    private func row(_ title: String, _ count: Int) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text("\(count)").monospacedDigit()
        }
    }
}
