import AppKit
@testable import CcinnStarRocksKit
import SwiftUI
import Testing
@testable import CcinnStarRocks

/// An editor wired like `SQLWorkbenchView` wires it, with the binding and the model's diagnostics held
/// here, so tests can play the model's part (including lagging behind the text view).
@MainActor
private final class EditorHarness {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    var diagnostics: [SQLDiagnostic] = []
    var reportedEdits: [SQLTextEdit] = []
    var completionProvider: CompletionProvider?
    let textView: SQLTextView
    let coordinator: SQLEditor.Coordinator
    private let window: NSWindow

    init(_ text: String, diagnostics: [SQLDiagnostic] = [], completionSchema: SchemaSnapshot? = nil) {
        self.text = text
        self.diagnostics = diagnostics
        if let completionSchema {
            completionProvider = { text, cursor in CompletionEngine.complete(text: text, cursor: cursor, schema: completionSchema) }
        }
        textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        coordinator = SQLEditor.Coordinator(SQLEditor(text: .constant(text), selection: .constant(selection)))
        coordinator.parent = editor
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.diagnostics = diagnostics
        window.contentView = textView
        window.makeFirstResponder(textView)
    }

    var editor: SQLEditor {
        SQLEditor(text: Binding(get: { self.text }, set: { self.text = $0 }),
                  selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
                  diagnostics: diagnostics,
                  completionProvider: completionProvider,
                  onEdit: { self.reportedEdits += $0 })
    }

    /// What SwiftUI does on every re-render of the workbench.
    func render() { coordinator.update(from: editor) }

