import Foundation

/// A release version (`major.minor.patch[-pre.release]`), compared by semantic-versioning precedence
/// (design D2). Parsing is strict enough that an unexpected tag is never mistaken for an update.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Pre-release identifiers (`beta.1` → `["beta", "1"]`); empty for a normal release.
    public let preRelease: [String]

    /// Upper bound for each numeric part, so huge values can never overflow.
    static let maxComponent = 999_999

    public init(major: Int, minor: Int, patch: Int, preRelease: [String] = []) {
        self.major = min(max(0, major), Self.maxComponent)
        self.minor = min(max(0, minor), Self.maxComponent)
        self.patch = min(max(0, patch), Self.maxComponent)
        self.preRelease = preRelease
    }

    /// Accepts an optional `v`/`V` prefix, a missing minor or patch part (`1.2` = `1.2.0`) and ignores build
    /// metadata (`+…`). Returns `nil` for anything else.
    public init?(_ text: String) {
        var string = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if string.first == "v" || string.first == "V" { string = string.dropFirst() }
        if let plus = string.firstIndex(of: "+") { string = string[..<plus] }
        guard !string.isEmpty else { return nil }

        var identifiers: [String] = []
        if let dash = string.firstIndex(of: "-") {
            let suffix = string[string.index(after: dash)...]
            let parts = suffix.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy(Self.isValidIdentifier) else { return nil }
            identifiers = parts.map(String.init)
            string = string[..<dash]
        }

        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], preRelease: identifiers)
    }

    private static func isValidIdentifier(_ part: Substring) -> Bool {
        guard !part.isEmpty, part.count <= 64, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        // Numeric identifiers must not have leading zeros (SemVer §9), so `==` and `<` always agree (review F8).
        let numeric = part.allSatisfy { $0.isNumber }
        return !(numeric && part.count > 1 && part.first == "0")
    }

    public var isPreRelease: Bool { !preRelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return preRelease.isEmpty ? core : "\(core)-\(preRelease.joined(separator: "."))"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A pre-release ranks below the same version without one.
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.preRelease, rhs.preRelease) where left != right {
            return identifierPrecedes(left, right)
        }
        return lhs.preRelease.count < rhs.preRelease.count
    }

    /// Numeric identifiers compare numerically (without parsing, so any length is safe) and rank below
    /// alphanumeric ones, which compare in ASCII order.
    private static func identifierPrecedes(_ left: String, _ right: String) -> Bool {
        let leftNumeric = left.allSatisfy { $0.isASCII && $0.isNumber }
        let rightNumeric = right.allSatisfy { $0.isASCII && $0.isNumber }
        switch (leftNumeric, rightNumeric) {
        case (true, true):
            let a = left.drop { $0 == "0" }, b = right.drop { $0 == "0" }
            return a.count != b.count ? a.count < b.count : a < b
        case (true, false): return true
        case (false, true): return false
        case (false, false): return left < right
        }
    }
}
