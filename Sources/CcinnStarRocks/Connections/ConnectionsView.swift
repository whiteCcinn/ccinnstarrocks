import AppKit
import CcinnStarRocksKit
import StarRocksKit
import SwiftUI
import UniformTypeIdentifiers

/// Connection manager: saved profiles on the left, editor (or welcome) on the right.
struct ConnectionsView: View {
    @Bindable var session: WindowSession
    let store: ProfileStore

    @State private var selection: UUID?
    @State private var draft: ConnectionDraft?
    @State private var search = ""
    @State private var pendingDelete: ConnectionProfile?

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .onChange(of: selection) { _, newValue in
            if let profile = store.profile(id: newValue) { draft = ConnectionDraft(profile: profile, store: store) }
        }
        .onAppear {
            if draft == nil, let first = store.favorites.first ?? store.recents.first ?? store.others.first {
                selection = first.id
                draft = ConnectionDraft(profile: first, store: store)
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayName ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete {
                    store.delete(profile)
                    if selection == profile.id {
                        selection = nil
                        draft = nil
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("The saved connection and its Keychain password will be removed.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter connections", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            List(selection: $selection) {
                if !store.favorites.isEmpty { Section("Favorites") { rows(filtered(store.favorites)) } }
                if !store.recents.isEmpty { Section("Recent") { rows(filtered(store.recents)) } }
                if !store.others.isEmpty { Section("Saved") { rows(filtered(store.others)) } }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.profiles.isEmpty {
                    ContentUnavailableView("No Saved Connections", systemImage: "sparkle", description: Text("Create a connection to get started."))
                }
            }
            Button {
                newConnection()
            } label: {
                Label("New Connection", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
        .placedBelowWindowToolbar()
    }

    private func filtered(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        guard !search.isEmpty else { return profiles }
        return profiles.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.hostSummary.localizedCaseInsensitiveContains(search) }
    }

    private func rows(_ profiles: [ConnectionProfile]) -> some View {
        ForEach(profiles) { profile in
            ProfileRow(profile: profile)
                .tag(profile.id)
                .contextMenu {
                    Button("Connect") { session.connect(profile: profile, store: store) }
                    Divider()
                    Button(profile.isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(profile) }
                    Button("Duplicate") { if let copy = store.duplicate(profile) { selection = copy.id } }
                    Button("Copy mysql Command") {
                        Pasteboard.copy("mysql -h \(profile.host) -P \(profile.port) -u \(profile.username) -p")
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = profile }
                }
                .onTapGesture(count: 2) { session.connect(profile: profile, store: store) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let draft {
            ConnectionEditorView(draft: draft, store: store, session: session) { saved in selection = saved.id }
                .id(draft.profileID ?? UUID())
        } else {
            WelcomeView(onNew: newConnection)
        }
    }

    private func newConnection() {
        selection = nil
        draft = ConnectionDraft(profile: nil, store: store)
    }
}

private struct ProfileRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.color(for: profile.color).gradient)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).lineLimit(1)
                Text(profile.hostSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if profile.ssh != nil { Image(systemName: "lock.shield").foregroundStyle(.secondary).help("SSH tunnel") }
            if profile.confirmMutations { Image(systemName: "exclamationmark.shield").foregroundStyle(.orange).help("Confirms data changes") }
            if profile.mcpAccess != .disabled {
                Image(systemName: "sparkles").foregroundStyle(profile.mcpAccess == .readWrite ? .orange : Theme.accent)
                    .help("AI access via MCP: \(profile.mcpAccess.displayName)")
            }
            if profile.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small) }
        }
        .padding(.vertical, 2)
    }
}

private struct WelcomeView: View {
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            AppLogo(size: 88)
            VStack(spacing: 6) {
                Text("Welcome to CcinnStarRocks").font(.largeTitle.weight(.semibold))
                Text("A native StarRocks client for macOS.").foregroundStyle(.secondary)
            }
            Button("New Connection…", action: onNew)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            HStack(spacing: 14) {
                FeaturePill(icon: "square.split.bottomrightquarter", text: "Partitions & tablets")
                FeaturePill(icon: "square.stack.3d.up.fill", text: "Materialized views")
                FeaturePill(icon: "bolt.horizontal.circle", text: "Running tasks")
                FeaturePill(icon: "chart.bar.xaxis", text: "Charts from SQL")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Edits one connection: server, credentials, SSH tunnel and safety options.
struct ConnectionEditorView: View {
    @Bindable var draft: ConnectionDraft
    let store: ProfileStore
    let session: WindowSession
    let onSaved: (ConnectionProfile) -> Void

    @State private var saveError: String?
    @State private var showPassword = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    Form {
                        Section("Server") {
                            HStack {
                                TextField("FE host", text: $draft.host, prompt: Text("fe.example.com"))
                                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                                    .frame(width: 90)
                            }
                            TextField("Default database", text: $draft.defaultDatabase, prompt: Text("optional"))
                            TextField("Default catalog", text: $draft.defaultCatalog, prompt: Text("default_catalog"))
                        }
                        Section("Authentication") {
                            TextField("User", text: $draft.username)
                            HStack {
                                Group {
                                    if showPassword {
                                        TextField("Password", text: $draft.password)
                                    } else {
                                        SecureField("Password", text: $draft.password)
                                    }
                                }
                                Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless)
                            }
                            Toggle("Allow clear-text password (LDAP users)", isOn: $draft.allowCleartextPassword)
                            if draft.allowCleartextPassword && !draft.sshEnabled {
                                Label("The password is sent unencrypted. Prefer an SSH tunnel.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Section("SSH Tunnel") {
                            Toggle("Connect through an SSH tunnel", isOn: $draft.sshEnabled)
                            if draft.sshEnabled { sshFields }
                        }
                        Section {
                            Picker("AI access (MCP)", selection: $draft.mcpAccess) {
                                ForEach(MCPAccess.allCases) { Text($0.displayName).tag($0) }
                            }
                            Text(mcpHint)
                                .font(.caption)
                                .foregroundStyle(draft.mcpAccess == .readWrite ? Color.orange : Color.secondary)
                        } header: {
                            Text("AI access")
                        }
                        Section("Safety & timeouts") {
                            Toggle("Ask before running statements that change data or schema", isOn: $draft.confirmMutations)
                            TextField("Connect timeout (seconds)", value: $draft.connectTimeout, format: .number)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)

                    testResult
                    ForEach(draft.validationErrors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                    if let saveError { ErrorBanner(message: saveError) { self.saveError = nil } }
                    if let error = session.connectError { ErrorBanner(message: error) { session.connectError = nil } }
                }
                .padding(28)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            Divider()
            actionBar
        }
    }

    private var mcpHint: String {
        switch draft.mcpAccess {
        case .disabled: "AI clients connected to the CcinnStarRocks MCP server cannot see this connection. Set up the server in Settings → MCP."
        case .readOnly: "AI clients may browse metadata and run read-only queries (SELECT, SHOW, DESC, EXPLAIN), limited to 1,000 rows per call."
        case .readWrite: "AI clients may also run statements that change data or schema. Use only for development clusters."
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(Theme.color(for: draft.color).gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "sparkle").foregroundStyle(.white).font(.system(size: 15, weight: .semibold)))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Connection name", text: $draft.name, prompt: Text(draft.host.isEmpty ? "Untitled connection" : draft.host))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(ProfileColor.allCases.filter { $0 != .none }) { color in
                        Button {
                            draft.color = color
                        } label: {
                            Circle()
                                .fill(Theme.color(for: color))
                                .frame(width: 13, height: 13)
                                .overlay(Circle().strokeBorder(.primary.opacity(draft.color == color ? 0.8 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(color.rawValue.capitalized)
                    }
                }
            }
            Spacer()
            Toggle(isOn: $draft.isFavorite) { Image(systemName: draft.isFavorite ? "star.fill" : "star") }
                .toggleStyle(.button)
                .help("Favorite")
        }
    }

    @ViewBuilder
    private var sshFields: some View {
        TextField("SSH host", text: $draft.ssh.host, prompt: Text("bastion.example.com"))
        TextField("SSH port", value: $draft.ssh.port, format: .number.grouping(.never))
        TextField("SSH user", text: $draft.ssh.username)
        Picker("Authentication", selection: $draft.ssh.authentication) {
            Text("SSH agent / ~/.ssh/config").tag(SSHTunnelConfiguration.Authentication.agent)
            Text("Password").tag(SSHTunnelConfiguration.Authentication.password)
            Text("Private key").tag(SSHTunnelConfiguration.Authentication.privateKey)
        }
        switch draft.ssh.authentication {
        case .password:
            SecureField("SSH password", text: $draft.sshSecret)
        case .privateKey:
            LabeledContent("Private key") {
                HStack {
                    TextField("", text: Binding(get: { draft.ssh.privateKeyPath ?? "" }, set: { draft.ssh.privateKeyPath = $0 }), prompt: Text("~/.ssh/id_ed25519"))
                        .labelsHidden()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.showsHiddenFiles = true
                        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                        if panel.runModal() == .OK, let url = panel.url { draft.ssh.privateKeyPath = url.path }
                    }
                }
            }
            SecureField("Passphrase (optional)", text: $draft.sshSecret)
        case .agent:
            EmptyView()
        }
        Text("Uses the system OpenSSH client, so ~/.ssh/config, known hosts and ssh-agent work as in Terminal. Traffic is forwarded to the FE host and port above.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var testResult: some View {
        switch draft.testState {
        case .idle:
            EmptyView()
        case let .running(status):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { draft.cancelTest() }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        case let .succeeded(message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        case let .failed(message):
            ErrorBanner(message: message) { draft.testState = .idle }
        }
    }

    private var actionBar: some View {
        HStack {
            Button { draft.test() } label: { Label("Test", systemImage: "bolt.horizontal.circle") }
                .disabled(!draft.isValid)
            Spacer()
            Button("Save") { _ = save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!draft.isValid)
            Button {
                if let profile = save() { session.connect(profile: profile, store: store) }
            } label: {
                Text(draft.profileID == nil ? "Save & Connect" : "Connect").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func save() -> ConnectionProfile? {
        do {
            let saved = try store.save(draft.makeProfile(), password: draft.password, sshSecret: draft.sshEnabled ? draft.sshSecret : nil)
            saveError = nil
            onSaved(saved)
            return saved
        } catch {
            saveError = describe(error)
            return nil
        }
    }
}
