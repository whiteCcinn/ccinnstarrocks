import Foundation

/// A problem marked in the editor text. Offsets are UTF-16 (they map 1:1 onto `NSRange`).
///
/// `range` is the marked text; `scope` is the text it is about. A server diagnostic becomes stale
/// when its scope (the failing statement) is edited — see `SQLTextEdit.adjust(_:)`. A local one only
/// when its marked text is; edits elsewhere in its construct move it until it is re-checked.
public struct SQLDiagnostic: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case error
        case warning
    }

    public enum Source: Sendable, Equatable {
        /// Reported by StarRocks when the statement ran.
        case server
        /// Found locally while typing.
        case local
    }

    public var range: Range<Int>
    public var scope: Range<Int>
    public var severity: Severity
    public var source: Source
    public var message: String
    /// The statement result a server diagnostic came from.
    public var origin: UUID?

    public init(range: Range<Int>, scope: Range<Int>, severity: Severity, source: Source, message: String, origin: UUID? = nil) {
        self.range = range
        self.scope = scope
        self.severity = severity
        self.source = source
        self.message = message
        self.origin = origin
    }

    /// The diagnostic after `edit`, or `nil` when it became stale.
    public func adjusted(by edit: SQLTextEdit) -> SQLDiagnostic? {
        if source == .local { return edit.mapLocal(self) }
        guard let newScope = edit.adjust(scope) else { return nil }
        let (lower, lowOverflow) = range.lowerBound.addingReportingOverflow(newScope.lowerBound - scope.lowerBound)
        let (upper, highOverflow) = range.upperBound.addingReportingOverflow(newScope.lowerBound - scope.lowerBound)
        guard !lowOverflow, !highOverflow, lower >= 0, lower <= upper else { return nil }
        var copy = self
        copy.scope = newScope
        copy.range = lower..<upper
        return copy
    }
}

/// One replacement in the editor: `range` in the text before the edit, replaced by
/// `replacementLength` UTF-16 units, plus what the edit left at its edges (see `made(in:…)`).
public struct SQLTextEdit: Sendable, Equatable {
    public var range: Range<Int>
    public var replacementLength: Int
    /// After the edit, the unit just before `range.lowerBound + replacementLength` — the last inserted
    /// unit, or the one before a deletion — is whitespace or `;` (or the text starts there). An edit
    /// ending exactly at a statement then leaves it a separate token, so the statement only moves.
    public var separatorBeforeEnd: Bool
    /// After the edit, the unit at `range.lowerBound` — the first inserted unit, or the one now after a
    /// deletion — is whitespace or `;` (or the text ends there). An edit starting exactly at a
    /// statement's end then does not extend its last token.
    public var separatorAtStart: Bool
    /// Offsets of line feeds within the inserted text (for `SQLLineIndex`).
    public var insertedLineBreaks: [Int]

    public init(range: Range<Int>, replacementLength: Int, separatorBeforeEnd: Bool = false, separatorAtStart: Bool = false,
                insertedLineBreaks: [Int] = []) {
        self.range = range
        self.replacementLength = replacementLength
        self.separatorBeforeEnd = separatorBeforeEnd
        self.separatorAtStart = separatorAtStart
        self.insertedLineBreaks = insertedLineBreaks
    }

    /// Describes an edit from the text **after** it, as `NSTextStorage` reports it (`editedRange` in the
    /// new text, `changeInLength`). `nil` when the report does not fit the text.
    public static func made(in text: NSString, editedRange: NSRange, changeInLength delta: Int) -> SQLTextEdit? {
        let length = text.length
        let oldLength = editedRange.length - delta
        guard editedRange.location != NSNotFound, editedRange.location >= 0, editedRange.length >= 0, oldLength >= 0,
              editedRange.location <= length, editedRange.length <= length - editedRange.location else { return nil }
        func isSeparator(_ index: Int) -> Bool {
            guard index >= 0, index < length else { return true }
            switch text.character(at: index) {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x3B: return true
            default: return false
            }
        }
        var breaks: [Int] = []
        for offset in 0..<editedRange.length where text.character(at: editedRange.location + offset) == 0x0A {
            breaks.append(offset)
        }
        return SQLTextEdit(range: editedRange.location..<(editedRange.location + oldLength), replacementLength: editedRange.length,
                           separatorBeforeEnd: isSeparator(editedRange.location + editedRange.length - 1),
                           separatorAtStart: isSeparator(editedRange.location), insertedLineBreaks: breaks)
    }

    var isValid: Bool { range.lowerBound >= 0 && replacementLength >= 0 }
    var delta: Int { replacementLength - range.count }

