import Foundation
import StarRocksKit

public struct CompletionItem: Sendable, Hashable, Identifiable {
    public enum Kind: Int, Sendable, Hashable {
        case column, alias, table, view, materializedView, externalTable, database, catalog, function, keyword
    }

    public let kind: Kind
    public let label: String
    public let insertText: String
    /// Secondary text: column type and table, function signature, object kind.
    public let detail: String?

    public var id: String { "\(kind.rawValue)\u{1F}\(label)\u{1F}\(detail ?? "")" }
}

public struct CompletionResult: Sendable {
    /// UTF-16 range in the editor text that the chosen item replaces.
    public let replacementRange: Range<Int>
    public let prefix: String
    public let items: [CompletionItem]
    /// Tables referenced by the statement whose columns are not in the snapshot yet; the app loads
    /// them and asks again.
    public let missingColumns: [TableKey]
    /// Databases whose object lists are needed but not loaded yet.
    public let missingDatabases: [String]

    public init(replacementRange: Range<Int>, prefix: String, items: [CompletionItem], missingColumns: [TableKey] = [],
                missingDatabases: [String] = []) {
        self.replacementRange = replacementRange
        self.prefix = prefix
        self.items = items
        self.missingColumns = missingColumns
        self.missingDatabases = missingDatabases
    }

    public var needsMoreSchema: Bool { !missingColumns.isEmpty || !missingDatabases.isEmpty }

    public static func empty(at cursor: Int) -> CompletionResult {
        CompletionResult(replacementRange: cursor..<cursor, prefix: "", items: [])
    }
}

/// Context-aware SQL completion (design D6). Pure and synchronous; callers run it off the main actor.
public enum CompletionEngine {
    public static let defaultLimit = 200

    enum Context: Equatable {
        case statementStart
        case showTarget
        case tableName(materializedViewsOnly: Bool)
        case afterTableReference
        case database
        case expression
    }

    /// A table reference in scope: a base table (database + name) or a derived table/CTE with known columns.
    struct ScopeTable {
        var alias: String?
        var database: String?
        var table: String
        var derivedColumns: [String]?
    }

    public static func complete(text: String, cursor: Int, schema: SchemaSnapshot, limit: Int = defaultLimit) -> CompletionResult {
        let lexer = SQLLexer(text)
        let cursor = max(0, min(cursor, lexer.units.count))
        let allTokens = lexer.tokens()

        // Restrict to the statement around the cursor.
        let isSemicolon: (SQLToken) -> Bool = { $0.kind == .punctuation && lexer.units[$0.range.lowerBound] == 0x3B }
        let statementStart = allTokens.last { isSemicolon($0) && $0.range.upperBound <= cursor }?.range.upperBound ?? 0
        let statementEnd = allTokens.first { isSemicolon($0) && $0.range.lowerBound >= cursor }?.range.lowerBound ?? lexer.units.count
        let tokens = allTokens.filter { $0.range.lowerBound >= statementStart && $0.range.upperBound <= statementEnd }

        // No completion inside strings or comments.
        if let enclosing = tokens.first(where: { $0.range.lowerBound < cursor && cursor < $0.range.upperBound }),
           enclosing.kind == .string || enclosing.kind == .comment {
            return .empty(at: cursor)
        }
        if let ending = tokens.last(where: { $0.range.upperBound == cursor }) {
            if ending.kind == .comment, lexer.text(of: ending).hasPrefix("--") || lexer.text(of: ending).hasPrefix("#") {
                return .empty(at: cursor)
            }
            if ending.kind == .string, !isTerminated(ending, lexer: lexer) { return .empty(at: cursor) }
        }

        let prefixToken = tokens.last {
            $0.range.upperBound == cursor && ($0.kind == .identifier || $0.kind == .keyword || $0.kind == .quotedIdentifier)
        }
        let replacementStart = prefixToken?.range.lowerBound ?? cursor
        let prefix: String = prefixToken.map { token in
            token.kind == .quotedIdentifier ? lexer.identifierValue(of: token) : lexer.text(of: token)
        } ?? ""
        let before = tokens.filter { $0.range.upperBound <= replacementStart && $0.kind != .comment }
        let significant = tokens.filter { $0.kind != .comment }
        let scope = scopeTables(tokens: significant, lexer: lexer, schema: schema)

        var candidates: [CompletionItem]
        var missing: [TableKey] = []
        var missingDatabases: [String] = []
        if let last = before.last, isDot(last, lexer) {
            let qualifier = qualifierChain(before: before, lexer: lexer)
            (candidates, missing) = memberCandidates(qualifier: qualifier, scope: scope, schema: schema)
            if let database = qualifier.first, qualifier.count == 1, schema.isDatabase(database), schema.objects(in: database) == nil {
                missingDatabases.append(database)
            }
        } else {
            let context = clauseContext(before: before, lexer: lexer)
            (candidates, missing) = contextCandidates(context, scope: scope, schema: schema)
            if case .tableName = context, let current = schema.currentDatabase, schema.objects(in: current) == nil {
                missingDatabases.append(current)
            }
        }
        let ranked = rank(candidates, prefix: prefix, limit: limit)
        return CompletionResult(replacementRange: replacementStart..<cursor, prefix: prefix, items: ranked,
                                missingColumns: missing, missingDatabases: missingDatabases)
    }

