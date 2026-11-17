import AppKit
import CcinnStarRocksKit
import SwiftUI

typealias CompletionProvider = @MainActor (_ text: String, _ cursor: Int) async -> CompletionResult

/// Lets a model read the editor's own text and change it the way typing does: one undoable edit that the editor's
/// edit tracking (and so the diagnostics) sees.
@MainActor
final class SQLEditorController {
    weak var textView: SQLTextView?

    var isAttached: Bool { textView != nil }

    /// The editor's text and selection. The model's copy lags behind while an input method composes.
    var state: (text: String, selection: NSRange, isComposing: Bool)? {
        guard let textView else { return nil }
        return (textView.string, textView.selectedRange(), textView.hasMarkedText())
    }

    /// Replaces `range` and selects `selection`, but only while the editor still holds `expected` and nothing is
    /// being composed; `false` otherwise.
    @discardableResult
    func replace(_ range: NSRange, with replacement: String, expecting expected: String, actionName: String,
                 selecting selection: NSRange) -> Bool {
        textView?.replace(range, with: replacement, expecting: expected, actionName: actionName, selecting: selection) ?? false
    }
}

/// SQL editor on NSTextView: lexer-driven highlighting, line numbers, current-statement highlight,
/// diagnostics (underlines and inline messages), bracket/quote pairing, comment toggling and
/// context-aware completion.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var isEditable = true
    var fontSize: CGFloat = 13
    var showsLineNumbers = true
    var highlightsCurrentStatement = true
    /// Diagnostics of `text` (UTF-16 ranges), underlined and shown at the end of their line.
    var diagnostics: [SQLDiagnostic] = []
    var completionProvider: CompletionProvider?
    /// Edits made by the user, reported before `text` is updated (see `SQLTabModel.editorDidEdit`).
    var onEdit: (@MainActor ([SQLTextEdit]) -> Void)?
    var focusOnAppear = false
    var controller: SQLEditorController?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = SQLTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.typingAttributes = Coordinator.baseAttributes(fontSize: fontSize)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = isEditable
        scrollView.documentView = textView

        if showsLineNumbers {
            let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            context.coordinator.ruler = ruler
        }

        context.coordinator.textView = textView
        controller?.textView = textView
        textView.string = text
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.diagnostics = diagnostics
        context.coordinator.textChanged()
        context.coordinator.observeScrolling(of: scrollView)
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.hideCompletions()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: SQLEditor
        weak var textView: SQLTextView?
        weak var ruler: LineNumberRulerView?
        var isApplyingBinding = false
        var isTrackingSelection = false
        /// The editor's own copy, moved with every edit immediately so markers never lag behind typing;
        /// replaced by the model's list whenever the two differ.
        var diagnostics: [SQLDiagnostic] = [] {
            didSet {
                guard diagnostics != oldValue else { return }
                textView?.inlineDiagnostics = diagnostics
                // Lines whose message disappeared are not otherwise invalidated.
                textView?.needsDisplay = true
            }
        }
        private var pendingEdits: [SQLTextEdit] = []
        private var statements: [SQLStatement] = []
        private var highlightedStatement: NSRange?
        private var lastInserted = ""
        private var completionTask: Task<Void, Never>?
        private let completionModel = CompletionListModel()
        private var completionPanel: CompletionPanel?
        private var activeCompletion: CompletionResult?
        private var observers: [any NSObjectProtocol] = []

        init(_ parent: SQLEditor) {
            self.parent = parent
            super.init()
            completionModel.onAccept = { [weak self] item in self?.accept(item) }
        }

        static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: NSColor.labelColor]
        }

        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.highlightVisibleRange() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                    queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.ruler?.needsDisplay = true
                    self?.hideCompletions()
                    self?.highlightVisibleRange()
                }
            })
        }

        // MARK: Text changes

        /// Records every character edit (typing, paste, undo, input methods, multi-range edits as their
        /// union). `willProcessEditing` reports the exact range; after attribute fixing (`didProcessEditing`)
        /// it is widened to the end of the paragraph, which would drop markers later on the same line.
        nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            // Described here, from the edited storage (scans only the inserted text); not describable →
            // invalidate everything rather than guess.
            let edit = SQLTextEdit.made(in: textStorage.mutableString, editedRange: editedRange, changeInLength: delta)
                ?? SQLTextEdit(range: 0..<Int.max, replacementLength: 0)
            MainActor.assumeIsolated {
                guard !isApplyingBinding else { return }
                pendingEdits.append(edit)
            }
        }

        /// Brings the view in line with the binding. Skipped while the text storage is ahead of it: an
        /// input method is composing (marked text fires `willProcessEditing` but no `textDidChange`) or
        /// edits wait to be reported. Replacing the text then would destroy the composition, and the
        /// binding's diagnostics describe older text.
        func update(from editor: SQLEditor) {
            parent = editor
            guard let textView else { return }
            textView.isEditable = editor.isEditable
            if textView.hasMarkedText() { return }
            if !pendingEdits.isEmpty {
                // Edits without a `textDidChange` (e.g. a cancelled composition): report them now, after
                // this view update, so the binding catches up instead of being overwritten.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.hasPendingEdits else { return }
                    self.reportPendingEdits()
                }
                return
            }
            let text = editor.text
            if textView.string != text {
                isApplyingBinding = true
                textView.string = text
                isApplyingBinding = false
                pendingEdits.removeAll()
                // The model's diagnostics already describe the new text.
                diagnostics = editor.diagnostics
                let length = (text as NSString).length
                textView.setSelectedRange(NSRange(location: min(editor.selection.location, length), length: 0))
                textChanged()
            } else if diagnostics != editor.diagnostics {
                diagnostics = editor.diagnostics
                diagnosticsDidChange()
            }
            let selection = editor.selection
            if selection != textView.selectedRange(), NSMaxRange(selection) <= (textView.string as NSString).length, !isTrackingSelection {
                textView.setSelectedRange(selection)
                textView.scrollRangeToVisible(selection)
            }
        }

        var hasPendingEdits: Bool { !pendingEdits.isEmpty }

        func textDidChange(_ notification: Notification) {
            reportPendingEdits()
        }

        /// Moves the diagnostics, tells the model about the edits, then writes the text to the binding.
        func reportPendingEdits() {
            guard !isApplyingBinding, let textView, !textView.hasMarkedText() || pendingEdits.isEmpty else { return }
            let edits = pendingEdits
            pendingEdits.removeAll()
            if !edits.isEmpty, !diagnostics.isEmpty {
                diagnostics = SQLDiagnosticTracker.apply(edits, to: diagnostics)
            }
            // Before the text: the model adjusts its diagnostics for exactly these edits.
            parent.onEdit?(edits)
            parent.text = textView.string
            textChanged()
            scheduleCompletion(force: false)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            lastInserted = replacementString ?? ""
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !isApplyingBinding else { return }
            let range = textView.selectedRange()
            isTrackingSelection = true
            if parent.selection != range { parent.selection = range }
            isTrackingSelection = false
            updateStatementHighlight()
            if let active = activeCompletion, range.length > 0 || range.location < active.replacementRange.lowerBound {
                hideCompletions()
            }
        }

        /// Lexed tokens of the current text (UTF-16 ranges, sorted).
        private var tokens: [SQLToken] = []
        private var functionTokens = Set<Int>()
        private var highlightedRange = NSRange(location: 0, length: 0)
        private static let highlightLimit = 4_000_000

        func textChanged() {
            ruler?.textDidChange()
            rehighlight()
        }

        /// Re-lexes the text (linear, no layout work) and recolours what is on screen. Colours are layout
        /// manager temporary attributes, so typing never invalidates the layout of the whole document.
        func rehighlight() {
            guard let textView else { return }
            let text = textView.string
            let length = (text as NSString).length
            if length <= Self.highlightLimit {
                let lexer = SQLLexer(text)
                tokens = lexer.tokens()
                statements = SQLStatementSplitter.split(lexer: lexer, tokens: tokens)
                var functions = Set<Int>()
                for index in tokens.indices.dropLast() where tokens[index].kind == .identifier {
                    let next = tokens[index + 1]
                    if next.kind == .punctuation, next.range.count == 1, lexer.units[next.range.lowerBound] == 0x28,
                       SQLFunctions.names.contains(lexer.text(of: tokens[index]).uppercased()) {
                        functions.insert(index)
                    }
                }
                functionTokens = functions
            } else {
                tokens = []
                functionTokens = []
                statements = []
            }
            highlightedRange = NSRange(location: 0, length: 0)
            highlightVisibleRange(force: true)
            highlightedStatement = nil
            updateStatementHighlight()
        }

        /// Diagnostics changed but the text did not: re-apply underlines (no re-lexing) and redraw messages.
        func diagnosticsDidChange() {
            highlightVisibleRange(force: true)
        }

        /// Colours the visible characters (plus a margin). Called after edits and when scrolling.
        func highlightVisibleRange(force: Bool = false) {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let length = (textView.string as NSString).length
            let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
            let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(0, visible.location - 4_000)
            let end = min(length, NSMaxRange(visible) + 4_000)
            let target = NSRange(location: start, length: max(0, end - start))
            if !force, NSLocationInRange(visible.location, highlightedRange), NSMaxRange(visible) <= NSMaxRange(highlightedRange) { return }
            highlightedRange = target
            for key in [NSAttributedString.Key.foregroundColor, .underlineStyle, .underlineColor] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: target)
            }
            // First token that ends after `start` (binary search).
            var low = 0
            var high = tokens.count
            while low < high {
                let mid = (low + high) / 2
                if tokens[mid].range.upperBound <= start { low = mid + 1 } else { high = mid }
            }
            var index = low
            while index < tokens.count, tokens[index].range.lowerBound < end {
                let token = tokens[index]
                let color: NSColor? = switch token.kind {
                case .keyword: .syntaxKeyword
                case .identifier: functionTokens.contains(index) ? .syntaxFunction : nil
                case .quotedIdentifier: .syntaxQuoted
                case .string: .syntaxString
                case .number: .syntaxNumber
                case .comment: .syntaxComment
                case .variable: .syntaxVariable
                case .operator, .punctuation: .secondaryLabelColor
                }
                if let color, token.range.upperBound <= length {
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.nsRange)
                }
                index += 1
            }
            for diagnostic in diagnostics {
                // Exactly the marked text, clipped to the re-coloured window (and the text).
                let lower = max(diagnostic.range.lowerBound, start)
                let upper = min(diagnostic.range.upperBound, end, length)
                guard lower < upper else { continue }
                let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemOrange
                layoutManager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                                      .underlineColor: color], forCharacterRange: NSRange(location: lower, length: upper - lower))
            }
        }

        private func updateStatementHighlight() {
            guard parent.highlightsCurrentStatement, let textView, let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            let cursor = textView.selectedRange().location
            var target: NSRange?
            if statements.count > 1 {
                let statement = statements.first { $0.range.lowerBound <= cursor && cursor <= $0.range.upperBound }
                    ?? statements.last { $0.range.upperBound <= cursor }
                if let statement { target = NSRange(location: statement.range.lowerBound, length: statement.range.count) }
            }
            guard target != highlightedStatement else { return }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            if let target, NSMaxRange(target) <= length {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.currentStatement, forCharacterRange: target)
            }
            highlightedStatement = target
        }

        // MARK: Key handling

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if completionPanel?.isVisible == true {
                switch selector {
                case #selector(NSResponder.moveDown(_:)):
                    completionModel.move(1)
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    completionModel.move(-1)
                    return true
                case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
                    completionModel.move(8)
                    return true
                case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
                    completionModel.move(-8)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if let item = completionModel.selectedItem { accept(item) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    hideCompletions()
                    return true
                case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
                    hideCompletions()
                    return false
                default:
                    break
                }
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        // MARK: Completion

        func forceCompletion() { scheduleCompletion(force: true) }

        private func scheduleCompletion(force: Bool) {
            completionTask?.cancel()
            guard let provider = parent.completionProvider, let textView, parent.isEditable else { return }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return hideCompletions() }
            if !force {
                let typed = lastInserted
                let isWordInput = typed.count == 1 && typed.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." || $0 == "`" || $0 == "$"
                }
                guard isWordInput else { return hideCompletions() }
            }
            let text = textView.string
            let cursor = selection.location
            let afterDot = lastInserted == "."
            completionTask = Task { [weak self] in
                if !force { try? await Task.sleep(for: .milliseconds(70)) }
                guard !Task.isCancelled else { return }
                let result = await provider(text, cursor)
                guard let self, !Task.isCancelled, let textView = self.textView,
                      textView.string == text, textView.selectedRange().location == cursor else { return }
                let exactOnly = result.items.count == 1 && result.items[0].label.caseInsensitiveCompare(result.prefix) == .orderedSame
                if result.items.isEmpty || exactOnly || (!force && result.prefix.isEmpty && !afterDot) {
                    self.hideCompletions()
                } else {
                    self.showCompletions(result)
                }
            }
        }

        private func showCompletions(_ result: CompletionResult) {
            guard let textView, let window = textView.window else { return }
            activeCompletion = result
            completionModel.update(items: result.items, prefix: result.prefix)
            let panel = completionPanel ?? CompletionPanel(model: completionModel)
            completionPanel = panel
            let anchor = textView.firstRect(forCharacterRange: NSRange(location: result.replacementRange.lowerBound, length: 0), actualRange: nil)
            let size = completionModel.preferredSize
            var origin = NSPoint(x: anchor.minX - 28, y: anchor.minY - size.height - 3)
            if let screen = window.screen?.visibleFrame {
                if origin.y < screen.minY { origin.y = anchor.maxY + 3 }
                origin.x = min(max(screen.minX, origin.x), screen.maxX - size.width)
            }
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
        }

        func hideCompletions() {
            completionTask?.cancel()
            activeCompletion = nil
            guard let panel = completionPanel, panel.isVisible else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        private func accept(_ item: CompletionItem) {
            guard let textView, let active = activeCompletion else { return }
            let cursor = textView.selectedRange().location
            let start = min(active.replacementRange.lowerBound, cursor)
            let range = NSRange(location: start, length: cursor - start)
            hideCompletions()
            if item.kind == .function {
                let name = item.insertText.hasSuffix("(") ? String(item.insertText.dropLast()) : item.insertText
                textView.insertText(name + "()", replacementRange: range)
                let caret = textView.selectedRange().location
                textView.setSelectedRange(NSRange(location: max(0, caret - 1), length: 0))
            } else {
                textView.insertText(item.insertText, replacementRange: range)
            }
            lastInserted = ""
        }
    }
}

/// NSTextView with SQL conveniences: pairing, auto-indent, ⌘/ comment toggle, ⌃Space completion,
/// and diagnostic messages drawn after the end of their line.
final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditor.Coordinator?
    var inlineDiagnostics: [SQLDiagnostic] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawInlineDiagnostics(in: dirtyRect)
    }

    /// The first message of every visible line that has one, in a tinted capsule after the line's
    /// last character, truncated; skipped when less than 80 pt remain.
    private func drawInlineDiagnostics(in dirtyRect: NSRect) {
        guard !inlineDiagnostics.isEmpty, let layoutManager, let textContainer else { return }
        let text = string as NSString
        let length = text.length
        guard length > 0 else { return }
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let font = NSFont.systemFont(ofSize: max(9, (self.font?.pointSize ?? 13) - 2))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var drawnLines = Set<Int>()
        for diagnostic in inlineDiagnostics {
            let location = diagnostic.range.lowerBound
            guard location >= 0, location < length, NSLocationInRange(location, visible) || location == NSMaxRange(visible) else { continue }
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            guard drawnLines.insert(lineRange.location).inserted else { continue }
            var lineEnd = NSMaxRange(lineRange)
            while lineEnd > lineRange.location, [0x0A, 0x0D].contains(text.character(at: lineEnd - 1)) { lineEnd -= 1 }
            let anchor = max(lineRange.location, lineEnd - 1)
            guard anchor < length else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let origin = textContainerOrigin
            let x = used.maxX + origin.x + 22
            let available = visibleRect.maxX - x - 10
            guard available >= 80 else { continue }
            let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemOrange
            // Bounded: messages are measured on every draw.
            let message = String(diagnostic.message.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            let size = (message as NSString).size(withAttributes: attributes)
            let width = min(ceil(size.width), available - 12)
            let height = ceil(size.height)
            let capsule = NSRect(x: x, y: fragment.minY + origin.y + max(0, (fragment.height - height - 2) / 2), width: width + 12, height: height + 2)
            guard capsule.intersects(dirtyRect) else { continue }
            color.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
            (message as NSString).draw(with: NSRect(x: x + 6, y: capsule.minY + 1, width: width, height: height),
                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
    }

    private static let pairs: [String: String] = ["(": ")", "'": "'", "\"": "\"", "`": "`"]
    private static let closers: Set<String> = [")", "'", "\"", "`"]

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, event.keyCode == 49 { // ⌃Space
            coordinator?.forceCompletion()
            return
        }
        if flags == .command, event.charactersIgnoringModifiers == "/" {
            toggleComment()
            return
        }
        super.keyDown(with: event)
    }

    /// Replaces `range` with `replacement` as a single undo step (⌘Z restores the original), then selects
    /// `selection`. Goes through `shouldChangeText` / `didChangeText` like typing, so edit tracking sees it.
    /// Refused while an input method composes, or when the text is no longer `expected` (the range would be stale).
    func replace(_ range: NSRange, with replacement: String, expecting expected: String? = nil, actionName: String,
                 selecting selection: NSRange) -> Bool {
        let length = (string as NSString).length
        guard isEditable, !hasMarkedText(), range.location >= 0, NSMaxRange(range) <= length, let textStorage else { return false }
        if let expected, expected != string { return false }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
        }
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
        didChangeText()
        undoManager?.setActionName(actionName)
        let updated = (string as NSString).length
        let clamped = NSRange(location: min(selection.location, updated), length: min(selection.length, max(0, updated - min(selection.location, updated))))
        setSelectedRange(clamped)
        scrollRangeToVisible(clamped)
        return true
    }

    override func complete(_ sender: Any?) {
        coordinator?.forceCompletion()
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.hideCompletions()
        return super.resignFirstResponder()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable, let typed = insertString as? String, typed.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        let text = string as NSString
        let next = selection.location < text.length ? text.substring(with: NSRange(location: selection.location, length: 1)) : ""
        if Self.closers.contains(typed), next == typed, selection.length == 0 {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        if let closer = Self.pairs[typed], selection.length == 0, shouldPair(typed, next: next, text: text, at: selection.location) {
            super.insertText(typed + closer, replacementRange: replacementRange)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    private func shouldPair(_ opener: String, next: String, text: NSString, at location: Int) -> Bool {
        let boundary = next.isEmpty || next.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || Self.closers.contains(next) || next == "," || next == ";"
        guard boundary else { return false }
        if opener != "(" {
            guard location > 0 else { return true }
            let previous = text.substring(with: NSRange(location: location - 1, length: 1))
            return previous.rangeOfCharacter(from: .alphanumerics) == nil
        }
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        let text = string as NSString
        if selection.length == 0, selection.location > 0, selection.location < text.length {
            let previous = text.substring(with: NSRange(location: selection.location - 1, length: 1))
            let next = text.substring(with: NSRange(location: selection.location, length: 1))
            if Self.pairs[previous] == next {
                insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let location = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        let line = text.substring(with: NSRange(location: lineRange.location, length: location - lineRange.location))
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        insertText("\n" + indentation, replacementRange: selectedRange())
    }

    /// Adds or removes `-- ` at the start of every selected line.
    func toggleComment() {
        let text = string as NSString
        let lines = text.lineRange(for: selectedRange())
        let block = text.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let hasTrailingNewline = block.hasSuffix("\n")
        if hasTrailingNewline { parts.removeLast() }
        let nonEmpty = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let updated = parts.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allCommented {
                guard let range = line.range(of: "--") else { return line }
                var result = line
                result.removeSubrange(range)
                if result[range.lowerBound...].hasPrefix(" ") { result.remove(at: range.lowerBound) }
                return result
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return indent + "-- " + line.dropFirst(indent.count)
        }.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        insertText(updated, replacementRange: lines)
        setSelectedRange(NSRange(location: lines.location, length: (updated as NSString).length))
    }
}

// MARK: - Line numbers

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func textDidChange() {
        guard let textView else { return }
        var starts = [0]
        let units = textView.string.utf16
        var offset = 0
        for unit in units {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let thickness = CGFloat(digits) * 7.5 + 18
        if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    private func lineIndex(for location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.4).setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 0.5, y: bounds.minY, width: 0.5, height: bounds.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let currentLine = lineIndex(for: textView.selectedRange().location)
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let length = (textView.string as NSString).length
        var line = lineIndex(for: characterRange.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characterRange), start > characterRange.location { break }
            var lineRect: NSRect
            if start >= length {
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.isEmpty, length > 0 { break }
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y), from: textView).y
            var lineAttributes = attributes
            if line == currentLine { lineAttributes[.foregroundColor] = NSColor.secondaryLabelColor }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: lineAttributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (lineRect.height - size.height) / 2), withAttributes: lineAttributes)
            line += 1
        }
    }
}

// MARK: - Completion popup

@MainActor
@Observable
final class CompletionListModel {
    var items: [CompletionItem] = []
    var prefix = ""
    var selectedIndex = 0
    var onAccept: (CompletionItem) -> Void = { _ in }

    static let rowHeight: CGFloat = 24
    static let visibleRows = 9

    func update(items: [CompletionItem], prefix: String) {
        self.items = items
        self.prefix = prefix
        selectedIndex = 0
    }

    var selectedItem: CompletionItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), items.count - 1)
    }

    var preferredSize: NSSize {
        let rows = CGFloat(min(items.count, Self.visibleRows))
        let footer: CGFloat = selectedItem?.kind == .function ? 26 : 0
        return NSSize(width: 460, height: rows * Self.rowHeight + 10 + footer)
    }
}

