import Foundation
import Testing
@testable import CcinnStarRocksKit

/// Text of a UTF-16 range (what the editor would underline).
private func slice(_ text: String, _ range: Range<Int>?) -> String? {
    guard let range else { return nil }
    let units = Array(text.utf16)
    guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
    return String(decoding: units[range], as: UTF16.self)
}

private func utf16Offset(of needle: String, in text: String) -> Int {
    (text as NSString).range(of: needle).location
}

// Messages recorded from StarRocks 3.3 and 4.1 (identical on both).
private enum Recorded {
    static let unexpectedShop = "Getting syntax error at line 1, column 14. Detail message: Unexpected input 'shop', the most similar input is {<EOF>, ';'}."
    static let absRange = "Getting analyzing error from line 1, column 7 to line 1, column 16. Detail message: No matching function with signature: abs(tinyint(4), tinyint(4), tinyint(4))."
    static let qualifiedColumn = "Getting analyzing error. Detail message: Column '`o`.`x`' cannot be resolved."
    static let eof = "Getting syntax error at line 1, column 28. Detail message: Unexpected input '<EOF>', the most similar input is {a legal identifier}."
    static let noViable = "Getting syntax error at line 1, column 38. Detail message: No viable statement for input '(1 = 1'."
}

@Suite("Server error parsing")
struct ServerErrorParsingTests {
    @Test func syntaxErrorWithStart() {
        let error = SQLServerError.parse(Recorded.unexpectedShop + " (error 1064)")
        #expect(error.phase == .syntax)
        #expect(error.start == SQLServerError.Position(line: 1, column: 14))
        #expect(error.end == nil)
        #expect(error.detail == "Unexpected input 'shop', the most similar input is {<EOF>, ';'}")
        #expect(error.names.isEmpty)
    }

    @Test func analysisErrorWithRange() {
        let error = SQLServerError.parse(Recorded.absRange)
        #expect(error.phase == .analysis)
        #expect(error.start == SQLServerError.Position(line: 1, column: 7))
        #expect(error.end == SQLServerError.Position(line: 1, column: 16))
        #expect(error.detail.hasPrefix("No matching function with signature: abs("))
    }

    @Test func otherErrorKeepsTheWholeMessage() {
        let error = SQLServerError.parse("table orders does not support update")
        #expect(error.phase == .other)
        #expect(error.start == nil)
        #expect(error.detail == "table orders does not support update")
    }

    @Test(arguments: [
        (Recorded.qualifiedColumn, [["o", "x"]]),
        ("Getting analyzing error. Detail message: Column 'NOSUCH' cannot be resolved.", [["NOSUCH"]]),
        ("Getting analyzing error. Detail message: Column '`nosuch col`' cannot be resolved.", [["nosuch col"]]),
        ("Getting analyzing error. Detail message: Column 'city' is ambiguous.", [["city"]]),
        ("Getting analyzing error. Detail message: Unknown column 'nosuch' in 'orders'.", [["nosuch"]]),
        ("Getting analyzing error. Detail message: Unknown table 'shop.nosuch'.", [["shop", "nosuch"]]),
        ("Getting analyzing error. Detail message: Table nosuch is not found.", [["nosuch"]]),
        ("Unknown database 'nosuchdb'", [["nosuchdb"]]),
        ("Getting analyzing error. Detail message: Unknown catalog 'nosuchcat'.", [["nosuchcat"]]),
        ("Getting analyzing error. Detail message: Key column(b) doesn't exist..", [["b"]]),
        ("Getting analyzing error. Detail message: Column '`we``ird`' cannot be resolved.", [["we`ird"]]),
    ])
    func namesInMessages(message: String, expected: [[String]]) {
        #expect(SQLServerError.parse(message).names == expected)
    }

    @Test func detailDropsTrailingPeriodsAndErrorCode() {
        #expect(SQLServerError.parse("Getting analyzing error. Detail message: Key column(b) doesn't exist.. (error 1064)").detail == "Key column(b) doesn't exist")
    }

