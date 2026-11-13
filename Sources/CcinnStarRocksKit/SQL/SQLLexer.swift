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

    public init(_ text: String) {
        units = Array(text.utf16)
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
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C:
                index += 1
                continue
            case 0x2D where peek(index + 1) == 0x2D: // --
                index = endOfLine(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x23: // # (MySQL line comment)
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
                return index + 1
            }
            index += 1
        }
        return units.count
    }

    private func endOfNumber(from index: Int) -> Int {
        var index = index
        if units[index] == 0x30, let next = peek(index + 1), next == 0x78 || next == 0x58 { // 0x…
            index += 2
            while index < units.count, Self.isHexDigit(units[index]) { index += 1 }
            return index
        }
        while index < units.count, Self.isDigit(units[index]) { index += 1 }
        if peek(index) == 0x2E {
            index += 1
            while index < units.count, Self.isDigit(units[index]) { index += 1 }
        }
        if let e = peek(index), e == 0x65 || e == 0x45 {
            var lookahead = index + 1
            if let sign = peek(lookahead), sign == 0x2B || sign == 0x2D { lookahead += 1 }
            if let digit = peek(lookahead), Self.isDigit(digit) {
                index = lookahead
                while index < units.count, Self.isDigit(units[index]) { index += 1 }
            }
        }
        // `1abc` is an identifier in MySQL; absorb trailing identifier characters into the number token.
        while index < units.count, Self.isIdentifierPart(units[index]) { index += 1 }
        return index
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit >= 0x80
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
