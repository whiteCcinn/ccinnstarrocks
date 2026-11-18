import Foundation

/// How `SQLFormatter` lays out SQL.
public struct SQLFormatOptions: Sendable, Equatable {
    public enum KeywordCase: String, Sendable, CaseIterable, Identifiable {
        case upper, lower, preserve
        public var id: String { rawValue }
    }

    public var keywordCase: KeywordCase
    /// Spaces per indent level, always 1…8: every assignment is clamped.
    public var indentWidth: Int {
        get { clampedIndentWidth }
        set { clampedIndentWidth = Self.clamped(newValue) }
    }
    /// Whether the connected server reads `$$ … $$` as one block (inline function bodies). When it does not, or
    /// nobody knows, text with such a block is not formatted: StarRocks 3.3 reads `$$` as part of a name, so a `--`
    /// inside the body would comment out what follows.
    public var dollarQuotedBlocks: Bool
    private var clampedIndentWidth: Int

    public init(keywordCase: KeywordCase = .upper, indentWidth: Int = 2, dollarQuotedBlocks: Bool = false) {
        self.keywordCase = keywordCase
        clampedIndentWidth = Self.clamped(indentWidth)
        self.dollarQuotedBlocks = dollarQuotedBlocks
    }

    /// `$$` blocks are verified on StarRocks 4.1; 3.3 reads `$$` as part of a name, and other versions are unverified.
    public static func dollarQuotedBlocksSupported(major: Int, minor: Int) -> Bool {
        (major, minor) >= (4, 1)
    }

    static func clamped(_ width: Int) -> Int { min(max(width, 1), 8) }
}

/// Formatting part of a text: `range` (UTF-16, in the original text) becomes `replacement`.
public struct SQLFormatEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Formats SQL by deciding the whitespace between the lexer's tokens (design D1–D5).
///
/// Only two things change:
/// - whitespace between tokens, and only where the server provably reads the tokens the same way;
/// - the letter case of words that can never be names (`caseSafeKeywords`) or that the formatter recognises by their
///   position (`END` of a CASE, StarRocks DDL clause words, window frame bounds, …).
///
/// Names, functions, strings, quoted identifiers, comments and hints keep their exact text. The result is re-lexed and
/// compared with the input; when anything else differs, `format` returns `nil` rather than a text that might mean
/// something else.
public enum SQLFormatter {
    /// Keywords whose letter case may change wherever they stand: the lexer keywords that StarRocks 3.3 and 4.1 reject
    /// both as a table name and as an alias. Table names are case-sensitive, so recasing a word the server also
    /// accepts as a name (`FROM current` → `FROM CURRENT`) would name another table. The integration tests re-check
    /// every word against live servers. ANTI, BINARY, CAST, CURRENT, END, EXCEPT, INTERVAL, MINUS, PRECEDING, ROLLUP,
    /// ROW, SEMI and the like are valid names there, so they are recased only where the formatter recognises them.
    public static let caseSafeKeywords: Set<String> = Set("""
    ADD ALL ALTER ANALYZE AND ARRAY AS ASC BETWEEN BIGINT BITMAP BY CASE CHAR COLUMN CREATE CROSS DATABASE \
    DATABASES DECIMAL DEFAULT DELETE DESC DESCRIBE DISTINCT DOUBLE DROP ELSE EXISTS EXPLAIN FALSE FILES FLOAT FOR \
    FORCE FROM FULL FUNCTION GRANT GROUP HAVING HLL IF IGNORE IN INDEX INNER INSERT INT INTERSECT INTO IS JOIN \
    JSON KEY KEYS KILL LARGEINT LATERAL LEFT LIKE LIMIT LOAD MAXVALUE NOT NULL ON OR ORDER OUTER OUTFILE OVER \
    PARTITION PERCENTILE PRIMARY RANGE REGEXP RENAME REPLACE REVOKE RIGHT RLIKE ROWS SCHEMA SELECT SET SHOW \
    SMALLINT TABLE THEN TINYINT TO TRUE UNION UNIQUE UPDATE USE USING VALUES VARCHAR WHEN WHERE WITH
    """.split(separator: " ").map(String.init))

    /// Deeper nesting is written at this indent level, so deeply nested input cannot make the output quadratic.
    static let maxIndentLevel = 16

    public static func format(_ text: String, options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        format(text, options: options, baseIndent: "", lineBreak: nil)
    }

    /// `baseIndent` starts every line after the first (a selection keeps the indent of its first line); `lineBreak` is
    /// the text's own line break, found in `text` itself when `nil`.
    static func format(_ text: String, options: SQLFormatOptions, baseIndent: String, lineBreak: String?) -> String? {
        let lexer = SQLLexer(text, dollarQuotedBlocks: options.dollarQuotedBlocks)
        let tokens = lexer.tokens()
        guard !tokens.isEmpty else { return "" }
        guard !mustRefuse(lexer, tokens) else { return nil }
        let lineBreak = lineBreak ?? Self.lineBreak(of: lexer, tokens)
        var engine = Engine(lexer: lexer, tokens: tokens, options: options, lineBreak: lineBreak, baseIndent: baseIndent)
        guard var output = engine.run() else { return nil } // cancelled, or runaway output
        // Keep a trailing newline only when the input ended with one after its last token.
        if let last = tokens.last, lexer.units[last.range.upperBound...].contains(where: isLineBreak) {
            output += lineBreak
        }
        guard equivalent(lexer: lexer, tokens: tokens, to: output, caseChangeable: engine.caseChangeable) else { return nil }
        return output
    }

    /// Formats the selected part of `text`, or returns `nil` when it cannot be formatted safely.
    ///
    /// The selection is widened to whole tokens: a boundary inside a name, string or comment would otherwise make the
    /// fragment lex differently (`from use|r` → `FROM USEr`). The fragment is formatted on its own; then the whole text
    /// with the replacement is compared with the original, where only words the formatter recognises *in the whole
    /// text* may change case.
    public static func formatSelection(in text: String, range: NSRange, options: SQLFormatOptions = SQLFormatOptions()) -> SQLFormatEdit? {
        let source = text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length else { return nil }
        let lexer = SQLLexer(text, dollarQuotedBlocks: options.dollarQuotedBlocks)
        let tokens = lexer.tokens()
        guard !mustRefuse(lexer, tokens) else { return nil }
        let lower = range.location
        let upper = max(NSMaxRange(range), lower + 1)
        guard let first = tokens.firstIndex(where: { $0.range.upperBound > lower }), tokens[first].range.lowerBound < upper else {
            return SQLFormatEdit(range: range, replacement: source.substring(with: range)) // only whitespace: nothing to do
        }
        var last = first
        while last + 1 < tokens.count, tokens[last + 1].range.lowerBound < upper { last += 1 }
        let snapped = NSRange(location: tokens[first].range.lowerBound,
                              length: tokens[last].range.upperBound - tokens[first].range.lowerBound)
        // Later lines take the indentation of the selection's first line.
        var lineStart = snapped.location
        while lineStart > 0, !isLineBreak(lexer.units[lineStart - 1]) { lineStart -= 1 }
        var indentEnd = lineStart
        while indentEnd < snapped.location, lexer.units[indentEnd] == 0x20 || lexer.units[indentEnd] == 0x09 { indentEnd += 1 }
        let baseIndent = lexer.text(in: lineStart..<indentEnd)
        guard let formatted = format(source.substring(with: snapped), options: options, baseIndent: baseIndent,
                                     lineBreak: lineBreak(of: lexer, tokens)) else { return nil }
        var whole = Engine(lexer: lexer, tokens: tokens, options: options, lineBreak: "\n", baseIndent: "")
        guard whole.run() != nil else { return nil }
        let spliced = source.replacingCharacters(in: snapped, with: formatted)
        guard equivalent(lexer: lexer, tokens: tokens, to: spliced, caseChangeable: whole.caseChangeable) else { return nil }
        return SQLFormatEdit(range: snapped, replacement: formatted)
    }

