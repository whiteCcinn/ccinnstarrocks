import Foundation

/// One lexical token. Ranges are UTF-16 offsets so they map 1:1 onto `NSRange` in the editor.
public struct SQLToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyword
        case identifier
        /// `` `name` `` (back-quoted).
        case quotedIdentifier
        case string
        case number
        case comment
        case `operator`
        /// `( ) , ; .`
        case punctuation
        /// `@user_var`, `@@session_var`
        case variable
    }

    public let kind: Kind
    public let range: Range<Int>

    public init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// Tokenizer for MySQL/StarRocks SQL. Never fails: unterminated strings and comments extend to the
/// end of the input, unknown characters become operators. Linear time over UTF-16 code units.
public struct SQLLexer: Sendable {
    public let units: [UInt16]
    /// Reads `$$ … $$` as one opaque token, as StarRocks 4.1 does for inline function bodies. Off by default: 3.3 reads
    /// `$$` as part of a name, and statement splitting and the read-only guard must never see fewer statements than any
    /// supported server. Only consumers that know the server reads blocks (the formatter on 4.1) turn it on.
    public let dollarQuotedBlocks: Bool

    public init(_ text: String, dollarQuotedBlocks: Bool = false) {
        units = Array(text.utf16)
        self.dollarQuotedBlocks = dollarQuotedBlocks
    }

    public static func tokenize(_ text: String) -> [SQLToken] {
        SQLLexer(text).tokens()
    }

    /// Source text of a token (identifier quotes are kept).
    public func text(of token: SQLToken) -> String {
        text(in: token.range)
    }