final class CompletionPanel: NSPanel {
    init(model: CompletionListModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: CompletionListView(model: model))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CompletionListView: View {
    @Bindable var model: CompletionListModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            CompletionRow(item: item, prefix: model.prefix, isSelected: index == model.selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectedIndex = index
                                    model.onAccept(item)
                                }
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selectedIndex) { _, index in proxy.scrollTo(index) }
            }
            if let item = model.selectedItem, item.kind == .function, let detail = item.detail {
                Divider()
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
    }
}

private struct CompletionRow: View {
    let item: CompletionItem
    let prefix: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? .white : color)
                .frame(width: 18)
            Text(item.label)
                .font(.system(size: 12.5, weight: item.kind == .keyword ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let detail = item.detail, item.kind != .function {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: CompletionListModel.rowHeight)
        .background(isSelected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private var icon: String {
        switch item.kind {
        case .column: "c.square"
        case .alias: "at"
        case .table: "tablecells"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up.fill"
        case .externalTable: "externaldrive.connected.to.line.below"
        case .database: "cylinder"
        case .catalog: "books.vertical"
        case .function: "function"
        case .keyword: "textformat"
        }
    }

    private var color: Color {
        switch item.kind {
        case .column: Color(nsColor: .kindTable)
        case .alias: .pink
        case .table: Color(nsColor: .kindTable)
        case .view: Color(nsColor: .kindView)
        case .materializedView: Color(nsColor: .kindAsyncMV)
        case .externalTable: Color(nsColor: .kindExternal)
        case .database: .teal
        case .catalog: .brown
        case .function: Color(nsColor: .syntaxFunction)
        case .keyword: Color(nsColor: .syntaxKeyword)
        }
    }
}
