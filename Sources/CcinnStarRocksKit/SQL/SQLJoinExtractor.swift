import Foundation

/// An equi-join of two tables as a statement writes it: `left.leftColumns[i] = right.rightColumns[i]`.
public struct JoinPair: Sendable, Equatable, Hashable {
    /// `database` as written: nil when unqualified.
    public var left: TableReference
    public var leftColumns: [String]
    public var right: TableReference
    public var rightColumns: [String]

    public init(left: TableReference, leftColumns: [String], right: TableReference, rightColumns: [String]) {
        self.left = left
        self.leftColumns = leftColumns
        self.right = right
        self.rightColumns = rightColumns
    }
}

/// Equi-joins in SQL text, for JOIN mining (design §2.5). Lexical, never fails, linear in the text for real queries.
///
/// - Only a statement's query is read: the whole of SELECT / WITH, and the query of INSERT … SELECT or CREATE VIEW …
///   AS SELECT (from its first top-level SELECT or WITH). Other statements give nothing.
/// - Conditions: each `ON` up to the next clause at its depth, and `WHERE` (implicit joins, correlated conditions),
///   split on `AND` at depth 0 (a `BETWEEN … AND` stays whole, wrapping parentheses are removed). A conjunct counts
///   when it is exactly `column = column` (or `<=>`), each side possibly parenthesised; anything else (literals,
///   functions, arithmetic, `OR`, `NOT`, other operators) is skipped.
/// - Conditions between the same two table references in one clause make one composite pair.
/// - `USING (a, b)` counts only right after a single table: `FROM a JOIN b USING (k)`.
/// - Qualifiers resolve in the innermost SELECT block first, then outwards; an unqualified column needs exactly one
///   table in the first block that has it, by `columnsOf` (a table whose columns are unknown makes it ambiguous).
/// - Sides on a CTE, a derived table or a catalog other than `default_catalog` are skipped. Join hints (`[broadcast]`)
///   are stepped over.
public enum SQLJoinExtractor {
    /// Nesting deeper than this is no real query; such a statement is skipped rather than walked.
    public static let maxNestingDepth = 128

    /// Equi-joins of every statement in `sql`, in order, each distinct pair once per statement. `columnsOf` answers which
    /// columns a table (as written) has, or nil when unknown.
    public static func joins(in sql: String, columnsOf: (TableReference) -> [String]?) -> [JoinPair] {
        withoutActuallyEscaping(columnsOf) { (lookup: @escaping (TableReference) -> [String]?) -> [JoinPair] in
            let lexer = SQLLexer(sql)
            var catalog = ColumnCatalog(lookup: lookup)
            var result: [JoinPair] = []
            var statement: [SQLToken] = []
            for token in lexer.tokens() where token.kind != .comment {
                if token.kind == .punctuation, lexer.units[token.range.lowerBound] == 0x3B {
                    result += joins(statement: statement, lexer: lexer, catalog: &catalog)
                    statement.removeAll(keepingCapacity: true)
                } else {
                    statement.append(token)
                }
            }
            result += joins(statement: statement, lexer: lexer, catalog: &catalog)
            return result
        }
    }

    private static func joins(statement: [SQLToken], lexer: SQLLexer, catalog: inout ColumnCatalog) -> [JoinPair] {
        let tokens = withoutJoinHints(statement, lexer)
        let words = tokens.map { (token: SQLToken) -> String in word(of: token, lexer) }
        guard nestingDepth(words) <= maxNestingDepth, let start = queryStart(words) else { return [] }
        let query = StatementQuery(tokens: Array(tokens[start...]), words: Array(words[start...]), lexer: lexer)
        return query.joins(catalog: &catalog)
    }

    // MARK: Statement level

    /// Upper-cased for keywords and plain names, the text for punctuation and operators, empty for literals and
    /// back-quoted names (which are never clause words).
    static func word(of token: SQLToken, _ lexer: SQLLexer) -> String {
        switch token.kind {
        case .keyword, .identifier: lexer.text(of: token).uppercased()
        case .punctuation, .operator: lexer.text(of: token)
        default: ""
        }
    }

