import Foundation

/// Declared constraints from the `foreign_key_constraints` and `unique_constraints` table properties, which StarRocks
/// keeps for the optimizer (it never enforces them). Strict: a part that is not exactly the grammar is skipped whole,
/// never guessed at.
public enum ForeignKeyConstraintParser {
    public struct ForeignKey: Sendable, Equatable {
        public var columns: [String]
        /// `database` is nil when the constraint names none (the table's own database); a catalog is dropped.
        public var target: TableReference
        /// Pairwise with `columns`.
        public var targetColumns: [String]

        public init(columns: [String], target: TableReference, targetColumns: [String]) {
            self.columns = columns
            self.target = target
            self.targetColumns = targetColumns
        }
    }

    /// `(c1[,c2]) REFERENCES [catalog.][database.]table(c1[,c2])`, several separated by `;`. Names may be back-quoted.
    public static func foreignKeys(_ property: String) -> [ForeignKey] {
        let lexer = SQLLexer(property)
        return parts(lexer).compactMap { (tokens: [SQLToken]) -> ForeignKey? in
            var cursor = Cursor(tokens: tokens, lexer: lexer)
            return foreignKey(&cursor)
        }
    }

    /// `c1,c2;c3` → `[["c1", "c2"], ["c3"]]`. A qualified name (`catalog.db.table.c3`, as external tables write it)
    /// keeps its column.
    public static func uniqueKeys(_ property: String) -> [[String]] {
        let lexer = SQLLexer(property)
        return parts(lexer).compactMap { (tokens: [SQLToken]) -> [String]? in
            var cursor = Cursor(tokens: tokens, lexer: lexer)
            return uniqueKey(&cursor)
        }
    }

    // MARK: Grammar

    private static func foreignKey(_ cursor: inout Cursor) -> ForeignKey? {
        guard let columns = columnList(&cursor), cursor.word() == "REFERENCES" else { return nil }
        guard let path = qualifiedName(&cursor), path.count <= 3, let targetColumns = columnList(&cursor) else { return nil }
        guard cursor.isAtEnd, columns.count == targetColumns.count, let table = path.last else { return nil }
        let database: String? = path.count >= 2 ? path[path.count - 2] : nil
        return ForeignKey(columns: columns, target: TableReference(database: database, table: table), targetColumns: targetColumns)
    }

    private static func uniqueKey(_ cursor: inout Cursor) -> [String]? {
        var columns: [String] = []
        repeat {
            guard let path = qualifiedName(&cursor), let column = path.last else { return nil }
            columns.append(column)
        } while cursor.punctuation(",")
        return cursor.isAtEnd ? columns : nil
    }

    /// `( name [, name]… )`
    private static func columnList(_ cursor: inout Cursor) -> [String]? {
        guard cursor.punctuation("(") else { return nil }
        var columns: [String] = []
        repeat {
            guard let column = cursor.name() else { return nil }
            columns.append(column)
        } while cursor.punctuation(",")
        return cursor.punctuation(")") ? columns : nil
    }

    /// `name [. name]…`
    private static func qualifiedName(_ cursor: inout Cursor) -> [String]? {
        guard let first = cursor.name() else { return nil }
        var path = [first]
        while cursor.punctuation(".") {
            guard let next = cursor.name() else { return nil }
            path.append(next)
        }
        return path
    }

    /// The `;`-separated parts, empty ones dropped. Comments stay in: text the grammar does not expect makes a part
    /// malformed.
    private static func parts(_ lexer: SQLLexer) -> [[SQLToken]] {
        var parts: [[SQLToken]] = []
        var current: [SQLToken] = []
        for token in lexer.tokens() {
            if token.kind == .punctuation, lexer.text(of: token) == ";" {
                if !current.isEmpty { parts.append(current) }
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private struct Cursor {
        let tokens: [SQLToken]
        let lexer: SQLLexer
        var index = 0

        init(tokens: [SQLToken], lexer: SQLLexer) {
            self.tokens = tokens
            self.lexer = lexer
        }

        var isAtEnd: Bool { index >= tokens.count }

        mutating func punctuation(_ text: String) -> Bool {
            guard index < tokens.count, tokens[index].kind == .punctuation, lexer.text(of: tokens[index]) == text else { return false }
            index += 1
            return true
        }

        /// An unquoted word, upper-cased.
        mutating func word() -> String? {
            guard index < tokens.count, tokens[index].kind == .identifier || tokens[index].kind == .keyword else { return nil }
            defer { index += 1 }
            return lexer.text(of: tokens[index]).uppercased()
        }

        /// A column, table or database name: a word (keywords such as `date` included) or a back-quoted name.
        mutating func name() -> String? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            guard token.kind == .identifier || token.kind == .keyword || token.kind == .quotedIdentifier else { return nil }
            if token.kind == .quotedIdentifier, lexer.isUnterminated(token) { return nil }
            let value = lexer.identifierValue(of: token)
            guard !value.isEmpty else { return nil }
            index += 1
            return value
        }
    }
}