    /// `tracked` (a statement) after this edit:
    /// - shifted when the edit ends before it, or exactly at its start leaving a separator before it;
    /// - unchanged when the edit starts after it, or exactly at its end leaving a separator after it;
    /// - `nil` otherwise: the statement's text changed (or a token was glued onto it). Invalid edits give `nil`.
    public func adjust(_ tracked: Range<Int>) -> Range<Int>? {
        guard isValid else { return nil }
        if range.upperBound < tracked.lowerBound || (range.upperBound == tracked.lowerBound && separatorBeforeEnd) {
            let (lower, lowOverflow) = tracked.lowerBound.addingReportingOverflow(delta)
            let (upper, highOverflow) = tracked.upperBound.addingReportingOverflow(delta)
            guard !lowOverflow, !highOverflow, lower >= 0 else { return nil }
            return lower..<upper
        }
        if range.lowerBound > tracked.upperBound || (range.lowerBound == tracked.upperBound && separatorAtStart) { return tracked }
        return nil
    }

    /// A local diagnostic after this edit: dropped only when its marked text is edited; otherwise its
    /// bounds move with the text (an insertion at its start goes before it, at its end after it), and
    /// its scope stretches over edits inside it until the text is checked again.
    func mapLocal(_ diagnostic: SQLDiagnostic) -> SQLDiagnostic? {
        guard isValid else { return nil }
        let marked = diagnostic.range
        let overlaps = range.lowerBound < marked.upperBound && range.upperBound > marked.lowerBound
        let insertsInside = range.isEmpty && marked.lowerBound < range.lowerBound && range.lowerBound < marked.upperBound
        guard !overlaps, !insertsInside,
              let lower = mapLowerBound(marked.lowerBound), let upper = mapUpperBound(marked.upperBound), lower <= upper,
              let scopeLower = mapLowerBound(diagnostic.scope.lowerBound), let scopeUpper = mapUpperBound(diagnostic.scope.upperBound)
        else { return nil }
        var copy = diagnostic
        copy.range = lower..<upper
        copy.scope = min(scopeLower, lower)..<max(scopeUpper, upper)
        return copy
    }

    /// A position that starts something: an insertion at it goes before it.
    private func mapLowerBound(_ position: Int) -> Int? {
        if position < range.lowerBound { return position }
        if position >= range.upperBound {
            let (moved, overflow) = position.addingReportingOverflow(delta)
            return overflow || moved < 0 ? nil : moved
        }
        return range.lowerBound + replacementLength
    }

    /// A position that ends something: an insertion at it goes after it.
    private func mapUpperBound(_ position: Int) -> Int? {
        if position <= range.lowerBound { return position }
        return mapLowerBound(position)
    }
}

/// Keeps diagnostics on the text they describe while the user edits.
public enum SQLDiagnosticTracker {
    /// Applies `edits` in order (each is relative to the text after the previous one).
    public static func apply(_ edits: [SQLTextEdit], to diagnostics: [SQLDiagnostic]) -> [SQLDiagnostic] {
        var current = diagnostics
        for edit in edits {
            if current.isEmpty { break }
            current = current.compactMap { $0.adjusted(by: edit) }
        }
        return current
    }

    /// Applies `edits` in order to optional ranges; a range an edit touches becomes `nil`.
    public static func apply(_ edits: [SQLTextEdit], to ranges: [Range<Int>?]) -> [Range<Int>?] {
        var current = ranges
        for edit in edits {
            current = current.map { $0.flatMap(edit.adjust) }
        }
        return current
    }
}

/// Structural checks that need no server: unterminated quotes and comments, unbalanced parentheses.
/// One lexer pass, linear in the text.
public enum SQLLinter {
    public static let maximumDiagnostics = 50
    /// Same bound as the editor's highlighting; larger scripts are not checked.
    public static let maximumLength = 4_000_000

    /// `dollarQuotedBlocks`: the connected server reads `$$ … $$` as one block (StarRocks 4.1), so nothing inside one
    /// is checked.
    public static func diagnose(_ text: String, dollarQuotedBlocks: Bool = false) -> [SQLDiagnostic] {
        let lexer = SQLLexer(text, dollarQuotedBlocks: dollarQuotedBlocks)
        let length = lexer.units.count
        guard length > 0, length <= maximumLength else { return [] }
        var diagnostics: [SQLDiagnostic] = []
        var openParentheses: [Int] = []
        var statementStart = 0
        var quoteRunsToEnd = false

        func add(_ range: Range<Int>, scope: Range<Int>, _ severity: SQLDiagnostic.Severity, _ message: String) {
            guard diagnostics.count < maximumDiagnostics else { return }
            diagnostics.append(SQLDiagnostic(range: range, scope: scope, severity: severity, source: .local, message: message))
        }
        func endStatement(at end: Int) {
            // A closing parenthesis may sit inside an unterminated quote: report the quote only.
            if !quoteRunsToEnd {
                for open in openParentheses {
                    add(open..<(open + 1), scope: open..<max(open + 1, end), .error, "'(' is not closed")
                }
            }
            openParentheses.removeAll()
        }

        for token in lexer.tokens() {
            if diagnostics.count >= maximumDiagnostics { break }
            let start = token.range.lowerBound
            switch token.kind {
            case .punctuation:
                switch lexer.units[start] {
                case 0x3B: // ;
                    endStatement(at: start)
                    statementStart = token.range.upperBound
                case 0x28: // (
                    openParentheses.append(start)
                case 0x29: // )
                    if openParentheses.popLast() == nil {
                        add(token.range, scope: min(statementStart, start)..<token.range.upperBound, .error, "Unmatched ')': there is no matching '(' before it")
                    }
                default:
                    break
                }
            case .string, .quotedIdentifier:
                guard lexer.isUnterminated(token) else { break }
                quoteRunsToEnd = true
                let quote = lexer.units[start] == 0x24 ? "$$" : String(decoding: [lexer.units[start]], as: UTF16.self)
                let what = token.kind == .string ? "string" : "quoted identifier"
                add(start..<(start + 1), scope: start..<length, .error, "Unterminated \(what): add the closing \(quote)")
            case .comment:
                // StarRocks rejects it (`Unexpected input '*'`); it does not ignore the rest.
                guard lexer.isUnterminated(token) else { break }
                add(start..<min(start + 2, token.range.upperBound), scope: start..<length, .error,
                    "Unterminated comment: add the closing */")
            default:
                break
            }
        }
        endStatement(at: length)
        return diagnostics.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}

/// A 1-based line and column (columns count Unicode code points, as StarRocks does).
public struct SQLTextPosition: Sendable, Equatable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    /// Position of a UTF-16 offset (clamped to the text).
    public static func lineAndColumn(of offset: Int, in text: String) -> SQLTextPosition {
        var line = 1
        var column = 1
        var remaining = max(0, offset)
        for unit in text.utf16 {
            if remaining == 0 { break }
            remaining -= 1
            if unit == 0x0A {
                line += 1
                column = 1
            } else if !UTF16.isTrailSurrogate(unit) {
                column += 1
            }
        }
        return SQLTextPosition(line: line, column: column)
    }
}

