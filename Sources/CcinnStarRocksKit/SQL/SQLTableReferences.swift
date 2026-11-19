import Foundation

/// A table, derived table or CTE a statement reads, as written: `[catalog.][database.]table [[AS] alias]`.
public struct SQLTableReference: Sendable, Equatable {
    public var alias: String?
    public var catalog: String?
    public var database: String?
    public var table: String
    /// Output columns of a derived table or CTE; `nil` for a base table.
    public var derivedColumns: [String]?

    public init(alias: String?, catalog: String? = nil, database: String?, table: String, derivedColumns: [String]?) {
        self.alias = alias
        self.catalog = catalog
        self.database = database
        self.table = table
        self.derivedColumns = derivedColumns
    }
}

/// Table references of a statement, shared by completion (one flat list) and JOIN mining (one list per SELECT block, so
/// an alias resolves in the innermost query that defines it). Works on the tokens of one statement, comments removed.
public enum SQLTableReferences {
    /// One SELECT block: the statement itself, a subquery, a derived table or a CTE body.
    public struct Scope: Sendable, Equatable {
        /// Token indices of the block, without its parentheses.
        public let range: Range<Int>
        /// Index of the enclosing scope in the result; `nil` for the statement.
        public let parent: Int?
        /// Tables read directly by this block (not by its subqueries).
        public let references: [SQLTableReference]
    }

    static let aliasStopWords: Set<String> = SQLKeywords.reserved.union([
        "LATERAL", "WINDOW", "SEMI", "ANTI", "OUTER", "INNER", "PARTITION", "TABLET", "LIMIT", "WHERE", "ON", "USING",
    ])

    /// Every table, derived table and CTE referenced anywhere in the statement, with aliases.
    public static func references(tokens: [SQLToken], lexer: SQLLexer) -> [SQLTableReference] {
        let words = keywords(tokens, lexer)
        return collect(tokens: tokens, words: words, range: tokens.indices, lexer: lexer, descend: true,
                       ctes: cteColumns(tokens: tokens, words: words, lexer: lexer))
    }

    /// The statement's SELECT blocks in document order, each enclosing block before the blocks inside it.
    public static func scopes(tokens: [SQLToken], lexer: SQLLexer) -> [Scope] {
        let words = keywords(tokens, lexer)
        let ctes = cteColumns(tokens: tokens, words: words, lexer: lexer)
        var scopes: [Scope] = []
        func build(_ range: Range<Int>, parent: Int?) {
            let references = collect(tokens: tokens, words: words, range: range, lexer: lexer, descend: false, ctes: ctes)
            let current = scopes.count
            scopes.append(Scope(range: range, parent: parent, references: references))
            var index = range.lowerBound
            while index < range.upperBound {
                let opensSubquery = isPunctuation(tokens[index], "(", lexer) && index + 1 < range.upperBound
                    && (words[index + 1] == "SELECT" || words[index + 1] == "WITH")
                if opensSubquery {
                    let close = min(matchingParen(tokens: tokens, open: index, lexer: lexer), range.upperBound)
                    build((index + 1)..<close, parent: current)
                    index = close + 1
                } else {
                    index += 1
                }
            }
        }
        build(tokens.indices, parent: nil)
        return scopes
    }

    // MARK: Parsing

    private static func keywords(_ tokens: [SQLToken], _ lexer: SQLLexer) -> [String] {
        tokens.map { (token: SQLToken) -> String in token.kind == .keyword ? lexer.text(of: token).uppercased() : "" }
    }

    /// `WITH name AS ( … ), name AS ( … )` at the start of the statement → output columns per CTE (lower-cased names).
    private static func cteColumns(tokens: [SQLToken], words: [String], lexer: SQLLexer) -> [String: [String]] {
        var ctes: [String: [String]] = [:]
        guard words.first == "WITH" else { return ctes }
        var index = 1
        if index < words.count, words[index] == "RECURSIVE" { index += 1 }
        while index + 2 < tokens.count, isName(tokens[index]), words[index + 1] == "AS", lexer.text(of: tokens[index + 2]) == "(" {
            let name = lexer.identifierValue(of: tokens[index])
            let close = matchingParen(tokens: tokens, open: index + 2, lexer: lexer)
            ctes[name.lowercased()] = derivedColumns(tokens: Array(tokens[(index + 3)..<close]), lexer: lexer)
            index = close + 1
            if index < tokens.count, lexer.text(of: tokens[index]) == "," { index += 1 } else { break }
        }
        return ctes
    }

