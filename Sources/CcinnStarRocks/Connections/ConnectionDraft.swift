import CcinnStarRocksKit
import Foundation
import Observation
import StarRocksKit

/// Editable copy of a connection profile plus its secrets, with "Test connection".
@MainActor
@Observable
final class ConnectionDraft {
    enum TestState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    let profileID: UUID?
    var name: String
    var color: ProfileColor
    var isFavorite: Bool
    var host: String
    var port: Int
    var username: String
    var password: String
    var defaultDatabase: String
    var defaultCatalog: String
    var allowCleartextPassword: Bool
    var confirmMutations: Bool
    var connectTimeout: Double
    var mcpAccess: MCPAccess
    var sshEnabled: Bool
    var ssh: SSHTunnelConfiguration
    var sshSecret: String
    var testState: TestState = .idle

    private let original: ConnectionProfile?
    private var testTask: Task<Void, Never>?

    init(profile: ConnectionProfile?, store: ProfileStore) {
        original = profile
        profileID = profile?.id
        let base = profile ?? ConnectionProfile(color: .indigo)
        name = base.name
        color = base.color
        isFavorite = base.isFavorite
        host = base.host
        port = base.port
        username = base.username
        password = profile.flatMap(store.password(for:)) ?? ""
        defaultDatabase = base.defaultDatabase ?? ""
        defaultCatalog = base.defaultCatalog ?? ""
        allowCleartextPassword = base.allowCleartextPassword
        confirmMutations = base.confirmMutations
        connectTimeout = base.connectTimeout
        mcpAccess = base.mcpAccess
        sshEnabled = base.ssh != nil
        ssh = base.ssh ?? SSHTunnelConfiguration(host: "", username: NSUserName(), authentication: .agent)
        sshSecret = profile.flatMap(store.sshSecret(for:)) ?? ""
    }

    func makeProfile() -> ConnectionProfile {
        var profile = original ?? ConnectionProfile()
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.color = color
        profile.isFavorite = isFavorite
        profile.host = host.trimmingCharacters(in: .whitespaces)
        profile.port = port
        profile.username = username.trimmingCharacters(in: .whitespaces)
        profile.defaultDatabase = defaultDatabase.nilIfEmpty
        profile.defaultCatalog = defaultCatalog.nilIfEmpty
        profile.allowCleartextPassword = allowCleartextPassword
        profile.confirmMutations = confirmMutations
        profile.connectTimeout = min(max(connectTimeout, 1), 120)
        profile.mcpAccess = mcpAccess
        profile.ssh = sshEnabled ? ssh : nil
        return profile
    }

    var validationErrors: [String] { makeProfile().validationErrors }
    var isValid: Bool { validationErrors.isEmpty }

    func test() {
        testTask?.cancel()
        let profile = makeProfile()
        let password = password
        let sshSecret = sshEnabled && ssh.authentication != .agent ? sshSecret : nil
        testState = .running("Connecting to \(profile.endpoint)…")
        let report: @Sendable (String) -> Void = { status in
            Task { @MainActor in
                if case .running = self.testState { self.testState = .running(status) }
            }
        }
        testTask = Task {
            do {
                let client = try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret, progress: report)
                let info = client.serverInfo
                let databases = (try? await client.databases().count) ?? 0
                await client.close()
                guard !Task.isCancelled else { return }
                var message = "Connected to \(info.version.map { "StarRocks \($0.shortDescription)" } ?? info.versionString)"
                if let mode = info.runMode { message += " (\(mode.replacingOccurrences(of: "_", with: "-")))" }
                message += " · \(databases) databases"
                if let user = info.currentUser { message += " · \(user)" }
                testState = .succeeded(message)
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed(describe(error))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