    @Test func backQuotedNamesReadPlainlyInTheDetail() {
        let error = SQLServerError.parse(Recorded.qualifiedColumn)
        #expect(error.summary == "Column 'o.x' cannot be resolved")
        #expect(error.names == [["o", "x"]])
        #expect(SQLServerError.parse("at line 1, column 7. Detail message: '`shop`.`orders`.`order_id`' must be an aggregate expression.").summary
            == "'shop.orders.order_id' must be an aggregate expression")
        // Quoting that carries meaning is kept.
        #expect(SQLServerError.parse("Detail message: Column '`a.b`' cannot be resolved.").summary == "Column '`a.b`' cannot be resolved")
        #expect(SQLServerError.parse("Detail message: Column '`a.b`' cannot be resolved.").names == [["a.b"]])
    }

    // Review #1: StarRocks groups digits by the FE's JVM locale (`1,501`; `1.214`, `1 214`, `1 214` elsewhere).
    @Test(arguments: [
        ("Getting syntax error at line 1,501, column 5. Detail message: x", 1501, 5, nil as Int?),
        ("Getting syntax error at line 1, column 1,214. Detail message: Unexpected input 'shop'", 1, 1214, nil),
        ("Getting analyzing error from line 1, column 1,207 to line 1, column 1,216. Detail message: x", 1, 1207, 1216),
        ("Getting syntax error at line 1, column 200,038. Detail message: x", 1, 200_038, nil),
        ("Getting syntax error at line 1, column 1.214. Detail message: x", 1, 1214, nil),
        ("Getting syntax error at line 1, column 1\u{00A0}214. Detail message: x", 1, 1214, nil),
        ("Getting syntax error at line 1, column 1\u{202F}214. Detail message: x", 1, 1214, nil),
        ("Getting syntax error at line 1, column 7. Detail message: x", 1, 7, nil),
        ("Getting syntax error at line 12, column 1234. Detail message: x", 12, 1234, nil),
    ])
    func groupedDigits(message: String, line: Int, column: Int, endColumn: Int?) {
        let error = SQLServerError.parse(message)
        #expect(error.start == SQLServerError.Position(line: line, column: column))
        #expect(error.end?.column == endColumn)
    }

    // Review #7: huge echoed statements are summarised; names and positions come from the head.
    @Test func longMessagesAreSummarised() {
        let echo = String(repeating: "x ", count: 100_000)
        let error = SQLServerError.parse("Getting syntax error at line 1, column 3. Detail message: No viable statement for input '\(echo)'.")
        #expect(error.start == SQLServerError.Position(line: 1, column: 3))
        #expect(error.summary.count <= SQLServerError.summaryLimit + 1)
        #expect(error.summary.hasSuffix("…"))
        #expect(error.detail.count > 100_000) // kept whole for locating the input
        #expect(SQLServerError.parse("Getting analyzing error. Detail message: Column 'nosuch' cannot be resolved.").summary == "Column 'nosuch' cannot be resolved")
    }

    // Review #9: without an editor position the title has no (statement-relative) position.
    @Test func titleUsesOnlyEditorPositions() {
        let error = SQLServerError.parse("Getting syntax error at line 2, column 3. Detail message: x")
        #expect(error.title(at: nil) == "Syntax error")
        #expect(error.title(at: SQLTextPosition(line: 11, column: 4)) == "Syntax error at line 11, column 4")
    }

    @Test func overflowingNumbersAreIgnored() {
        let error = SQLServerError.parse("at line 99999999999999999999, column 1")
        #expect(error.start == nil)
    }
}

@Suite("Error location")
struct ErrorLocatorTests {
    @Test func mapsLineAndColumn() {
        let statement = "SELECT *\nFROM shop.orders WHERE order_id = = 1"
        let message = "Getting syntax error at line 2, column 32. Detail message: Unexpected input '='"
        let offset = SQLErrorLocator.offset(in: statement, message: message)
        #expect(offset == 9 + 32)
        #expect(SQLErrorLocator.offset(in: "select 1", message: "Unknown table") == nil)
        #expect(SQLErrorLocator.offset(in: "select 1", message: "at line 9, column 1") == nil)
        #expect(SQLErrorLocator.offset(in: "select 1", message: "at line 1, column 99") == 8)
    }

