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
        phase = .connecting(name: name, status: "Connecting…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in self.updateStatus(name: name, status: status) }
        }
        connectTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret, progress: report)
                if Task.isCancelled {
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
                guard !Task.isCancelled else { return }
                self.connectError = describe(error)
                self.phase = .connections
            }
        }
    }

    private func updateStatus(name: String, status: String) {
        guard case .connecting = phase else { return }
        phase = .connecting(name: name, status: status)
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        phase = .connections
    }

    func disconnect() {
        DebugLog.write("disconnect()")
        // A connect still in flight would otherwise finish later and leave a live client/tunnel behind.
        connectTask?.cancel()
        connectTask = nil
        workspace?.shutdown()
        phase = .connections
    }
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