    /// The offset in `formatted` that corresponds to `offset` in `original`: the position after the same number of
    /// non-whitespace UTF-16 units. Exact for formatter output, which only changes whitespace and letter case.
    public static func mapOffset(_ offset: Int, from original: String, to formatted: String) -> Int {
        let source = Array(original.utf16)
        let target = Array(formatted.utf16)
        let end = min(max(0, offset), source.count)
        let count = source[..<end].reduce(0) { $0 + (isWhitespace($1) ? 0 : 1) }
        var index = 0
        var seen = 0
        while index < target.count, seen < count {
            if !isWhitespace(target[index]) { seen += 1 }
            index += 1
        }
        return index
    }

    /// Whether `rhs` is `lhs` reformatted: the same tokens with the same texts, letter case differing only on words
    /// the formatter may recase in `lhs`, and whitespace added or removed only where that is safe.
    public static func sameTokens(_ lhs: String, _ rhs: String) -> Bool {
        let lexer = SQLLexer(lhs)
        let tokens = lexer.tokens()
        var engine = Engine(lexer: lexer, tokens: tokens, options: SQLFormatOptions(), lineBreak: "\n", baseIndent: "")
        _ = engine.run()
        return equivalent(lexer: lexer, tokens: tokens, to: rhs, caseChangeable: engine.caseChangeable)
    }

    static func equivalent(lexer: SQLLexer, tokens: [SQLToken], to output: String, caseChangeable: Set<Int>) -> Bool {
        let outLexer = SQLLexer(output, dollarQuotedBlocks: lexer.dollarQuotedBlocks)
        let outTokens = outLexer.tokens()
        guard outTokens.count == tokens.count else { return false }
        for index in tokens.indices {
            let original = tokens[index]
            let formatted = outTokens[index]
            guard original.kind == formatted.kind, original.range.count == formatted.range.count else { return false }
            let originalUnits = lexer.units[original.range]
            let formattedUnits = outLexer.units[formatted.range]
            let sameText = caseChangeable.contains(index)
                ? zip(originalUnits, formattedUnits).allSatisfy(sameIgnoringASCIICase)
                : originalUnits.elementsEqual(formattedUnits)
            guard sameText else { return false }
            guard index > 0 else { continue }
            let previous = tokens[index - 1]
            let wasAdjacent = previous.range.upperBound == original.range.lowerBound
            let isAdjacent = outTokens[index - 1].range.upperBound == formatted.range.lowerBound
            if wasAdjacent, !isAdjacent, !mayInsertSpace(lexer, previous, original) { return false }
            if !wasAdjacent, isAdjacent, !mayRemoveSpace(lexer, previous, original) { return false }
        }
        return true
    }

    /// `\r\n` when the text breaks lines with CRLF between tokens; line breaks inside strings and comments do not count.
    static func lineBreak(of lexer: SQLLexer, _ tokens: [SQLToken]) -> String {
        var gapStart = 0
        for index in 0...tokens.count {
            let gapEnd = index < tokens.count ? tokens[index].range.lowerBound : lexer.units.count
            var cursor = gapStart
            while cursor + 1 < gapEnd {
                if lexer.units[cursor] == 0x0D, lexer.units[cursor + 1] == 0x0A { return "\r\n" }
                cursor += 1
            }
            if index < tokens.count { gapStart = tokens[index].range.upperBound }
        }
        return "\n"
    }

    /// Letters that StarRocks upper-cases to an ASCII letter: it upper-cases per character (Java's simple mapping), so
    /// `exiſts` is EXISTS and `ıf` is IF there. ı (U+0131) and ſ (U+017F) are the only ones in the BMP (pinned by a
    /// test that enumerates it).
    static let lettersUpperCasingToASCII: Set<UInt16> = [0x131, 0x17F]

    /// Text the formatter will not touch:
    /// - a word split between two tokens (below);
    /// - a word outside strings, comments and back-quoted names that contains ı or ſ: the server may read it as a
    ///   keyword, and taking it for a name would mislead the rules that infer from a word not being a keyword;
    /// - an unclosed `$$` block; and, unless the server is known to read `$$` blocks (the lexer then reads them too),
    ///   any `$$` outside strings and comments, which StarRocks 4.1 would read as the start of a block.
    static func mustRefuse(_ lexer: SQLLexer, _ tokens: [SQLToken]) -> Bool {
        if splitsAWord(lexer, tokens) { return true }
        // `#`, `\`, control characters and characters above U+FFFF: the server drops them, so the formatter would too.
        if lexer.containsDroppedCharacters(tokens) { return true }
        for token in tokens {
            switch token.kind {
            case .string where lexer.units[token.range.lowerBound] == 0x24: // a `$$` block (blocks on)
                if lexer.isUnterminated(token) { return true }
            case .string, .quotedIdentifier, .comment:
                continue
            default:
                let units = lexer.units[token.range]
                if units.contains(where: { lettersUpperCasingToASCII.contains($0) }) { return true }
                if !lexer.dollarQuotedBlocks, containsDollarPair(units) { return true }
            }
        }
        return false
    }

    static func containsDollarPair(_ units: ArraySlice<UInt16>) -> Bool {
        zip(units, units.dropFirst()).contains { $0 == 0x24 && $1 == 0x24 }
    }

    /// Opening brackets and the closer each expects: `(`, `[` (arrays, subscripts) and `{` (maps).
    static func closer(of token: SQLToken, _ text: String) -> String? {
        switch (token.kind, text) {
        case (.punctuation, "("): ")"
        case (.operator, "["): "]"
        case (.operator, "{"): "}"
        default: nil
        }
    }

    static func isCloser(_ token: SQLToken, _ text: String) -> Bool {
        (token.kind == .punctuation && text == ")") || (token.kind == .operator && (text == "]" || text == "}"))
    }

    /// Whether two tokens meet between two word characters (`1.5|end`, `1e+5|x`). The server splits there too, but
    /// that is exactly where lexers can disagree, and a hidden or extra `END` changes what a statement means; the
    /// re-lex check cannot see such a disagreement, so the formatter refuses instead.
    static func splitsAWord(_ lexer: SQLLexer, _ tokens: [SQLToken]) -> Bool {
        for index in tokens.indices.dropFirst() {
            let previous = tokens[index - 1].range
            let current = tokens[index].range
            guard previous.upperBound == current.lowerBound, !previous.isEmpty, !current.isEmpty else { continue }
            if SQLLexer.isIdentifierPart(lexer.units[previous.upperBound - 1]), SQLLexer.isIdentifierPart(lexer.units[current.lowerBound]) {
                return true
            }
        }
        return false
    }

    // MARK: Whitespace rules

    /// Whether whitespace may appear between two tokens that touch in the input. Only next to separators and
    /// operators, after a closing quote or around comments: elsewhere the server may read a touching pair as one token
    /// (`0xabc_flag`, `x'0F'`, `\N`, `a::int`) even where this lexer splits it.
    static func mayInsertSpace(_ lexer: SQLLexer, _ first: SQLToken, _ second: SQLToken) -> Bool {
        if first.kind == .comment || second.kind == .comment { return true }
        if isSeparator(lexer, first) || isSeparator(lexer, second) { return true }
        // After a closing quote, but not before `@`: `'root'@'%'` is one user identity.
        if first.kind == .string || first.kind == .quotedIdentifier { return second.kind != .variable }
        if second.kind == .quotedIdentifier { return true }
        return isSeparableOperator(lexer, first) || isSeparableOperator(lexer, second)
    }

