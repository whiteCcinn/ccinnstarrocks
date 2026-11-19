import Foundation

// What a `.ccinnstarrocks-backup` file holds: line 1 is a `BackupHeader`, line 2 a `BackupPayload`. Secrets never
// appear in either in clear text; they are sealed into the header with a passphrase (`BackupCrypto`).

/// The parts a backup can hold.
public enum BackupSection: String, CaseIterable, Codable, Sendable {
    case profiles, knowledge, settings, history
}

/// Line 1: what the file is, which sections it holds, the payload's length and SHA-256, and the sealed secrets.
public struct BackupHeader: Codable, Sendable, Equatable {
    public static let formatName = "ccinnstarrocks-backup"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var createdAt: Date
    public var appVersion: String
    public var sections: [String]
    /// The exact byte count and lower-case hex SHA-256 of line 2.
    public var payloadBytes: Int
    public var payloadSHA256: String
    /// `nil` unless the backup was made with a passphrase.
    public var secrets: BackupSecretsEnvelope?

    public init(createdAt: Date, appVersion: String, sections: [String], payloadBytes: Int, payloadSHA256: String, secrets: BackupSecretsEnvelope?) {
        format = Self.formatName
        formatVersion = Self.currentFormatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.sections = sections
        self.payloadBytes = payloadBytes
        self.payloadSHA256 = payloadSHA256
        self.secrets = secrets
    }

    enum CodingKeys: String, CodingKey {
        case format
        case formatVersion = "format_version"
        case createdAt = "created_at"
        case appVersion = "app_version"
        case sections
        case payloadBytes = "payload_bytes"
        case payloadSHA256 = "payload_sha256"
        case secrets
    }
}

/// The sealed secrets and what is needed to open them with the passphrase (see `BackupCrypto`).
public struct BackupSecretsEnvelope: Codable, Sendable, Equatable {
    public var kdf: String
    public var iterations: Int
    /// Base64 of the 16-byte salt.
    public var salt: String
    /// Base64 of 16 bytes that tell a wrong passphrase from a modified file.
    public var keyCheck: String
    public var cipher: String
    /// Base64 of nonce ‖ ciphertext ‖ tag.
    public var sealed: String

    enum CodingKeys: String, CodingKey {
        case kdf, iterations, salt
        case keyCheck = "key_check"
        case cipher, sealed
    }
}

/// One profile's password and SSH secret (password or key passphrase). Descriptions and mirrors never show them.
public struct BackupProfileSecrets: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var password: String?
    public var sshSecret: String?

    public init(password: String? = nil, sshSecret: String? = nil) {
        self.password = password?.isEmpty == false ? password : nil
        self.sshSecret = sshSecret?.isEmpty == false ? sshSecret : nil
    }

    public var isEmpty: Bool { password == nil && sshSecret == nil }

    func value(for kind: SecretKey.Kind) -> String? {
        switch kind {
        case .password: password
        case .sshSecret: sshSecret
        }
    }

    public var description: String { "BackupProfileSecrets(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Line 2: the backed-up content. Profiles are always present; the other sections only when chosen.
public struct BackupPayload: Sendable, Equatable {
    public var profiles: [ConnectionProfile]
    public var knowledge: BackupKnowledge?
    /// Whitelisted settings (`BackupSettings`).
    public var settings: [String: BackupSettingValue]?
    public var history: [BackupHistory]?

    public init(profiles: [ConnectionProfile], knowledge: BackupKnowledge? = nil, settings: [String: BackupSettingValue]? = nil,
                history: [BackupHistory]? = nil) {
        self.profiles = profiles
        self.knowledge = knowledge
        self.settings = settings
        self.history = history
    }

    public var sections: [BackupSection] {
        var sections: [BackupSection] = [.profiles]
        if knowledge != nil { sections.append(.knowledge) }
        if settings != nil { sections.append(.settings) }
        if history != nil { sections.append(.history) }
        return sections
    }
}

extension BackupPayload: Encodable {
    enum CodingKeys: String, CodingKey {
        case profiles, knowledge, settings, history
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profiles, forKey: .profiles)
        try container.encodeIfPresent(knowledge, forKey: .knowledge)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encodeIfPresent(history, forKey: .history)
    }
}

/// The knowledge index and every database file, as `KnowledgeStore` keeps them.
public struct BackupKnowledge: Codable, Sendable, Equatable {
    public var schemaVersion = KnowledgeStore.schemaVersion
    public var index: KnowledgeIndex
    public var databases: [DatabaseKnowledge]

    public init(index: KnowledgeIndex, databases: [DatabaseKnowledge]) {
        self.index = index
        self.databases = databases
    }
}

/// One profile's query history, newest first.
public struct BackupHistory: Codable, Sendable, Equatable {
    public var profile: UUID
    public var entries: [QueryHistoryEntry]

    public init(profile: UUID, entries: [QueryHistoryEntry]) {
        self.profile = profile
        self.entries = entries
    }
}

/// A setting's value. Anything else found in a file decodes as `unsupported` and is never applied.
public enum BackupSettingValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case unsupported

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .unsupported
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case .unsupported: try container.encodeNil()
        }
    }

    /// The value to store in `UserDefaults`.
    public var propertyListValue: Any? {
        switch self {
        case let .bool(value): value
        case let .int(value): value
        case let .string(value): value
        case .unsupported: nil
        }
    }

    public var displayValue: String {
        switch self {
        case let .bool(value): value ? "On" : "Off"
        case let .int(value): String(value)
        case let .string(value): value
        case .unsupported: "—"
        }
    }
}

/// A decoded, verified backup.
public struct BackupBundle: Sendable {
    public let header: BackupHeader
    public let payload: BackupPayload
    /// Secrets by profile id; empty unless the passphrase opened them.
    public let secrets: [UUID: BackupProfileSecrets]
    /// Whether the passphrase proved the whole file unmodified. An unauthenticated file only had its corruption
    /// checked: anyone could have written it, so its preview is untrusted.
    public let isAuthenticated: Bool
    public let warnings: [BackupWarning]

    public init(header: BackupHeader, payload: BackupPayload, secrets: [UUID: BackupProfileSecrets], isAuthenticated: Bool, warnings: [BackupWarning]) {
        self.header = header
        self.payload = payload
        self.secrets = secrets
        self.isAuthenticated = isAuthenticated
        self.warnings = warnings
    }
}
