import Foundation

/// Decides whether SQL is a single read-only statement (used for MCP read-only access). The check
/// is token-based (strings, quoted identifiers and comments cannot smuggle keywords) and
/// conservative: anything not clearly a read is rejected.
public enum ReadOnlySQLGuard {
    /// Keywords that must not appear anywhere in a read-only statement.
    static let forbidden: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "DROP", "CREATE", "ALTER", "TRUNCATE", "GRANT", "REVOKE", "KILL", "SUBMIT",
        "OUTFILE", "OVERWRITE", "RENAME", "RECOVER", "INSTALL", "UNINSTALL", "CANCEL", "PAUSE", "RESUME", "STOP",
        "REFRESH", "ANALYZE", "BACKUP", "RESTORE", "LOAD", "EXPORT", "SWAP", "UPSERT", "MERGE",
    ]

    /// Text where supported servers disagree about statement boundaries. StarRocks 4.1 reads `$$ … $$` as one block
    /// while 3.3 reads `$$` as part of a name, so `SELECT 1 $$a; DROP … -- $$` is one statement on one version and two on
    /// the other. A block can only start where code is, so any `$$` outside strings, comments and back-quoted names (as
    /// 3.3 lexes the text) is refused; `LIKE '%$$%'` or `-- costs $$` are fine.
    public static func ambiguityRejection(_ sql: String) -> String? {
        let lexer = SQLLexer(sql) // `$$` blocks off: what StarRocks 3.3 reads
        let ambiguous = lexer.tokens().contains { token in
            token.kind != .string && token.kind != .comment && token.kind != .quotedIdentifier
                && SQLFormatter.containsDollarPair(lexer.units[token.range])
        }
        guard ambiguous else { return nil }
        return "Statements with $$ outside quotes and comments are not allowed here: StarRocks versions read $$ differently (a code block on 4.1, part of a name on 3.3), so where the statement ends cannot be known."
    }

    /// `nil` when allowed; otherwise the reason it is rejected.
    public static func check(_ sql: String) -> String? {
        if let ambiguous = ambiguityRejection(sql) { return ambiguous }
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let lexer = SQLLexer(statement.text)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        let words = tokens.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : lexer.text(of: $0) }
        guard let first = words.first else { return "The statement is empty." }

        switch first {
        case "SELECT", "WITH", "(":
            return checkQuery(tokens: tokens, words: words, lexer: lexer)
        case "SHOW", "DESC", "DESCRIBE":
            return nil
        case "ADMIN":
            return words.count > 1 && words[1] == "SHOW" ? nil : rejection(first)
        case "EXPLAIN":
            var index = 1
            let modifiers: Set<String> = ["LOGICAL", "VERBOSE", "COSTS", "SCHEDULER", "ANALYZE"]
            while index < words.count, modifiers.contains(words[index]) { index += 1 }
            guard index < words.count, ["SELECT", "WITH", "("].contains(words[index]) else {
                return "Only EXPLAIN of a SELECT query is allowed in read-only mode."
            }
            return checkQuery(tokens: Array(tokens[index...]), words: Array(words[index...]), lexer: lexer)
        default:
            return rejection(first)
        }
    }

    private static func checkQuery(tokens: [SQLToken], words: [String], lexer: SQLLexer) -> String? {
        var depth = 0
        for (index, token) in tokens.enumerated() {
            if token.kind == .punctuation {
                if words[index] == "(" { depth += 1 }
                if words[index] == ")" { depth = max(0, depth - 1) }
            }
            guard token.kind == .keyword || token.kind == .identifier else { continue }
            let word = words[index]
            if forbidden.contains(word) { return "`\(word)` is not allowed in a read-only query." }
            if word == "INTO", depth == 0 { return "SELECT … INTO is not allowed in read-only mode." }
        }
        return nil
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH, SHOW, DESC, EXPLAIN, ADMIN SHOW) are allowed; `\(keyword)` statements need a connection with read-write MCP access."
    }
}
