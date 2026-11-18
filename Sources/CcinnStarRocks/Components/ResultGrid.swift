import AppKit
import CcinnStarRocksKit
import MySQLWire
import StarRocksKit
import SwiftUI

/// Value shown in the inspector sheet.
struct InspectedValue: Identifiable {
    let id = UUID()
    let column: String
    let type: String
    let value: String?
}

/// Result grid on NSTableView: virtualised rows, sortable columns (sorted off the main actor),
/// NULL styling, numeric alignment, multi-row copy as TSV/CSV/INSERT and a value inspector.
struct ResultGrid: NSViewRepresentable {
    let resultID: UUID
    let columns: [ColumnDefinition]
    let rows: [[String?]]
    var insertTableName = "`table`"
    var onInspect: (InspectedValue) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 21
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tableView.menu = context.coordinator.makeMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.tableView = tableView
        context.coordinator.load(self)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.resultID != resultID
        coordinator.parent = self
        if changed { coordinator.load(self) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ResultGrid
        weak var tableView: NSTableView?
        private var order: [Int]?
        private var sortTask: Task<Void, Never>?
        private static let rowNumberID = NSUserInterfaceItemIdentifier("#")
        private static let cellFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        private static let nullFont = NSFontManager.shared.convert(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), toHaveTrait: .italicFontMask)

        init(_ parent: ResultGrid) {
            self.parent = parent
        }

        func load(_ grid: ResultGrid) {
            guard let tableView else { return }
            sortTask?.cancel()
            order = nil
            tableView.sortDescriptors = []
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }

            let numberColumn = NSTableColumn(identifier: Self.rowNumberID)
            numberColumn.title = "#"
            numberColumn.width = max(36, CGFloat(String(grid.rows.count).count) * 8 + 14)
            numberColumn.minWidth = 30
            numberColumn.resizingMask = []
            tableView.addTableColumn(numberColumn)