    public func text(in range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, units.count))
        let upper = max(lower, min(range.upperBound, units.count))
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    /// Identifier value: back-quotes removed and doubled back-quotes unescaped.
    public func identifierValue(of token: SQLToken) -> String {
        let raw = text(of: token)
        guard token.kind == .quotedIdentifier else { return raw }
        var inner = Substring(raw.dropFirst())
        if inner.hasSuffix("`") { inner = inner.dropLast() }
        return inner.replacingOccurrences(of: "``", with: "`")
    }

    public func tokens() -> [SQLToken] {
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(units.count / 4)
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            let start = index
            switch unit {
            case _ where Self.isDropped(unit):
                // Whitespace, and characters StarRocks drops: they separate tokens and hide nothing (`#` is no comment).
                index += 1
                continue
            case 0x2D where peek(index + 1) == 0x2D: // --
                index = endOfLine(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x2F where peek(index + 1) == 0x2A: // /*
                index += 2
                while index < count, !(units[index] == 0x2A && peek(index + 1) == 0x2F) { index += 1 }
                index = min(count, index + 2)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x27, 0x22: // ' or "
                index = endOfQuoted(from: index, quote: unit, backslashEscapes: true)
                tokens.append(SQLToken(kind: .string, range: start..<index))
            case 0x60: // `
                index = endOfQuoted(from: index, quote: unit, backslashEscapes: false)
                tokens.append(SQLToken(kind: .quotedIdentifier, range: start..<index))
            case 0x40: // @ / @@
                index += 1
                if peek(index) == 0x40 { index += 1 }
                if peek(index) == 0x60 {
                    index = endOfQuoted(from: index, quote: 0x60, backslashEscapes: false)
                } else {
                    while index < count, Self.isIdentifierPart(units[index]) || units[index] == 0x2E { index += 1 }
                }
                tokens.append(SQLToken(kind: .variable, range: start..<index))
            case 0x24 where dollarQuotedBlocks && peek(index + 1) == 0x24: // $$ … $$: an inline function body (StarRocks 4.1)
                let (end, isBlock) = endOfDollarWord(from: index)
                index = end
                tokens.append(SQLToken(kind: isBlock ? .string : .identifier, range: start..<index))
            case 0x30...0x39:
                index = endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x2E where peek(index + 1).map(Self.isDigit) == true && !isMemberAccess(tokens, at: index):
                index = endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x28, 0x29, 0x2C, 0x3B, 0x2E: // ( ) , ; .
                index += 1
                tokens.append(SQLToken(kind: .punctuation, range: start..<index))
            default:
                if Self.isIdentifierStart(unit) {
                    while index < count, Self.isIdentifierPart(units[index]) { index += 1 }
                    // Upper-cased like the server, which reads `ın` as IN; consumers that change text (the formatter)
                    // must treat non-ASCII words as names themselves.
                    let word = String(decoding: units[start..<index], as: UTF16.self).uppercased()
                    let kind: SQLToken.Kind = SQLKeywords.all.contains(word) ? .keyword : .identifier
                    tokens.append(SQLToken(kind: kind, range: start..<index))
                } else {
                    index += 1
                    // Combine multi-character operators: <= >= <> != || && := <=> ->
                    while index < count, Self.isOperatorContinuation(units[index]), index - start < 3 { index += 1 }
                    tokens.append(SQLToken(kind: .operator, range: start..<index))
                }
            }
        }
        return tokens
    }

    // MARK: Scanners

    private func peek(_ index: Int) -> UInt16? { index < units.count ? units[index] : nil }

    /// `t.5` is member access, `.5` alone is a number.
    private func isMemberAccess(_ tokens: [SQLToken], at index: Int) -> Bool {
        guard let last = tokens.last, last.range.upperBound == index else { return false }
        return last.kind == .identifier || last.kind == .quotedIdentifier
    }

    private func endOfLine(from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A, units[index] != 0x0D { index += 1 }
        return index
    }

    private func endOfQuoted(from index: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        scanQuoted(from: index, quote: quote, backslashEscapes: backslashEscapes).end
    }

    private func scanQuoted(from index: Int, quote: UInt16, backslashEscapes: Bool) -> (end: Int, closed: Bool) {
        var index = index + 1
        while index < units.count {
            let unit = units[index]
            if backslashEscapes, unit == 0x5C {
                index += 2
                continue
            }
            if unit == quote {
                if peek(index + 1) == quote {
                    index += 2
                    continue
                }
                return (index + 1, true)
            }
            index += 1
        }
        return (units.count, false)
    }

    /// A string, back-quoted identifier or `/* */` comment that runs to the end of the input without
    /// its closing delimiter. Only the last token can be unterminated, so this rescans at most once.
    public func isUnterminated(_ token: SQLToken) -> Bool {
        let start = token.range.lowerBound
        guard token.range.upperBound >= units.count, start >= 0, start < units.count else { return false }
        switch token.kind {
        case .string where units[start] == 0x24: // $$ … $$
            let end = token.range.upperBound
            return token.range.count < 4 || !(units[end - 2] == 0x24 && units[end - 1] == 0x24)
        case .string, .quotedIdentifier:
            return !scanQuoted(from: start, quote: units[start], backslashEscapes: token.kind == .string).closed
        case .comment:
            guard units[start] == 0x2F else { return false } // `--` and `#` comments end at the line end
            let end = token.range.upperBound
            return token.range.count < 4 || !(units[end - 2] == 0x2A && units[end - 1] == 0x2F)
        default:
            return false
        }
    }

    /// A token starting with `$$`, as StarRocks 4.1 reads it: the longer of a name (`$$abc$$`, identifier characters
    /// only) and a `$$ … $$` block kept as one opaque token. An unclosed block runs to the end of the text.
    private func endOfDollarWord(from start: Int) -> (end: Int, isBlock: Bool) {
        var word = start
        while word < units.count, Self.isIdentifierPart(units[word]) { word += 1 }
        var close = start + 2
        while close + 1 < units.count, !(units[close] == 0x24 && units[close + 1] == 0x24) { close += 1 }
        let block = close + 1 < units.count ? close + 2 : units.count
        return block > word ? (block, true) : (word, false)
    }

    /// Where a token starting with a digit (or `.digit`) ends, as StarRocks decides: the longer of a word (a digit or
    /// `.digit` followed by identifier characters: `1abc`, `1e2x`, `0x1F`, `.5x`) and a numeric literal (`1`, `1.`,
    /// `1.5`, `.5`, `1e5`, `1.5e-3`). So `1.5x`, `1.end` and `1e+5x` end after the number and the word that follows is
    /// a token of its own. Checked against live servers by the integration tests.
    private func endOfNumber(from start: Int) -> Int {
        var literal = start
        while literal < units.count, Self.isDigit(units[literal]) { literal += 1 }
        if peek(literal) == 0x2E {
            literal += 1
            while literal < units.count, Self.isDigit(units[literal]) { literal += 1 }
        }
        if let e = peek(literal), e == 0x65 || e == 0x45 {
            var lookahead = literal + 1
            if let sign = peek(lookahead), sign == 0x2B || sign == 0x2D { lookahead += 1 }
            if let digit = peek(lookahead), Self.isDigit(digit) {
                literal = lookahead
                while literal < units.count, Self.isDigit(units[literal]) { literal += 1 }
            }
        }
        var word = units[start] == 0x2E ? start + 1 : start
        while word < units.count, Self.isIdentifierPart(units[word]) { word += 1 }
        return max(literal, word)
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24
            || (unit >= 0x80 && !isSurrogate(unit))
    }

    static func isSurrogate(_ unit: UInt16) -> Bool { unit >= 0xD800 && unit <= 0xDFFF }

    /// Characters StarRocks 3.3 and 4.1 drop outside strings, quoted names and comments: every C0 control (whitespace
    /// included), space, `#`, `\`, DEL and every code point above U+FFFF (a UTF-16 surrogate pair). No token rule
    /// matches them, so they separate tokens and hide nothing. `#` is not a comment over COM_QUERY (the mysql CLI strips
    /// `#` comments itself, which is why it looks like one). Pinned for every code point by the lexer-versus-server
    /// integration test.
    public static func isDropped(_ unit: UInt16) -> Bool {
        unit <= 0x20 || unit == 0x23 || unit == 0x5C || unit == 0x7F || isSurrogate(unit)
    }

    /// Plain layout whitespace: space, tab and line breaks. The other dropped characters are not.
    public static func isLayoutWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    /// Whether a dropped character other than layout whitespace (`#`, `\`, a control character, an emoji, …) stands
    /// outside the tokens. Such text is valid for the server, but a reader (or an older lexer) easily misreads it: the
    /// read-only guard and the formatter refuse it.
    public func containsDroppedCharacters(_ tokens: [SQLToken]) -> Bool {
        var gapStart = 0
        for index in 0...tokens.count {
            let gapEnd = index < tokens.count ? tokens[index].range.lowerBound : units.count
            if gapStart < gapEnd, units[gapStart..<gapEnd].contains(where: { !Self.isLayoutWhitespace($0) }) { return true }
            if index < tokens.count { gapStart = max(gapStart, tokens[index].range.upperBound) }
        }
        return false
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    static func isOperatorContinuation(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x3D, 0x3E, 0x3C, 0x7C, 0x26, 0x21: true // = > < | & !
        default: false
        }
    }
}