    @Test func columnsAreCodePoints() {
        // StarRocks reports column 20 (code points); the flag is 4 UTF-16 units.
        let statement = "SELECT '🇲🇾', 1 FORM shop.orders"
        let message = "Getting syntax error at line 1, column 20. Detail message: Unexpected input 'shop'"
        #expect(SQLErrorLocator.offset(in: statement, message: message) == utf16Offset(of: "shop", in: statement))
        #expect(slice(statement, SQLErrorLocator.range(in: statement, message: message)) == "shop")
        let cjk = "SELECT '吉隆坡', 1 FORM t"
        #expect(slice(cjk, SQLErrorLocator.range(in: cjk, message: "at line 1, column 21")) == "t")
    }

    @Test func positionExpandsToItsToken() {
        #expect(slice("SELECT 1 FORM shop.orders", SQLErrorLocator.range(in: "SELECT 1 FORM shop.orders", message: Recorded.unexpectedShop)) == "shop")
        let sql = "SELECT\n  order_id,\n  nosuch\nFROM shop.orders WHERE order_id = = 1"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: "Getting syntax error at line 4, column 34. Detail message: Unexpected input '='")) == "=")
    }

    @Test func rangeEndsAfterItsLastToken() {
        let sql = "SELECT abs(1,2,3) FROM t"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: Recorded.absRange)) == "abs(1,2,3)")
        let multi = "SELECT nosuchfunc(\n  1,\n  2) FROM t"
        let message = "Getting analyzing error from line 1, column 7 to line 3, column 3. Detail message: No matching function"
        #expect(slice(multi, SQLErrorLocator.range(in: multi, message: message)) == "nosuchfunc(\n  1,\n  2)")
    }

    @Test func endOfInputMarksTheLastToken() {
        let sql = "SELECT 'abc FROM shop.orders"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: Recorded.eof)) == "'abc FROM shop.orders")
        let whitespace = "SELECT 1 FROM   "
        #expect(slice(whitespace, SQLErrorLocator.range(in: whitespace, message: "at line 1, column 16")) == "FROM")
    }

    @Test func noViableInputMarksThatInput() {
        let sql = "SELECT 1 FROM shop.orders WHERE (1 = 1"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: Recorded.noViable)) == "(1 = 1")
    }

    // Review #1: positions beyond 999 must not be read as their first digit group.
    @Test func groupedPositionsLocateTheRightToken() {
        let wide = "SELECT " + String(repeating: " ", count: 1200) + "1 FORM shop.orders"
        #expect(slice(wide, SQLErrorLocator.range(in: wide, message: "Getting syntax error at line 1, column 1,214. Detail message: Unexpected input 'shop'")) == "shop")
        let tall = "SELECT 1" + String(repeating: "\n", count: 1500) + "FORM shop.orders"
        #expect(slice(tall, SQLErrorLocator.range(in: tall, message: "Getting syntax error at line 1,501, column 5. Detail message: Unexpected input 'shop'")) == "shop")
        let ranged = "SELECT " + String(repeating: " ", count: 1200) + "abs(1,2,3) FROM shop.orders"
        #expect(slice(ranged, SQLErrorLocator.range(in: ranged, message: "Getting analyzing error from line 1, column 1,207 to line 1, column 1,216. Detail message: x")) == "abs(1,2,3)")
    }

    // Review #4: the server stops at an unterminated comment; mark its `/*`, not the token before.
    @Test func positionsInsideAnUnterminatedCommentMarkIt() {
        #expect(slice("SELECT 1 /* x", SQLErrorLocator.range(in: "SELECT 1 /* x", message: "Getting syntax error at line 1, column 10. Detail message: Unexpected input '*'")) == "/*")
        let sql = "SELECT * FROM shop.orders /* note"
        #expect(slice(sql, SQLErrorLocator.range(in: sql, message: "Getting syntax error at line 1, column 26. Detail message: Unexpected input '/'")) == "/*")
        // A terminated comment is still skipped.
        let closed = "SELECT 1 /* c */ FORM t"
        #expect(slice(closed, SQLErrorLocator.range(in: closed, message: "at line 1, column 22")) == "t")
    }

    @Test func noViableInputPicksTheOccurrenceAtThePosition() {
        // Many earlier occurrences must neither be chosen nor make the search quadratic.
        let sql = "SELECT " + String(repeating: "(1, ", count: 20_000) + "1 FROM t WHERE (1"
        let column = (sql as NSString).length
        let range = SQLErrorLocator.range(in: sql, message: "Getting syntax error at line 1, column \(column). Detail message: No viable statement for input '(1'.")
        #expect(range == (column - 2)..<column)
    }

    @Test(arguments: [
        ("SELECT o.x FROM shop.orders o", Recorded.qualifiedColumn, "o.x"),
        ("SELECT `o` . `x` FROM shop.orders o", Recorded.qualifiedColumn, "`o` . `x`"),
        ("select Order_ID, NOSUCH from shop.orders", "Getting analyzing error. Detail message: Column 'NOSUCH' cannot be resolved.", "NOSUCH"),
        ("SELECT nosuch FROM t", "Getting analyzing error. Detail message: Column 'NOSUCH' cannot be resolved.", "nosuch"),
        ("SELECT * FROM nosuch", "Getting analyzing error. Detail message: Unknown table 'shop.nosuch'.", "nosuch"),
        ("SELECT * FROM shop.nosuch n", "Getting analyzing error. Detail message: Unknown table 'shop.nosuch'.", "shop.nosuch"),
        ("SELECT `nosuch col` FROM t", "Getting analyzing error. Detail message: Column '`nosuch col`' cannot be resolved.", "`nosuch col`"),
        ("DESC shop.nosuch", "Getting analyzing error. Detail message: Table nosuch is not found.", "nosuch"),
        ("SELECT * FROM nosuchdb.t", "Unknown database 'nosuchdb'", "nosuchdb"),
        ("SELECT 吉 FROM shop.orders", "Getting analyzing error. Detail message: Column '吉' cannot be resolved.", "吉"),
        ("SELECT c.city FROM shop.orders o", "Getting analyzing error. Detail message: Column '`c`.`city`' cannot be resolved.", "c.city"),
    ])
    func namedIdentifiers(statement: String, message: String, expected: String) {
        #expect(slice(statement, SQLErrorLocator.range(in: statement, message: message)) == expected)
    }

    @Test func namesInsideStringsAndCommentsAreSkipped() {
        let sql = "SELECT 'nosuch', /* nosuch */ nosuch FROM t"
        let range = SQLErrorLocator.range(in: sql, message: "Getting analyzing error. Detail message: Column 'nosuch' cannot be resolved.")
        #expect(range?.lowerBound == utf16Offset(of: " nosuch FROM", in: sql) + 1)
    }

    @Test func unknownNamesAndMessagesGiveNoRange() {
        #expect(SQLErrorLocator.range(in: "SELECT 1", message: "Getting analyzing error. Detail message: Column 'zzz' cannot be resolved.") == nil)
        #expect(SQLErrorLocator.range(in: "SELECT 1", message: "Operands have unequal number of columns.") == nil)
        #expect(SQLErrorLocator.range(in: "", message: "at line 1, column 0") == nil)
    }

    @Test func explainPrefixMapsBack() {
        let source = "SELECT 1 FORM shop.orders"
        let executed = "EXPLAIN COSTS " + source
        let mapping = SQLExecutedTextMapping(prefixLength: ("EXPLAIN COSTS " as NSString).length)
        let error = SQLServerError.parse("Getting syntax error at line 1, column 28. Detail message: Unexpected input 'shop'")
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: executed, mapping: mapping, error: error)) == "shop")
    }

    @Test func autoLimitInsertionMapsBack() {
        let source = "SELECT * FROM nosuch -- note"
        let outcome = AutoLimit.apply(to: source, limit: 10)
        #expect(outcome.applied)
        #expect(outcome.insertion == utf16Offset(of: " -- note", in: source)..<(utf16Offset(of: " -- note", in: source) + (" LIMIT 10" as NSString).length))
        let mapping = SQLExecutedTextMapping(insertion: outcome.insertion)
        // A position inside the inserted LIMIT maps to the insertion point (the last source token).
        let inside = SQLServerError.parse("Getting syntax error at line 1, column 22. Detail message: x")
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: outcome.sql, mapping: mapping, error: inside)) == "nosuch")
        #expect(mapping.sourceOffset(forExecuted: (outcome.sql as NSString).length) == (source as NSString).length)
        #expect(AutoLimit.apply(to: "SELECT 1 LIMIT 3", limit: 10).insertion == nil)
    }
}

