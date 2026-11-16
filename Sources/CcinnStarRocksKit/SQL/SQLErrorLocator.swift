import Foundation

/// A StarRocks statement error, parsed from its message.
///
/// Shapes (3.3 and 4.1): `Getting syntax error at line 1, column 14. Detail message: …`,
/// `Getting analyzing error from line 1, column 7 to line 1, column 16. Detail message: …` and,
/// for most analysis errors, no position at all (`… Detail message: Column 'x' cannot be resolved.`).
/// Lines are 1-based; columns are 0-based **Unicode code points** (ANTLR), not UTF-16 units.
public struct SQLServerError: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case syntax
        case analysis
        case other
    }

    public struct Position: Sendable, Equatable {
        public var line: Int
        public var column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }

        /// `nil` when a number does not fit an `Int` or is out of range. Digit-group separators
        /// (`1,501`, `1.214`, `1 214`) are dropped: StarRocks formats numbers in the FE's JVM locale.
        init?(line: Substring, column: Substring) {
            guard let line = Self.number(line), let column = Self.number(column), line >= 1, column >= 0 else { return nil }
            self.init(line: line, column: column)
        }

        static func number(_ text: Substring) -> Int? {
            Int(String(text.unicodeScalars.filter { $0.properties.numericType == .decimal && $0.isASCII }))
        }
    }

    public var phase: Phase
    public var start: Position?
    /// Start of the **last token** of the reported range (inclusive), when the server sends a range.
    public var end: Position?
    /// The message without StarRocks' "Getting … error … Detail message:" framing, the app's
    /// `(error N)` suffix and trailing periods. Kept whole: `No viable statement for input '…'`
    /// echoes the input, which locates the error.
    public var detail: String
    /// `detail` for display: back-quoted names read plainly and at most `summaryLimit` characters.
    public var summary: String
    /// Identifiers the message names (`Column '`o`.`x`'` → `["o", "x"]`), most specific first.
    public var names: [[String]]

    public static let summaryLimit = 500

    public init(phase: Phase, start: Position? = nil, end: Position? = nil, detail: String, names: [[String]] = []) {
        self.phase = phase
        self.start = start
        self.end = end
        self.detail = detail
        self.names = names
        summary = Self.summarize(detail)
    }

    public static func parse(_ message: String) -> SQLServerError {
        let phase: Phase = message.contains("Getting syntax error") ? .syntax
            : message.contains("Getting analyzing error") ? .analysis : .other
        var start: Position?
        var end: Position?
        // Positions are in the header; a huge echoed statement after it is never scanned.
        let head = message.prefix(1_024)
        // A number, digit-grouped or not: `7`, `1234`, `1,214`, `1.214`, `1 214` (no-break spaces).
        if let match = head.firstMatch(of: /from\s+line\s+(\d{1,3}(?:[,.\x{00A0}\x{202F}]\d{3})+|\d+),\s*column\s+(\d{1,3}(?:[,.\x{00A0}\x{202F}]\d{3})+|\d+)\s+to\s+line\s+(\d{1,3}(?:[,.\x{00A0}\x{202F}]\d{3})+|\d+),\s*column\s+(\d{1,3}(?:[,.\x{00A0}\x{202F}]\d{3})+|\d+)/) {
            start = Position(line: match.output.1, column: match.output.2)
            end = start == nil ? nil : Position(line: match.output.3, column: match.output.4)
        } else if let match = head.firstMatch(of: /line\s+(\d{1,3}(?:[,.\x{00A0}\x{202F}]\d{3})+|\d+),\s*column\s+(\d{1,3}(?:[,.\x{00A0}\x{202F}]\d{3})+|\d+)/) {
            start = Position(line: match.output.1, column: match.output.2)
        }
        let detail = cleanedDetail(message)
        return SQLServerError(phase: phase, start: start, end: end, detail: detail, names: names(in: String(detail.prefix(4_096))))
    }

    /// The kind, with an **editor** position when one is known. The server's own position is relative
    /// to the executed statement (and includes an `EXPLAIN` prefix), so it is never shown here.
    public func title(at position: SQLTextPosition?) -> String {
        guard let position else { return kindLabel }
        return "\(kindLabel) at line \(position.line), column \(position.column)"
    }

    static func summarize(_ detail: String) -> String {
        let plain = plainNames(in: String(detail.prefix(summaryLimit * 4)))
        guard plain.count > summaryLimit else { return plain }
        return String(plain.prefix(summaryLimit)) + "…"
    }

    /// "Syntax error", "Analysis error" or "Error".
    public var kindLabel: String {
        switch phase {
        case .syntax: "Syntax error"
        case .analysis: "Analysis error"
        case .other: "Error"
        }
    }

    static func cleanedDetail(_ message: String) -> String {
        var detail = Substring(message)
        if let marker = detail.range(of: "Detail message:") { detail = detail[marker.upperBound...] }
        var text = String(detail).trimmingCharacters(in: .whitespacesAndNewlines)
        // The app's ` (error N)` suffix (checked from the end: the message may be huge).
        if text.hasSuffix(")"), let open = text.range(of: " (error ", options: .backwards),
           text[open.upperBound...].dropLast().allSatisfy(\.isNumber) {
            text.removeSubrange(open.lowerBound...)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? message.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    /// `'`o`.`x`'` → `'o.x'`, unless a part contains a dot or back-quote (then the quoting matters).
    static func plainNames(in detail: String) -> String {
        detail.replacing(/'(`(?:[^`]|``)*`(?:\.`(?:[^`]|``)*`)*)'/) { match -> String in
            let segments = nameSegments(String(match.output.1))
            guard !segments.isEmpty, !segments.contains(where: { $0.contains(".") || $0.contains("`") }) else { return String(match.output.0) }
            return "'" + segments.joined(separator: ".") + "'"
        }
    }

    static func names(in detail: String) -> [[String]] {
        // Patterns recorded from StarRocks 3.3 and 4.1 (plus the MySQL-style variants).
        let captures: [Substring?] = [
            detail.firstMatch(of: /Column '(.+?)' cannot be resolved/)?.output.1,
            detail.firstMatch(of: /Column '(.+?)' is ambiguous/)?.output.1,
            detail.firstMatch(of: /Column '(.+?)' (?:does not exist|doesn't exist|not found)/)?.output.1,
            detail.firstMatch(of: /Unknown column '(.+?)'/)?.output.1,
            detail.firstMatch(of: /Unknown table '(.+?)'/)?.output.1,
            detail.firstMatch(of: /[Tt]able [`']?([^\s`']+)[`']? (?:is not found|does not exist|doesn't exist)/)?.output.1,
            detail.firstMatch(of: /Unknown database '(.+?)'/)?.output.1,
            detail.firstMatch(of: /Database '(.+?)' (?:does not exist|doesn't exist|not found)/)?.output.1,
            detail.firstMatch(of: /Unknown catalog '(.+?)'/)?.output.1,
            detail.firstMatch(of: /Key column\((.+?)\) doesn't exist/)?.output.1,
        ]
        var names: [[String]] = []
        for capture in captures.compactMap({ $0 }) {
            let segments = nameSegments(String(capture))
            if !segments.isEmpty, !names.contains(segments) { names.append(segments) }
        }
        return names
    }

    /// `` `a`.`b` `` → `["a", "b"]` (doubled back-quotes unescaped); `shop.t` → `["shop", "t"]`.
    static func nameSegments(_ raw: String) -> [String] {
        let characters = Array(raw)
        var segments: [String] = []
        var current = ""
        var quoted = false
        var index = 0
        func flush() {
            let segment = quoted ? current : current.trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty { segments.append(segment) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "`" {
                    if index + 1 < characters.count, characters[index + 1] == "`" {
                        current.append("`")
                        index += 2
                        continue
                    }
                    quoted = false
                } else {
                    current.append(character)
                }
            } else if character == "`" {
                quoted = true
            } else if character == "." {
                flush()
            } else {
                current.append(character)
            }
            index += 1
        }
        flush()
        return segments
    }
}

/// How the text the server executed relates to the statement in the editor: the app may prepend
/// (`EXPLAIN `) and insert (` LIMIT n`). Offsets are UTF-16.
public struct SQLExecutedTextMapping: Sendable, Equatable {
    public var prefixLength: Int
    /// Range of inserted text, in executed coordinates.
    public var insertion: Range<Int>?

    public static let identity = SQLExecutedTextMapping()

    public init(prefixLength: Int = 0, insertion: Range<Int>? = nil) {
        self.prefixLength = max(0, prefixLength)
        self.insertion = insertion
    }

    /// Source offset for an executed offset. Positions inside the insertion map to its start;
    /// positions inside the prefix map to 0. Never negative.
    public func sourceOffset(forExecuted offset: Int) -> Int {
        var value = max(0, offset)
        if let insertion {
            if value >= insertion.upperBound {
                value -= insertion.count
            } else if value > insertion.lowerBound {
                value = insertion.lowerBound
            }
        }
        return max(0, value - prefixLength)
    }
}

/// Finds the text a StarRocks error refers to inside the statement that failed.
public enum SQLErrorLocator {
    /// UTF-16 offset of the error's start position in `statement` (no token expansion).
    public static func offset(in statement: String, message: String) -> Int? {
        guard let start = SQLServerError.parse(message).start else { return nil }
        return utf16Offset(of: start, in: Array(statement.utf16))
    }

    /// The range to mark in `statement`, for a message about that same text.
    public static func range(in statement: String, message: String) -> Range<Int>? {
        range(in: statement, error: SQLServerError.parse(message))
    }

    /// The range (UTF-16, in `source`) to mark for `error`. Positions are resolved in `executed`
    /// (what the server saw; `source` when nil) and mapped back with `mapping`. Then:
    /// a reported range runs to the end of its last token; a single position marks its token (or the
    /// last token before it, e.g. at end of input); without a position the named identifier is
    /// searched. `nil` when nothing can be located.
    public static func range(in source: String, executed: String? = nil, mapping: SQLExecutedTextMapping = .identity,
                             error: SQLServerError) -> Range<Int>? {
        let lexer = SQLLexer(source)
        let allTokens = lexer.tokens()
        let tokens = allTokens.filter { $0.kind != .comment }
        guard !tokens.isEmpty else { return nil }
        let sourceLength = lexer.units.count
        let executedUnits = executed.map { Array($0.utf16) } ?? lexer.units
        func sourceOffset(_ position: SQLServerError.Position) -> Int? {
            guard let offset = utf16Offset(of: position, in: executedUnits) else { return nil }
            return min(mapping.sourceOffset(forExecuted: offset), sourceLength)
        }

        if let startPosition = error.start, let start = sourceOffset(startPosition) {
            // StarRocks rejects an unterminated `/*` where it starts; mark the `/*`.
            if let comment = allTokens.last, comment.kind == .comment, lexer.isUnterminated(comment),
               comment.range.lowerBound <= start {
                return comment.range.lowerBound..<min(comment.range.lowerBound + 2, comment.range.upperBound)
            }
            if let input = noViableInput(in: error.detail), let found = occurrence(of: input, covering: start, in: source) {
                return found
            }
            let first = tokenIndex(at: start, in: tokens)
            var last = first
            if let endPosition = error.end, let end = sourceOffset(endPosition) {
                let candidate = tokenIndex(at: end, in: tokens)
                if candidate > first { last = candidate }
            }
            return tokens[first].range.lowerBound..<tokens[last].range.upperBound
        }
        for name in error.names {
            var segments = name[...]
            while !segments.isEmpty {
                if let found = sequence(Array(segments), in: tokens, lexer: lexer) { return found }
                segments = segments.dropFirst()
            }
        }
        return nil
    }

    // MARK: Positions

    /// UTF-16 offset of a (line, code-point column) position; the column is clamped to the line end.
    /// `nil` when the line does not exist. Only `\n` ends a line (as in ANTLR).
    static func utf16Offset(of position: SQLServerError.Position, in units: [UInt16]) -> Int? {
        var index = 0
        var line = 1
        while line < position.line {
            while index < units.count, units[index] != 0x0A { index += 1 }
            guard index < units.count else { return nil }
            index += 1
            line += 1
        }
        var remaining = position.column
        while remaining > 0, index < units.count, units[index] != 0x0A {
            if UTF16.isLeadSurrogate(units[index]), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                index += 2
            } else {
                index += 1
            }
            remaining -= 1
        }
        return index
    }

    /// The token containing `offset`, else the last token ending at or before it, else the first.
    static func tokenIndex(at offset: Int, in tokens: [SQLToken]) -> Int {
        // First token that ends after `offset` (binary search).
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        if low < tokens.count, tokens[low].range.lowerBound <= offset { return low }
        return max(0, low - 1)
    }

    // MARK: Input snippets and names

    /// `No viable statement for input '(1 = 1'` → `(1 = 1`.
    static func noViableInput(in detail: String) -> String? {
        guard let match = detail.firstMatch(of: /for input '(.+)'/) else { return nil }
        let input = String(match.output.1)
        return input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : input
    }

    /// The case-insensitive occurrence of `needle` that starts at or before `offset` and ends at or
    /// after it. One backwards search in the window ending `needle.length` past `offset`: the match
    /// with the greatest start there is the only candidate (earlier ones end earlier). Linear time.
    static func occurrence(of needle: String, covering offset: Int, in text: String) -> Range<Int>? {
        let haystack = text as NSString
        let needleLength = (needle as NSString).length
        guard needleLength > 0, offset >= 0, offset <= haystack.length else { return nil }
        let windowEnd = min(haystack.length, offset + needleLength)
        let found = haystack.range(of: needle, options: [.caseInsensitive, .literal, .backwards],
                                   range: NSRange(location: 0, length: windowEnd))
        guard found.location != NSNotFound, found.length > 0, found.location <= offset, NSMaxRange(found) >= offset else { return nil }
        return found.location..<NSMaxRange(found)
    }

    /// Tokens spelling `a . b . c` (identifier values compared case-insensitively).
    static func sequence(_ segments: [String], in tokens: [SQLToken], lexer: SQLLexer) -> Range<Int>? {
        guard !segments.isEmpty else { return nil }
        let wanted = segments.map { $0.lowercased() }
        let span = segments.count * 2 - 1
        guard tokens.count >= span else { return nil }
        func isName(_ token: SQLToken) -> Bool {
            token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
        }
        for start in 0...(tokens.count - span) {
            var matches = true
            for (offset, name) in wanted.enumerated() {
                let token = tokens[start + offset * 2]
                guard isName(token), lexer.identifierValue(of: token).lowercased() == name else { matches = false; break }
                if offset > 0 {
                    let dot = tokens[start + offset * 2 - 1]
                    guard dot.kind == .punctuation, lexer.units[dot.range.lowerBound] == 0x2E else { matches = false; break }
                }
            }
            if matches { return tokens[start].range.lowerBound..<tokens[start + span - 1].range.upperBound }
        }
        return nil
    }
}
