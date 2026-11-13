import Foundation

/// Parsed StarRocks release, e.g. `3.3.22-753696f`.
public struct StarRocksVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let raw: String

    public init(major: Int, minor: Int, patch: Int = 0, raw: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.raw = raw ?? "\(major).\(minor).\(patch)"
    }

    /// Accepts `3.3.22-753696f`, `v3.2.1`, `4.1.7-ee-abc`; `nil` when no `major.minor` is present.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let body = trimmed.drop(while: { !$0.isNumber })
        let numbers = body.prefix(while: { $0.isNumber || $0 == "." }).split(separator: ".").prefix(3).compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0, raw: trimmed)
    }

    public static func < (lhs: StarRocksVersion, rhs: StarRocksVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func == (lhs: StarRocksVersion, rhs: StarRocksVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }

    public var shortDescription: String { "\(major).\(minor).\(patch)" }
    public var description: String { raw }
}

/// Facts about the connected cluster, loaded once per client.
public struct ServerInfo: Sendable, Equatable {
    /// Release string from `current_version()` (falls back to the protocol version).
    public let versionString: String
    public let version: StarRocksVersion?
    /// MySQL-compatible version from the handshake (e.g. `8.0.33`).
    public let protocolVersion: String
    public let currentUser: String?
    /// `shared_nothing` or `shared_data`; `nil` when the user may not read FE config.
    public let runMode: String?

    public init(versionString: String, protocolVersion: String, currentUser: String?, runMode: String?) {
        self.versionString = versionString
        version = StarRocksVersion(versionString)
        self.protocolVersion = protocolVersion
        self.currentUser = currentUser
        self.runMode = runMode
    }

    public var isSharedData: Bool { runMode?.lowercased() == "shared_data" }

    static func load(from connection: MySQLConnection) async throws -> ServerInfo {
        var versionString = connection.protocolVersion
        var user: String?
        if let row = try? await connection.execute("SELECT current_version() AS v, current_user() AS u").first {
            versionString = row.text("v") ?? versionString
            user = row.text("u")
        } else if let comment = try? await connection.execute("SELECT @@version_comment AS v").scalar {
            versionString = comment
        }
        let runMode = try? await connection.execute("ADMIN SHOW FRONTEND CONFIG LIKE 'run_mode'").first?.text("Value")
        return ServerInfo(versionString: versionString, protocolVersion: connection.protocolVersion, currentUser: user, runMode: runMode)
    }
}