@Suite("Error location bounds")
struct ErrorLocatorBoundsTests {
    @Test func hugeColumnsDoNotOverflow() {
        let statement = "USE\n`x`"
        #expect(SQLErrorLocator.offset(in: statement, message: "at line 2, column 9223372036854775807") == statement.utf16.count)
        #expect(SQLErrorLocator.offset(in: statement, message: "at line 99999999999999999999, column 1") == nil)
        #expect(SQLErrorLocator.range(in: statement, message: "from line 2, column 9223372036854775807 to line 2, column 9223372036854775807") != nil)
        // A reversed range falls back to its start.
        #expect(slice("SELECT abc", SQLErrorLocator.range(in: "SELECT abc", message: "from line 1, column 7 to line 1, column 2")) == "abc")
    }

    @Test func mappingNeverGoesNegative() {
        let mapping = SQLExecutedTextMapping(prefixLength: 8, insertion: 20..<29)
        #expect(mapping.sourceOffset(forExecuted: 0) == 0)
        #expect(mapping.sourceOffset(forExecuted: Int.max) == Int.max - 9 - 8)
        #expect(mapping.sourceOffset(forExecuted: 25) == 12)
    }
}

@Suite("Local checks")
struct LinterTests {
    private func lint(_ text: String) -> [(SQLDiagnostic.Severity, String, String)] {
        SQLLinter.diagnose(text).map { ($0.severity, slice(text, $0.range) ?? "?", $0.message) }
    }

