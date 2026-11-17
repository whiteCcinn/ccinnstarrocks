import CcinnStarRocksKit
import Foundation
import Observation
import StarRocksKit

/// Opens a StarRocks client for a profile (optionally through an SSH tunnel).
enum ConnectionOpener {
    static func open(profile: ConnectionProfile, password: String, sshSecret: String?,
                     progress: @escaping @Sendable (String) -> Void) async throws -> StarRocksClient {
        try await ClientOpener.open(profile: profile, password: password, sshSecret: sshSecret, progress: progress)
    }
}

/// State of one window: choosing a connection, connecting, or connected to a workspace.
@MainActor
@Observable
final class WindowSession {
    enum Phase {
        case connections
        case connecting(name: String, status: String)
        case connected(WorkspaceModel)
    }

    var phase: Phase = .connections {
        didSet { DebugLog.write("phase -> \(phaseName)") }
    }
    var connectError: String?

    private var phaseName: String {
        switch phase {
        case .connections: "connections"
        case let .connecting(name, status): "connecting(\(name), \(status))"
        case .connected: "connected"
        }
    }
    private var connectTask: Task<Void, Never>?
    /// Identifies the latest connect: progress and results of an older (cancelled) one are ignored.
    private var connectGeneration = 0

    typealias Opener = @Sendable (_ profile: ConnectionProfile, _ password: String, _ sshSecret: String?,
                                  _ progress: @escaping @Sendable (String) -> Void) async throws -> StarRocksClient
    /// Opens the client; replaced in tests.
    var opener: Opener = { profile, password, sshSecret, progress in
        try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret, progress: progress)
    }

    var workspace: WorkspaceModel? {
        if case let .connected(model) = phase { return model }
        return nil
    }

    func connect(profile: ConnectionProfile, store: ProfileStore, password overridePassword: String? = nil,
                 then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        connectError = nil
        let name = profile.displayName
        let password = overridePassword ?? store.password(for: profile) ?? ""
        let sshSecret = profile.ssh.map { $0.authentication == .agent } == false ? store.sshSecret(for: profile) : nil
        // A connect still in flight (double-click, a second Connect) would otherwise finish later and leave a live
        // client behind, and its progress would overwrite this connect's status.
        connectTask?.cancel()
        connectGeneration += 1
        let generation = connectGeneration
        phase = .connecting(name: name, status: "Connecting…")
        let report: @Sendable (String) -> Void = { [weak self] status in
            Task { @MainActor in self?.updateStatus(generation: generation, name: name, status: status) }
        }
        let opener = opener
        connectTask = Task {
            do {
                let client = try await opener(profile, password, sshSecret, report)
                if Task.isCancelled || generation != self.connectGeneration {
                    await client.close()
                    return
                }
                store.markConnected(profile.id)
                let workspace = WorkspaceModel(profile: profile, client: client)
                self.phase = .connected(workspace)
                workspace.start()
                then?(workspace)
            } catch {
                DebugLog.write("connect failed: \(error) cancelled=\(Task.isCancelled)")
                guard !Task.isCancelled, generation == self.connectGeneration else { return }
                self.connectError = describe(error)
                self.phase = .connections
            }
        }
    }

    /// Connects a window opened by a request of this process; `false` when the request carries no handed-off
    /// connection. Such a request was restored by macOS after a relaunch: the window then behaves exactly like a
    /// new empty window (connection screen, launch arguments) and never connects by itself.
    @discardableResult
    func connect(_ request: WindowRequest, store: ProfileStore) -> Bool {
        guard let connection = Self.handoff.take(request) else { return false }
        connect(profile: connection.profile, store: store, password: connection.password)
        return true
    }

    /// A request for another window connected like this one, with the same profile and the password in use (so
    /// unsaved connections and passwords not in the Keychain work too).
    func duplicateRequest() -> WindowRequest? {
        guard let workspace else { return nil }
        return Self.handoff.request(profileID: workspace.profile.id,
                                    payload: WindowConnection(profile: workspace.profile, password: workspace.client.configuration.password))
    }

    /// A request for a new window that connects to a saved profile, reading its password from the Keychain as
    /// Connect does.
    static func request(opening profile: ConnectionProfile) -> WindowRequest {
        handoff.request(profileID: profile.id, payload: WindowConnection(profile: profile, password: nil))
    }

    /// Connections handed to windows this process opens (see `WindowHandoff`).
    private static let handoff = WindowHandoff<WindowConnection>()

    private func updateStatus(generation: Int, name: String, status: String) {
        guard generation == connectGeneration, case .connecting = phase else { return }
        phase = .connecting(name: name, status: status)
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        phase = .connections
    }

    func disconnect() {
        DebugLog.write("disconnect()")
        // A connect still in flight would otherwise finish later and leave a live client/tunnel behind.
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        workspace?.shutdown()
        phase = .connections
    }
}

/// The connection a new window opens: a profile and, when duplicating, the password in use (`nil` = Keychain).
struct WindowConnection {
    let profile: ConnectionProfile
    let password: String?
}

/// User-facing text for any error.
func describe(_ error: any Error) -> String {
    if let error = error as? StarRocksError {
        if let code = error.code { return "\(error.message) (error \(code))" }
        return error.message
    }
    return error.localizedDescription
}

/// `CCINNSTARROCKS_DEBUG=1` writes lifecycle events to stderr (development aid).
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["CCINNSTARROCKS_DEBUG"] == "1"

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[ccinnstarrocks] \(message())\n".utf8))
    }
}
