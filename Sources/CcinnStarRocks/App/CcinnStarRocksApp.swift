import AppKit
import CcinnStarRocksKit
import StarRocksKit
import SwiftUI

struct CcinnStarRocksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        // Every window has its own connection. A request opens a window that connects right away.
        WindowGroup("CcinnStarRocks", id: RootView.windowGroupID, for: WindowRequest.self) { $request in
            RootView(request: request)
                .frame(minWidth: 1040, minHeight: 640)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
            UpdateCommands()
        }

        Settings {
            SettingsTabs()
            .frame(width: 620)
            .tint(Theme.accent)
        }

        SoftwareUpdateScene()
    }
}

private struct SettingsTabs: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            MCPSettingsView(store: AppServices.shared.profiles)
                .tabItem { Label("MCP", systemImage: "sparkles") }
                .tag("mcp")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restored windows would only reopen the connection screen; start with one clean window.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Behave like a regular app when launched from `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        SnapshotTool.scheduleIfRequested()
        UpdateController.shared.scheduleAutomaticCheck()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Close SSH port forwards synchronously; detached cleanup tasks do not run during exit.
        SSHTunnel.terminateAll()
    }
}

/// Per-window root: connection manager, progress, or workspace.
struct RootView: View {
    static let windowGroupID = "main"

    /// Set when the window was opened for a connection (Open in New Window, New Window with This Connection).
    let request: WindowRequest?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var session = WindowSession()
    private let store = AppServices.shared.profiles

    var body: some View {
        Group {
            switch session.phase {
            case .connections:
                ConnectionsView(session: session, store: store)
                    .transition(.opacity)
            case let .connecting(name, status):
                ConnectingView(name: name, status: status) { session.cancelConnecting() }
                    .transition(.opacity)
            case let .connected(workspace):
                WorkspaceView(workspace: workspace, session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .presentsSoftwareUpdates()
        .onDisappear { session.disconnect() }
        .task {
            if let request {
                session.connect(request, store: store)
                return
            }
            LaunchArguments.consume(into: session, store: store) { openWindow(id: Self.windowGroupID, value: $0) }
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--settings"), arguments.indices.contains(index + 1) {
                UserDefaults.standard.set(arguments[index + 1], forKey: "settingsTab")
                openSettings()
            }
        }
    }

    private var phaseKey: Int {
        switch session.phase {
        case .connections: 0
        case .connecting: 1
        case .connected: 2
        }
    }

    private var windowTitle: String {
        switch session.phase {
        case .connections: "CcinnStarRocks — Connections"
        case let .connecting(name, _): "Connecting to \(name)"
        case let .connected(workspace): workspace.profile.displayName
        }
    }
}

/// Full-window progress while a connection is being established.
struct ConnectingView: View {
    let name: String
    let status: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 64).symbolEffect(.pulse)
            Text("Connecting to \(name)").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Developer conveniences and automated visual checks:
/// `CcinnStarRocks --connect host:port [--user u] [--database db] [--object db.name]
///  [--section overview|partitions|tablets|refreshes|columns|ddl|data] [--sql "…"] [--auto-run]
///  [--view grid|chart|plan] [--operations running|sessions|loads|cluster|configuration|…]
///  [--load-type STREAM_LOAD] [--load-database db] [--load-search text] [--load-history]
///  [--config-scope variables|frontend|backend] [--config-search text] [--duplicate-window] [--profile name]`
@MainActor
enum LaunchArguments {
    private static var consumed = false