    /// Drops `[hint]` right after JOIN, so the joined table is read.
    private static func withoutJoinHints(_ tokens: [SQLToken], _ lexer: SQLLexer) -> [SQLToken] {
        var result: [SQLToken] = []
        result.reserveCapacity(tokens.count)
        var index = 0
        while index < tokens.count {
            let afterJoin = result.last.map { word(of: $0, lexer) == "JOIN" } ?? false
            if afterJoin, index + 2 < tokens.count, word(of: tokens[index], lexer) == "[", word(of: tokens[index + 2], lexer) == "]" {
                index += 3
                continue
            }
            result.append(tokens[index])
            index += 1
        }
        return result
    }

    private static func nestingDepth(_ words: [String]) -> Int {
        var depth = 0
        var deepest = 0
        for word in words {
            if word == "(" {
                depth += 1
                deepest = max(deepest, depth)
            } else if word == ")" {
                depth = max(0, depth - 1)
            }
        }
        return deepest
    }

    /// The first top-level SELECT or WITH, or a top-level `(` opening one.
    private static func queryStart(_ words: [String]) -> Int? {
        var depth = 0
        for (index, word) in words.enumerated() {
            if depth == 0, word == "SELECT" || word == "WITH" { return index }
            if word == "(" {
                let next = index + 1 < words.count ? words[index + 1] : ""
                if depth == 0, next == "SELECT" || next == "WITH" { return index }
                depth += 1
            } else if word == ")" {
                depth = max(0, depth - 1)
            }
        }
        return nil
    }
}

/// Columns per table from the caller, asked once per table.
private struct ColumnCatalog {
    let lookup: (TableReference) -> [String]?
    private var cache: [TableReference: Set<String>?] = [:]

    init(lookup: @escaping (TableReference) -> [String]?) {
        self.lookup = lookup
    }

    /// Lower-cased names, or nil when unknown.
    mutating func columns(of table: TableReference) -> Set<String>? {
        if let cached = cache[table] { return cached }
        let found = lookup(table).map { (names: [String]) -> Set<String> in Set(names.map { $0.lowercased() }) }
        cache[table] = .some(found)
        return found
    }
}

/// The query of one statement, split into SELECT blocks (`SQLTableReferences.Scope`), and the joins it writes.
private struct StatementQuery {
    let tokens: [SQLToken]
    let words: [String]
    let lexer: SQLLexer
    let scopes: [SQLTableReferences.Scope]
    /// Per scope, its own token indices: inside it but outside the subqueries it contains.
    let ownTokens: [[Int]]
    /// CTE names declared anywhere in the statement (lower-cased), nested WITH included.
    let cteNames: Set<String>

    /// Words that end an ON or WHERE expression at its depth.
    static let clauseBoundaries: Set<String> = [
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "STRAIGHT_JOIN", "SEMI", "ANTI", "OUTER", "WHERE",
        "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT", "MINUS", "WINDOW", "QUALIFY", "ON",
        "USING", "LATERAL", "FROM", "SELECT", "INTO", ",",
    ]
    static let nameKinds: [SQLToken.Kind] = [.identifier, .keyword, .quotedIdentifier]
    /// Words that close a FROM list.
    static let fromListEnds: Set<String> = [
        "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "UNION", "EXCEPT", "INTERSECT", "MINUS", "WINDOW", "QUALIFY", "ON", "USING",
    ]

    init(tokens: [SQLToken], words: [String], lexer: SQLLexer) {
        let scopes = SQLTableReferences.scopes(tokens: tokens, lexer: lexer)
        self.tokens = tokens
        self.words = words
        self.lexer = lexer
        self.scopes = scopes
        ownTokens = Self.ownTokens(count: tokens.count, scopes: scopes)
        cteNames = Self.cteNames(tokens: tokens, words: words, lexer: lexer)
    }

    struct Instance: Hashable {
        let scope: Int
        let reference: Int
    }

    private enum Clause {
        /// An ON or WHERE expression (token indices).
        case condition([Int])
        /// USING columns, and how many tables the FROM list had then (the joined one included).
        case using([String], tablesSoFar: Int)
    }