    @Test func unclosedParenthesis() {
        let found = lint("SELECT count(1 FROM t")
        #expect(found.count == 1)
        #expect(found.first?.0 == .error)
        #expect(found.first?.1 == "(")
        #expect(found.first?.2.contains("not closed") == true)
    }

    @Test func unmatchedClosingParenthesis() {
        let found = lint("SELECT 1)")
        #expect(found.map(\.1) == [")"])
        #expect(found.first?.2.contains("no matching") == true)
    }

    @Test func parenthesesArePerStatement() {
        let text = "SELECT (1; SELECT 2)"
        let diagnostics = SQLLinter.diagnose(text)
        #expect(diagnostics.map { slice(text, $0.range) } == ["(", ")"])
        #expect(diagnostics.first?.scope == 7..<9)
    }

    @Test func unterminatedQuotes() {
        #expect(lint("SELECT 'abc").map { [$0.1, $0.2] } == [["'", "Unterminated string: add the closing '"]])
        #expect(lint("SELECT \"abc").map(\.1) == ["\""])
        #expect(lint("SELECT `abc").map(\.2) == ["Unterminated quoted identifier: add the closing `"])
        #expect(lint("SELECT 'a\\").map(\.1) == ["'"])
    }

    @Test func unterminatedQuoteSuppressesParenthesisNoise() {
        #expect(lint("SELECT count('abc)").map(\.1) == ["'"])
    }

    // Review #4: StarRocks rejects an unterminated comment (`Unexpected input '*'`); it is not ignored.
    @Test func unterminatedBlockCommentIsAnError() {
        let found = lint("SELECT 1 /* note")
        #expect(found.map(\.0) == [.error])
        #expect(found.map(\.1) == ["/*"])
        #expect(found.map(\.2) == ["Unterminated comment: add the closing */"])
        #expect(lint("SELECT 1 /*/").map(\.0) == [.error])
    }

