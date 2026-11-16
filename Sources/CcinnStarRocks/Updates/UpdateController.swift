import AppKit
import CcinnStarRocksKit
import Observation
import os

/// Drives update checks and downloads for the whole app (design D5/D6): one state machine, generation
/// tokens so late results never overwrite newer state, and a silent daily check after launch.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        /// `latest` is nil when the repository has no release yet.
        case upToDate(latest: String?)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        case downloaded(ReleaseInfo, file: URL)
        case failed(String, release: ReleaseInfo?)
    }

    private(set) var phase: Phase = .idle
    /// Incremented whenever the Software Update window should come to the front.
    private(set) var windowRequest = 0
    private(set) var lastCheck: Date?

    private enum Keys {
        static let automatic = "updates.automaticallyCheck"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
    }

    private let defaults: UserDefaults
    private let client: any UpdateHTTPClient
    private var generation = 0
    private var work: Task<Void, Never>?
    private var scheduledAutomaticCheck = false
    /// Whether the check in flight is a silent automatic one. A manual request while it runs makes it
    /// manual, so its result is always shown (review F1).
    private var inFlightIsAutomatic = false
    /// The last attempt that failed for lack of network; retried after an hour (review F4). Memory only.
    private var lastFailure: Date?
    private let log = Logger(subsystem: "io.github.whiteccinn.\(AppInfo.repository.name.lowercased())", category: "updates")

    init(defaults: UserDefaults = .standard, client: any UpdateHTTPClient = URLSessionUpdateClient()) {
        self.defaults = defaults
        self.client = client
        defaults.register(defaults: [Keys.automatic: true])
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    static var automaticCheckKey: String { Keys.automatic }

    /// The version compared against releases (`--pretend-version` lets snapshots show the "available" state).
    var currentVersion: SemanticVersion {
        Self.argument("--pretend-version").flatMap(SemanticVersion.init) ?? AppInfo.semanticVersion
    }

    var skippedVersion: String? { defaults.string(forKey: Keys.skipped) }

    // MARK: Checking

    /// Checks GitHub now. A manual check always ends visibly; an automatic one only surfaces a new,
    /// not-skipped version.
    func checkForUpdates(automatic: Bool) {
        if !automatic { windowRequest &+= 1 }
        switch phase {
        case .checking:
            if !automatic { inFlightIsAutomatic = false }
            return // Already checking; a manual request joins it and will see its result.
        case .downloading:
            return // A manual request just brings the window forward.
        default:
            break
        }
        work?.cancel()
        generation &+= 1
        let token = generation
        inFlightIsAutomatic = automatic
        phase = .checking
        let checker = UpdateChecker(repository: AppInfo.repository, currentVersion: currentVersion, client: client)
        work = Task { [weak self] in
            let outcome: Result<UpdateCheckResult, UpdateError>
            do {
                outcome = .success(try await checker.check())
            } catch let error as UpdateError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(UpdateError(.network, error.localizedDescription))
            }
            self?.finishCheck(outcome, token: token)
        }
    }

    private func finishCheck(_ outcome: Result<UpdateCheckResult, UpdateError>, token: Int) {
        guard token == generation else { return }
        let automatic = inFlightIsAutomatic
        if case .failure(let error) = outcome, error.kind == .cancelled {
            phase = .idle
            return
        }
        if case .failure(let error) = outcome, error.kind == .network {
            lastFailure = Date() // No answer from GitHub: not a completed check.
        } else {
            lastFailure = nil
            recordCheck()
        }
        switch outcome {
        case .success(.available(let release)):
            if UpdateSchedule.shouldPresent(release.version, skipped: skippedVersion, automatic: automatic) {
                phase = .available(release)
                if automatic { windowRequest &+= 1 }
            } else {
                phase = .idle
            }
        case .success(.upToDate(let release)):
            phase = automatic ? .idle : .upToDate(latest: release.version.description)
        case .success(.noReleases):
            phase = automatic ? .idle : .upToDate(latest: nil)
        case .failure(let error):
            if automatic {
                log.notice("Automatic update check failed: \(error.message, privacy: .public)")
                phase = .idle
            } else {
                phase = .failed(error.message, release: nil)
            }
        }
    }

    private func recordCheck() {
        let now = Date()
        lastCheck = now
        defaults.set(now, forKey: Keys.lastCheck)
    }

    /// Starts 8 s after launch and then looks every 30 minutes, so an app left open for weeks still checks
    /// daily (review F4). Never in snapshot or test launches.
    func scheduleAutomaticCheck() {
        guard !scheduledAutomaticCheck, !Self.automaticChecksDisabledForThisLaunch else { return }
        scheduledAutomaticCheck = true
        let controller = self // The controller lives for the whole process.
        Task {
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                controller.checkIfDue()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    private func checkIfDue() {
        // Any settled state may be refreshed (closing the window with its close button leaves the last
        // result in place); never while checking, downloading, or with a download ready to install.
        switch phase {
        case .idle, .upToDate, .available, .failed: break
        case .checking, .downloading, .downloaded: return
        }
        guard UpdateSchedule.isDue(now: Date(), lastCheck: lastCheck, lastFailure: lastFailure,
                                   enabled: defaults.bool(forKey: Keys.automatic)) else { return }
        checkForUpdates(automatic: true)
    }

    static var automaticChecksDisabledForThisLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--snapshot") || arguments.contains("--no-update-check")
            || ProcessInfo.processInfo.environment["\(AppInfo.productName.uppercased())_DISABLE_UPDATE_CHECK"] == "1"
    }

    private var handledLaunchRequest = false

    /// `--check-updates` runs one manual check at launch (combine with `--pretend-version 1.0.0` to see
    /// the "available" state in snapshots).
    func checkIfRequestedAtLaunch() {
        guard !handledLaunchRequest, ProcessInfo.processInfo.arguments.contains("--check-updates") else { return }
        handledLaunchRequest = true
        checkForUpdates(automatic: false)
    }

    private static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: Actions

    func download(_ release: ReleaseInfo) {
        switch phase {
        case .available, .failed, .downloaded: break
        default: return // Never two downloads at once (review F5).
        }
        work?.cancel()
        generation &+= 1
        let token = generation
        phase = .downloading(release, progress: 0)
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let downloader = UpdateDownloader(repository: AppInfo.repository, client: client, destination: destination)
        let throttle = ProgressThrottle()
        // The controller lives for the whole process, so the download may hold it strongly.
        let controller = self
        work = Task {
            let outcome: Result<URL, UpdateError>
            do {
                let file = try await downloader.download(release) { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor in controller.reportProgress(fraction, release: release, token: token) }
                }
                outcome = .success(file)
            } catch let error as UpdateError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(UpdateError(.network, error.localizedDescription))
            }
            controller.finishDownload(outcome, release: release, token: token)
        }
    }

    private func reportProgress(_ fraction: Double, release: ReleaseInfo, token: Int) {
        guard token == generation, case .downloading = phase else { return }
        phase = .downloading(release, progress: fraction)
    }

    private func finishDownload(_ outcome: Result<URL, UpdateError>, release: ReleaseInfo, token: Int) {
        guard token == generation else {
            // Superseded: do not leave an unannounced copy in Downloads.
            if case .success(let file) = outcome { try? FileManager.default.removeItem(at: file) }
            return
        }
        switch outcome {
        case .success(let file):
            phase = .downloaded(release, file: file)
            windowRequest &+= 1 // Show the next steps even if the window was closed meanwhile.
            NSWorkspace.shared.open(file)
        case .failure(let error) where error.kind == .cancelled:
            phase = .available(release)
        case .failure(let error):
            phase = .failed(error.message, release: release)
        }
    }

    func cancel() {
        work?.cancel()
    }

    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version.description, forKey: Keys.skipped)
        generation &+= 1
        phase = .idle
    }

    /// Forget a finished result so the next time the window opens it checks again.
    func reset() {
        switch phase {
        case .checking, .downloading: return
        default:
            generation &+= 1
            phase = .idle
        }
    }
}

/// Lets through progress updates of at least 1 % (the download delegate reports every chunk).
private final class ProgressThrottle: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: -1.0)

    func shouldReport(_ fraction: Double) -> Bool {
        last.withLock { last in
            guard fraction >= 1 || fraction - last >= 0.01 else { return false }
            last = fraction
            return true
        }
    }
}

/// The standard About panel, with the project link in the credits (design D8).
@MainActor
enum AboutPanel {
    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let credits = NSMutableAttributedString(string: AppInfo.tagline + "\n", attributes: body)
        var link = body
        link[.link] = AppInfo.links.repository
        credits.append(NSAttributedString(string: "github.com/\(AppInfo.repository.owner)/\(AppInfo.repository.name)", attributes: link))
        credits.append(NSAttributedString(string: "\nMIT License · © 2026 whiteCcinn", attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: AppInfo.version,
            .version: "",
        ])
        NSApp.activate()
    }
}
