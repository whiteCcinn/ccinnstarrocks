import AppKit
import CcinnStarRocksKit
import SwiftUI

/// App-menu and Help-menu items for updates and the project links (design D8).
struct UpdateCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.productName)") { AboutPanel.show() }
            Button("Check for Updates…") {
                UpdateController.shared.reset()
                UpdateController.shared.checkForUpdates(automatic: false)
                openWindow(id: SoftwareUpdateView.windowID)
            }
        }
        CommandGroup(replacing: .help) {
            Button("\(AppInfo.productName) on GitHub") { NSWorkspace.shared.open(AppInfo.links.repository) }
            Button("Release Notes") { NSWorkspace.shared.open(AppInfo.links.releases) }
            Divider()
            Button("Report an Issue…") { NSWorkspace.shared.open(AppInfo.links.newIssue) }
        }
    }
}

/// Brings the Software Update window forward when the controller asks (an automatic check found an update,
/// a download finished) and handles `--check-updates`. Attach once to each main window's root view.
struct UpdateWindowPresenter: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    private let updates = UpdateController.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: updates.windowRequest) { openWindow(id: SoftwareUpdateView.windowID) }
            .task { updates.checkIfRequestedAtLaunch() }
    }
}

extension View {
    func presentsSoftwareUpdates() -> some View { modifier(UpdateWindowPresenter()) }
}

/// The Updates and About sections of Settings → General.
struct UpdateSettingsSections: View {
    @AppStorage(UpdateController.automaticCheckKey) private var automaticallyCheck = true
    @Environment(\.openWindow) private var openWindow
    private let updates = UpdateController.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $automaticallyCheck)
            LabeledContent("Last checked") {
                HStack(spacing: 10) {
                    Text(updates.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                        .foregroundStyle(.secondary)
                    Button("Check Now") {
                        updates.reset()
                        updates.checkForUpdates(automatic: false)
                        openWindow(id: SoftwareUpdateView.windowID)
                    }
                }
            }
        }
        Section("About") {
            LabeledContent("Version", value: AppInfo.version)
            LabeledContent("Project") {
                HStack(spacing: 12) {
                    Link("GitHub", destination: AppInfo.links.repository)
                    Link("Release Notes", destination: AppInfo.links.releases)
                    Link("Report an Issue", destination: AppInfo.links.newIssue)
                }
            }
        }
    }
}

/// The Software Update window scene, shared by every ccinn app.
struct SoftwareUpdateScene: Scene {
    @AppStorage("appearance") private var appearance = "System"

    var body: some Scene {
        Window("Software Update", id: SoftwareUpdateView.windowID) {
            SoftwareUpdateView()
                .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
                .tint(Theme.accent)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