/// Line starts of a text, kept up to date edit by edit, so positions are found without scanning the
/// text (`position(of:in:)` is O(log lines + line length)).
public struct SQLLineIndex: Sendable, Equatable {
    /// UTF-16 offsets where lines start; the first is 0.
    public private(set) var lineStarts: [Int]
    /// UTF-16 length of the text.
    public private(set) var length: Int

    public init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        length = offset
    }

    /// Applies an edit made by `SQLTextEdit.made(in:…)`. Returns `false` (and changes nothing) when the
    /// edit does not fit; the caller then rebuilds the index from the text.
    @discardableResult
    public mutating func apply(_ edit: SQLTextEdit) -> Bool {
        let range = edit.range
        guard edit.isValid, range.upperBound <= length,
              edit.insertedLineBreaks.allSatisfy({ $0 >= 0 && $0 < edit.replacementLength }) else { return false }
        let delta = edit.delta
        // A start `s` follows a line feed at `s - 1`; those inside the replaced range disappear.
        let removedFrom = firstIndex(after: range.lowerBound)
        let removedTo = firstIndex(after: range.upperBound)
        var updated: [Int] = []
        updated.reserveCapacity(lineStarts.count - (removedTo - removedFrom) + edit.insertedLineBreaks.count)
        updated.append(contentsOf: lineStarts[..<removedFrom])
        updated.append(contentsOf: edit.insertedLineBreaks.sorted().map { range.lowerBound + $0 + 1 })
        updated.append(contentsOf: lineStarts[removedTo...].lazy.map { $0 + delta })
        lineStarts = updated
        length += delta
        return true
    }

    /// 1-based line and code-point column of a UTF-16 offset (clamped to the text).
    public func position(of offset: Int, in text: NSString) -> SQLTextPosition {
        let target = min(max(0, offset), min(length, text.length))
        let lineIndex = max(0, firstIndex(after: target) - 1)
        let start = min(lineStarts[lineIndex], target)
        var column = 1
        var index = start
        while index < target {
            if !UTF16.isTrailSurrogate(text.character(at: index)) { column += 1 }
            index += 1
        }
        return SQLTextPosition(line: lineIndex + 1, column: column)
    }

    /// Index of the first line start greater than `offset`.
    private func firstIndex(after offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Which diagnostic the cursor is on, for the editor's diagnostics bar.
public enum SQLDiagnosticNavigator {
    /// `preferred` when it starts at the cursor (the one just navigated to); else the first starting at
    /// the cursor; else the innermost containing it; else the one ending at it; else the next after it;
    /// else the last. Adjacent and nested diagnostics stay reachable with Next / Previous.
    public static func currentIndex(in diagnostics: [SQLDiagnostic], cursor: Int, preferred: SQLDiagnostic? = nil) -> Int? {
        guard !diagnostics.isEmpty else { return nil }
        if let preferred, preferred.range.lowerBound == cursor, let index = diagnostics.firstIndex(of: preferred) { return index }
        if let index = diagnostics.firstIndex(where: { $0.range.lowerBound == cursor }) { return index }
        if let index = diagnostics.lastIndex(where: { $0.range.lowerBound <= cursor && cursor < $0.range.upperBound }) { return index }
        if let index = diagnostics.lastIndex(where: { $0.range.upperBound == cursor }) { return index }
        return diagnostics.firstIndex { $0.range.lowerBound > cursor } ?? diagnostics.count - 1
    }
}
