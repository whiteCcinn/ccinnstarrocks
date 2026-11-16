import Foundation

/// A statement that changes a cluster-wide setting. Such statements always need an explicit confirmation in the
/// SQL editor, whatever the connection's other safety settings, and are refused over MCP, which cannot confirm.
public enum ClusterSettingChange: String, Sendable, Equatable, CaseIterable {
    /// `SET GLOBAL x = …`, `SET @@global.x = …`.
    case globalVariable
    /// `ADMIN SET FRONTEND CONFIG (…)`, `ADMIN SET ALL FRONTENDS CONFIG (…)`.
    case frontendConfig
    /// `UPDATE information_schema.be_configs SET VALUE = … WHERE NAME = …`.
    case backendConfig

    public var displayName: String {
        switch self {
        case .globalVariable: "a global variable"
        case .frontendConfig: "frontend configuration"
        case .backendConfig: "backend configuration"
        }
    }

    /// The kind of setting `statement` changes, or `nil`. Token-based, so strings and comments never match; when
    /// in doubt it errs towards asking (a column named `be_configs` in an UPDATE also counts).
    public static func of(_ statement: String) -> ClusterSettingChange? {
        let lexer = SQLLexer(statement)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        let words = tokens.map { token -> String in
            switch token.kind {
            case .keyword, .identifier: lexer.text(of: token).uppercased()
            case .quotedIdentifier: lexer.text(of: token).replacingOccurrences(of: "`", with: "").uppercased()
            default: ""
            }
        }
        guard let first = words.first else { return nil }
        switch first {
        case "SET":
            // A scope applies per assignment: `SET a = 1, GLOBAL b = 2` changes b globally.
            for (index, token) in tokens.enumerated().dropFirst() {
                if (token.kind == .keyword || token.kind == .identifier), words[index] == "GLOBAL" { return .globalVariable }
                if token.kind == .variable, lexer.text(of: token).lowercased().hasPrefix("@@global.") { return .globalVariable }
            }
            return nil
        case "ADMIN":
            return words.count > 2 && words[1] == "SET" && words.contains("CONFIG") ? .frontendConfig : nil
        default:
            guard SQLStatementKind.of(statement) == .dataModification else { return nil }
            return words.contains("BE_CONFIGS") ? .backendConfig : nil
        }
    }
}
