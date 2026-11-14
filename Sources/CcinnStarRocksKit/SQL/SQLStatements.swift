import Foundation

/// One statement of a script. `range` is in UTF-16 offsets of the whole script and excludes the
/// terminating semicolon; `text` is trimmed.
public struct SQLStatement: Sendable, Equatable {
    public let text: String
    public let range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

public enum SQLStatementSplitter {
    /// Splits on semicolons outside strings, quoted identifiers and comments. Statements made only
    /// of comments/whitespace are dropped.
    public static func split(_ script: String) -> [SQLStatement] {
        let lexer = SQLLexer(script)
        return split(lexer: lexer, tokens: lexer.tokens())
    }

    public static func split(lexer: SQLLexer, tokens: [SQLToken]) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        var firstSignificant: Int?
        var lastSignificantEnd = 0
        func flush() {
            if let start = firstSignificant {
                let range = start..<lastSignificantEnd
                statements.append(SQLStatement(text: lexer.text(in: range), range: range))
            }
            firstSignificant = nil
        }
        for token in tokens {
            if token.kind == .punctuation, lexer.units[token.range.lowerBound] == 0x3B {
                flush()
                continue
            }
            if token.kind == .comment {
                // Leading comments belong to no statement; inner comments stay inside the range.
                if firstSignificant != nil { lastSignificantEnd = max(lastSignificantEnd, token.range.upperBound) }
                continue
            }
            if firstSignificant == nil { firstSignificant = token.range.lowerBound }
            lastSignificantEnd = token.range.upperBound
        }
        flush()
        return statements
    }

    /// The statement containing `offset` (UTF-16). A cursor right after a statement's `;` or in the
    /// blank space after it belongs to that statement.
    public static func statement(at offset: Int, in script: String) -> SQLStatement? {
        let statements = split(script)
        guard !statements.isEmpty else { return nil }
        if let containing = statements.first(where: { $0.range.lowerBound <= offset && offset <= $0.range.upperBound }) {
            return containing
        }
        return statements.last { $0.range.upperBound <= offset } ?? statements.first
    }
}

/// What kind of statement a text is; drives auto-limit, history and confirmation UI.
public enum SQLStatementKind: Sendable, Equatable {
    case query
    case explain
    case show
    case use
    case set
    case dataModification
    case definition
    case administration
    case other

    public static func of(_ statement: String) -> SQLStatementKind {
        let lexer = SQLLexer(statement)
        guard let first = lexer.tokens().first(where: { $0.kind != .comment }) else { return .other }
        let word = lexer.text(of: first).uppercased()
        switch word {
        case "SELECT", "WITH", "VALUES": return .query
        case "(": return .query
        case "EXPLAIN", "DESC", "DESCRIBE": return word == "EXPLAIN" ? .explain : .show
        case "SHOW": return .show
        case "USE": return .use
        case "SET": return .set
        case "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFRESH": return .dataModification
        case "CREATE", "ALTER", "DROP", "RENAME", "RECOVER": return .definition
        case "KILL", "ADMIN", "GRANT", "REVOKE", "PAUSE", "RESUME", "STOP", "CANCEL", "SUBMIT", "ANALYZE", "INSTALL": return .administration
        default: return .other
        }
    }

    /// Statements that change data or schema (asked to confirm on production connections).
    public var isMutation: Bool {
        self == .dataModification || self == .definition || self == .administration
    }
}

/// Adds `LIMIT n` to top-level queries without one (design: workbench auto-limit).
public enum AutoLimit {
    public struct Outcome: Sendable, Equatable {
        public let sql: String
        public let applied: Bool
    }

    public static func apply(to sql: String, limit: Int) -> Outcome {
        guard limit > 0 else { return Outcome(sql: sql, applied: false) }
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        guard let first = tokens.first else { return Outcome(sql: sql, applied: false) }
        let firstWord = lexer.text(of: first).uppercased()
        guard firstWord == "SELECT" || firstWord == "WITH" else { return Outcome(sql: sql, applied: false) }

        var depth = 0
        var lastSignificant: SQLToken?
        for token in tokens {
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" { depth = max(0, depth - 1) }
                if text == ";" { break }
            }
            if depth == 0, token.kind == .keyword || token.kind == .identifier {
                switch text.uppercased() {
                case "LIMIT", "OUTFILE", "INTO":
                    // An explicit limit, or SELECT … INTO OUTFILE / INTO variables: leave unchanged.
                    return Outcome(sql: sql, applied: false)
                default: break
                }
            }
            lastSignificant = token
        }
        guard let lastSignificant else { return Outcome(sql: sql, applied: false) }
        let insertAt = lastSignificant.range.upperBound
        let units = lexer.units
        let head = String(decoding: units[0..<insertAt], as: UTF16.self)
        let tail = String(decoding: units[insertAt...], as: UTF16.self)
        return Outcome(sql: head + " LIMIT \(limit)" + tail, applied: true)
    }
}