    private struct ColumnPair {
        let left: Instance
        let leftColumn: String
        let right: Instance
        let rightColumn: String
    }

    func joins(catalog: inout ColumnCatalog) -> [JoinPair] {
        var result: [JoinPair] = []
        var seen: Set<JoinPair> = []
        for scope in scopes.indices {
            let parsed = clauses(of: scope)
            for clause in parsed.clauses {
                var pairs: [JoinPair] = []
                switch clause {
                case let .condition(expression):
                    pairs = conditionJoins(expression, scope: scope, catalog: &catalog)
                case let .using(columns, tablesSoFar):
                    // Exactly one table before the joined one, and the table count agrees with the parsed references.
                    if tablesSoFar == 2, parsed.tableCount == scopes[scope].references.count, let pair = usingJoin(columns, scope: scope) {
                        pairs = [pair]
                    }
                }
                for pair in pairs where seen.insert(pair).inserted { result.append(pair) }
            }
        }
        return result
    }

    // MARK: Clauses

    /// ON, WHERE and USING clauses of one scope in order, and the number of tables its FROM clause names.
    private func clauses(of scope: Int) -> (clauses: [Clause], tableCount: Int) {
        let own = ownTokens[scope]
        var clauses: [Clause] = []
        var depth = 0
        var tableCount = 0
        var inFromList = false
        var position = 0
        while position < own.count {
            let word = words[own[position]]
            if word == "(" {
                depth += 1
            } else if word == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                if word == "FROM" {
                    tableCount += 1
                    inFromList = true
                } else if word == "JOIN" {
                    tableCount += 1
                    inFromList = false
                } else if word == ",", inFromList {
                    tableCount += 1
                } else if Self.fromListEnds.contains(word) {
                    inFromList = false
                }
            }
            if word == "ON" || word == "WHERE" {
                let end = expressionEnd(own, from: position + 1)
                clauses.append(.condition(Array(own[(position + 1)..<end])))
                position = end
                continue
            }
            if word == "USING", let (columns, next) = usingColumns(own, from: position + 1) {
                clauses.append(.using(columns, tablesSoFar: tableCount))
                position = next
                continue
            }
            position += 1
        }
        return (clauses, tableCount)
    }

    /// Position after the expression starting at `start`: the next clause word at its depth, or a `)` closing it.
    private func expressionEnd(_ own: [Int], from start: Int) -> Int {
        var depth = 0
        var position = start
        while position < own.count {
            let index = own[position]
            let word = words[index]
            if word == "(" {
                depth += 1
            } else if word == ")" {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, isClauseBoundary(at: index) {
                break
            }
            position += 1
        }
        return position
    }

    private func isClauseBoundary(at index: Int) -> Bool {
        let word = words[index]
        guard Self.clauseBoundaries.contains(word) else { return false }
        // `t.left` is a column; `left(x, 2)` and `right(x, 2)` are functions.
        if index > 0, words[index - 1] == "." { return false }
        let next = index + 1 < words.count ? words[index + 1] : ""
        if word == "LEFT" || word == "RIGHT", next == "(" { return false }
        return true
    }

    /// `( name [, name]… )` → names and the position after `)`.
    private func usingColumns(_ own: [Int], from start: Int) -> ([String], Int)? {
        guard start < own.count, words[own[start]] == "(" else { return nil }
        var columns: [String] = []
        var position = start + 1
        while position < own.count {
            guard let name = name(at: own[position]) else { return nil }
            columns.append(name)
            position += 1
            guard position < own.count else { return nil }
            let separator = words[own[position]]
            position += 1
            if separator == ")" { return (columns, position) }
            guard separator == "," else { return nil }
        }
        return nil
    }

    private func usingJoin(_ columns: [String], scope: Int) -> JoinPair? {
        let references = scopes[scope].references
        guard references.count >= 2, isBaseTable(references[0]), isBaseTable(references[1]) else { return nil }
        return JoinPair(left: table(references[0]), leftColumns: columns, right: table(references[1]), rightColumns: columns)
    }

    // MARK: Conditions

    private func conditionJoins(_ expression: [Int], scope: Int, catalog: inout ColumnCatalog) -> [JoinPair] {
        var pairs: [ColumnPair] = []
        for conjunct in conjuncts(expression) {
            guard let (leftSide, rightSide) = equality(conjunct) else { continue }
            guard let leftPath = columnPath(leftSide), let rightPath = columnPath(rightSide) else { continue }
            guard let left = resolve(leftPath, in: scope, catalog: &catalog) else { continue }
            guard let right = resolve(rightPath, in: scope, catalog: &catalog), left.instance != right.instance else { continue }
            pairs.append(ColumnPair(left: left.instance, leftColumn: left.column, right: right.instance, rightColumn: right.column))
        }
        return merged(pairs)
    }

    /// The AND-conjuncts of an expression, in order, without wrapping parentheses.
    private func conjuncts(_ expression: [Int]) -> [ArraySlice<Int>] {
        var result: [ArraySlice<Int>] = []
        var pending: [ArraySlice<Int>] = [expression[...]]
        while let part = pending.popLast() {
            let inner = withoutWrappingParentheses(part)
            let pieces = splitOnAnd(inner)
            if pieces.count == 1 {
                result.append(inner)
            } else {
                pending.append(contentsOf: pieces.reversed())
            }
        }
        return result
    }

    private func splitOnAnd(_ part: ArraySlice<Int>) -> [ArraySlice<Int>] {
        var pieces: [ArraySlice<Int>] = []
        var depth = 0
        var pieceStart = part.startIndex
        var inBetween = false
        for position in part.indices {
            let word = words[part[position]]
            if word == "(" {
                depth += 1
            } else if word == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, word == "BETWEEN" {
                inBetween = true
            } else if depth == 0, word == "AND" || word == "&&" {
                if inBetween {
                    inBetween = false
                } else {
                    pieces.append(part[pieceStart..<position])
                    pieceStart = position + 1
                }
            }
        }
        pieces.append(part[pieceStart..<part.endIndex])
        return pieces
    }

    private func withoutWrappingParentheses(_ part: ArraySlice<Int>) -> ArraySlice<Int> {
        var part = part
        while part.count >= 2, let first = part.first, let last = part.last, words[first] == "(", words[last] == ")",
              closingParenthesis(of: part) == part.endIndex - 1 {
            part = part.dropFirst().dropLast()
        }
        return part
    }

    /// Position of the `)` closing the `(` that starts `part`, if inside it.
    private func closingParenthesis(of part: ArraySlice<Int>) -> Int? {
        var depth = 0
        for position in part.indices {
            let word = words[part[position]]
            if word == "(" { depth += 1 }
            if word == ")" {
                depth -= 1
                if depth == 0 { return position }
            }
        }
        return nil
    }

    /// `side = side` (or `<=>`) with exactly one equality at depth 0.
    private func equality(_ conjunct: ArraySlice<Int>) -> (ArraySlice<Int>, ArraySlice<Int>)? {
        var depth = 0
        var operatorPosition: Int?
        for position in conjunct.indices {
            let index = conjunct[position]
            let word = words[index]
            if word == "(" {
                depth += 1
            } else if word == ")" {
                depth = max(0, depth - 1)
            } else if depth == 0, tokens[index].kind == .operator, word == "=" || word == "<=>" {
                if operatorPosition != nil { return nil }
                operatorPosition = position
            }
        }
        guard let operatorPosition else { return nil }
        return (conjunct[conjunct.startIndex..<operatorPosition], conjunct[(operatorPosition + 1)..<conjunct.endIndex])
    }

    /// `column`, `t.column`, `db.t.column` or `catalog.db.t.column`, possibly parenthesised → its parts.
    private func columnPath(_ side: ArraySlice<Int>) -> [String]? {
        let inner = withoutWrappingParentheses(side)
        guard !inner.isEmpty, inner.count <= 7, inner.count % 2 == 1 else { return nil }
        var parts: [String] = []
        for (offset, index) in inner.enumerated() {
            if offset % 2 == 1 {
                guard tokens[index].kind == .punctuation, words[index] == "." else { return nil }
            } else {
                guard let part = name(at: index) else { return nil }
                parts.append(part)
            }
        }
        // A lone reserved word (`NULL`, `TRUE`) is a value.
        if parts.count == 1, let index = inner.first, tokens[index].kind == .keyword, SQLKeywords.reserved.contains(words[index]) { return nil }
        return parts
    }

    /// A plain, keyword or back-quoted name; nil for anything else.
    private func name(at index: Int) -> String? {
        let token = tokens[index]
        guard token.kind == .identifier || token.kind == .keyword || token.kind == .quotedIdentifier else { return nil }
        if token.kind == .quotedIdentifier, lexer.isUnterminated(token) { return nil }
        let value = lexer.identifierValue(of: token)
        return value.isEmpty ? nil : value
    }

    /// Conditions between two table references in one clause: one composite join.
    private struct CompositeJoin {
        let first: Instance
        let second: Instance
        var firstColumns: [String]
        var secondColumns: [String]

        func links(_ one: Instance, _ other: Instance) -> Bool {
            let forward = first == one && second == other
            let backward = first == other && second == one
            return forward || backward
        }

        /// Adds a condition, oriented like the first one; a repeated condition is kept once.
        mutating func add(_ pair: ColumnPair) {
            let forward = first == pair.left
            let firstColumn = forward ? pair.leftColumn : pair.rightColumn
            let secondColumn = forward ? pair.rightColumn : pair.leftColumn
            for (known, other) in zip(firstColumns, secondColumns) {
                let sameFirst = known.caseInsensitiveCompare(firstColumn) == .orderedSame
                if sameFirst, other.caseInsensitiveCompare(secondColumn) == .orderedSame { return }
            }
            firstColumns.append(firstColumn)
            secondColumns.append(secondColumn)
        }
    }

    /// Composite pairs: conditions between the same two references merge, oriented as the first one was written.
    private func merged(_ pairs: [ColumnPair]) -> [JoinPair] {
        var joins: [CompositeJoin] = []
        for pair in pairs {
            if let existing = joins.firstIndex(where: { (join: CompositeJoin) -> Bool in join.links(pair.left, pair.right) }) {
                joins[existing].add(pair)
            } else {
                joins.append(CompositeJoin(first: pair.left, second: pair.right, firstColumns: [pair.leftColumn], secondColumns: [pair.rightColumn]))
            }
        }
        return joins.map { (join: CompositeJoin) -> JoinPair in
            JoinPair(left: table(reference(join.first)), leftColumns: join.firstColumns, right: table(reference(join.second)),
                     rightColumns: join.secondColumns)
        }
    }

    // MARK: Resolution

    /// The table reference a column path belongs to, when it is a base table.
    private func resolve(_ path: [String], in scope: Int, catalog: inout ColumnCatalog) -> (instance: Instance, column: String)? {
        guard let column = path.last else { return nil }
        let instance: Instance?
        switch path.count {
        case 1:
            instance = owner(ofColumn: column, from: scope, catalog: &catalog)
        case 2:
            let qualifier = path[0]
            instance = innermost(from: scope) { (reference: SQLTableReference) -> Bool in
                if let alias = reference.alias { return alias.caseInsensitiveCompare(qualifier) == .orderedSame }
                return reference.table == qualifier
            }
        case 3, 4:
            let database = path[path.count - 3]
            let table = path[path.count - 2]
            instance = innermost(from: scope) { (reference: SQLTableReference) -> Bool in
                reference.alias == nil && reference.table == table && (reference.database == nil || reference.database == database)
            } ?? innermost(from: scope) { (reference: SQLTableReference) -> Bool in
                // StarRocks 3.3 prints view definitions with `db`.`alias`.`column`.
                guard let alias = reference.alias, alias.caseInsensitiveCompare(table) == .orderedSame else { return false }
                return reference.database == nil || reference.database == database
            }
        default:
            instance = nil
        }
        guard let instance, isBaseTable(reference(instance)) else { return nil }
        return (instance, column)
    }

    /// The single reference matching `matches` in the innermost scope that has any; nil when none or ambiguous.
    private func innermost(from scope: Int, where matches: (SQLTableReference) -> Bool) -> Instance? {
        var current: Int? = scope
        while let index = current {
            let found = scopes[index].references.indices.filter { matches(scopes[index].references[$0]) }
            if found.count > 1 { return nil }
            if let only = found.first { return Instance(scope: index, reference: only) }
            current = scopes[index].parent
        }
        return nil
    }

    /// The single table having `column` in the innermost scope where any table may have it.
    private func owner(ofColumn column: String, from scope: Int, catalog: inout ColumnCatalog) -> Instance? {
        let name = column.lowercased()
        var current: Int? = scope
        while let index = current {
            var owners: [Int] = []
            var hasUnknown = false
            for (offset, reference) in scopes[index].references.enumerated() {
                guard let known = knownColumns(reference, catalog: &catalog) else {
                    hasUnknown = true
                    continue
                }
                if known.contains(name) { owners.append(offset) }
            }
            if owners.count == 1, !hasUnknown, let only = owners.first { return Instance(scope: index, reference: only) }
            if !owners.isEmpty || hasUnknown { return nil }
            current = scopes[index].parent
        }
        return nil
    }

    private func knownColumns(_ reference: SQLTableReference, catalog: inout ColumnCatalog) -> Set<String>? {
        if let derived = reference.derivedColumns {
            return derived.isEmpty ? nil : Set(derived.map { $0.lowercased() })
        }
        guard isBaseTable(reference) else { return nil }
        return catalog.columns(of: table(reference))
    }

    private func isBaseTable(_ reference: SQLTableReference) -> Bool {
        guard reference.derivedColumns == nil else { return false }
        if reference.database == nil, cteNames.contains(reference.table.lowercased()) { return false }
        guard let catalog = reference.catalog else { return true }
        return catalog.caseInsensitiveCompare("default_catalog") == .orderedSame
    }

    private func reference(_ instance: Instance) -> SQLTableReference {
        scopes[instance.scope].references[instance.reference]
    }

    private func table(_ reference: SQLTableReference) -> TableReference {
        TableReference(database: reference.database, table: reference.table)
    }

    // MARK: Preparation

    /// Assigns every token to the innermost scope containing it (scopes come in document order, outer first).
    private static func ownTokens(count: Int, scopes: [SQLTableReferences.Scope]) -> [[Int]] {
        var own = [[Int]](repeating: [], count: scopes.count)
        guard !scopes.isEmpty else { return own }
        var open: [Int] = []
        var next = 0
        for index in 0..<count {
            while let top = open.last, scopes[top].range.upperBound <= index { open.removeLast() }
            while next < scopes.count, scopes[next].range.lowerBound <= index {
                if scopes[next].range.upperBound > index { open.append(next) }
                next += 1
            }
            own[open.last ?? 0].append(index)
        }
        return own
    }

    /// `WITH [RECURSIVE] name [(columns)] AS ( … ) [, …]` anywhere in the statement.
    private static func cteNames(tokens: [SQLToken], words: [String], lexer: SQLLexer) -> Set<String> {
        var names: Set<String> = []
        for start in words.indices where words[start] == "WITH" {
            var index = start + 1
            if index < words.count, words[index] == "RECURSIVE" { index += 1 }
            while index < tokens.count, nameKinds.contains(tokens[index].kind) {
                let name = lexer.identifierValue(of: tokens[index]).lowercased()
                var next = index + 1
                if next < words.count, words[next] == "(" {
                    next = SQLTableReferences.matchingParen(tokens: tokens, open: next, lexer: lexer) + 1
                }
                guard next + 1 < words.count, words[next] == "AS", words[next + 1] == "(" else { break }
                names.insert(name)
                index = SQLTableReferences.matchingParen(tokens: tokens, open: next + 1, lexer: lexer) + 1
                guard index < words.count, words[index] == "," else { break }
                index += 1
            }
        }
        return names
    }
}
