import Foundation
import os
import Security
import StarRocksKit

public enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// Whether AI clients may use a connection through the built-in MCP server.
public enum MCPAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case readOnly
    case readWrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disabled: "Off"
        case .readOnly: "Read-only"
        case .readWrite: "Read & write"
        }
    }
}

/// A saved connection. Never contains secrets: passwords live in a `SecretStore` (the Keychain).
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ProfileColor
    public var isFavorite: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var defaultDatabase: String?
    public var defaultCatalog: String?
    public var ssh: SSHTunnelConfiguration?
    public var allowCleartextPassword: Bool
    /// Ask before running statements that change data or schema.
    public var confirmMutations: Bool
    public var connectTimeout: Double
    /// AI access through the MCP server (off unless the user opts in).
    public var mcpAccess: MCPAccess
    /// Read-only AI access is refused for accounts with administrator privileges unless the user allows it here. The
    /// opt-in is for one account: changing the host, port or user name clears it (`keepingPrivilegedOptIn`).
    public var mcpAllowPrivilegedAccount: Bool = false
    public var createdAt: Date
    public var lastConnectedAt: Date?
    /// Set on every save; backups use it to tell which side of a conflict is newer.
    public var updatedAt: Date?
    /// Whether an AI may write knowledge (notes, relationships, glossary) for this connection's databases. Knowledge is
    /// local to this Mac and never changes the cluster, so it is allowed on read-only AI access too.
    public var mcpKnowledgeWrites: Bool = true

    public init(id: UUID = UUID(), name: String = "", host: String = "127.0.0.1", port: Int = 9030, username: String = "root",
                defaultDatabase: String? = nil, defaultCatalog: String? = nil, color: ProfileColor = .none, isFavorite: Bool = false,
                ssh: SSHTunnelConfiguration? = nil, allowCleartextPassword: Bool = false, confirmMutations: Bool = false,
                connectTimeout: Double = 10, mcpAccess: MCPAccess = .disabled, createdAt: Date = Date(), lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.defaultDatabase = defaultDatabase
        self.defaultCatalog = defaultCatalog
        self.color = color
        self.isFavorite = isFavorite
        self.ssh = ssh
        self.allowCleartextPassword = allowCleartextPassword
        self.confirmMutations = confirmMutations
        self.connectTimeout = connectTimeout
        self.mcpAccess = mcpAccess
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try container.decodeIfPresent(ProfileColor.self, forKey: .color) ?? .none
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 9030
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? "root"
        defaultDatabase = try container.decodeIfPresent(String.self, forKey: .defaultDatabase)
        defaultCatalog = try container.decodeIfPresent(String.self, forKey: .defaultCatalog)
        ssh = try container.decodeIfPresent(SSHTunnelConfiguration.self, forKey: .ssh)
        allowCleartextPassword = try container.decodeIfPresent(Bool.self, forKey: .allowCleartextPassword) ?? false
        confirmMutations = try container.decodeIfPresent(Bool.self, forKey: .confirmMutations) ?? false
        connectTimeout = try container.decodeIfPresent(Double.self, forKey: .connectTimeout) ?? 10
        mcpAccess = (try? container.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess)) ?? .disabled
        mcpAllowPrivilegedAccount = (try? container.decodeIfPresent(Bool.self, forKey: .mcpAllowPrivilegedAccount)) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        mcpKnowledgeWrites = (try? container.decodeIfPresent(Bool.self, forKey: .mcpKnowledgeWrites)) ?? true
    }

    public static func recents(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    public var endpoint: Endpoint { Endpoint(host: host.trimmingCharacters(in: .whitespaces), port: port) }

    public var hostSummary: String {
        let base = "\(username)@\(endpoint)"
        if let ssh { return "\(base) via \(ssh.host)" }
        return base
    }

    public var displayName: String { name.isEmpty ? endpoint.description : name }

    public func configuration(password: String) -> ConnectionConfiguration {
        ConnectionConfiguration(endpoint: endpoint, username: username, password: password,
                                database: defaultDatabase?.nilIfBlank, catalog: defaultCatalog?.nilIfBlank,
                                connectTimeout: connectTimeout, allowCleartextPassword: allowCleartextPassword)
    }

    /// Problems that prevent connecting, for inline form validation.
    public var validationErrors: [String] {
        var errors: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the FE host") }
        if !(1...65_535).contains(port) { errors.append("Port must be between 1 and 65535") }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter a user name") }
        if let ssh {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the SSH host") }
            if ssh.authentication == .privateKey, (ssh.privateKeyPath ?? "").isEmpty { errors.append("Choose an SSH private key") }
        }
        return errors
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Secrets

public struct SecretKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case password
        case sshSecret
    }

    public let profileID: UUID
    public let kind: Kind

    public init(profileID: UUID, kind: Kind) {
        self.profileID = profileID
        self.kind = kind
    }

    var account: String { "\(profileID.uuidString).\(kind.rawValue)" }
}

public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Stores `value`, or deletes the secret when `value` is nil or empty.
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public struct SecretStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// macOS Keychain (generic passwords, this-device-only, available after first unlock).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.whiteccinn.ccinnstarrocks.connections") {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError(message: "Keychain read failed (\(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(message: "Keychain delete failed (\(status))")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "CcinnStarRocks connection secret"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError(message: "Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw SecretStoreError(message: "Keychain update failed (\(update))")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[SecretKey: String]>(initialState: [:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? { storage.withLock { $0[key] } }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = value?.isEmpty == false ? value : nil }
    }
}

// MARK: - Repository

/// Persists profiles as JSON (atomic writes) and their secrets in a `SecretStore`.
public final class ProfileRepository: Sendable {
    public let directory: URL
    private let secrets: any SecretStore

    /// `CCINNSTARROCKS_PROFILE_DIR` overrides the location (used by tests and for portable setups).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CCINNSTARROCKS_PROFILE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnStarRocks", isDirectory: true)
    }

    public init(directory: URL = ProfileRepository.defaultDirectory, secrets: any SecretStore = KeychainSecretStore()) {
        self.directory = directory
        self.secrets = secrets
    }

    private var fileURL: URL { directory.appendingPathComponent("connections.json") }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionProfile].self, from: data)
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profiles).write(to: fileURL, options: [.atomic])
    }

    public func storeSecrets(for profile: ConnectionProfile, password: String?, sshSecret: String?) throws {
        try secrets.setSecret(password, for: SecretKey(profileID: profile.id, kind: .password))
        try secrets.setSecret(sshSecret, for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func password(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .password))
    }

    public func sshSecret(for profile: ConnectionProfile) -> String? {
        try? secrets.secret(for: SecretKey(profileID: profile.id, kind: .sshSecret))
    }

    public func delete(_ profile: ConnectionProfile) throws {
        try deleteSecrets(of: profile.id)
    }

    /// Removes a profile's password and SSH secret from the Keychain.
    public func deleteSecrets(of profileID: UUID) throws {
        try secrets.setSecret(nil, for: SecretKey(profileID: profileID, kind: .password))
        try secrets.setSecret(nil, for: SecretKey(profileID: profileID, kind: .sshSecret))
    }
}