    static func consume(into session: WindowSession, store: ProfileStore, openWindow: @escaping @MainActor (WindowRequest) -> Void) {
        guard !consumed else { return }
        consumed = true
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let profile: ConnectionProfile
        var password: String?
        if let name = value("--profile"), let saved = store.profiles.first(where: { $0.displayName == name }) {
            profile = saved
        } else if let raw = value("--connect") {
            let parts = raw.split(separator: ":")
            let host = parts.first.map(String.init) ?? "127.0.0.1"
            let port = parts.count > 1 ? Int(parts[1]) ?? 9030 : 9030
            profile = ConnectionProfile(name: "\(host):\(port)", host: host, port: port, username: value("--user") ?? "root",
                                        defaultDatabase: value("--database"), color: .indigo,
                                        connectTimeout: value("--connect-timeout").flatMap(Double.init) ?? 30)
            // Passwords never go on the command line (visible to other processes); use the environment.
            password = ProcessInfo.processInfo.environment["CCINNSTARROCKS_PASSWORD"] ?? ""
        } else {
            return
        }
        session.connect(profile: profile, store: store, password: password) { workspace in
            Task { @MainActor in
                if let target = value("--object"), let dot = target.firstIndex(of: ".") {
                    let database = String(target[..<dot])
                    let name = String(target[target.index(after: dot)...])
                    workspace.setExpanded(database, true)
                    if let object = await workspace.awaitObjects(database: database)?.first(where: { $0.name == name }) {
                        let section = value("--section").flatMap { raw in
                            ObjectDetailModel.Section.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
                        }
                        workspace.openObject(object, section: section)
                    }
                }
                if let sql = value("--sql") {
                    let model = workspace.openSQL(text: sql.replacingOccurrences(of: "\\n", with: "\n"), database: value("--database"))
                    if arguments.contains("--auto-run") {
                        model.runAll()
                        if let view = value("--view"), let mode = StatementOutcome.ViewMode.allCases.first(where: { $0.rawValue.lowercased() == view.lowercased() }) {
                            for _ in 0..<100 where model.isRunning || model.outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                            model.selectedOutcome?.viewMode = mode
                        }
                    }
                }
                if arguments.contains("--duplicate-window"), let request = session.duplicateRequest() { openWindow(request) }
                if let raw = value("--operations"),
                   let section = OperationsModel.Section.allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(raw.lowercased()) }) {
                    if section == .loads, value("--load-type") != nil || value("--load-database") != nil {
                        workspace.openLoads(database: value("--load-database"), type: value("--load-type"))
                    } else {
                        workspace.openOperations(section: section)
                    }
                    if let model = workspace.selectedOperations {
                        if let keyword = value("--load-search") { model.loadFilter.keyword = keyword }
                        if arguments.contains("--load-history") { model.includeLoadHistory = true }
                        if let raw = value("--config-scope"), let scope = ConfigItem.Scope(rawValue: raw) { model.configurationScope = scope }
                        if let search = value("--config-search") { model.configurationSearch = search }
                    }
                }
            }
        }
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot]`: renders the key window
/// into a PNG (used for automated visual checks; needs no screen-recording permission).
@MainActor
enum SnapshotTool {
    static func scheduleIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else { return }
        let path = arguments[index + 1]
        var delay = 6.0
        if let delayIndex = arguments.firstIndex(of: "--snapshot-delay"), arguments.indices.contains(delayIndex + 1),
           let parsed = Double(arguments[delayIndex + 1]) {
            delay = parsed
        }
        let quit = arguments.contains("--quit-after-snapshot")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var candidates = [NSApp.keyWindow].compactMap { $0 } + NSApp.windows
            if let titleIndex = arguments.firstIndex(of: "--snapshot-window"), arguments.indices.contains(titleIndex + 1) {
                let title = arguments[titleIndex + 1]
                candidates = NSApp.windows.filter { $0.title.localizedCaseInsensitiveContains(title) } + candidates
            }
            if let window = candidates.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
               let view = window.contentView?.superview ?? window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if quit { NSApp.terminate(nil) }
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("autoLimit") private var autoLimit = 1000

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Automatic LIMIT for SELECT", selection: $autoLimit) {
                Text("None").tag(0)
                ForEach([100, 500, 1000, 5000, 10_000, 50_000], id: \.self) { Text($0.formatted()).tag($0) }
            }
            LabeledContent("Saved connections") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ProfileRepository.defaultDirectory])
                }
            }
            UpdateSettingsSections()
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Commands

struct WindowSessionKey: FocusedValueKey {
    typealias Value = WindowSession
}

extension FocusedValues {
    var windowSession: WindowSession? {
        get { self[WindowSessionKey.self] }
        set { self[WindowSessionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // File ▸ New Window (⌘N) comes from the window group and opens the connection screen.
            Button("New Window with This Connection") {
                if let request = session?.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(session?.workspace == nil)
            Divider()
            Button("New Query") { session?.workspace?.openSQL() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session?.workspace == nil)
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
        CommandMenu("Cluster") {
            Button("Refresh Catalog") { session?.workspace?.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Running Now") { session?.workspace?.openOperations(section: .running) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Button("Sessions") { session?.workspace?.openOperations(section: .sessions) }
                .disabled(session?.workspace == nil)
            Button("Loads") { session?.workspace?.openLoads() }
                .disabled(session?.workspace == nil)
            Button("Stream Loads") { session?.workspace?.openLoads(type: "STREAM_LOAD") }
                .disabled(session?.workspace == nil)
            Button("Cluster Nodes") { session?.workspace?.openOperations(section: .cluster) }
                .disabled(session?.workspace == nil)
            Button("Configuration") { session?.workspace?.openOperations(section: .configuration) }
                .disabled(session?.workspace == nil)
            Divider()
            Button("Close Tab") { session?.workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedTab == nil)
            Button("Next Tab") { session?.workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Previous Tab") { session?.workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
    }
}
