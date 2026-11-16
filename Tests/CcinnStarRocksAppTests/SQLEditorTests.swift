import AppKit
import CcinnStarRocksKit
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
    let textView: SQLTextView
    let coordinator: SQLEditor.Coordinator
    private let window: NSWindow

    init(_ text: String, diagnostics: [SQLDiagnostic] = []) {
        self.text = text
        self.diagnostics = diagnostics
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
                  onEdit: { self.reportedEdits += $0 })
    }

    /// What SwiftUI does on every re-render of the workbench.
    func render() { coordinator.update(from: editor) }

    func type(_ string: String, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        selection = textView.selectedRange()
        textView.insertText(string, replacementRange: textView.selectedRange())
    }
}

@Suite("SQL editor", .serialized)
@MainActor
struct SQLEditorTests {
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
