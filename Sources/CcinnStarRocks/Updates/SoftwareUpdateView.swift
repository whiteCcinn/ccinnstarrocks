import AppKit
import CcinnStarRocksKit
import SwiftUI

/// The Software Update window: check result, release notes, download progress and next steps.
struct SoftwareUpdateView: View {
    static let windowID = "software-update"

    @Bindable private var updates = UpdateController.shared
    @AppStorage(UpdateController.automaticCheckKey) private var automaticallyCheck = true
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                AppLogo(size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            content
            Divider()
            HStack {
                Toggle("Check for updates automatically", isOn: $automaticallyCheck)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                Link("\(AppInfo.productName) on GitHub", destination: AppInfo.links.repository)
                    .font(.callout)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task {
            // Opening the window (also from window restoration) always shows a fresh result.
            if case .idle = updates.phase { updates.checkForUpdates(automatic: false) }
        }
    }

    private var current: String { updates.currentVersion.description }

    private var title: String {
        switch updates.phase {
        case .idle: "Software Update"
        case .checking: "Checking for Updates…"
        case .upToDate: "You’re Up to Date"
        case let .available(release): "\(AppInfo.productName) \(release.version) Is Available"
        case let .downloading(release, _): "Downloading \(AppInfo.productName) \(release.version)…"
        case .downloaded: "Ready to Install"
        case .failed: "Update Check Failed"
        }
    }

    private var subtitle: String {
        switch updates.phase {
        case .idle:
            return "You have \(AppInfo.productName) \(current)."
        case .checking:
            return "Looking for the latest release on GitHub."
        case let .upToDate(latest):
            return latest == nil ? "No release has been published yet. You have \(current)."
                : "\(AppInfo.productName) \(current) is the latest version."
        case let .available(release):
            let date = release.publishedAt.map { " · released \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            return "You have \(current)\(date)."
        case .downloading:
            return "The disk image is verified against the release’s SHA-256 checksum before it is opened."
        case .downloaded:
            return "The verified disk image is open. Quit \(AppInfo.productName), then drag \(AppInfo.productName) onto Applications and choose Replace."
        case let .failed(message, _):
            return message
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updates.phase {
        case .idle:
            // Never a spinner without work behind it: a settled idle state offers a fresh check.
            HStack {
                Spacer()
                Button("Check Now") { updates.checkForUpdates(automatic: false) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .checking:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        case .upToDate:
            HStack {
                if let lastCheck = updates.lastCheck {
                    Text("Last checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("OK") { close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        case let .available(release):
            ReleaseNotesView(notes: release.notes)
            HStack {
                Button("Skip This Version") {
                    updates.skip(release)
                    close()
                }
                Spacer()
                Button("Release Page") { NSWorkspace.shared.open(release.pageURL) }
                Button("Later") { close() }.keyboardShortcut(.cancelAction)
                if release.diskImage != nil {
                    Button("Download & Open") { updates.download(release) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        case let .downloading(release, progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                HStack {
                    Text(release.diskImage?.name ?? "")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { updates.cancel() }.keyboardShortcut(.cancelAction)
                }
            }
        case let .downloaded(_, file):
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Spacer()
                Button("Later") { close() }
                Button("Quit \(AppInfo.productName)") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        case let .failed(_, release):
            HStack {
                Button("Release Page") { NSWorkspace.shared.open(release?.pageURL ?? AppInfo.links.releases) }
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    if let release { updates.download(release) } else { updates.checkForUpdates(automatic: false) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func close() {
        updates.reset()
        dismissWindow(id: Self.windowID)
    }
}

/// Release notes from GitHub, rendered as headings, bullets and paragraphs with inline Markdown.
private struct ReleaseNotesView: View {
    let notes: String

    var body: some View {
        let blocks = ReleaseNotes.blocks(from: notes)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if blocks.isEmpty {
                    Text("No release notes.").foregroundStyle(.secondary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .heading(text):
                        Text(Self.inline(text)).font(.headline).padding(.top, 4)
                    case let .bullet(text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                        }
                    case let .paragraph(text):
                        Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(height: 220)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        // Release notes are server text: only web links open (review F7).
        .environment(\.openURL, OpenURLAction { url in url.scheme?.lowercased() == "https" ? .systemAction : .discarded })
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