    /// Whether whitespace between two tokens may be removed: only inside brackets, before separators, around the `.`
    /// of a qualified name, between a function name and its `(` or subscript `[`, and after a sign.
    static func mayRemoveSpace(_ lexer: SQLLexer, _ first: SQLToken, _ second: SQLToken) -> Bool {
        if first.kind == .comment || second.kind == .comment { return false }
        let firstText = lexer.text(of: first)
        let secondText = lexer.text(of: second)
        let nameKinds: Set<SQLToken.Kind> = [.identifier, .quotedIdentifier, .keyword]
        if first.kind == .punctuation, firstText == "(" { return true }
        if first.kind == .operator, firstText == "[" || firstText == "{" { return true }
        if second.kind == .punctuation, secondText == ")" || secondText == "," || secondText == ";" { return true }
        if second.kind == .operator, secondText == "]" || secondText == "}" { return true }
        if second.kind == .punctuation, secondText == ".", nameKinds.contains(first.kind) { return true }
        if first.kind == .punctuation, firstText == "." {
            return nameKinds.contains(second.kind) || (second.kind == .operator && secondText == "*")
        }
        if second.kind == .punctuation, secondText == "(", nameKinds.contains(first.kind) { return true }
        if second.kind == .operator, secondText == "[" {
            return nameKinds.contains(first.kind) || firstText == ")" || firstText == "]"
        }
        if first.kind == .operator, firstText == "-" || firstText == "+" {
            let operands: Set<SQLToken.Kind> = [.number, .identifier, .quotedIdentifier, .keyword, .variable]
            return operands.contains(second.kind) || (second.kind == .punctuation && secondText == "(")
        }
        return false
    }

    private static func isSeparator(_ lexer: SQLLexer, _ token: SQLToken) -> Bool {
        guard token.kind == .punctuation, token.range.count == 1 else { return false }
        let unit = lexer.units[token.range.lowerBound]
        return unit == 0x28 || unit == 0x29 || unit == 0x2C || unit == 0x3B // ( ) , ;
    }

    /// Comparison, arithmetic, logical and assignment operators: never part of a name or literal.
    private static func isSeparableOperator(_ lexer: SQLLexer, _ token: SQLToken) -> Bool {
        guard token.kind == .operator else { return false }
        let units = lexer.units[token.range]
        if units.elementsEqual([0x3A, 0x3D]) { return true } // :=
        return units.allSatisfy { unit in
            switch unit {
            case 0x3D, 0x3C, 0x3E, 0x21, 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x7C, 0x26, 0x5E, 0x7E: true // = < > ! + - * / % | & ^ ~
            default: false
            }
        }
    }

    private static func sameIgnoringASCIICase(_ pair: (UInt16, UInt16)) -> Bool {
        let (left, right) = pair
        if left == right { return true }
        return isASCIILetter(left) && isASCIILetter(right) && left | 0x20 == right | 0x20
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    static func isLineBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }
}

// MARK: - Engine