    func type(_ string: String, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        selection = textView.selectedRange()
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    /// Types `string` at the end, one key at a time.
    func typeAtEnd(_ string: String) {
        for character in string { type(String(character), at: (textView.string as NSString).length) }
    }

    /// Labels of the completion popup once it shows something, `nil` if it stays hidden.
    func shownCompletions(within timeout: Duration = .seconds(2)) async throws -> [String]? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let items = coordinator.visibleCompletions { return items.map(\.label) }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@Suite("SQL editor", .serialized)
@MainActor
struct SQLEditorTests {
    // Review #2: the format result is applied only to the text it was computed from, never during composition.
    @Test func formattingIsRefusedWhileComposingOrAfterTheTextChanged() throws {
        let original = "select a from t"
        let harness = EditorHarness(original)
        let controller = SQLEditorController()
        controller.textView = harness.textView
        let formatted = try #require(SQLFormatter.format(original))
        let whole = NSRange(location: 0, length: (original as NSString).length)
        harness.textView.setSelectedRange(NSRange(location: whole.length, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(controller.state?.isComposing == true)
        #expect(controller.state?.text == "select a from t ni", "the editor's own text, ahead of the binding")
        #expect(!controller.replace(whole, with: formatted, expecting: original, actionName: "Format SQL", selecting: NSRange(location: 0, length: 0)))
        #expect(harness.textView.hasMarkedText(), "composition is left alone")
        // Committed: the text is no longer what was formatted, so the stale range is refused (no `…FROM t t`).
        harness.textView.insertText(" 你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!controller.replace(whole, with: formatted, expecting: original, actionName: "Format SQL", selecting: NSRange(location: 0, length: 0)))
        #expect(harness.textView.string == "select a from t 你好")
        let current = harness.textView.string
        let reformatted = try #require(SQLFormatter.format(current))
        #expect(controller.replace(NSRange(location: 0, length: (current as NSString).length), with: reformatted, expecting: current,
                                   actionName: "Format SQL", selecting: NSRange(location: 0, length: 0)))
        #expect(harness.textView.string == reformatted)
    }

    @Test func formattingIsOneUndoableEditThatEditTrackingSees() throws {
        let original = "select a, b from t"
        let harness = EditorHarness(original)
        let undo = try #require(harness.textView.undoManager)
        undo.groupsByEvent = false
        let formatted = try #require(SQLFormatter.format(original))
        let length = (original as NSString).length
        undo.beginUndoGrouping()
        #expect(harness.textView.replace(NSRange(location: 0, length: length), with: formatted, actionName: "Format SQL",
                                         selecting: NSRange(location: 3, length: 0)))
        undo.endUndoGrouping()
        #expect(harness.textView.string == formatted)
        #expect(harness.text == formatted, "the binding is updated like typing")
        #expect(!harness.reportedEdits.isEmpty, "edit tracking sees the replacement")
        #expect(harness.textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(undo.undoActionName == "Format SQL")
        undo.undo()
        #expect(harness.textView.string == original, "one ⌘Z restores the original")
        // Out-of-date ranges are refused instead of trapping.
        #expect(!harness.textView.replace(NSRange(location: 0, length: 10_000), with: "x", actionName: "Format SQL",
                                          selecting: NSRange(location: 0, length: 0)))
    }

    // Review #2: a re-render while an input method composes must not overwrite the marked text.
    @Test func compositionSurvivesARenderWithLaggingText() {
        let harness = EditorHarness("SELECT 1")
        harness.textView.setSelectedRange(NSRange(location: 8, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textView.hasMarkedText())
        // The 300 ms lint lands while composing: the model's text is behind the storage.
        harness.diagnostics = SQLLinter.diagnose("SELECT (")
        harness.render()
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "SELECT 1 ni")
        // Committing reports every edit, in order, and the binding catches up.
        harness.textView.insertText(" 你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.text == "SELECT 1 你")
        var index = SQLLineIndex("SELECT 1")
        for edit in harness.reportedEdits { index.apply(edit) }
        #expect(index.length == ("SELECT 1 你" as NSString).length)
    }

    // Review #2: storage edits that get no textDidChange are reported instead of being overwritten.
    @Test func unreportedStorageEditsCatchUp() async throws {
        let harness = EditorHarness("SELECT 1")
        harness.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- c\n")
        #expect(harness.coordinator.hasPendingEdits)
        harness.render()
        #expect(harness.textView.string == "-- c\nSELECT 1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.text == "-- c\nSELECT 1")
        #expect(!harness.coordinator.hasPendingEdits)
    }

    // Review #3: Return after a failed statement keeps its marker; typing onto its last token does not.
    @Test func returnAfterTheStatementKeepsItsMarker() {
        let failure = SQLDiagnostic(range: 14..<18, scope: 0..<25, severity: .error, source: .server, message: "Unexpected input 'shop'")
        let harness = EditorHarness("SELECT 1 FORM shop.orders", diagnostics: [failure])
        harness.type("\n", at: 25)
        #expect(harness.coordinator.diagnostics == [failure])
        let glued = EditorHarness("SELECT 1 FORM shop.orders", diagnostics: [failure])
        glued.type("x", at: 25)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // Review #3: text typed right before a statement only moves it when it stays a separate token.
    @Test func typingBeforeAStatement() {
        let failure = SQLDiagnostic(range: 18..<22, scope: 9..<24, severity: .error, source: .server, message: "m")
        let newline = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        newline.type("\n", at: 9)
        #expect(newline.coordinator.diagnostics.map(\.range) == [19..<23])
        let glued = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        glued.type("x", at: 9)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // Review #6: a local marker stays put while the user types elsewhere in its statement.
    @Test func localMarkersDoNotBlinkWhileTyping() {
        let text = "SELECT count(1 FROM t"
        let harness = EditorHarness(text, diagnostics: SQLLinter.diagnose(text))
        harness.type(" ", at: 21)
        harness.type("W", at: 22)
        #expect(harness.coordinator.diagnostics.map(\.range) == [12..<13])
    }
}

// MARK: - Completion

@Suite("SQL completion popup", .serialized)
@MainActor
struct CompletionPopupTests {
    static let schema = SchemaSnapshot(
        currentDatabase: "taku", databases: ["taku"],
        objectsByDatabase: ["taku": ["adx_demand", "adx_publisher", "dws_uparpu_adx_funnel_reason_hi", "mv_report_adx_hour"]
            .map { SchemaSnapshot.ObjectEntry(name: $0, kind: .table) }])

    private func item(_ label: String) -> CompletionItem { CompletionItem(kind: .keyword, label: label, insertText: label, detail: nil) }

    private func runLoop(for seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pixels(of panel: NSPanel) throws -> Data {
        let view = try #require(panel.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try #require(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    /// What a panel shows for `items`, drawn by a panel that never showed anything else.
    private func freshRendering(of items: [CompletionItem], frame: NSRect) throws -> Data {
        let model = CompletionListModel()
        model.update(items: items, prefix: "")
        let panel = CompletionPanel(model: model)
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        runLoop()
        return try pixels(of: panel)
    }

    // The popup kept drawing the first list it showed: `from` listed SELECT/SET, `adx_publisher` the `adx` list.
    @Test func theListDrawsTheLatestResult() throws {
        _ = NSApplication.shared
        let first = ["SELECT", "SET"].map(item)
        let second = ["FROM", "from_unixtime"].map(item)
        let model = CompletionListModel()
        let panel = CompletionPanel(model: model)
        model.update(items: first, prefix: "se")
        let frame = NSRect(origin: NSPoint(x: 240, y: 320), size: model.preferredSize)
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        runLoop()
        model.update(items: second, prefix: "from")
        runLoop()
        let shown = try pixels(of: panel)
        panel.orderOut(nil)

        let expected = try freshRendering(of: second, frame: frame)
        #expect(try freshRendering(of: first, frame: frame) != expected, "the two lists must look different for this test to mean anything")
        #expect(shown == expected)
    }

    // Spec "Tables after FROM": the list opens on the space, before any letter is typed.
    @Test func spaceAfterFromListsTheTables() async throws {
        let harness = EditorHarness("select * from", completionSchema: Self.schema)
        harness.typeAtEnd(" ")
        let labels = try #require(try await harness.shownCompletions())
        #expect(Array(labels.prefix(4)) == ["adx_demand", "adx_publisher", "dws_uparpu_adx_funnel_reason_hi", "mv_report_adx_hour"])
    }

    @Test func spaceElsewhereKeepsTheListClosed() async throws {
        for text in ["select *", "select * from adx_demand", "select * from adx_demand order by id desc"] {
            let harness = EditorHarness(text, completionSchema: Self.schema)
            harness.typeAtEnd(" ")
            #expect(try await harness.shownCompletions(within: .milliseconds(300)) == nil, "\(text)")
        }
    }

    // Return is pressed twice for a blank line; a list opened by the first would take the second.
    @Test func returnOrTabAfterFromKeepsTheListClosed() async throws {
        for typed in ["\n", "    "] {
            let harness = EditorHarness("select *\nfrom", completionSchema: Self.schema)
            harness.type(typed, at: (harness.textView.string as NSString).length)
            #expect(try await harness.shownCompletions(within: .milliseconds(300)) == nil, "\(typed.debugDescription)")
        }
    }

    // A list computed for `adx` must not stay up (and be accepted with Return) once a space ends the name.
    @Test func whitespaceClosesTheListAtOnce() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("adx")
        #expect(try await harness.shownCompletions()?.first == "adx_demand")
        harness.typeAtEnd(" ")
        #expect(harness.coordinator.visibleCompletions == nil)
        #expect(try await harness.shownCompletions(within: .milliseconds(300)) == nil)
    }

    @Test func typingNarrowsTheListUntilOnlyTheExactNameIsLeft() async throws {
        let harness = EditorHarness("select * from ", completionSchema: Self.schema)
        harness.typeAtEnd("adx")
        #expect(try await harness.shownCompletions()?.count == 4)
        harness.typeAtEnd("_p")
        let deadline = ContinuousClock.now + .seconds(2)
        while harness.coordinator.visibleCompletions?.map(\.label) != ["adx_publisher"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.coordinator.visibleCompletions?.map(\.label) == ["adx_publisher"])
        harness.typeAtEnd("ublisher")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.coordinator.visibleCompletions == nil, "only the exact name is left")
    }
}
