import Foundation

/// The function calls in a statement, as StarRocks 3.3 and 4.1 parse them, for the read-only guard's deny-by-default
/// check: a token that might be a call counts as one. A call is a name (bare, back-quoted, a digit-led word, and a
/// string too, which is a name when the session's sql_dialect is trino) directly followed by `(`, unless the server
/// provably reads the word as syntax there. Each exception below was probed on both versions; when in doubt a token
/// is a call, so the guard may over-refuse but never under-refuse. Linear in the number of tokens, no recursion.
enum SQLFunctionCalls {
    struct Call: Equatable, Sendable {
        /// Lower-cased name; a qualified call keeps its qualifier (`shop.my_udf`). Strings keep their quotes.
        let name: String
        /// `db.fn(` or `catalog.db.fn(`: a user-defined function.
        let isQualified: Bool
    }

    /// Words reserved on every supported version that may precede `(` in valid SQL without being a call (`IN (`,
    /// `OVER (`, `UNION ALL (`, `DECIMAL(10, 2)` in `ARRAY<…>`, `10 DIV (3)`, `GROUP BY CUBE (`). On 3.3 and 4.1
    /// `SELECT 1, W(1, 2)` is a syntax error for each, never a function lookup (the integration test re-checks this).
    /// Words that are not reserved on some version reach function lookup there (EXCEPT, MINUS, ANY, SOME, INTERVAL,
    /// BINARY, ROLLUP, TABLET, PARTITIONS, REPLICA, DECIMAL256, VARBINARY, …): they are calls unless a rule below
    /// places them.
    static let syntaxKeywords: Set<String> = [
        "ALL", "AND", "AS", "BETWEEN", "BY", "CASE", "CUBE", "DECIMAL", "DECIMAL128", "DECIMAL32", "DECIMAL64", "DECIMALV2",
        "DISTINCT", "DIV", "ELSE", "EXISTS", "FROM", "HAVING", "IN", "INTERSECT", "JOIN", "LATERAL", "NOT", "ON", "OR", "OVER",
        "PARTITION", "SELECT", "TABLE", "THEN", "UNION", "USING", "VALUES", "VARCHAR", "WHEN", "WHERE",
    ]

    /// Set operators that are not reserved on every version: syntax only when a query follows (`EXCEPT (SELECT …`); a
    /// function's arguments never start with SELECT or WITH (a syntax error on both versions).
    private static let setOperators: Set<String> = ["EXCEPT", "MINUS"]

    /// Units of `INTERVAL (n) UNIT`. Inside a call's parentheses a call followed by one of these is a syntax error (probed
    /// for every unit and argument form), so there `INTERVAL (n) UNIT` is an interval; elsewhere `+ INTERVAL (1) DAY` is
    /// `interval(1)` aliased DAY, a call.
    static let intervalUnits: Set<String> = [
        "YEAR", "QUARTER", "MONTH", "WEEK", "DAY", "HOUR", "MINUTE", "SECOND", "MILLISECOND", "MICROSECOND",
    ]

    /// Table clauses after a table name in FROM: `t TABLET (1)`, `t PARTITIONS (p1, p2)`, `t REPLICA (1)`.
    private static let tableClauses: Set<String> = ["TABLET", "TABLETS", "PARTITIONS", "REPLICA"]

    /// `* EXCEPT (c)` and `* EXCLUDE (c)` (4.1): a name right after a select-list star is a syntax error, never a call.
    private static let starColumnLists: Set<String> = ["EXCEPT", "EXCLUDE"]

    static func calls(in tokens: [SQLToken], lexer: SQLLexer) -> [Call] {
        let reading = Reading(tokens: tokens, lexer: lexer)
        var calls: [Call] = []
        // Whether the name at an index is a call: decided in order, so a rule may look at an earlier, enclosing call.
        var isCall = [Bool](repeating: false, count: tokens.count)
        for index in tokens.indices where reading.isPunctuation(index + 1, "(") && reading.isNameLike(index) {
            if reading.isSyntax(at: index, isCall: isCall) { continue }
            isCall[index] = true
            calls.append(reading.call(at: index))
        }
        return calls
    }

    /// One statement's tokens with the lookups the rules need; every index is bounds-checked.
    private struct Reading {
        let tokens: [SQLToken]
        let lexer: SQLLexer
        /// For each `(`, the index of its `)`; `nil` when unbalanced.
        let closing: [Int?]
        /// For each token, the index of the innermost `(` still open before it; `nil` at the top level.
        let enclosing: [Int?]

        init(tokens: [SQLToken], lexer: SQLLexer) {
            self.tokens = tokens
            self.lexer = lexer
            var closing = [Int?](repeating: nil, count: tokens.count)
            var enclosing = [Int?](repeating: nil, count: tokens.count)
            var open: [Int] = []
            for index in tokens.indices {
                enclosing[index] = open.last
                guard tokens[index].kind == .punctuation else { continue }
                switch lexer.text(of: tokens[index]) {
                case "(": open.append(index)
                case ")": if let opener = open.popLast() { closing[opener] = index }
                default: break
                }
            }
            self.closing = closing
            self.enclosing = enclosing
        }