extension SQLFormatter {
    /// Words before which a statement-level (or subquery-level) clause starts on its own line.
    static let clauseWords: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "UNION", "INTERSECT",
                                           "EXCEPT", "MINUS", "VALUES", "SET", "WINDOW", "QUALIFY"]
    /// Set operators; EXCEPT and MINUS are also valid names, so they count only before a proven query.
    static let setOperators: Set<String> = ["UNION", "INTERSECT", "EXCEPT", "MINUS"]
    /// Words that start a query operand of a set operator.
    static let queryStarts: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE"]
    /// Words that end a clause for the list look-ahead.
    static let clauseEndWords: Set<String> = clauseWords.union(["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "ON",
                                                                "USING", "OFFSET", "INTO"])
    /// Statements that get clause layout; others only get normalised spacing.
    static let layoutStatements: Set<String> = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "VALUES", "CREATE", "EXPLAIN",
                                                "SUBMIT", "UPSERT"]
    /// Words that may precede the query of an EXPLAIN-like statement without a break.
    static let queryPrefixWords: Set<String> = ["EXPLAIN", "COSTS", "VERBOSE", "LOGICAL", "ANALYZE", "SCHEDULER"]
    static let joinStarts: Set<String> = ["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS"]
    /// Keywords written directly before `(` like a function call.
    static let callLikeKeywords: Set<String> = {
        var words = Set(SQLFunctions.names)
        words.formUnion(["CAST", "IF", "KEY", "HASH", "RANGE", "LIST", "RANDOM", "LEFT", "RIGHT", "ROW", "CONVERT", "EXTRACT",
                         "BIGINT", "INT", "INTEGER", "TINYINT", "SMALLINT", "LARGEINT", "DECIMAL", "DECIMALV2", "DECIMAL32", "DECIMAL64",
                         "DECIMAL128", "DOUBLE", "FLOAT", "CHAR", "VARCHAR", "STRING", "BINARY", "VARBINARY", "DATE", "DATETIME",
                         "TIMESTAMP", "BOOLEAN", "JSON", "ARRAY", "MAP", "STRUCT", "BITMAP", "HLL", "PERCENTILE", "VALUES_LIST"])
        words.subtract(["IN", "VALUES", "AS", "ON", "USING", "EXISTS", "OVER", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE", "END",
                        "START", "EVERY", "PARTITION", "PROPERTIES", "INDEX", "INTO", "TABLE", "FROM", "WHERE", "SELECT", "WITH"])
        return words
    }()
    /// Keywords after which the next word is a name (`FROM properties`, `ON minus`, `INTO interval`): unless it is a
    /// keyword the server never accepts as a name, it is treated as one. Only case-safe keywords open a slot (VIEW or
    /// OVERWRITE may themselves be column names). DESC / DESCRIBE / USE count only at a statement start.
    static let nameSlotKeywords: Set<String> = ["FROM", "JOIN", "INTO", "TABLE", "INDEX", "UPDATE", "DATABASE", "SCHEMA",
                                                "ON", "EXISTS", "WITH", "FUNCTION"]
    static let statementNameSlotKeywords: Set<String> = ["DESC", "DESCRIBE", "USE"]
    /// Clause and operator keywords that take a space before `(` even when the input has none (`IN(1)` → `IN (1)`).
    /// Other keywords written against their `(` are calls and stay attached (`user()`, `quarter('…')`, `rollup(a)`).
    static let spacedBeforeParen: Set<String> = [
        "IN", "VALUES", "AS", "ON", "USING", "EXISTS", "OVER", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE", "END", "FROM",
        "WHERE", "SELECT", "WITH", "BY", "JOIN", "HAVING", "UNION", "INTERSECT", "EXCEPT", "MINUS", "ALL", "DISTINCT", "LIKE",
        "RLIKE", "REGEXP", "IS", "BETWEEN", "CASE", "LIMIT", "SET", "INTO", "TABLE", "PARTITION", "PROPERTIES", "INDEX",
        "START", "EVERY", "LATERAL", "QUALIFY", "WINDOW", "ANY", "SOME",
    ]
    /// Reserved words that are values, not operators: a `-` after them is binary.
    static let operandKeywords: Set<String> = ["NULL", "TRUE", "FALSE", "END"]

    struct Frame {
        enum Kind { case statement, subquery, list, paren }
        enum Clause { case none, select, from, whereLike, groupBy, orderBy, limit, join, on, set, values, with, window, ddl, other }

        var kind: Kind
        /// Indent level of clauses (statement, subquery) or items (list) in this frame.
        var indent: Int
        /// Indent level of the line holding the opening `(`.
        var openIndent: Int
        var clause: Clause = .none
        var listBreak = false
        var betweenPending = false
        /// ORDER BY seen inside these parentheses (a window specification, `group_concat(… ORDER BY …)`).
        var orderBySeen = false
        /// These parentheses hold a window specification: `OVER (…)`, `WINDOW w AS (…)`.
        var isWindowSpec = false
        /// A window frame (`ROWS | RANGE BETWEEN …`) started inside this window specification.
        var windowFrame = false
        /// The `(`, `[` or `{` that opened this frame (-1 for the statement).
        var opener = -1

        var allowsClauses: Bool { kind == .statement || kind == .subquery }
    }

    /// A CASE being written; `depth` is the frame it belongs to (`frames.count` when it opened).
    struct OpenCase {
        let endIndex: Int?
        let multiline: Bool
        let indent: Int
        let depth: Int
    }

    struct Engine {
        let lexer: SQLLexer
        let tokens: [SQLToken]
        let options: SQLFormatOptions
        /// Upper-cased text of keyword and identifier tokens; the raw text otherwise. Empty for a word next to `.`: it is
        /// a name (`end.a`, `t.case`), so no keyword rule (CASE … END, joins, set operators, DDL, case changes) matches it.
        let words: [String]
        /// Tokens whose letter case may change: safe keywords, plus words recognised by position while formatting.
        private(set) var caseChangeable = Set<Int>()
        private let nextSignificantIndex: [Int]
        /// For each opening bracket its closer, and for each closer its opener (-1: unmatched).
        private let matchingBracket: [Int]
        private let caseEnds: [Int: Int]
        private let caseBranches: [Int: Int]
        /// CASE, WHEN, THEN, ELSE and END of statements whose CASE structure is unproven: written exactly as they are.
        private let frozenCaseWords: Set<Int>
        private let outputLimit: Int
        private let lineBreak: String
        private let baseIndent: String

        private var output = ""
        private var lineIndent = 0
        private var atLineStart = true
        private var pendingBreak: (indent: Int, blank: Bool)?
        /// Comments that started their own line (and comments after them on that line), written before the next token.
        private var heldComments: [(index: Int, sameLine: Bool)] = []
        private var frames: [Frame] = [Frame(kind: .statement, indent: 0, openIndent: 0)]
        private var caseStack: [OpenCase] = []
        private var lastSignificant: Int?
        private var previousSignificant: Int?
        private var lastWasSign = false
        private var statementTokens = 0
        private var statementFirst = ""
        private var onlyPrefixWords = true
        /// Every token of the statement so far is a keyword (`CREATE OR REPLACE MATERIALIZED`).
        private var onlyKeywordsSoFar = true
        /// The query of a CREATE … AS SELECT has begun: DDL clause words no longer apply.
        private var queryStarted = false
        /// CREATE [EXTERNAL | TEMPORARY] TABLE or CREATE MATERIALIZED VIEW: the statements with DDL clause words.
        private var definesTable = false
        /// The table or view name of that statement has been written.
        private var objectNamed = false
        private var sawDistributed = false
        private var layout = true
        private var listHeadEnd: Int?
        /// After INTO / TABLE / VIEW: 1 = expecting the name, 2 = inside the (qualified) name.
        private var tableNameState = 0
        private var tableNameIsCreateTable = false
        /// Last word of a multi-word join operator being written.
        private var joinWordsThrough: Int?

        init(lexer: SQLLexer, tokens: [SQLToken], options: SQLFormatOptions, lineBreak: String, baseIndent: String) {
            self.lexer = lexer
            self.tokens = tokens
            self.options = options
            self.lineBreak = lineBreak
            self.baseIndent = baseIndent
            var words = tokens.map { token in
                let text = lexer.text(of: token)
                return token.kind == .keyword || token.kind == .identifier ? text.uppercased() : text
            }
            /// The words before any name rule: the CASE proof counts every CASE and `end` keyword, wherever it stands.
            let rawWords = words
            outputLimit = 16 * lexer.units.count + 65_536

            var next = [Int](repeating: -1, count: tokens.count)
            var following = -1
            for index in tokens.indices.reversed() {
                next[index] = following
                if tokens[index].kind != .comment { following = index }
            }
            nextSignificantIndex = next
            var previous = [Int](repeating: -1, count: tokens.count)
            var preceding = -1
            for index in tokens.indices {
                previous[index] = preceding
                if tokens[index].kind != .comment { preceding = index }
            }

            // Names, before any rule looks at the words (an empty word matches no rule):
            // - a word with a non-ASCII character: the server never reads it as a keyword (`ﬁrst`);
            // - a word next to `.` (`end.a`, `t.case`);
            // - a word in a name slot (`FROM properties`), except END: the CASE proof below decides about END.
            let isDot = tokens.indices.map { tokens[$0].kind == .punctuation && words[$0] == "." }
            for index in tokens.indices where tokens[index].kind == .keyword || tokens[index].kind == .identifier {
                let dotted = (previous[index] >= 0 && isDot[previous[index]]) || (next[index] >= 0 && isDot[next[index]])
                if dotted || !Self.isASCII(lexer, tokens[index]) { words[index] = "" }
            }
            for index in tokens.indices where tokens[index].kind == .keyword && words[index] != "END"
                && !words[index].isEmpty && !SQLFormatter.caseSafeKeywords.contains(words[index]) {
                let slot = previous[index]
                guard slot >= 0, tokens[slot].kind == .keyword, SQLFormatter.caseSafeKeywords.contains(words[slot]) else { continue }
                let startsStatement = previous[slot] < 0 || (tokens[previous[slot]].kind == .punctuation && words[previous[slot]] == ";")
                if SQLFormatter.nameSlotKeywords.contains(words[slot])
                    || (startsStatement && SQLFormatter.statementNameSlotKeywords.contains(words[slot])) {
                    words[index] = ""
                }
            }
            self.words = words

            // One pass: matching brackets, and CASE … END with a statement-level proof. Every CASE needs exactly one
            // END, so when a statement has as many `end` keywords as CASE keywords (all of them: `end.a` may be the
            // terminator, as the CASE result's field) and each CASE pairs with one at its own bracket depth, every `end`
            // is a terminator: a name `end` would leave a CASE open, and the server rejects that. The statement is also
            // left unproven when one of its CASE words is a name to the formatter (next to `.`, or non-ASCII), so the
            // layout never has to treat a name as structure. Unproven: every CASE word stays exactly as written.
            var matching = [Int](repeating: -1, count: tokens.count)
            var openers: [(index: Int, closer: String)] = []
            var openCases: [(index: Int, depth: Int)] = []
            var ends: [Int: Int] = [:]
            var branches: [Int: Int] = [:]
            var frozen = Set<Int>()
            var statementCases: [Int] = []
            var statementEnds = 0
            var statementCaseWords: [Int] = []
            func finishStatement() {
                let proven = statementCases.count == statementEnds && statementCases.allSatisfy { ends[$0] != nil }
                    && statementCaseWords.allSatisfy { !words[$0].isEmpty }
                if !proven {
                    frozen.formUnion(statementCaseWords)
                    for open in statementCases {
                        ends[open] = nil
                        branches[open] = nil
                    }
                }
                statementCases.removeAll()
                statementEnds = 0
                statementCaseWords.removeAll()
                openCases.removeAll()
                openers.removeAll()
            }
            for index in tokens.indices {
                let token = tokens[index]
                let word = words[index]
                if let closer = SQLFormatter.closer(of: token, word) {
                    openers.append((index, closer))
                } else if SQLFormatter.isCloser(token, word) {
                    guard let open = openers.last, open.closer == word else { continue } // unbalanced: no frame closes
                    while let open = openCases.last, open.depth >= openers.count { openCases.removeLast() }
                    matching[open.index] = index
                    matching[index] = open.index
                    openers.removeLast()
                } else if token.kind == .punctuation, word == ";" {
                    finishStatement()
                } else if token.kind == .keyword {
                    switch rawWords[index] {
                    case "CASE":
                        statementCases.append(index)
                        statementCaseWords.append(index)
                        openCases.append((index, openers.count))
                    case "END":
                        statementEnds += 1
                        statementCaseWords.append(index)
                        if let open = openCases.last, open.depth == openers.count {
                            ends[open.index] = index
                            openCases.removeLast()
                        }
                    case "WHEN", "ELSE":
                        statementCaseWords.append(index)
                        if let open = openCases.last, open.depth == openers.count { branches[open.index, default: 0] += 1 }
                    case "THEN":
                        statementCaseWords.append(index)
                    default:
                        break
                    }
                }
            }
            finishStatement()
            matchingBracket = matching
            caseEnds = ends
            caseBranches = branches
            frozenCaseWords = frozen

            for index in tokens.indices where tokens[index].kind == .keyword && SQLFormatter.caseSafeKeywords.contains(words[index]) {
                if !frozen.contains(index) { caseChangeable.insert(index) }
            }
        }

        // MARK: Run

        /// The formatted text, or `nil` when the task was cancelled or the output grew out of proportion.
        mutating func run() -> String? {
            for index in tokens.indices {
                if index & 1023 == 0, Task.isCancelled { return nil }
                if tokens[index].kind == .comment {
                    comment(index)
                } else {
                    token(index)
                }
                if output.utf8.count > outputLimit { return nil }
            }
            flushHeldComments(final: true)
            return output
        }

        private var frame: Frame {
            get { frames[frames.count - 1] }
            set { frames[frames.count - 1] = newValue }
        }

        /// The CASE whose WHEN / ELSE / END belong to the current frame.
        private var currentCase: OpenCase? {
            guard let open = caseStack.last, open.depth == frames.count else { return nil }
            return open
        }

        private func isWord(_ index: Int, _ word: String) -> Bool {
            tokens[index].kind == .keyword && words[index] == word
        }

        private func nextSignificant(after index: Int) -> Int? {
            let next = nextSignificantIndex[index]
            return next >= 0 ? next : nil
        }

        private func isPunctuation(_ index: Int, _ text: String) -> Bool {
            (tokens[index].kind == .punctuation || tokens[index].kind == .operator) && words[index] == text
        }

        private static func isASCII(_ lexer: SQLLexer, _ token: SQLToken) -> Bool {
            lexer.units[token.range].allSatisfy { $0 < 0x80 }
        }

        /// Marks a word recognised by its position as recasable (ASCII words only: case mapping is unambiguous there).
        private mutating func recase(_ index: Int) {
            if Self.isASCII(lexer, tokens[index]) { caseChangeable.insert(index) }
        }

        // MARK: Comments

        private mutating func comment(_ index: Int) {
            let startsLine = index == 0
                || lexer.units[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound].contains(where: SQLFormatter.isLineBreak)
            if !output.isEmpty, startsLine || !heldComments.isEmpty {
                // Own-line comments wait for the next token's indent; comments after them on that line stay with them.
                heldComments.append((index, sameLine: !startsLine))
                return
            }
            // Inline: stays on the current line, whatever break is pending for the next token.
            if !output.isEmpty, !atLineStart { output += " " }
            output += lexer.text(of: tokens[index])
            atLineStart = false
            if isLineComment(index) {
                requestBreak(pendingBreak?.indent ?? continuationIndent, blank: pendingBreak?.blank ?? false)
            }
        }

        private func isLineComment(_ index: Int) -> Bool {
            tokens[index].kind == .comment && lexer.units[tokens[index].range.lowerBound] != 0x2F // `--`; not `/*`
        }

        private var continuationIndent: Int {
            statementTokens == 0 ? frame.openIndent : frame.indent + (frame.kind == .list || frame.kind == .paren ? 0 : 1)
        }

        private mutating func flushHeldComments(final: Bool = false) {
            guard !heldComments.isEmpty else { return }
            let indent = pendingBreak?.indent ?? continuationIndent
            let blank = pendingBreak?.blank ?? false
            pendingBreak = nil
            newline(indent: indent, blank: blank)
            for (position, held) in heldComments.enumerated() {
                if position > 0 {
                    if held.sameLine { output += " " } else { newline(indent: indent, blank: false) }
                }
                output += lexer.text(of: tokens[held.index])
                atLineStart = false
            }
            heldComments.removeAll()
            if !final { requestBreak(indent) }
        }

        // MARK: Writing

        private mutating func requestBreak(_ indent: Int, blank: Bool = false) {
            guard !output.isEmpty else { return }
            pendingBreak = (indent, blank || (pendingBreak?.blank ?? false))
        }

        private mutating func newline(indent: Int, blank: Bool) {
            guard !output.isEmpty else { return }
            // No trailing-space trimming: the formatter never writes trailing spaces, and spaces at the end of a
            // `--` comment belong to the comment token.
            let level = min(max(0, indent), SQLFormatter.maxIndentLevel)
            output += blank ? lineBreak + lineBreak : lineBreak
            output += baseIndent + String(repeating: " ", count: level * SQLFormatOptions.clamped(options.indentWidth))
            lineIndent = level
            atLineStart = true
        }

        /// Writes a token after the pending break or the wanted space, but changes the input's whitespace only where
        /// `mayInsertSpace` / `mayRemoveSpace` allow it.
        private mutating func write(_ index: Int, space wanted: Bool) {
            flushHeldComments()
            let sign = isSign(index)
            if !output.isEmpty, index > 0 {
                let previous = index - 1
                let adjacent = tokens[previous].range.upperBound == tokens[index].range.lowerBound
                let mayInsert = !adjacent || SQLFormatter.mayInsertSpace(lexer, tokens[previous], tokens[index])
                if isLineComment(previous) {
                    let pending = pendingBreak ?? (continuationIndent, false)
                    newline(indent: pending.indent, blank: pending.blank)
                } else if let pending = pendingBreak, mayInsert {
                    newline(indent: pending.indent, blank: pending.blank)
                } else if !atLineStart {
                    var space = (wanted || pendingBreak != nil) && mayInsert
                    if !space, !adjacent, !SQLFormatter.mayRemoveSpace(lexer, tokens[previous], tokens[index]) || mustSeparate(previous, index) {
                        space = true
                    }
                    if space { output += " " }
                }
            }
            pendingBreak = nil
            output += text(of: index)
            atLineStart = false
            previousSignificant = lastSignificant
            lastSignificant = index
            lastWasSign = sign
        }

        private func text(of index: Int) -> String {
            let raw = lexer.text(of: tokens[index])
            guard caseChangeable.contains(index) else { return raw }
            switch options.keywordCase {
            case .upper: return raw.uppercased()
            case .lower: return raw.lowercased()
            case .preserve: return raw
            }
        }

        // MARK: Tokens

        private mutating func token(_ index: Int) {
            let kind = tokens[index].kind
            let word = words[index]

            if kind == .punctuation, word == ";" {
                write(index, space: false)
                endStatement()
                return
            }
            if statementTokens == 0 {
                layout = word == "(" || (kind == .keyword && SQLFormatter.layoutStatements.contains(word))
                statementFirst = kind == .keyword || kind == .identifier ? word : ""
            }

            if kind == .punctuation, word == "(" {
                openParen(index)
            } else if kind == .operator, word == "[" || word == "{" {
                openBracket(index)
            } else {
                if SQLFormatter.isCloser(tokens[index], word) {
                    close(index)
                } else if kind == .punctuation, word == "," {
                    comma(index)
                } else if kind == .keyword {
                    keyword(index)
                } else {
                    write(index, space: spaceBefore(index))
                }
                advanceTableName(index)
            }
            statementTokens += 1
            if !(kind == .keyword && SQLFormatter.queryPrefixWords.contains(word)) { onlyPrefixWords = false }
            if kind != .keyword { onlyKeywordsSoFar = false }
            if kind == .keyword, word == "DISTRIBUTED" { sawDistributed = true }
        }

        private mutating func endStatement() {
            frames = [Frame(kind: .statement, indent: 0, openIndent: 0)]
            caseStack.removeAll()
            statementTokens = 0
            statementFirst = ""
            onlyPrefixWords = true
            onlyKeywordsSoFar = true
            queryStarted = false
            definesTable = false
            objectNamed = false
            sawDistributed = false
            listHeadEnd = nil
            joinWordsThrough = nil
            tableNameState = 0
            requestBreak(0, blank: true)
        }

        // MARK: Parentheses, commas

        private mutating func openParen(_ index: Int) {
            let previous = lastSignificant
            let afterTableName = tableNameState == 2
            let inDefinition = frame.kind == .statement && definesTable && !queryStarted
            let isColumnList = afterTableName && tableNameIsCreateTable && inDefinition
            // PROPERTIES recognised as the DDL clause (not a view called `properties`).
            let afterProperties = inDefinition && previous.map { isWord($0, "PROPERTIES") && caseChangeable.contains($0) } == true
            let space = (index > 0 && tokens[index - 1].kind == .comment)
                || spaceBeforeOpenParen(index, previous: previous, afterTableName: afterTableName)
            write(index, space: space)
            tableNameState = 0
            let nextWord = nextSignificant(after: index).map { words[$0] }
            var opened: Frame
            if layout, nextWord == "SELECT" || nextWord == "WITH" {
                opened = Frame(kind: .subquery, indent: lineIndent + 1, openIndent: lineIndent)
                requestBreak(lineIndent + 1)
            } else if layout, isColumnList || afterProperties {
                opened = Frame(kind: .list, indent: lineIndent + 1, openIndent: lineIndent)
                requestBreak(lineIndent + 1)
            } else {
                opened = Frame(kind: .paren, indent: lineIndent + 1, openIndent: lineIndent)
                opened.isWindowSpec = previous.map { isWord($0, "OVER") || (isWord($0, "AS") && frame.clause == .window) } == true
            }
            opened.opener = index
            frames.append(opened)
        }

        /// `[` (an array or a subscript) and `{` (a map) nest like parentheses, so their commas never break a list.
        private mutating func openBracket(_ index: Int) {
            write(index, space: spaceBefore(index))
            tableNameState = 0
            var opened = Frame(kind: .paren, indent: lineIndent + 1, openIndent: lineIndent)
            opened.opener = index
            frames.append(opened)
        }

        /// `)`, `]` or `}`: closes its frame when the pre-pass matched it with the frame's opener; unbalanced input
        /// closes nothing.
        private mutating func close(_ index: Int) {
            guard frames.count > 1, let top = frames.last, top.opener >= 0, matchingBracket[index] == top.opener else {
                write(index, space: false)
                return
            }
            while let open = caseStack.last, open.depth >= frames.count { caseStack.removeLast() } // unterminated CASE
            let closing = frames.removeLast()
            if closing.kind == .subquery || closing.kind == .list {
                requestBreak(closing.openIndent)
            }
            write(index, space: false)
        }

        private mutating func comma(_ index: Int) {
            write(index, space: false)
            // A line comment put this comma on a line of its own: the next item stays beside it (`, b`).
            if index > 0, isLineComment(index - 1) { return }
            switch frame.kind {
            case .list:
                requestBreak(frame.indent)
            case .statement, .subquery:
                if frame.clause == .with {
                    requestBreak(frame.indent)
                } else if frame.listBreak {
                    requestBreak(frame.indent + 1)
                }
            case .paren:
                break
            }
        }

        // MARK: Keywords

        private mutating func keyword(_ index: Int) {
            let word = words[index]
            let next = nextSignificant(after: index)
            let nextWord = next.map { words[$0] }

            // A word next to `.` or after the AS of an alias is a name (`end.a`, `t.end`, `a AS following`): never recased,
            // no layout.
            if word.isEmpty || (lastSignificant.map { isWord($0, "AS") } == true && isAliasPosition) {
                caseChangeable.remove(index)
                write(index, space: spaceBefore(index))
                return
            }
            // The rest of a multi-word join operator (`LEFT SEMI JOIN`): recognised words, written as is.
            if let last = joinWordsThrough, index <= last {
                if index == last { joinWordsThrough = nil }
                recase(index)
                write(index, space: true)
                return
            }
            // CASE words of a statement whose CASE structure is unproven: exactly as written, no layout.
            if frozenCaseWords.contains(index) {
                write(index, space: spaceBefore(index))
                return
            }
            if word == "CASE" {
                beginCase(index)
                return
            }
            if let open = currentCase {
                if word == "END", open.endIndex == index {
                    recase(index)
                    if open.multiline { requestBreak(open.indent) }
                    write(index, space: spaceBefore(index))
                    caseStack.removeLast()
                    return
                }
                if open.multiline, word == "WHEN" || word == "ELSE" {
                    requestBreak(open.indent + 1)
                    write(index, space: true)
                    return
                }
            }
            if layout, frame.allowsClauses, clause(index, word: word, next: next, nextWord: nextWord) {
                finishListHead(index)
                return
            }
            if layout, frame.kind == .statement, definesTable, objectNamed, !queryStarted,
               ddlClause(index, word: word, next: next, nextWord: nextWord) {
                return
            }
            if word == "BETWEEN" { frame.betweenPending = true }
            noteContext(index, word: word, next: next, nextWord: nextWord)
            write(index, space: spaceBefore(index))
            finishListHead(index)
        }

        /// After AS in a select list, FROM or JOIN clause, the next word is an alias.
        private var isAliasPosition: Bool {
            frame.allowsClauses && (frame.clause == .select || frame.clause == .from || frame.clause == .join)
        }

        /// Window specifications and ORDER BY items: frame bounds and NULLS FIRST / LAST are keywords only there.
        private mutating func noteContext(_ index: Int, word: String, next: Int?, nextWord: String?) {
            let previous = lastSignificant
            let previousWord = previous.map { words[$0] }
            let previousRecognised = previous.map { caseChangeable.contains($0) } == true
            if statementFirst == "CREATE", onlyKeywordsSoFar,
               word == "TABLE" || (word == "VIEW" && previousWord == "MATERIALIZED") {
                definesTable = true
            }
            switch word {
            case "ORDER":
                if nextWord == "BY", !frame.allowsClauses { frame.orderBySeen = true }
            case "ROWS", "RANGE":
                if frame.isWindowSpec, let next, ["BETWEEN", "UNBOUNDED", "CURRENT"].contains(words[next]) || tokens[next].kind == .number {
                    frame.windowFrame = true
                }
            case "UNBOUNDED":
                if frame.windowFrame, nextWord == "PRECEDING" || nextWord == "FOLLOWING" { recase(index) }
            case "PRECEDING", "FOLLOWING":
                if frame.windowFrame, (previousWord == "UNBOUNDED" && previousRecognised) || previous.map({ tokens[$0].kind == .number }) == true {
                    recase(index)
                }
            case "CURRENT":
                if frame.windowFrame, nextWord == "ROW" { recase(index) }
            case "ROW":
                if frame.windowFrame, previousWord == "CURRENT", previousRecognised { recase(index) }
            case "NULLS":
                // After an ORDER BY item (not as the item itself: `ORDER BY nulls`).
                let inOrderBy = (frame.allowsClauses && frame.clause == .orderBy) || frame.orderBySeen
                let afterItem = previous.map { !(isWord($0, "BY") || isPunctuation($0, ",")) } == true
                if inOrderBy, afterItem, nextWord == "FIRST" || nextWord == "LAST" { recase(index) }
            case "FIRST", "LAST":
                if previousWord == "NULLS", previousRecognised { recase(index) }
            default:
                break
            }
        }

        /// Clause layout inside a statement or subquery. Returns `true` when the token was written.
        private mutating func clause(_ index: Int, word: String, next: Int?, nextWord: String?) -> Bool {
            let isFirstQueryWord = onlyPrefixWords
            let breakIndent = frame.indent

            // AND / OR conditions; the AND of BETWEEN stays.
            if word == "AND" || word == "OR" {
                if word == "AND", frame.betweenPending {
                    frame.betweenPending = false
                    return false
                }
                guard currentCase == nil, frame.clause == .whereLike || frame.clause == .on else { return false }
                requestBreak(breakIndent + 1)
                write(index, space: true)
                return true
            }
            // Joins: [LEFT|RIGHT|FULL] [OUTER|SEMI|ANTI] JOIN, INNER JOIN, CROSS JOIN.
            if SQLFormatter.joinStarts.contains(word), let end = joinEnd(from: index) {
                recase(index)
                requestBreak(breakIndent)
                write(index, space: true)
                if end > index { joinWordsThrough = end }
                setClause(.join)
                return true
            }
            if word == "ON", frame.clause == .join {
                requestBreak(breakIndent + 1)
                write(index, space: true)
                setClause(.on)
                return true
            }
            if word == "OFFSET", frame.clause == .limit, let next, tokens[next].kind == .number {
                recase(index)
                requestBreak(breakIndent)
                write(index, space: true)
                return true
            }
            if word == "WITH" {
                // A WITH that starts the query (statement, subquery, CREATE … AS); others (`WITH ROLLUP`, …) stay inline.
                let afterParen = lastSignificant.map { isPunctuation($0, "(") } == true
                let afterCreateAs = frame.kind == .statement && statementFirst == "CREATE" && lastSignificant.map { isWord($0, "AS") } == true
                guard isFirstQueryWord || afterParen || afterCreateAs else { return false }
                if afterCreateAs { requestBreak(breakIndent) }
                write(index, space: true)
                setClause(.with)
                if frame.kind == .statement { queryStarted = true }
                return true
            }

            guard SQLFormatter.clauseWords.contains(word) else { return false }
            switch word {
            case "SET":
                guard statementFirst == "UPDATE" || statementTokens == 0 else { return false }
            case "VALUES":
                guard statementFirst == "INSERT" || statementFirst == "UPSERT" || statementTokens == 0 || frame.kind == .subquery
                else { return false }
            case "GROUP", "ORDER":
                guard nextWord == "BY" else { return false }
            case "FROM":
                // `IS [NOT] DISTINCT FROM b` is an operator, not a clause.
                if lastSignificant.map({ isWord($0, "DISTINCT") }) == true { return false }
                if lastSignificant.map({ isWord($0, "DELETE") }) == true {
                    write(index, space: true)
                    setClause(.from)
                    return true
                }
            case "WINDOW":
                // `WINDOW w AS (`; otherwise a name.
                guard let name = next, let asWord = nextSignificant(after: name), let paren = nextSignificant(after: asWord),
                      tokens[name].kind == .identifier || tokens[name].kind == .quotedIdentifier,
                      isWord(asWord, "AS"), isPunctuation(paren, "("), frame.clause != .none, frame.clause != .select
                else { return false }
                recase(index)
            case "QUALIFY":
                // After FROM / WHERE / GROUP BY / HAVING, following an operand; never an alias in a select list.
                guard frame.clause != .none, frame.clause != .select, let previous = lastSignificant,
                      [.identifier, .quotedIdentifier, .number, .string].contains(tokens[previous].kind) || isPunctuation(previous, ")")
                else { return false }
            default:
                if SQLFormatter.setOperators.contains(word) {
                    // A set operator follows a query and precedes a proven one; otherwise it is a name: `select a minus
                    // from t` (an alias), `from (…) minus (x)` (an alias with a column list).
                    guard frame.clause != .none, startsQuery(next) else { return false }
                    recase(index)
                }
            }
            if !(isFirstQueryWord && (word == "SELECT" || word == "VALUES" || word == "SET")) {
                requestBreak(breakIndent)
            }
            write(index, space: true)
            if frame.kind == .statement, word == "SELECT" || word == "VALUES" { queryStarted = true }
            switch word {
            case "SELECT":
                var head = index
                if let next, isWord(next, "DISTINCT") || isWord(next, "ALL") { head = next }
                startList(.select, headEnd: head)
            case "GROUP": startList(.groupBy, headEnd: next ?? index)
            case "ORDER": startList(.orderBy, headEnd: next ?? index)
            case "SET": startList(.set, headEnd: index)
            case "VALUES": startList(.values, headEnd: index)
            case "FROM": setClause(.from)
            case "WHERE", "HAVING", "QUALIFY": setClause(.whereLike)
            case "LIMIT": setClause(.limit)
            case "WINDOW": setClause(.window)
            default: setClause(.other)
            }
            return true
        }

        /// StarRocks CREATE TABLE clauses at statement level, before any AS SELECT. Returns `true` when written.
        private mutating func ddlClause(_ index: Int, word: String, next: Int?, nextWord: String?) -> Bool {
            // `CREATE VIEW properties (a) AS …`: a word where the table name goes is the name.
            guard tableNameState != 1 else { return false }
            var starts = false
            switch word {
            case "DUPLICATE", "AGGREGATE", "UNIQUE", "PRIMARY":
                starts = nextWord == "KEY"
            case "DISTRIBUTED", "PARTITION":
                starts = nextWord == "BY"
            case "PROPERTIES":
                starts = nextWord == "("
            case "ENGINE":
                starts = nextWord == "="
            case "BUCKETS":
                if frame.clause == .ddl, sawDistributed, let next, tokens[next].kind == .number { recase(index) }
            case "HASH", "RANDOM":
                if let last = lastSignificant, let before = previousSignificant, isWord(last, "BY"), isWord(before, "DISTRIBUTED") {
                    recase(index)
                }
            default:
                break
            }
            guard starts else { return false }
            recase(index)
            if let next, words[next] == "KEY" || words[next] == "BY" { recase(next) }
            requestBreak(frame.indent)
            write(index, space: true)
            setClause(.ddl)
            return true
        }

        /// Whether a query starts at `index`: SELECT, WITH, VALUES or TABLE, after an optional ALL / DISTINCT and any
        /// number of opening parentheses.
        private func startsQuery(_ index: Int?) -> Bool {
            var cursor = index
            if let start = cursor, isWord(start, "ALL") || isWord(start, "DISTINCT") { cursor = nextSignificant(after: start) }
            while let current = cursor {
                if isPunctuation(current, "(") {
                    cursor = nextSignificant(after: current)
                    continue
                }
                return tokens[current].kind == .keyword && SQLFormatter.queryStarts.contains(words[current])
            }
            return false
        }

        /// Index of the `JOIN` that completes a join operator starting at `index`, or `nil`.
        private func joinEnd(from index: Int) -> Int? {
            if words[index] == "JOIN" { return index }
            var cursor = index
            while let next = nextSignificant(after: cursor) {
                guard tokens[next].kind == .keyword else { return nil }
                switch words[next] {
                case "JOIN": return next
                case "OUTER", "SEMI", "ANTI": cursor = next
                default: return nil
                }
            }
            return nil
        }

        private mutating func setClause(_ clause: Frame.Clause) {
            frame.clause = clause
            frame.listBreak = false
            frame.betweenPending = false
            listHeadEnd = nil
        }

        private mutating func startList(_ clause: Frame.Clause, headEnd: Int) {
            setClause(clause)
            frame.listBreak = topLevelCommas(after: headEnd) > 0
            listHeadEnd = headEnd
        }

        /// After the last word of a list clause head (SELECT [DISTINCT], GROUP BY, …): break before the first item.
        private mutating func finishListHead(_ index: Int) {
            guard let head = listHeadEnd, head == index, frame.allowsClauses else { return }
            listHeadEnd = nil
            if frame.listBreak { requestBreak(frame.indent + 1) }
        }

        /// Commas at nesting level zero until the clause ends. Parenthesised groups are skipped through their
        /// precomputed match, so nested subqueries are never rescanned.
        private func topLevelCommas(after index: Int) -> Int {
            var commas = 0
            var cursor = index + 1
            while cursor < tokens.count {
                let token = tokens[cursor]
                let word = words[cursor]
                if SQLFormatter.closer(of: token, word) != nil {
                    let close = matchingBracket[cursor]
                    guard close > cursor else { return commas }
                    cursor = close + 1
                    continue
                }
                if SQLFormatter.isCloser(token, word) { return commas }
                if token.kind == .punctuation {
                    if word == ";" { return commas }
                    if word == "," { commas += 1 }
                } else if token.kind == .keyword, SQLFormatter.clauseEndWords.contains(word) {
                    return commas
                }
                cursor += 1
            }
            return commas
        }

        // MARK: CASE

        private mutating func beginCase(_ index: Int) {
            let endIndex = caseEnds[index]
            let multiline = layout && frame.kind != .paren && endIndex != nil && caseBranches[index, default: 0] >= 2
            write(index, space: spaceBefore(index))
            caseStack.append(OpenCase(endIndex: endIndex, multiline: multiline, indent: lineIndent, depth: frames.count))
            finishListHead(index)
        }

        // MARK: Spacing

        /// Tracks whether the tokens after INTO / TABLE / VIEW are a (qualified) table name, so `t (a, b)` keeps its space.
        private mutating func advanceTableName(_ index: Int) {
            let kind = tokens[index].kind
            let word = words[index]
            // INTO / TABLE / VIEW, and the ON of CREATE INDEX … ON t (c).
            let createIndexOn = kind == .keyword && word == "ON" && statementFirst == "CREATE" && !queryStarted
            // VIEW and OVERWRITE are also column names: only in a statement head (`CREATE VIEW v`, `INSERT OVERWRITE t`).
            let headWord = kind == .keyword && onlyKeywordsSoFar
                && ((word == "VIEW" && ["CREATE", "DROP", "ALTER"].contains(statementFirst)) || (word == "OVERWRITE" && statementFirst == "INSERT"))
            if kind == .keyword, word == "INTO" || word == "TABLE" || createIndexOn || headWord {
                tableNameState = 1
                tableNameIsCreateTable = word == "TABLE" && statementFirst == "CREATE"
                return
            }
            switch tableNameState {
            case 1:
                if kind == .keyword, word == "IF" || word == "NOT" || word == "EXISTS" { return }
                let isName = kind == .identifier || kind == .quotedIdentifier
                    || (kind == .keyword && !SQLFormatter.caseSafeKeywords.contains(word))
                tableNameState = isName ? 2 : 0
                if isName { objectNamed = true }
            case 2:
                tableNameState = isPunctuation(index, ".") ? 1 : 0
            default:
                break
            }
        }

        private func spaceBeforeOpenParen(_ index: Int, previous: Int?, afterTableName: Bool) -> Bool {
            guard let previous else { return false }
            if afterTableName { return true }
            switch tokens[previous].kind {
            case .identifier, .quotedIdentifier: return false
            case .keyword:
                let word = words[previous]
                let touching = tokens[previous].range.upperBound == tokens[index].range.lowerBound
                // A name (`properties(int)`), or a set operator that turned out to be one (`) minus (x)`): as written.
                if word.isEmpty || (SQLFormatter.setOperators.contains(word) && !caseChangeable.contains(previous)) { return !touching }
                if SQLFormatter.callLikeKeywords.contains(word) { return false }
                return !touching || SQLFormatter.spacedBeforeParen.contains(words[previous])
            case .punctuation: return words[previous] == "," || words[previous] == ")"
            case .operator: return words[previous] != "["
            default: return true
            }
        }

        /// The space the layout wants before a token; `write` reconciles it with the input's whitespace.
        private func spaceBefore(_ index: Int) -> Bool {
            guard index > 0 else { return false }
            let previous = index - 1
            if tokens[previous].kind == .comment { return true }
            if lastWasSign { return false }
            let previousText = words[previous]
            // Nothing after an opening bracket or a dot.
            if tokens[previous].kind == .punctuation, previousText == "(" || previousText == "." { return false }
            if tokens[previous].kind == .operator, previousText == "[" || previousText == "{" { return false }
            let text = words[index]
            switch tokens[index].kind {
            case .punctuation where text == ")" || text == "," || text == ";" || text == ".":
                return false
            case .operator where text == "]" || text == "}":
                return false
            case .operator where text == "[":
                return !takesSubscript(previous)
            default:
                return true
            }
        }

        /// Whether a `[` right after this token is its subscript (`arr[1]`, `f(x)[1]`) rather than an array (`SELECT [1]`).
        private func takesSubscript(_ index: Int) -> Bool {
            switch tokens[index].kind {
            case .identifier, .quotedIdentifier, .variable: true
            case .keyword: words[index].isEmpty // a name
            case .punctuation: words[index] == ")"
            case .operator: words[index] == "]" || words[index] == "}"
            default: false
            }
        }

        /// A `-` / `+` sign (not a binary operator), judged from the token before it.
        private func isSign(_ index: Int) -> Bool {
            guard tokens[index].kind == .operator, words[index] == "-" || words[index] == "+" else { return false }
            guard let previous = lastSignificant else { return true }
            let word = words[previous]
            switch tokens[previous].kind {
            case .operator: return word != "]"
            case .punctuation: return word == "(" || word == ","
            case .keyword: return SQLKeywords.reserved.contains(word) && !SQLFormatter.operandKeywords.contains(word)
            default: return false
            }
        }

        /// Whether writing `index` directly after `previous` would lex differently.
        private func mustSeparate(_ previous: Int, _ index: Int) -> Bool {
            let prev = tokens[previous]
            let current = tokens[index]
            let wordLike: Set<SQLToken.Kind> = [.identifier, .keyword, .number, .variable]
            if wordLike.contains(prev.kind), wordLike.contains(current.kind) { return true }
            if prev.kind == current.kind, prev.kind == .string || prev.kind == .quotedIdentifier { return true }
            if prev.kind == .number, words[index] == "." { return true }
            if words[previous] == ".", current.kind == .number { return true }
            if prev.kind == .variable, words[index] == "." { return true }
            if prev.kind == .operator, current.kind == .operator || current.kind == .number || current.kind == .comment {
                let last = lexer.units[prev.range.upperBound - 1]
                let first = lexer.units[current.range.lowerBound]
                if current.kind == .operator, SQLLexer.isOperatorContinuation(first) { return true }
                if last == 0x2D, first == 0x2D { return true } // `- -` would start a comment
                if last == 0x2F, first == 0x2A { return true } // `/ *` would start a comment
            }
            return false
        }
    }
}
