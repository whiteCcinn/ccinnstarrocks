import AppKit
import CcinnStarRocksKit
import Foundation
import MySQLWire
import Observation
import StarRocksKit
import UniformTypeIdentifiers

/// Result of one executed statement.
@MainActor
@Observable
final class StatementOutcome: Identifiable {
    let id = UUID()
    let index: Int
    let sql: String
    let executedSQL: String
    let kind: SQLStatementKind
    let startedAt: Date
    var durationMilliseconds: Double = 0
    var results: [ResultSet] = []
    var errorMessage: String?
    var errorCode: Int?
    /// `errorMessage` parsed once, off the main actor.
    var serverError: SQLServerError?
    var limitApplied: Int?
    var isRunning = true
    var viewMode: ViewMode = .grid
    var chart: ChartState?

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grid"
        case chart = "Chart"
        case plan = "Plan"
        var id: String { rawValue }
    }

    init(index: Int, sql: String, executedSQL: String, kind: SQLStatementKind) {
        self.index = index
        self.sql = sql
        self.executedSQL = executedSQL
        self.kind = kind
        startedAt = Date()
        if kind == .explain { viewMode = .plan }
    }

    /// The row set to display (last result that has columns).
    var rowSet: ResultSet? { results.last { $0.hasRowSet } }

    var summary: String {
        if isRunning { return "Running…" }
        if errorMessage != nil { return "Failed" }
        if let rowSet {
            let rows = Format.count(rowSet.rows.count)
            return rowSet.isTruncated ? "\(rows)+ rows" : "\(rows) row\(rowSet.rows.count == 1 ? "" : "s")"
        }
        let affected = results.reduce(UInt64(0)) { $0 &+ $1.affectedRows }
        return affected > 0 ? "\(affected.formatted()) affected" : "OK"
    }

    /// Plain-text plan for EXPLAIN results (one column of lines).
    var planText: String? {
        guard let rowSet, kind == .explain else { return nil }
        return rowSet.rows.map { $0.compactMap { $0 }.joined(separator: "\t") }.joined(separator: "\n")
    }
}

/// Chart configuration and prepared data for one result.
@MainActor
@Observable
final class ChartState {
    var spec: ChartSpec { didSet { if spec != oldValue { rebuild() } } }
    let roles: [ColumnRole]
    private(set) var data: ChartData = .empty
    private(set) var isPreparing = false
    private let columns: [ColumnDefinition]
    private let rows: [[String?]]
    private var buildTask: Task<Void, Never>?

    init?(result: ResultSet) {
        guard result.hasRowSet, !result.rows.isEmpty else { return nil }
        columns = result.columns
        rows = result.rows
        let roles = ChartSuggester.roles(columns: result.columns, rows: result.rows)
        self.roles = roles
        let numeric = roles.indices.first { roles[$0] == .numeric }
        guard let suggested = ChartSuggester.suggest(roles: roles, rows: result.rows)
            ?? numeric.map({ ChartSpec(kind: .bar, xColumn: 0, yColumns: [$0]) }) else { return nil }
        spec = suggested
        rebuild()
    }

    var columnNames: [String] { columns.map(\.name) }
    var numericColumns: [Int] { roles.indices.filter { roles[$0] == .numeric } }

    private func rebuild() {
        buildTask?.cancel()
        isPreparing = true
        let (columns, rows, spec, roles) = (self.columns, self.rows, self.spec, self.roles)
        buildTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                ChartDataBuilder.build(columns: columns, rows: rows, spec: spec, roles: roles)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.data = data
            self.isPreparing = false
        }
    }
}