    @Test(arguments: ["SELECT 'it''s', \"a\\\"b\", (1), `x``y` FROM t", "SELECT 1 -- (", "/**/ SELECT (1)", "SELECT ')' FROM t", "", "SELECT 1 # )"])
    func cleanTextHasNoDiagnostics(text: String) {
        #expect(SQLLinter.diagnose(text).isEmpty)
    }

    @Test func diagnosticsAreCapped() {
        let text = String(repeating: ")", count: 500)
        #expect(SQLLinter.diagnose(text).count == SQLLinter.maximumDiagnostics)
    }

    @Test func localDiagnosticsAreMarkedAsLocal() {
        #expect(SQLLinter.diagnose("SELECT (").allSatisfy { $0.source == .local })
    }
}

@Suite("Diagnostic edit tracking")
struct DiagnosticTrackingTests {
    private let diagnostic = SQLDiagnostic(range: 10..<14, scope: 5..<20, severity: .error, source: .server, message: "m")

    private func apply(_ edits: SQLTextEdit...) -> SQLDiagnostic? {
        SQLDiagnosticTracker.apply(edits, to: [diagnostic]).first
    }

    @Test func editBeforeShifts() {
        let moved = apply(SQLTextEdit(range: 0..<0, replacementLength: 3))
        #expect(moved?.range == 13..<17)
        #expect(moved?.scope == 8..<23)
    }

    // Review #3: at the scope's edges, what the edit leaves next to the statement decides.
    @Test func separatedInsertionAtScopeStartShifts() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 2, separatorBeforeEnd: true))?.range == 12..<16)
    }

    @Test func gluedInsertionAtScopeStartDrops() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 1, separatorBeforeEnd: false)) == nil)
    }

    @Test func deletionEndingAtScopeStart() {
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: true))?.scope == 2..<17)
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: false)) == nil)
    }

    @Test func separatedInsertionAtScopeEndKeeps() {
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: true)) == diagnostic)
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: false)) == nil)
    }

    @Test func editAfterKeeps() {
        #expect(apply(SQLTextEdit(range: 21..<21, replacementLength: 1)) == diagnostic)
    }

    @Test(arguments: [SQLTextEdit(range: 12..<12, replacementLength: 1), SQLTextEdit(range: 20..<20, replacementLength: 1),
                      SQLTextEdit(range: 3..<6, replacementLength: 1), SQLTextEdit(range: 19..<25, replacementLength: 0),
                      SQLTextEdit(range: 0..<100, replacementLength: 0), SQLTextEdit(range: 6..<6, replacementLength: 1, separatorBeforeEnd: true)])
    func editTouchingTheScopeDrops(edit: SQLTextEdit) {
        #expect(SQLDiagnosticTracker.apply([edit], to: [diagnostic]).isEmpty)
    }

    @Test func sequencesApplyInOrder() {
        let roundTrip = apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 0..<3, replacementLength: 0))
        #expect(roundTrip == diagnostic)
        #expect(apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 14..<14, replacementLength: 1)) == nil)
    }

    @Test func rangeEditTracksASingleRange() {
        #expect(SQLTextEdit(range: 0..<0, replacementLength: 4).adjust(6..<9) == 10..<13)
        #expect(SQLTextEdit(range: 7..<7, replacementLength: 4).adjust(6..<9) == nil)
    }

    @Test func malformedEditsDrop() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<0, replacementLength: -5)], to: [diagnostic]).isEmpty)
    }

    // Review #3, from real text: the edit is described from the text after it.
    @Test func editsDescribedFromTheEditedText() throws {
        // `SELECT 1;SELECT x FORM t`, type `x` at 9 → `xSELECT`: glued onto the statement.
        let glued = try #require(SQLTextEdit.made(in: "SELECT 1;xSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(!glued.separatorBeforeEnd)
        #expect(glued.adjust(9..<24) == nil)
        // Return at the start of the statement: it moves down.
        let newline = try #require(SQLTextEdit.made(in: "SELECT 1;\nSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(newline.adjust(9..<24) == 10..<25)
        // Return right after the last token (no `;`): the statement keeps its marker.
        let after = try #require(SQLTextEdit.made(in: "SELECT x FORM t\n", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(after.separatorAtStart)
        #expect(after.adjust(0..<15) == 0..<15)
        #expect(after.insertedLineBreaks == [0])
        // Typing right after the last token extends it.
        let typed = try #require(SQLTextEdit.made(in: "SELECT x FORM tx", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(typed.adjust(0..<15) == nil)
        // Deleting the `;` between two statements glues them.
        let merged = try #require(SQLTextEdit.made(in: "SELECT 1SELECT x", editedRange: NSRange(location: 8, length: 0), changeInLength: -1))
        #expect(merged.range == 8..<9)
        #expect(merged.adjust(9..<16) == nil)
        // Inconsistent reports are refused.
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 2, length: 5), changeInLength: 0) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 1, length: 1), changeInLength: 3) == nil)
    }
}