    /// References after FROM / JOIN / UPDATE / INTO / TABLE in `range`. Without `descend`, parenthesised groups other
    /// than derived tables are skipped: their tables belong to inner scopes.
    private static func collect(tokens: [SQLToken], words: [String], range: Range<Int>, lexer: SQLLexer, descend: Bool,
                                ctes: [String: [String]]) -> [SQLTableReference] {
        var result: [SQLTableReference] = []
        var index = range.lowerBound
        let end = range.upperBound
        while index < end {
            let word = words[index]
            if !descend, isPunctuation(tokens[index], "(", lexer) {
                index = matchingParen(tokens: tokens, open: index, lexer: lexer) + 1
                continue
            }
            let startsReference = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"].contains(word)
            index += 1
            guard startsReference else { continue }
            var parsingList = true
            while parsingList, index < end {
                parsingList = false
                if isPunctuation(tokens[index], "(", lexer) {
                    // Derived table: ( SELECT … ) [AS] alias
                    let close = matchingParen(tokens: tokens, open: index, lexer: lexer)
                    let columns = derivedColumns(tokens: Array(tokens[(index + 1)..<min(close, tokens.count)]), lexer: lexer)
                    index = close + 1
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, end: end, lexer: lexer) {
                        result.append(SQLTableReference(alias: alias, database: nil, table: alias, derivedColumns: columns))
                        index = next
                    }
                } else if isName(tokens[index]), tokens[index].kind != .keyword || !aliasStopWords.contains(words[index]) {
                    var parts = [lexer.identifierValue(of: tokens[index])]
                    index += 1
                    while index + 1 < end, isDot(tokens[index], lexer), isName(tokens[index + 1]) {
                        parts.append(lexer.identifierValue(of: tokens[index + 1]))
                        index += 2
                    }
                    var reference = SQLTableReference(alias: nil, catalog: parts.count >= 3 ? parts[parts.count - 3] : nil,
                                                      database: parts.count >= 2 ? parts[parts.count - 2] : nil,
                                                      table: parts[parts.count - 1], derivedColumns: nil)
                    if reference.database == nil, let columns = ctes[reference.table.lowercased()] { reference.derivedColumns = columns }
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, end: end, lexer: lexer) {
                        reference.alias = alias
                        index = next
                    }
                    result.append(reference)
                }
                if index < end, lexer.text(of: tokens[index]) == ",", word == "FROM" {
                    index += 1
                    parsingList = true
                }
            }
        }
        return result
    }

    static func parseAlias(tokens: [SQLToken], words: [String], at index: Int, end: Int, lexer: SQLLexer) -> (String, Int)? {
        var index = index
        if index < end, words[index] == "AS" { index += 1 }
        guard index < end, isName(tokens[index]) else { return nil }
        if tokens[index].kind == .keyword, aliasStopWords.contains(words[index]) { return nil }
        return (lexer.identifierValue(of: tokens[index]), index + 1)
    }

    /// Index of the `)` closing the `(` at `open`, or `tokens.count` when it is never closed.
    public static func matchingParen(tokens: [SQLToken], open: Int, lexer: SQLLexer) -> Int {
        var depth = 0
        var index = open
        while index < tokens.count {
            if tokens[index].kind == .punctuation {
                let text = lexer.text(of: tokens[index])
                if text == "(" { depth += 1 }
                if text == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index += 1
        }
        return tokens.count
    }

    /// Output column names of `SELECT a, b AS c, t.d, count(*) AS n FROM …`.
    static func derivedColumns(tokens: [SQLToken], lexer: SQLLexer) -> [String] {
        guard let selectIndex = tokens.firstIndex(where: { lexer.text(of: $0).uppercased() == "SELECT" }) else { return [] }
        var columns: [String] = []
        var depth = 0
        var item: [SQLToken] = []
        // The output name is the item's last identifier: `b AS c` → c, `t.d` → d, `count(*) n` → n.
        func flushItem() {
            defer { item.removeAll() }
            guard let last = item.last, isName(last) else { return }
            columns.append(lexer.identifierValue(of: last))
        }
        for token in tokens[(selectIndex + 1)...] {
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" { depth -= 1 }
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "FROM" { break }
            if depth == 0, text == "," {
                flushItem()
                continue
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "DISTINCT", item.isEmpty { continue }
            item.append(token)
        }
        flushItem()
        return columns
    }

    static func isName(_ token: SQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
    }

    static func isDot(_ token: SQLToken, _ lexer: SQLLexer) -> Bool {
        token.kind == .punctuation && lexer.units[token.range.lowerBound] == 0x2E
    }

    static func isPunctuation(_ token: SQLToken, _ text: String, _ lexer: SQLLexer) -> Bool {
        guard token.kind == .punctuation else { return false }
        return lexer.text(of: token) == text
    }
}