/// One SQL editor tab: text, session, execution of current/selected/all statements, results and history.
@MainActor
@Observable
final class SQLTabModel {
    let title: String
    /// Edits made in the editor arrive through `editorDidEdit` first; any other assignment (History →
    /// Open) replaces the text, which makes every server diagnostic stale.
    var text: String {
        didSet {
            formatRuns.textChanged(from: oldValue, to: text) // a running format would no longer apply
            if editorEditPending {
                editorEditPending = false
                if lineIndexIsStale { rebuildLineIndex() }
            } else {
                textWasReplaced()
            }
            scheduleLint()
        }
    }
    var selection = NSRange(location: 0, length: 0)
    private(set) var database: String?
    private(set) var catalog: String
    var outcomes: [StatementOutcome] = []
    var selectedOutcomeID: UUID?
    var isRunning = false
    var runStartedAt: Date?
    /// Errors of the last run, anchored to the statements that failed.
    private(set) var serverDiagnostics: [SQLDiagnostic] = []
    /// Local checks of the current text (refreshed shortly after typing stops).
    private(set) var localDiagnostics: [SQLDiagnostic] = []
    var inspected: InspectedValue?
    var pendingConfirmation: PendingConfirmation?
    var showHistory = false

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let request: RunConfirmation
        let continuation: CheckedContinuation<Bool, Never>
    }

    unowned let workspace: WorkspaceModel
    private let session: SQLSession
    private var runTask: Task<Void, Never>?
    private var lintTask: Task<Void, Never>?
    private var editorEditPending = false
    /// Line starts of `text`, maintained edit by edit (positions without scanning the text).
    @ObservationIgnored private var lineIndex: SQLLineIndex
    @ObservationIgnored private var lineIndexIsStale = false
    /// Editor ranges of the statements in the running batch, by index; `nil` once a statement was edited.
    private var runAnchors: [Range<Int>?] = []

    /// A statement to execute: `sql` is sent as is; `editorOffset` is where its source starts in the
    /// editor (nil when unknown) and `prefixLength` the units the app prepended (`EXPLAIN `).
    private struct PlannedStatement {
        let sql: String
        let editorOffset: Int?
        var prefixLength = 0
    }

    /// Rows kept per result (hard cap) and the default auto-limit for plain SELECTs.
    static let hardRowCap = 100_000
    var autoLimit: Int {
        get { UserDefaults.standard.object(forKey: "autoLimit") as? Int ?? 1000 }
        set { UserDefaults.standard.set(newValue, forKey: "autoLimit") }
    }

    // MARK: Formatting

    /// The editor of this tab, for edits that must be undoable (formatting).
    let editorController = SQLEditorController()
    let formatRuns = SQLFormatRuns()
    var isFormatting: Bool { formatRuns.isRunning }
    /// Why the last Format SQL changed nothing, shown briefly in the editor's status bar.
    var formatNotice: String? { formatRuns.notice }

    /// Settings ▸ General ▸ SQL formatting, and whether the connected server reads `$$ … $$` blocks.
    var formatOptions: SQLFormatOptions {
        let defaults = UserDefaults.standard
        let keywordCase = defaults.string(forKey: "sqlFormatKeywordCase").flatMap(SQLFormatOptions.KeywordCase.init(rawValue:)) ?? .upper
        let indent = defaults.object(forKey: "sqlFormatIndent") as? Int ?? 2
        return SQLFormatOptions(keywordCase: keywordCase, indentWidth: indent, dollarQuotedBlocks: readsDollarQuotedBlocks)
    }

    /// StarRocks 4.1 reads `$$ … $$` (inline function bodies) as one block; 3.3 and unknown versions do not. Only the
    /// release `current_version()` reported counts: fallbacks (3.3 announces 5.1.0, 4.1 announces 8.0.33) are unknown.
    private var readsDollarQuotedBlocks: Bool {
        workspace.serverInfo.releaseVersion.map { SQLFormatOptions.dollarQuotedBlocksSupported(major: $0.major, minor: $0.minor) } ?? false
    }

    private func noteFormatSkipped(_ notice: String) {
        formatRuns.note(notice)
    }

    /// Formats the selection, or the whole script when nothing is selected, as one undoable edit. Works on the editor's
    /// own text (the model's copy lags behind while an input method composes) and off the main actor; a newer format or
    /// any edit cancels it, and the result is applied only if the editor still holds the formatted text.
    func formatSQL() {
        formatRuns.cancel()
        let live = editorController.state
        if live?.isComposing == true { // an input method is composing: format once it commits
            noteFormatSkipped("Format SQL skipped while composing")
            return
        }
        let source = live?.text ?? text
        let cursor = live?.selection ?? selection
        let length = (source as NSString).length
        let formatsSelection = cursor.length > 0 && NSMaxRange(cursor) <= length
        let range = formatsSelection ? cursor : NSRange(location: 0, length: length)
        let options = formatOptions
        formatRuns.start({
            if formatsSelection { return SQLFormatter.formatSelection(in: source, range: range, options: options) }
            return SQLFormatter.format(source, options: options).map { SQLFormatEdit(range: range, replacement: $0) }
        }, apply: { [weak self] edit in
            self?.applyFormat(edit, source: source, cursor: cursor, formatsSelection: formatsSelection)
        })
    }

    private func applyFormat(_ edit: SQLFormatEdit?, source: String, cursor: NSRange, formatsSelection: Bool) {
        guard let edit else {
            noteFormatSkipped("Format SQL skipped: couldn't prove the result equivalent")
            return
        }
        let nsSource = source as NSString
        guard edit.replacement != nsSource.substring(with: edit.range) else { return }
        let newSelection = formatsSelection
            ? NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
            : NSRange(location: SQLFormatter.mapOffset(cursor.location, from: source, to: edit.replacement), length: 0)
        if editorController.isAttached {
            // Refused when the editor text changed or an input method started composing meanwhile.
            if !editorController.replace(edit.range, with: edit.replacement, expecting: source, actionName: "Format SQL", selecting: newSelection) {
                noteFormatSkipped(editorController.state?.isComposing == true ? "Format SQL skipped while composing"
                                                                               : "Format SQL skipped: the text changed")
            }
        } else if text == source {
            // No editor yet (a tab opened from launch arguments): replace the text directly.
            text = nsSource.replacingCharacters(in: edit.range, with: edit.replacement)
            selection = newSelection
        } else {
            noteFormatSkipped("Format SQL skipped: the text changed")
        }
    }

    init(title: String, text: String, database: String?, catalog: String, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        lineIndex = SQLLineIndex(text)
        self.database = database
        self.catalog = catalog
        self.workspace = workspace
        session = workspace.client.openSession(database: database, catalog: catalog)
        self.selection = NSRange(location: (text as NSString).length, length: 0)
        scheduleLint(after: .zero)
    }

    var selectedOutcome: StatementOutcome? {
        outcomes.first { $0.id == selectedOutcomeID } ?? outcomes.last
    }

    // MARK: Diagnostics

    /// Server and local diagnostics, in text order.
    var diagnostics: [SQLDiagnostic] {
        guard !localDiagnostics.isEmpty else { return serverDiagnostics }
        guard !serverDiagnostics.isEmpty else { return localDiagnostics }
        // Server first on ties, so the order is deterministic and the editor does not re-highlight needlessly.
        return (serverDiagnostics + localDiagnostics).sorted {
            ($0.range.lowerBound, $0.source == .server ? 0 : 1, $0.range.upperBound) < ($1.range.lowerBound, $1.source == .server ? 0 : 1, $1.range.upperBound)
        }
    }

    /// The marker of a result's error, while it is still valid.
    func serverDiagnostic(for outcome: StatementOutcome) -> SQLDiagnostic? {
        serverDiagnostics.first { $0.origin == outcome.id }
    }

    /// Called by the editor before it writes the edited text: keeps markers, run anchors and the line
    /// index on their text.
    func editorDidEdit(_ edits: [SQLTextEdit]) {
        editorEditPending = true
        guard !edits.isEmpty else { return }
        for edit in edits where !lineIndexIsStale {
            if !lineIndex.apply(edit) { lineIndexIsStale = true }
        }
        let server = SQLDiagnosticTracker.apply(edits, to: serverDiagnostics)
        if server != serverDiagnostics { serverDiagnostics = server }
        let local = SQLDiagnosticTracker.apply(edits, to: localDiagnostics)
        if local != localDiagnostics { localDiagnostics = local }
        if !runAnchors.isEmpty { runAnchors = SQLDiagnosticTracker.apply(edits, to: runAnchors) }
    }

    /// Selects a diagnostic's text in the editor (which scrolls to it).
    func reveal(_ diagnostic: SQLDiagnostic) {
        let length = (text as NSString).length
        let lower = min(max(0, diagnostic.range.lowerBound), length)
        let upper = min(max(lower, diagnostic.range.upperBound), length)
        selection = NSRange(location: lower, length: upper - lower)
    }

    /// 1-based line and column of an offset in `text` (O(log lines + line length)).
    func position(of offset: Int) -> SQLTextPosition {
        lineIndex.position(of: offset, in: text as NSString)
    }

    private func rebuildLineIndex() {
        lineIndex = SQLLineIndex(text)
        lineIndexIsStale = false
    }

    private func textWasReplaced() {
        rebuildLineIndex()
        if !serverDiagnostics.isEmpty { serverDiagnostics = [] }
        if !localDiagnostics.isEmpty { localDiagnostics = [] }
        runAnchors = runAnchors.map { _ in nil }
    }

    /// Re-checks the text off the main actor once typing pauses; a newer edit cancels the check.
    private func scheduleLint(after delay: Duration = .milliseconds(300)) {
        lintTask?.cancel()
        let snapshot = text
        let blocks = readsDollarQuotedBlocks
        lintTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .utility) { SQLLinter.diagnose(snapshot, dollarQuotedBlocks: blocks) }.value
            // Any edit since the snapshot cancelled this task (both run on the main actor).
            guard let self, !Task.isCancelled else { return }
            if found != self.localDiagnostics { self.localDiagnostics = found }
        }
    }

    // MARK: Running

    /// Selection if any, otherwise the statement under the cursor.
    func runCurrent() {
        if let selected = selectedText {
            run(SQLStatementSplitter.split(selected).map { PlannedStatement(sql: $0.text, editorOffset: selection.location + $0.range.lowerBound) })
            return
        }
        guard let statement = SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        run([PlannedStatement(sql: statement.text, editorOffset: statement.range.lowerBound)])
    }

    func runAll() {
        run(SQLStatementSplitter.split(text).map { PlannedStatement(sql: $0.text, editorOffset: $0.range.lowerBound) })
    }

    func explain(costs: Bool) {
        let selected = selectedText
        guard let statement = selected.map({ SQLStatementSplitter.split($0).first })
            ?? SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        let base = selected == nil ? 0 : selection.location
        let body = statement.text
        guard SQLStatementKind.of(body) != .explain else {
            return run([PlannedStatement(sql: body, editorOffset: base + statement.range.lowerBound)])
        }
        let prefix = costs ? "EXPLAIN COSTS " : "EXPLAIN "
        run([PlannedStatement(sql: prefix + body, editorOffset: base + statement.range.lowerBound, prefixLength: prefix.utf16.count)])
    }

    /// The selected text, when the selection is non-empty and inside the text.
    private var selectedText: String? {
        let nsText = text as NSString
        guard selection.length > 0, selection.location >= 0, NSMaxRange(selection) <= nsText.length else { return nil }
        return nsText.substring(with: selection)
    }

    func stop() {
        guard isRunning else { return }
        Task { await session.cancel() }
    }

    /// Runs statements sequentially; stops at the first error.
    private func run(_ statements: [PlannedStatement]) {
        guard !isRunning, !statements.isEmpty else { return }
        serverDiagnostics = []
        runAnchors = statements.map { statement in
            statement.editorOffset.map { $0..<($0 + max(0, statement.sql.utf16.count - statement.prefixLength)) }
        }
        isRunning = true
        runStartedAt = Date()
        outcomes = []
        runTask = Task {
            defer {
                isRunning = false
                runStartedAt = nil
                runAnchors = []
            }
            // Cluster setting changes are always confirmed; other changes when the connection asks for it.
            if let request = RunConfirmation.required(for: statements.map(\.sql), confirmMutations: workspace.profile.confirmMutations) {
                let confirmed = await withCheckedContinuation { continuation in
                    pendingConfirmation = PendingConfirmation(request: request, continuation: continuation)
                }
                guard confirmed else { return }
            }
            for (index, statement) in statements.enumerated() {
                let succeeded = await execute(statement, index: index)
                if !succeeded || Task.isCancelled { break }
            }
        }
    }

    func resolveConfirmation(_ confirmed: Bool) {
        pendingConfirmation?.continuation.resume(returning: confirmed)
        pendingConfirmation = nil
    }

    private func execute(_ statement: PlannedStatement, index: Int) async -> Bool {
        let sql = statement.sql
        let kind = SQLStatementKind.of(sql)
        var executed = sql
        var limitApplied: Int?
        var mapping = SQLExecutedTextMapping(prefixLength: statement.prefixLength)
        if kind == .query, autoLimit > 0 {
            let outcome = AutoLimit.apply(to: sql, limit: autoLimit)
            if outcome.applied {
                executed = outcome.sql
                limitApplied = autoLimit
                mapping.insertion = outcome.insertion
            }
        }
        let outcome = StatementOutcome(index: index, sql: sql, executedSQL: executed, kind: kind)
        outcome.limitApplied = limitApplied
        outcomes.append(outcome)
        selectedOutcomeID = outcome.id

        let clock = ContinuousClock()
        let started = clock.now
        var historyEntry = QueryHistoryEntry(sql: sql, database: database, durationMilliseconds: 0)
        var failure: String?
        do {
            let results = try await session.run(executed, limits: RowLimits(maxRows: Self.hardRowCap))
            outcome.results = results
            if let rowSet = outcome.rowSet { historyEntry.rowCount = rowSet.rows.count }
            historyEntry.affectedRows = results.reduce(0) { $0 &+ $1.affectedRows }
            database = await session.database
            catalog = await session.catalog ?? SQLText.defaultCatalog
            if kind == .definition || kind == .use { refreshSidebar(after: sql) }
        } catch {
            outcome.errorMessage = describe(error)
            outcome.errorCode = (error as? StarRocksError)?.code
            historyEntry.errorMessage = outcome.errorMessage
            failure = (error as? StarRocksError)?.message ?? describe(error)
        }
        // Measured before locating the error, which is not part of the statement's run time.
        let elapsed = clock.now - started
        outcome.durationMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        historyEntry.durationMilliseconds = outcome.durationMilliseconds
        if let failure {
            let (parsed, diagnostic) = await diagnose(failure, statement: statement, executed: executed, mapping: mapping,
                                                      index: index, origin: outcome.id)
            outcome.serverError = parsed
            if let diagnostic { serverDiagnostics.append(diagnostic) }
        }
        outcome.isRunning = false
        await workspace.history.append(historyEntry)
        return outcome.errorMessage == nil
    }

    /// Parses a failure and, unless the statement was edited while it ran, its editor marker. Both run
    /// off the main actor: messages can echo a huge statement, and locating lexes it.
    private func diagnose(_ message: String, statement: PlannedStatement, executed: String, mapping: SQLExecutedTextMapping,
                          index: Int, origin: UUID) async -> (SQLServerError, SQLDiagnostic?) {
        let wantsMarker = runAnchors.indices.contains(index) && runAnchors[index] != nil
        let sql = statement.sql
        let prefixLength = statement.prefixLength
        let (parsed, located) = await Task.detached(priority: .userInitiated) { () -> (SQLServerError, Range<Int>?) in
            let parsed = SQLServerError.parse(message)
            guard wantsMarker else { return (parsed, nil) }
            let units = Array(sql.utf16)
            let source = String(decoding: units[min(max(0, prefixLength), units.count)...], as: UTF16.self)
            return (parsed, SQLErrorLocator.range(in: source, executed: executed, mapping: mapping, error: parsed))
        }.value
        // Re-read the anchor: the user may have typed while the statement was being located.
        guard let range = located, runAnchors.indices.contains(index), let anchor = runAnchors[index],
              range.upperBound <= anchor.count else { return (parsed, nil) }
        let marked = (anchor.lowerBound + range.lowerBound)..<(anchor.lowerBound + range.upperBound)
        return (parsed, SQLDiagnostic(range: marked, scope: anchor, severity: .error, source: .server, message: parsed.summary, origin: origin))
    }

    private func refreshSidebar(after sql: String) {
        guard let database, catalog == workspace.selectedCatalog else { return }
        if SessionContextChange.parse(sql) == nil { workspace.loadObjects(database: database, force: true) }
    }

    /// Changes the session database (`USE`).
    func use(database name: String) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                // Databases in the menu belong to the sidebar's catalog.
                _ = try await session.run("USE \(SQLText.qualified(workspace.selectedCatalog, name))")
                database = await session.database
                catalog = await session.catalog ?? SQLText.defaultCatalog
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }

    // MARK: Completion

    func completions(text: String, cursor: Int) async -> CompletionResult {
        let (database, catalog) = (self.database, self.catalog)
        var result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(currentDatabase: database, catalog: catalog))
        if result.needsMoreSchema {
            await workspace.ensureSchema(columns: result.missingColumns, databases: result.missingDatabases, catalog: catalog)
            result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(currentDatabase: database, catalog: catalog))
        }
        return result
    }

    /// Runs the (pure) completion engine off the main actor.
    private nonisolated static func complete(text: String, cursor: Int, schema: SchemaSnapshot) async -> CompletionResult {
        await Task.detached(priority: .userInitiated) {
            CompletionEngine.complete(text: text, cursor: cursor, schema: schema)
        }.value
    }

    // MARK: Export

    /// Saves the whole result as `format`, written off the main actor. INSERTs go to the result's source table.
    func export(_ result: ResultSet, sql: String, as format: ExportFormat) {
        let baseName = Self.exportBaseName(result, sql: sql, fallback: title)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType(for: format)]
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await write(result, sql: sql, as: format, to: url) }
    }

    /// Writes the result to `url` off the main actor and reports the outcome in a toast.
    func write(_ result: ResultSet, sql: String, as format: ExportFormat, to url: URL) async {
        let (columns, rows) = (result.columns, result.rows)
        let table = ResultExport.insertTarget(columns: columns, sql: sql)
        let sheetName = Self.exportBaseName(result, sql: sql, fallback: title)
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try ResultExport.write(format, to: url, columns: columns, rows: rows, table: table, sheetName: sheetName)
            }.value
            var message = "Exported \(Format.count(summary.rows)) rows to \(url.lastPathComponent)"
            if summary.truncatedCells > 0 {
                message += "; \(Format.count(summary.truncatedCells)) values cut to Excel's 32,767 characters"
            }
            workspace.showToast(message)
        } catch {
            workspace.showToast("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// Automated checks (`--export excel --export-to /path/result.xlsx` with `--auto-run`): waits for the run, then
    /// writes the selected result exactly as Export does.
    func runAutomatedExport(format raw: String, to path: String) async {
        guard let format = ExportFormat(rawValue: raw) else { return }
        for _ in 0..<600 where isRunning || outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        guard let outcome = selectedOutcome, let rowSet = outcome.rowSet else { return }
        await write(rowSet, sql: outcome.executedSQL, as: format, to: URL(fileURLWithPath: path))
    }

    /// Copies the whole result as `format` (text formats only).
    func copy(_ result: ResultSet, sql: String, as format: ExportFormat) {
        guard format.isCopyable else { return }
        let (columns, rows) = (result.columns, result.rows)
        let table = ResultExport.insertTarget(columns: columns, sql: sql)
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                ResultExport.render(format, columns: columns, rows: rows, table: table)
            }.value
            Pasteboard.copy(text)
            workspace.showToast("Copied \(Format.count(rows.count)) rows as \(format.displayName)")
        }
    }

    /// The source table when every column comes from one, else the tab's title; safe as a file name.
    static func exportBaseName(_ result: ResultSet, sql: String?, fallback: String) -> String {
        let name = ResultExport.sourceTableName(columns: result.columns, sql: sql) ?? fallback
        let unsafe: Set<Character> = ["/", ":", "\\", " "]
        let cleaned = String(name.map { (character: Character) -> Character in
            unsafe.contains(character) || character.isNewline ? "_" : character
        })
        return cleaned.isEmpty ? "result" : cleaned
    }

    static func contentType(for format: ExportFormat) -> UTType {
        switch format {
        case .csv: .commaSeparatedText
        case .tsv: .tabSeparatedText
        case .excel: UTType(filenameExtension: "xlsx") ?? .data
        case .insert, .multiRowInsert: UTType(filenameExtension: "sql") ?? .plainText
        }
    }

    func close() {
        runTask?.cancel()
        lintTask?.cancel()
        if let pendingConfirmation { pendingConfirmation.continuation.resume(returning: false) }
        pendingConfirmation = nil
        let session = session
        Task { await session.cancel(graceSeconds: 1); await session.close() }
    }
}