// Review #2/#6: local checks move with edits inside their construct instead of blinking.
@Suite("Local diagnostic tracking")
struct LocalTrackingTests {
    private let local = SQLDiagnostic(range: 12..<13, scope: 12..<20, severity: .error, source: .local, message: "'(' is not closed")

    @Test func typingInsideTheScopeKeepsTheMarker() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 15..<15, replacementLength: 1)], to: [local]).first
        #expect(moved?.range == 12..<13)
        #expect(moved?.scope == 12..<21)
    }

    @Test func typingRightAfterTheMarkKeepsIt() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 13..<13, replacementLength: 2)], to: [local]).first?.range == 12..<13)
    }

    @Test func insertionBeforeTheMarkShiftsIt() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 12..<12, replacementLength: 2)], to: [local]).first
        #expect(moved?.range == 14..<15)
        #expect(moved?.scope == 14..<22)
    }

    @Test func editingTheMarkedTextDrops() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 11..<13, replacementLength: 0)], to: [local]).isEmpty)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<Int.max, replacementLength: 0)], to: [local]).isEmpty)
    }
}

// Review #5: Next/Previous must not get stuck on adjacent or nested diagnostics.
@Suite("Diagnostic navigation")
struct NavigationTests {
    @Test func adjacentDiagnosticsAreReachable() {
        let text = "SELECT count((a FROM t"
        let diagnostics = SQLLinter.diagnose(text)
        #expect(diagnostics.map(\.range) == [12..<13, 13..<14])
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 12) == 0)
        // Next selects #2, whose start is the new cursor.
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 13) == 1)
    }

    @Test func preferenceResolvesTies() {
        let a = SQLDiagnostic(range: 5..<9, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 5..<6, scope: 5..<20, severity: .error, source: .local, message: "b")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5, preferred: b) == 1)
    }

    @Test func cursorPositions() {
        let a = SQLDiagnostic(range: 2..<10, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 4..<5, scope: 4..<20, severity: .error, source: .local, message: "b")
        let c = SQLDiagnostic(range: 14..<15, scope: 14..<20, severity: .error, source: .local, message: "c")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 4) == 1)      // starts here
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 7) == 0)      // innermost containing
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 15) == 2)     // just after it
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 12) == 2)     // next after the cursor
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 0) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 99) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [], cursor: 0) == nil)
    }
}

// Review #7: positions come from an incrementally maintained line index, not a scan of the text.
@Suite("Line index")
struct LineIndexTests {
    @Test func positionsAreOneBasedCodePoints() {
        let text = "SELECT\n  '🇲🇾' x"
        let index = SQLLineIndex(text)
        #expect(index.lineStarts == [0, 7])
        #expect(index.position(of: utf16Offset(of: "x", in: text), in: text as NSString) == SQLTextPosition(line: 2, column: 8))
        #expect(index.position(of: 999, in: text as NSString) == SQLTextPosition(line: 2, column: 9))
        #expect(index.position(of: -1, in: text as NSString) == SQLTextPosition(line: 1, column: 1))
    }