            for (index, definition) in grid.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = definition.name
                column.headerToolTip = "\(definition.name) · \(Self.typeName(definition.type))"
                column.minWidth = 48
                column.maxWidth = 1600
                column.width = Self.estimateWidth(column: index, title: definition.name, rows: grid.rows)
                column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
                if definition.type.isNumeric { column.headerCell.alignment = .right }
                tableView.addTableColumn(column)
            }
            tableView.reloadData()
            tableView.scrollRowToVisible(0)
        }

        static func estimateWidth(column: Int, title: String, rows: [[String?]]) -> CGFloat {
            var longest = title.count + 2
            for row in rows.prefix(200) where column < row.count {
                longest = max(longest, min(60, (row[column] ?? "NULL").count))
            }
            return min(420, max(64, CGFloat(longest) * 7.2 + 16))
        }

        static func typeName(_ type: ColumnType) -> String {
            switch type.kind {
            case .integer: "integer"
            case .float: "float"
            case .decimal: "decimal"
            case .date: "date"
            case .dateTime: "datetime"
            case .time: "time"
            case .json: "json"
            case .binary: "binary"
            case .null: "null"
            case .text: "string"
            }
        }

        private func rowIndex(_ displayRow: Int) -> Int {
            guard let order else { return displayRow }
            return order.indices.contains(displayRow) ? order[displayRow] : displayRow
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, parent.rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            guard let field = cell.textField else { return cell }
            if tableColumn.identifier == Self.rowNumberID {
                field.stringValue = String(row + 1)
                field.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
                field.textColor = .tertiaryLabelColor
                field.alignment = .right
                cell.toolTip = nil
                return cell
            }
            guard let column = Int(tableColumn.identifier.rawValue), parent.columns.indices.contains(column) else { return cell }
            let values = parent.rows[rowIndex(row)]
            let value = column < values.count ? values[column] : nil
            field.alignment = parent.columns[column].type.isNumeric ? .right : .left
            if let value {
                field.font = Self.cellFont
                field.textColor = .labelColor
                field.stringValue = Self.display(value)
                cell.toolTip = value.count > 60 ? String(value.prefix(2_000)) : nil
            } else {
                field.font = Self.nullFont
                field.textColor = .tertiaryLabelColor
                field.stringValue = "NULL"
                cell.toolTip = nil
            }
            return cell
        }

        static func display(_ value: String) -> String {
            let clipped = value.count > 500 ? String(value.prefix(500)) + "…" : value
            guard clipped.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else { return clipped }
            return clipped.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let column = Int(key),
                  parent.columns.indices.contains(column) else {
                order = nil
                tableView.reloadData()
                return
            }
            let rows = parent.rows
            let ascending = descriptor.ascending
            let numeric = parent.columns[column].type.isNumeric
            sortTask?.cancel()
            sortTask = Task { [weak self] in
                let sorted = await Task.detached(priority: .userInitiated) {
                    Self.sortedOrder(rows: rows, column: column, numeric: numeric, ascending: ascending)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.order = sorted
                self.tableView?.reloadData()
            }
        }

        nonisolated static func sortedOrder(rows: [[String?]], column: Int, numeric: Bool, ascending: Bool) -> [Int] {
            let values: [String?] = rows.map { column < $0.count ? $0[column] : nil }
            let numbers: [Double?]? = numeric ? values.map { $0.flatMap(TextValue.double) } : nil
            return rows.indices.sorted { lhs, rhs in
                let ordered: Bool
                switch (values[lhs], values[rhs]) {
                case (nil, nil): return lhs < rhs
                case (nil, _): ordered = true
                case (_, nil): ordered = false
                case let (left?, right?):
                    if let numbers, let a = numbers[lhs], let b = numbers[rhs] {
                        if a == b { return lhs < rhs }
                        ordered = a < b
                    } else {
                        let comparison = left.localizedStandardCompare(right)
                        if comparison == .orderedSame { return lhs < rhs }
                        ordered = comparison == .orderedAscending
                    }
                }
                return ascending ? ordered : !ordered
            }
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            inspect(row: sender.clickedRow, column: sender.clickedColumn)
        }

        private func inspect(row: Int, column tableColumnIndex: Int) {
            guard let tableView, parent.rows.indices.contains(row), tableView.tableColumns.indices.contains(tableColumnIndex),
                  let column = Int(tableView.tableColumns[tableColumnIndex].identifier.rawValue), parent.columns.indices.contains(column) else { return }
            let values = parent.rows[rowIndex(row)]
            parent.onInspect(InspectedValue(column: parent.columns[column].name, type: Self.typeName(parent.columns[column].type),
                                            value: column < values.count ? values[column] : nil))
        }

        private var targetRows: [Int] {
            guard let tableView else { return [] }
            let clicked = tableView.clickedRow
            if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) { return [clicked] }
            return tableView.selectedRowIndexes.map { $0 }
        }

        private func selectedData() -> [[String?]] {
            targetRows.filter(parent.rows.indices.contains).map { parent.rows[rowIndex($0)] }
        }

        func copySelectionAsTSV() {
            let rows = selectedData()
            guard !rows.isEmpty else { return }
            Pasteboard.copy(ResultExport.tsv(columns: parent.columns, rows: rows, includeHeader: rows.count > 1))
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy Value", action: #selector(copyValue), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Rows", action: #selector(copyRows), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Rows as CSV", action: #selector(copyCSV), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Rows as INSERT", action: #selector(copyInsert), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Rows as Multi-row INSERT", action: #selector(copyMultiRowInsert), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Column Name", action: #selector(copyColumnName), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Inspect Value…", action: #selector(inspectValue), keyEquivalent: "").target = self
            return menu
        }

        @objc private func copyValue() {
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0,
                  let column = Int(tableView.tableColumns[tableView.clickedColumn].identifier.rawValue),
                  parent.rows.indices.contains(tableView.clickedRow) else { return }
            let values = parent.rows[rowIndex(tableView.clickedRow)]
            Pasteboard.copy((column < values.count ? values[column] : nil) ?? "NULL")
        }

        @objc private func copyRows() { copySelectionAsTSV() }

        @objc private func copyCSV() {
            let rows = selectedData()
            if !rows.isEmpty { Pasteboard.copy(ResultExport.csv(columns: parent.columns, rows: rows)) }
        }

        @objc private func copyInsert() {
            let rows = selectedData()
            if !rows.isEmpty { Pasteboard.copy(ResultExport.insertStatements(table: parent.insertTableName, columns: parent.columns, rows: rows)) }
        }

        @objc private func copyMultiRowInsert() {
            let rows = selectedData()
            if !rows.isEmpty { Pasteboard.copy(ResultExport.multiRowInsert(table: parent.insertTableName, columns: parent.columns, rows: rows)) }
        }

        @objc private func copyColumnName() {
            guard let tableView, tableView.clickedColumn >= 0 else { return }
            Pasteboard.copy(tableView.tableColumns[tableView.clickedColumn].title)
        }

        @objc private func inspectValue() {
            guard let tableView else { return }
            inspect(row: tableView.clickedRow, column: tableView.clickedColumn)
        }
    }
}

final class GridTableView: NSTableView {
    weak var coordinator: ResultGrid.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelectionAsTSV()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRowIndexes.count > 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// Full value of one cell, with JSON pretty-printing.
struct ValueInspectorView: View {
    let value: InspectedValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(value.column).font(.headline)
                Badge(text: value.type, color: Theme.accent)
                Spacer()
                if let text = value.value {
                    Text("\(text.count.formatted()) characters").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(formatted)
                    .font(Theme.monospaced)
                    .foregroundStyle(value.value == nil ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Copy") { Pasteboard.copy(value.value ?? "NULL") }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620, height: 440)
    }

    private var formatted: String {
        guard let text = value.value else { return "NULL" }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return text
    }
}
