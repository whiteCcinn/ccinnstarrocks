import Foundation

/// Maps StarRocks parse errors (`… at line 2, column 32 …`, 1-based line, 0-based UTF-16 column)
/// to an offset inside the statement text.
public enum SQLErrorLocator {
    public static func offset(in statement: String, message: String) -> Int? {
        guard let match = message.firstMatch(of: /line\s+(\d+),\s*column\s+(\d+)/),
              let line = Int(match.output.1), let column = Int(match.output.2), line >= 1 else { return nil }
        let units = Array(statement.utf16)
        var currentLine = 1
        var lineStart = 0
        var index = 0
        while currentLine < line, index < units.count {
            if units[index] == 0x0A {
                currentLine += 1
                lineStart = index + 1
            }
            index += 1
        }
        guard currentLine == line else { return nil }
        var lineEnd = lineStart
        while lineEnd < units.count, units[lineEnd] != 0x0A { lineEnd += 1 }
        // `column` comes from server text and may be absurdly large; clamp before adding.
        return lineStart + min(max(0, column), lineEnd - lineStart)
    }
}
