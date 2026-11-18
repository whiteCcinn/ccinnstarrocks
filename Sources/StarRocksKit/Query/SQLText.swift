import Foundation

/// Safe construction of identifiers and literals for statements the app builds itself.
public enum SQLText {
    public static let defaultCatalog = "default_catalog"

    /// Back-quoted identifier; embedded back-quotes are doubled, NUL bytes removed.
    public static func quoteIdentifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// `a`.`b`.`c` from the non-empty parts.
    public static func qualified(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.map(quoteIdentifier).joined(separator: ".")
    }

    /// Single-quoted string literal that no value can break out of, in either dialect StarRocks parses: a quote is
    /// doubled, which ends nothing in the StarRocks or the trino dialect (in trino `\'` ends the string, so a quote in a
    /// name could inject SQL). Backslashes and control characters keep MySQL escapes: StarRocks reads the exact value,
    /// trino reads two characters (a wrong value at worst, never a way out of the string).
    public static func literal(_ value: String) -> String {
        var escaped = "'"
        escaped.reserveCapacity(value.utf8.count + 2)
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "'": escaped += "''"
            case "\0": escaped += "\\0"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\u{1A}": escaped += "\\Z"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return escaped + "'"
    }
}