        /// A bare ASCII word (keyword or identifier), upper-cased; `nil` for anything else or out of range. Words only
        /// grant exceptions, so a non-ASCII word (which case mapping could turn into a keyword) never matches one.
        func word(_ index: Int) -> String? {
            guard tokens.indices.contains(index), tokens[index].kind == .keyword || tokens[index].kind == .identifier else { return nil }
            let text = lexer.text(of: tokens[index])
            return text.unicodeScalars.allSatisfy(\.isASCII) ? text.uppercased() : nil
        }

        func isPunctuation(_ index: Int, _ text: String) -> Bool {
            tokens.indices.contains(index) && tokens[index].kind == .punctuation && lexer.text(of: tokens[index]) == text
        }

        func isNameLike(_ index: Int) -> Bool {
            guard tokens.indices.contains(index) else { return false }
            switch tokens[index].kind {
            case .keyword, .identifier, .quotedIdentifier, .number, .string: return true
            default: return false
            }
        }

        func isOperator(_ index: Int, _ text: String) -> Bool {
            tokens.indices.contains(index) && tokens[index].kind == .operator && lexer.text(of: tokens[index]) == text
        }

        /// Whether the server reads the name at `index`, followed by `(`, as anything but a call. `isCall` holds the
        /// decisions for the names before `index`.
        func isSyntax(at index: Int, isCall: [Bool]) -> Bool {
            // `(…) t(a, b)`, `PARTITION (p) TABLET (1)`: nothing directly after `)` is a call.
            if isPunctuation(index - 1, ")") { return true }
            // `AS t(a, b)`, `CAST(x AS DECIMAL(10, 2))`, `AS OF (…)`: a name or a type, never a call.
            if word(index - 1) == "AS" { return true }
            if isCTEName(at: index) { return true }
            guard let word = word(index) else { return false }
            if SQLFunctionCalls.syntaxKeywords.contains(word) { return true }
            if SQLFunctionCalls.starColumnLists.contains(word), followsSelectListStar(index) { return true }
            if SQLFunctionCalls.setOperators.contains(word) { return ["SELECT", "WITH"].contains(self.word(index + 2) ?? "") }
            if word == "INTERVAL" { return isIntervalInCallArguments(index, isCall: isCall) }
            if SQLFunctionCalls.tableClauses.contains(word) { return followsTableName(index) }
            // `GROUP BY ROLLUP (…)` and `GROUP BY GROUPING SETS (…)`; anywhere else ROLLUP( and SETS( are calls.
            if word == "ROLLUP" { return self.word(index - 1) == "BY" && self.word(index - 2) == "GROUP" }
            if word == "SETS" { return self.word(index - 1) == "GROUPING" && self.word(index - 2) == "BY" && self.word(index - 3) == "GROUP" }
            return false
        }

        /// `WITH c(a, b) AS (…)` and `…), d(x) AS (…)`: the name's `)` is followed by `AS (`.
        private func isCTEName(at index: Int) -> Bool {
            guard tokens.indices.contains(index + 1), [.keyword, .identifier, .quotedIdentifier].contains(tokens[index].kind),
                  ["WITH", "RECURSIVE"].contains(word(index - 1) ?? "") || isPunctuation(index - 1, ","),
                  let close = closing[index + 1] else { return false }
            return word(close + 1) == "AS" && isPunctuation(close + 2, "(")
        }

        /// The previous token is the select-list star: `*` after SELECT, DISTINCT, ALL, `,` or `.` (after a value, `*`
        /// multiplies: `2 * exclude(1)` is a call).
        private func followsSelectListStar(_ index: Int) -> Bool {
            guard isOperator(index - 1, "*") else { return false }
            return ["SELECT", "DISTINCT", "ALL"].contains(word(index - 2) ?? "") || isPunctuation(index - 2, ",") || isPunctuation(index - 2, ".")
        }

        /// `INTERVAL (n) UNIT` directly inside a call's parentheses: `date_add(d, INTERVAL (1) DAY)`.
        private func isIntervalInCallArguments(_ index: Int, isCall: [Bool]) -> Bool {
            guard tokens.indices.contains(index + 1), let close = closing[index + 1], let unit = word(close + 1), SQLFunctionCalls.intervalUnits.contains(unit),
                  let opener = enclosing[index], opener > 0, isCall[opener - 1] else { return false }
            return true
        }

        /// The previous token is a table name (bare or back-quoted) right after FROM, JOIN, `,` or `.`: a name followed
        /// by a name cannot be an expression, so the clause is not a call.
        private func followsTableName(_ index: Int) -> Bool {
            guard tokens.indices.contains(index - 1), [.identifier, .quotedIdentifier].contains(tokens[index - 1].kind) else { return false }
            return ["FROM", "JOIN"].contains(word(index - 2) ?? "") || isPunctuation(index - 2, ",") || isPunctuation(index - 2, ".")
        }

        func call(at index: Int) -> Call {
            guard isPunctuation(index - 1, ".") else { return Call(name: name(index), isQualified: false) }
            var parts = [name(index)]
            var current = index
            while isPunctuation(current - 1, "."), isNameLike(current - 2) {
                parts.append(name(current - 2))
                current -= 2
            }
            return Call(name: parts.reversed().joined(separator: "."), isQualified: true)
        }

        private func name(_ index: Int) -> String {
            let token = tokens[index]
            switch token.kind {
            case .quotedIdentifier: return lexer.identifierValue(of: token).lowercased()
            case .string: return lexer.text(of: token)
            default: return lexer.text(of: token).lowercased()
            }
        }
    }
}
