import Foundation

/// Other sessions' SQL as the AI may see it: every literal (string, number) becomes `?` and comments are removed, so
/// credentials or personal data in the statement never reach it; the shape (tables, columns, functions) stays.
public enum SQLDigest {
    public static func digest(_ sql: String) -> String {
        let lexer = SQLLexer(sql)
        var result = ""
        var cursor = 0
        for token in lexer.tokens() {
            let gap = lexer.text(in: cursor..<token.range.lowerBound).filter { $0.isWhitespace }
            cursor = token.range.upperBound
            switch token.kind {
            case .comment:
                result += gap
            case .string, .number:
                result += gap + "?"
            default:
                result += gap + lexer.text(of: token)
            }
        }
        return result.split(whereSeparator: { $0 == " " }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