    // MARK: Scope analysis

    static func isDot(_ token: SQLToken, _ lexer: SQLLexer) -> Bool {
        token.kind == .punctuation && lexer.units[token.range.lowerBound] == 0x2E
    }

    static func isTerminated(_ token: SQLToken, lexer: SQLLexer) -> Bool {
        guard token.range.count >= 2 else { return false }
        return lexer.units[token.range.upperBound - 1] == lexer.units[token.range.lowerBound]
    }

    static func isName(_ token: SQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
    }

    /// `a.b.` before the cursor → ["a", "b"].
    static func qualifierChain(before: [SQLToken], lexer: SQLLexer) -> [String] {
        var parts: [String] = []
        var index = before.count - 1
        while index >= 1, isDot(before[index], lexer), isName(before[index - 1]),
              before[index - 1].range.upperBound == before[index].range.lowerBound {
            parts.insert(lexer.identifierValue(of: before[index - 1]), at: 0)
            index -= 2
        }
        return parts
    }

    static let aliasStopWords: Set<String> = SQLKeywords.reserved.union([
        "LATERAL", "WINDOW", "SEMI", "ANTI", "OUTER", "INNER", "PARTITION", "TABLET", "LIMIT", "WHERE", "ON", "USING",
    ])

    /// Tables, derived tables and CTEs referenced anywhere in the statement, with their aliases.
    static func scopeTables(tokens: [SQLToken], lexer: SQLLexer, schema: SchemaSnapshot) -> [ScopeTable] {
        var result: [ScopeTable] = []
        var ctes: [String: [String]] = [:]
        let words = tokens.map { $0.kind == .keyword ? lexer.text(of: $0).uppercased() : "" }

        // CTEs: WITH name AS ( … ), name AS ( … )
        if words.first == "WITH" {
            var index = 1
            if index < words.count, words[index] == "RECURSIVE" { index += 1 }
            while index + 2 < tokens.count, isName(tokens[index]), words[index + 1] == "AS",
                  lexer.text(of: tokens[index + 2]) == "(" {
                let name = lexer.identifierValue(of: tokens[index])
                let close = matchingParen(tokens: tokens, open: index + 2, lexer: lexer)
                ctes[name.lowercased()] = derivedColumns(tokens: Array(tokens[(index + 3)..<close]), lexer: lexer)
                index = close + 1
                if index < tokens.count, lexer.text(of: tokens[index]) == "," { index += 1 } else { break }
            }
        }

        var index = 0
        while index < tokens.count {
            let word = words[index]
            let startsReference = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"].contains(word)
            index += 1
            guard startsReference else { continue }
            var parsingList = true
            while parsingList, index < tokens.count {
                parsingList = false
                if lexer.text(of: tokens[index]) == "(" {
                    // Derived table: ( SELECT … ) [AS] alias
                    let close = matchingParen(tokens: tokens, open: index, lexer: lexer)
                    let columns = derivedColumns(tokens: Array(tokens[(index + 1)..<min(close, tokens.count)]), lexer: lexer)
                    index = close + 1
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        result.append(ScopeTable(alias: alias, database: nil, table: alias, derivedColumns: columns))
                        index = next
                    }
                } else if isName(tokens[index]), !aliasStopWords.contains(words[index]) || tokens[index].kind != .keyword {
                    var parts = [lexer.identifierValue(of: tokens[index])]
                    index += 1
                    while index + 1 < tokens.count, isDot(tokens[index], lexer), isName(tokens[index + 1]) {
                        parts.append(lexer.identifierValue(of: tokens[index + 1]))
                        index += 2
                    }
                    let table = parts[parts.count - 1]
                    let database = parts.count >= 2 ? parts[parts.count - 2] : nil
                    var reference = ScopeTable(alias: nil, database: database, table: table, derivedColumns: nil)
                    if database == nil, let cteColumns = ctes[table.lowercased()] { reference.derivedColumns = cteColumns }
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        reference.alias = alias
                        index = next
                    }
                    result.append(reference)
                }
                if index < tokens.count, lexer.text(of: tokens[index]) == ",", word == "FROM" {
                    index += 1
                    parsingList = true
                }
            }
        }
        return result
    }

    static func parseAlias(tokens: [SQLToken], words: [String], at index: Int, lexer: SQLLexer) -> (String, Int)? {
        var index = index
        if index < tokens.count, words[index] == "AS" { index += 1 }
        guard index < tokens.count, isName(tokens[index]) else { return nil }
        if tokens[index].kind == .keyword, aliasStopWords.contains(words[index]) { return nil }
        return (lexer.identifierValue(of: tokens[index]), index + 1)
    }

    static func matchingParen(tokens: [SQLToken], open: Int, lexer: SQLLexer) -> Int {
        var depth = 0
        var index = open
        while index < tokens.count {
            let text = lexer.text(of: tokens[index])
            if tokens[index].kind == .punctuation {
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

    // MARK: Clause context

    static func clauseContext(before: [SQLToken], lexer: SQLLexer) -> Context {
        guard !before.isEmpty else { return .statementStart }
        let words = before.map { $0.kind == .keyword ? lexer.text(of: $0).uppercased() : "" }
        let firstWord = words.first ?? ""
        let lastText = lexer.text(of: before[before.count - 1]).uppercased()

        if lastText == "SHOW" { return .showTarget }
        if lastText == "USE" || (lastText == "CATALOG" && words.count >= 2 && words[words.count - 2] == "SET") { return .database }
        if words.suffix(2) == ["MATERIALIZED", "VIEW"] { return .tableName(materializedViewsOnly: true) }

        // Walk back within the current parenthesis level to the nearest clause keyword.
        var depth = 0
        var distance = 0
        var sawComma = false
        for index in stride(from: before.count - 1, through: 0, by: -1) {
            let token = before[index]
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == ")" { depth += 1 }
                if text == "(" {
                    if depth == 0 { return .expression } // inside a function call or subquery start
                    depth -= 1
                }
                if depth == 0, text == ",", distance == 0 { sawComma = true }
            }
            guard depth == 0 else { continue }
            let word = words[index]
            switch word {
            case "FROM" where firstWord == "SHOW":
                let lowered = words.joined(separator: " ")
                return lowered.contains("TABLES") || lowered.contains("ROUTINE") || lowered.contains("LOAD") || lowered.contains("ALTER")
                    ? .database : .tableName(materializedViewsOnly: false)
            case "FROM", "JOIN", "UPDATE", "INTO", "TABLE", "DESC", "DESCRIBE", "OVERWRITE":
                if distance == 0 || sawComma { return .tableName(materializedViewsOnly: false) }
                return word == "UPDATE" || word == "INTO" || word == "TABLE" ? .expression : .afterTableReference
            case "SELECT", "WHERE", "ON", "HAVING", "BY", "SET", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE", "CASE",
                 "DISTINCT", "IN", "LIKE", "BETWEEN", "IS", "USING", "OVER", "PARTITION", "VALUES":
                return .expression
            case "USE":
                return .database
            default:
                break
            }
            if token.kind == .operator { return .expression }
            if token.kind != .punctuation || text != "." { distance += 1 }
        }
        return .expression
    }

    // MARK: Candidates

    static func memberCandidates(qualifier: [String], scope: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        guard let head = qualifier.first else { return ([], []) }
        let current = schema.currentDatabase
        switch qualifier.count {
        case 1:
            // Precedence: explicit alias, database name, table referenced without alias, catalog, table in current database.
            if let table = scope.first(where: { $0.alias?.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if schema.isDatabase(head) {
                return (objectCandidates(database: head, schema: schema, materializedViewsOnly: false), [])
            }
            if let table = scope.first(where: { $0.alias == nil && $0.table.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if schema.isCatalog(head) {
                return (schema.catalogs.first { $0.caseInsensitiveCompare(head) == .orderedSame } == schema.currentCatalog
                    ? databaseCandidates(schema) : [], [])
            }
            if let current, schema.object(named: head, in: current) != nil {
                return columnCandidates(of: [ScopeTable(alias: nil, database: current, table: head, derivedColumns: nil)], schema: schema)
            }
            return ([], [])
        case 2:
            if schema.isCatalog(head) {
                return (objectCandidates(database: qualifier[1], schema: schema, materializedViewsOnly: false), [])
            }
            return columnCandidates(of: [ScopeTable(alias: nil, database: head, table: qualifier[1], derivedColumns: nil)], schema: schema)
        default:
            return columnCandidates(of: [ScopeTable(alias: nil, database: qualifier[qualifier.count - 2],
                                                    table: qualifier[qualifier.count - 1], derivedColumns: nil)], schema: schema)
        }
    }

    static func contextCandidates(_ context: Context, scope: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        switch context {
        case .statementStart:
            return (SQLKeywords.statementStarters.map(keywordItem), [])
        case .showTarget:
            return (SQLKeywords.showTargets.map(keywordItem), [])
        case .database:
            return (databaseCandidates(schema) + schema.catalogs.map {
                CompletionItem(kind: .catalog, label: $0, insertText: quoteIfNeeded($0), detail: "catalog")
            }, [])
        case let .tableName(materializedViewsOnly):
            var items: [CompletionItem] = []
            if let current = schema.currentDatabase {
                items += objectCandidates(database: current, schema: schema, materializedViewsOnly: materializedViewsOnly)
            }
            items += databaseCandidates(schema)
            return (items, [])
        case .afterTableReference:
            let keywords = ["WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "FULL OUTER JOIN", "CROSS JOIN",
                            "ON", "USING", "AS", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "UNION ALL", "PARTITION"]
            return (keywords.map(keywordItem), [])
        case .expression:
            let (columns, missing) = columnCandidates(of: scope, schema: schema)
            let aliases = scope.compactMap(\.alias).map {
                CompletionItem(kind: .alias, label: $0, insertText: quoteIfNeeded($0), detail: "alias")
            }
            let functions = SQLFunctions.all.map {
                CompletionItem(kind: .function, label: $0.name, insertText: $0.name + "(", detail: $0.signature)
            }
            return (columns + aliases + functions + SQLKeywords.clauseKeywords.map(keywordItem), missing)
        }
    }

    static func columnCandidates(of tables: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        var items: [CompletionItem] = []
        var missing: [TableKey] = []
        var seen = Set<String>()
        for table in tables {
            let source = table.alias ?? table.table
            if let derived = table.derivedColumns {
                for column in derived where seen.insert("\(source).\(column)").inserted {
                    items.append(CompletionItem(kind: .column, label: column, insertText: quoteIfNeeded(column), detail: source))
                }
                continue
            }
            guard let database = table.database ?? schema.currentDatabase else { continue }
            guard let columns = schema.columns(database: database, table: table.table) else {
                if schema.object(named: table.table, in: database) != nil || table.database != nil {
                    missing.append(TableKey(database: database, table: table.table))
                }
                continue
            }
            for column in columns where seen.insert("\(source).\(column.name)").inserted {
                items.append(CompletionItem(kind: .column, label: column.name, insertText: quoteIfNeeded(column.name),
                                            detail: "\(column.columnType) · \(table.table)"))
            }
        }
        return (items, missing)
    }

    static func objectCandidates(database: String, schema: SchemaSnapshot, materializedViewsOnly: Bool) -> [CompletionItem] {
        (schema.objects(in: database) ?? []).compactMap { object in
            let kind: CompletionItem.Kind
            switch object.kind {
            case .table: kind = .table
            case .view, .systemView: kind = .view
            case .asyncMaterializedView, .syncMaterializedView: kind = .materializedView
            case .externalTable: kind = .externalTable
            }
            if materializedViewsOnly, kind != .materializedView { return nil }
            // Sync MVs cannot be queried directly by name.
            if object.kind == .syncMaterializedView, !materializedViewsOnly { return nil }
            return CompletionItem(kind: kind, label: object.name, insertText: quoteIfNeeded(object.name), detail: object.kind.displayName)
        }
    }

    static func databaseCandidates(_ schema: SchemaSnapshot) -> [CompletionItem] {
        schema.databases.map { CompletionItem(kind: .database, label: $0, insertText: quoteIfNeeded($0), detail: "database") }
    }

    static func keywordItem(_ keyword: String) -> CompletionItem {
        CompletionItem(kind: .keyword, label: keyword, insertText: keyword, detail: nil)
    }

    /// Back-quotes identifiers that are reserved words or contain unusual characters.
    public static func quoteIfNeeded(_ name: String) -> String {
        let simple = name.utf16.enumerated().allSatisfy { offset, unit in
            offset == 0 ? SQLLexer.isIdentifierStart(unit) && unit < 0x80 : SQLLexer.isIdentifierPart(unit) && unit < 0x80
        }
        if simple, !SQLKeywords.reserved.contains(name.uppercased()) { return name }
        return SQLText.quoteIdentifier(name)
    }

    // MARK: Ranking

    /// Prefix matches first, then word-boundary matches (`cd` → `city_daily`), then subsequences.
    static func rank(_ items: [CompletionItem], prefix: String, limit: Int) -> [CompletionItem] {
        let needle = prefix.lowercased()
        var scored: [(item: CompletionItem, score: Int)] = []
        scored.reserveCapacity(items.count)
        var seen = Set<String>()
        for item in items where seen.insert(item.id).inserted {
            let score = matchScore(label: item.label.lowercased(), needle: needle)
            if score > 0 { scored.append((item, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.kind != rhs.item.kind { return lhs.item.kind.rawValue < rhs.item.kind.rawValue }
            return lhs.item.label.localizedStandardCompare(rhs.item.label) == .orderedAscending
        }
        return scored.prefix(max(0, limit)).map(\.item)
    }

    static func matchScore(label: String, needle: String) -> Int {
        if needle.isEmpty { return 1 }
        if label == needle { return 5 }
        if label.hasPrefix(needle) { return 4 }
        let words = label.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "." })
        if words.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 3 }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(needle) { return 2 }
        var remaining = Substring(needle)
        for character in label where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 1 }
        }
        return 0
    }
}