    @Test func editsKeepTheIndexEqualToARebuild() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab\n;吉🇲🇾 ")
        var text = "SELECT 1;\nSELECT 2\n"
        var index = SQLLineIndex(text)
        for _ in 0..<1_500 {
            let units = Array(text.utf16)
            let start = Int.random(in: 0...units.count, using: &generator)
            let end = Int.random(in: start...min(units.count, start + 6), using: &generator)
            let inserted = String((0..<Int.random(in: 0...4, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let updated = String(decoding: units[..<start], as: UTF16.self) + inserted + String(decoding: units[end...], as: UTF16.self)
            // Composed characters can split differently; describe the edit from what actually changed.
            let insertedLength = updated.utf16.count - (units.count - (end - start))
            let edit = try #require(SQLTextEdit.made(in: updated as NSString, editedRange: NSRange(location: start, length: insertedLength),
                                                     changeInLength: insertedLength - (end - start)))
            let applied = index.apply(edit)
            #expect(applied)
            text = updated
            #expect(index == SQLLineIndex(text))
        }
    }

    @Test func invalidEditsAreRefused() {
        var index = SQLLineIndex("ab\ncd")
        let beyondEnd = index.apply(SQLTextEdit(range: 3..<9, replacementLength: 0))
        let negative = index.apply(SQLTextEdit(range: 0..<0, replacementLength: -1))
        #expect(!beyondEnd)
        #expect(!negative)
        #expect(index == SQLLineIndex("ab\ncd"))
    }
}

@Suite("Text positions")
struct TextPositionTests {
    @Test func lineAndColumnAreOneBasedCodePoints() {
        let text = "SELECT\n  o.x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "o.x", in: text), in: text) == SQLTextPosition(line: 2, column: 3))
        let emoji = "'🇲🇾' x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "x", in: emoji), in: emoji) == SQLTextPosition(line: 1, column: 6))
        #expect(SQLTextPosition.lineAndColumn(of: 999, in: "ab\nc") == SQLTextPosition(line: 2, column: 2))
        #expect(SQLTextPosition.lineAndColumn(of: -3, in: "ab") == SQLTextPosition(line: 1, column: 1))
    }
}

@Suite("Diagnostics robustness")
struct DiagnosticsFuzzTests {
    @Test func randomInputNeverCrashes() {
        let alphabet = Array("select from 'x' \"y\" `z` -- # /* */ ; . , ( ) @ 0x1F 1e9 吉 🇲🇾 \\ \n")
        let messages = ["at line 1, column 3", "from line 2, column 1 to line 1, column 9", "Column '`a`.`b`' cannot be resolved",
                        "Unknown table 'x.y'", "No viable statement for input 'from'", "at line 3, column 9999", "Table select is not found"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = String((0..<Int.random(in: 0...80, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let length = text.utf16.count
            let diagnostics = SQLLinter.diagnose(text)
            for diagnostic in diagnostics {
                #expect(diagnostic.range.lowerBound >= 0 && diagnostic.range.upperBound <= length)
                #expect(diagnostic.scope.lowerBound <= diagnostic.range.lowerBound && diagnostic.range.upperBound <= diagnostic.scope.upperBound)
            }
            for message in messages {
                if let range = SQLErrorLocator.range(in: text, message: message) {
                    #expect(range.lowerBound >= 0 && range.upperBound <= length && !range.isEmpty)
                }
            }
            let start = Int.random(in: 0...length, using: &generator)
            let end = Int.random(in: start...length, using: &generator)
            let edit = SQLTextEdit(range: start..<end, replacementLength: Int.random(in: 0...5, using: &generator),
                                   separatorBeforeEnd: Bool.random(using: &generator), separatorAtStart: Bool.random(using: &generator))
            for diagnostic in SQLDiagnosticTracker.apply([edit], to: diagnostics) {
                #expect(diagnostic.range.lowerBound >= 0)
            }
            _ = SQLTextPosition.lineAndColumn(of: Int.random(in: -2...(length + 2), using: &generator), in: text)
        }
    }
}
