import Foundation

/// Removes credentials from SQL before it is written to history or audit logs: string literals after
/// `IDENTIFIED [WITH plugin] BY`, `PASSWORD` / `PASSWORD(`, and values of credential-like properties
/// (`"aws.s3.secret_key" = "…"`, `'password' = '…'`, …) become `'***'`.
public enum SQLRedactor {
    static let sensitiveKeyFragments = ["password", "passwd", "secret", "access_key", "accesskey", "token", "credential",
                                        "private_key", "privatekey", "sas", "auth"]

    public static func redact(_ sql: String) -> String {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        var redactions: [Range<Int>] = []
        for (index, token) in tokens.enumerated() where token.kind == .string {
            if isSecretLiteral(at: index, tokens: tokens, lexer: lexer) { redactions.append(token.range) }
        }
        guard !redactions.isEmpty else { return sql }
        var units = lexer.units
        for range in redactions.reversed() {
            let quote = units[range.lowerBound]
            units.replaceSubrange(range, with: [quote] + Array("***".utf16) + [quote])
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func isSecretLiteral(at index: Int, tokens: [SQLToken], lexer: SQLLexer) -> Bool {
        func word(_ offset: Int) -> String? {
            let position = index + offset
            guard tokens.indices.contains(position) else { return nil }
            return lexer.text(of: tokens[position]).uppercased()
        }
        // IDENTIFIED BY '…' / IDENTIFIED WITH plugin BY '…' / IDENTIFIED WITH plugin AS '…'
        if word(-1) == "BY", word(-2) == "IDENTIFIED" || word(-4) == "IDENTIFIED" { return true }
        if word(-1) == "AS", word(-3) == "WITH", word(-4) == "IDENTIFIED" { return true }
        // PASSWORD '…', PASSWORD('…'), PASSWORD = '…'
        if word(-1) == "PASSWORD" || (word(-1) == "(" && word(-2) == "PASSWORD") || (word(-1) == "=" && word(-2) == "PASSWORD") { return true }
        // "key" = "value" with a credential-like key
        if word(-1) == "=", index >= 2, tokens[index - 2].kind == .string {
            let key = lexer.text(of: tokens[index - 2]).lowercased()
            return sensitiveKeyFragments.contains { key.contains($0) }
        }
        return false
    }
}
