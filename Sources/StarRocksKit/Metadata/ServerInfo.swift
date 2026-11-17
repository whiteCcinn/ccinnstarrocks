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

    /// A release only when the whole text is one: `[v]major.minor[.patch][-suffix]`, ASCII digits, a 1–2 digit major
    /// (`3.3.22-753696f`, `v4.1.0-rc1`, `3.3.5-ee`). A suffix holding another dotted version, or anything before the
    /// number, is vendor packaging (`EMR-5.14.0-starrocks-3.2.8`, `2024.10-starrocks-3.3`) and says nothing reliable
    /// about the StarRocks release: `nil`. For release-dependent behaviour only; labels use the lenient `init?(_:)`.
    public static func strictRelease(_ text: String) -> StarRocksVersion? {
        var rest = Substring(text)
        if rest.hasPrefix("v") { rest = rest.dropFirst() }
        func number(maxDigits: Int) -> Int? {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= maxDigits else { return nil }
            rest = rest.dropFirst(digits.count)
            return Int(digits)
        }
        guard let major = number(maxDigits: 2), rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard let minor = number(maxDigits: 3) else { return nil }
        var patch = 0
        if rest.first == "." {
            rest = rest.dropFirst()
            guard let value = number(maxDigits: 4) else { return nil }
            patch = value
        }
        if !rest.isEmpty {
            guard rest.first == "-" else { return nil }
            let suffix = rest.dropFirst()
            guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }),
                  !containsDottedNumber(suffix) else { return nil }
        }
        return StarRocksVersion(major: major, minor: minor, patch: patch, raw: text)
    }

    private static func containsDottedNumber(_ text: Substring) -> Bool {
        let characters = Array(text)
        for index in characters.indices.dropFirst().dropLast() where characters[index] == "." {
            if characters[index - 1].isNumber, characters[index + 1].isNumber { return true }
        }
        return false
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
    /// Release string from `current_version()` (falls back to `@@version_comment` or the protocol version).
    public let versionString: String
    /// Parsed from `versionString`, fallbacks included: good for labels.
    public let version: StarRocksVersion?
    /// The release as `current_version()` reported it, parsed strictly (`StarRocksVersion.strictRelease`); `nil` when
    /// only a fallback was available or the text is not a plain release. A fallback says nothing reliable about the
    /// release (StarRocks 3.3 announces 5.1.0 in the handshake, 4.1 announces 8.0.33), nor does a vendor-prefixed string,
    /// so behaviour that depends on the release (reading `$$` blocks) must use this.
    public let releaseVersion: StarRocksVersion?
    /// MySQL-compatible version from the handshake (e.g. `8.0.33`).
    public let protocolVersion: String
    public let currentUser: String?
    /// `shared_nothing` or `shared_data`; `nil` when the user may not read FE config.
    public let runMode: String?

    public init(versionString: String, protocolVersion: String, currentUser: String?, runMode: String?, fromCurrentVersion: Bool = true) {
        self.versionString = versionString
        version = StarRocksVersion(versionString)
        releaseVersion = fromCurrentVersion ? StarRocksVersion.strictRelease(versionString.trimmingCharacters(in: .whitespaces)) : nil
        self.protocolVersion = protocolVersion
        self.currentUser = currentUser
        self.runMode = runMode
    }

    public var isSharedData: Bool { runMode?.lowercased() == "shared_data" }

    static func load(from connection: MySQLConnection) async throws -> ServerInfo {
        var versionString = connection.protocolVersion
        var fromCurrentVersion = false
        var user: String?
        if let row = try? await connection.execute("SELECT current_version() AS v, current_user() AS u").first {
            if let release = row.text("v") {
                versionString = release
                fromCurrentVersion = true
            }
            user = row.text("u")
        } else if let comment = try? await connection.execute("SELECT @@version_comment AS v").scalar {
            versionString = comment
        }
        let runMode = try? await connection.execute("ADMIN SHOW FRONTEND CONFIG LIKE 'run_mode'").first?.text("Value")
        return ServerInfo(versionString: versionString, protocolVersion: connection.protocolVersion, currentUser: user, runMode: runMode,
                          fromCurrentVersion: fromCurrentVersion)
    }
}
