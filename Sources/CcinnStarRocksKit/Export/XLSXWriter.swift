import Foundation

/// A one-sheet Excel workbook (Office Open XML, `.xlsx`) written without any dependency: a bold, frozen header row,
/// column widths from the data, numbers as numbers where Excel keeps them exactly, everything else as exact text.
/// Shared verbatim by the ccinn* apps.
public enum XLSXWriter {
    /// How a column's values are stored.
    /// Integers and decimals become number cells only when Excel keeps the value exactly (at most 15 significant
    /// digits, no leading zeros) and text otherwise, so 64-bit IDs and ZEROFILL values survive.
    public enum CellKind: Sendable, Hashable {
        case text
        /// Shown with every digit (format `0`), never as 1.2E+12.
        case integer
        /// Shown with `scale` decimals (`0.00`); Excel's General format when the scale is unknown or above 30.
        case decimal(scale: Int?)
        /// Floating point: any finite value, plain or exponent notation, in Excel's General format.
        case approximateNumber
    }

    public struct Summary: Sendable, Equatable {
        public let rows: Int
        /// Values longer than Excel's 32,767-character cell limit, cut to the limit.
        public let truncatedCells: Int

        public init(rows: Int, truncatedCells: Int) {
            self.rows = rows
            self.truncatedCells = truncatedCells
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case tooManyRows(Int, limit: Int)
        case tooManyColumns(Int)

        public var errorDescription: String? {
            switch self {
            case let .tooManyRows(count, limit):
                "Excel holds at most \(limit.formatted()) rows under the header; this result has \(count.formatted()). Export it as CSV instead."
            case let .tooManyColumns(count):
                "Excel holds at most \(XLSXWriter.maxColumns.formatted()) columns; this result has \(count.formatted()). Export it as CSV instead."
            }
        }
    }

    /// Excel's grid: 1,048,576 rows (one is the header) by 16,384 columns; 32,767 characters per cell.
    public static let maxDataRows = 1_048_575
    public static let maxColumns = 16_384
    public static let maxCellCharacters = 32_767

    /// Writes the workbook to `url`. Nothing is left behind when it fails; results beyond Excel's grid are refused
    /// before anything is written.
    @discardableResult
    public static func write(to url: URL, sheetName: String, header: [String], kinds: [CellKind], rows: [[String?]],
                             rowLimit: Int = maxDataRows) throws -> Summary {
        guard header.count <= maxColumns else { throw Failure.tooManyColumns(header.count) }
        guard rows.count <= rowLimit else { throw Failure.tooManyRows(rows.count, limit: rowLimit) }
        do {
            let archive = try ZipArchiveWriter(url: url)
            try archive.addEntry("[Content_Types].xml", data: Data(contentTypes.utf8))
            try archive.addEntry("_rels/.rels", data: Data(packageRelationships.utf8))
            try archive.addEntry("xl/workbook.xml", data: Data(workbook(sheetName: sheetName).utf8))
            try archive.addEntry("xl/_rels/workbook.xml.rels", data: Data(workbookRelationships.utf8))
            let plan = StylePlan(kinds: kinds)
            try archive.addEntry("xl/styles.xml", data: Data(plan.xml.utf8))
            var truncated = 0
            try archive.addEntry("xl/worksheets/sheet1.xml") { write in
                truncated = try writeSheet(header: header, kinds: kinds, styles: plan.columnStyles, rows: rows, emit: write)
            }
            try archive.finish()
            return Summary(rows: rows.count, truncatedCells: truncated)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: Sheet

    /// Streams `sheet1.xml` in ~1 MB pieces; returns how many cells were cut to the limit.
    private static func writeSheet(header: [String], kinds: [CellKind], styles: [Int?], rows: [[String?]], emit: (Data) throws -> Void) throws -> Int {
        let columnNames = header.indices.map(columnName)
        var truncated = 0
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>\
        </sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/>
        """
        if !header.isEmpty {
            xml += "<cols>"
            for (index, width) in columnWidths(header: header, rows: rows).enumerated() {
                xml += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }
        xml += "<sheetData><row r=\"1\">"
        for (index, name) in header.enumerated() {
            let (text, cut) = cellText(name)
            if cut { truncated += 1 }
            xml += "<c r=\"\(columnNames[index])1\" s=\"1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(text)</t></is></c>"
        }
        xml += "</row>"

        for (rowIndex, row) in rows.enumerated() {
            let rowNumber = rowIndex + 2
            xml += "<row r=\"\(rowNumber)\">"
            for index in header.indices where index < row.count {
                guard let value = row[index] else { continue }
                let reference = "\(columnNames[index])\(rowNumber)"
                if isNumberCell(value, kind: index < kinds.count ? kinds[index] : .text) {
                    let style = index < styles.count ? styles[index].map { " s=\"\($0)\"" } ?? "" : ""
                    xml += "<c r=\"\(reference)\"\(style)><v>\(value)</v></c>"
                } else {
                    let (text, cut) = cellText(value)
                    if cut { truncated += 1 }
                    xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(text)</t></is></c>"
                }
            }
            xml += "</row>"
            if xml.utf8.count >= 1 << 20 {
                try emit(Data(xml.utf8))
                xml.removeAll(keepingCapacity: true)
            }
        }
        xml += "</sheetData></worksheet>"
        try emit(Data(xml.utf8))
        return truncated
    }

    /// Whether `value` becomes a number cell. The text must already be a number literal Excel reads as such.
    static func isNumberCell(_ value: String, kind: CellKind) -> Bool {
        switch kind {
        case .text:
            return false
        case .integer, .decimal:
            guard let digits = plainNumberDigits(value, allowExponent: false) else { return false }
            let significant = digits.drop { $0 == 0x30 } // leading zeros of "0.000123" are not significant
            return significant.count <= 15
        case .approximateNumber:
            return plainNumberDigits(value, allowExponent: true) != nil && Double(value).map(\.isFinite) == true
        }
    }

    /// The digits of `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, or `nil` when `value` is anything else.
    private static func plainNumberDigits(_ value: String, allowExponent: Bool) -> [UInt8]? {
        var bytes = Array(value.utf8)[...]
        if bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        let isDigit: (UInt8) -> Bool = { $0 >= 0x30 && $0 <= 0x39 }
        let integer = bytes.prefix(while: isDigit)
        guard !integer.isEmpty, integer.first != 0x30 || integer.count == 1 else { return nil }
        var digits = Array(integer)
        bytes = bytes.dropFirst(integer.count)
        if bytes.first == UInt8(ascii: ".") {
            let fraction = bytes.dropFirst().prefix(while: isDigit)
            guard !fraction.isEmpty else { return nil }
            digits += fraction
            bytes = bytes.dropFirst(1 + fraction.count)
        }
        if allowExponent, let marker = bytes.first, marker == UInt8(ascii: "e") || marker == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
            let exponent = bytes.prefix(while: isDigit)
            guard !exponent.isEmpty else { return nil }
            bytes = bytes.dropFirst(exponent.count)
        }
        return bytes.isEmpty ? digits : nil
    }

    /// XML text for a cell, cut to Excel's limit. Control characters XML cannot carry are written as ECMA-376 `_xHHHH_`
    /// escapes, and so is the `_` of a literal `_xHHHH_` (which Excel would otherwise decode); CR is `&#13;`.
    static func cellText(_ value: String) -> (text: String, truncated: Bool) {
        var value = value
        var truncated = false
        if value.utf16.count > maxCellCharacters {
            var kept = 0
            var end = value.startIndex
            for index in value.indices {
                let width = value[index].utf16.count
                if kept + width > maxCellCharacters { break }
                kept += width
                end = value.index(after: index)
            }
            value = String(value[..<end])
            truncated = true
        }
        var text = ""
        text.reserveCapacity(value.utf8.count)
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "&": text += "&amp;"
            case "<": text += "&lt;"
            case ">": text += "&gt;"
            case "_" where isEscapeSequence(scalars, at: index): text += "_x005F_"
            case "\t", "\n": text.unicodeScalars.append(scalar)
            // A character reference survives XML's line-end normalisation and every reader decodes it; `_x000D_` is
            // decoded by Excel only.
            case "\r": text += "&#13;"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0xFFFE || scalar.value == 0xFFFF:
                text += "_x" + String(format: "%04X", scalar.value) + "_"
            default: text.unicodeScalars.append(scalar)
            }
            index += 1
        }
        return (text, truncated)
    }

    /// `_x` + four hex digits + `_` starting at `index`.
    private static func isEscapeSequence(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + 6 < scalars.count, scalars[index + 1] == "x", scalars[index + 6] == "_" else { return false }
        return scalars[(index + 2)...(index + 5)].allSatisfy { $0.properties.isASCIIHexDigit }
    }

    /// Widths in characters from the header and the first 1,000 rows, between 6 and 60; wide (CJK) characters count twice.
    private static func columnWidths(header: [String], rows: [[String?]]) -> [Int] {
        header.indices.map { index in
            var widest = displayWidth(header[index])
            for row in rows.prefix(1_000) where index < row.count {
                if let value = row[index] { widest = max(widest, displayWidth(value)) }
                if widest >= 60 { break }
            }
            return min(max(widest + 2, 6), 60)
        }
    }

    private static func displayWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars.prefix(80) {
            let value = scalar.value
            let wide = (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value)
                || (0xF900...0xFAFF).contains(value) || (0xFE30...0xFE4F).contains(value) || (0xFF00...0xFF60).contains(value)
                || (0xFFE0...0xFFE6).contains(value) || value >= 0x1_F300
            width += wide ? 2 : 1
        }
        return width
    }

    /// `A`, …, `Z`, `AA`, …, `XFD` for a zero-based column index.
    public static func columnName(_ index: Int) -> String {
        var number = index + 1
        var name: [Character] = []
        while number > 0 {
            let remainder = (number - 1) % 26
            name.insert(Character(Unicode.Scalar(UInt8(65 + remainder))), at: 0)
            number = (number - 1) / 26
        }
        return String(name)
    }

    /// A sheet name Excel accepts: without `[ ] : * ? / \`, not wrapped in apostrophes, at most 31 characters.
    public static func sheetName(_ name: String) -> String {
        var cleaned = String(name.filter { !"[]:*?/\\".contains($0) && !$0.isNewline })
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "'").union(.whitespaces))
        cleaned = String(cleaned.prefix(31)).trimmingCharacters(in: CharacterSet(charactersIn: "'").union(.whitespaces))
        return cleaned.isEmpty ? "Result" : cleaned
    }

    // MARK: Package parts

    private static func workbook(sheetName: String) -> String {
        let (name, _) = cellText(Self.sheetName(sheetName))
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="\(name.replacingOccurrences(of: "\"", with: "&quot;"))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
    </Types>
    """

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
    </Relationships>
    """

    private static let workbookRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    </Relationships>
    """

    /// Cell styles: 0 normal, 1 bold (the header), 2 integer (built-in format 1, `0`: Excel shows every digit where
    /// General would show 1.2E+12), then one per decimal scale with a custom format (ids from 164, the first custom id).
    /// Apple's Quick Look preview shows 12+ digit numbers in E notation whatever the format; the value stays exact.
    struct StylePlan {
        let columnStyles: [Int?]
        let xml: String

        init(kinds: [CellKind]) {
            var scales: [Int] = []
            columnStyles = kinds.map { kind in
                switch kind {
                case .integer, .decimal(scale: 0): return 2
                case let .decimal(scale?) where (1...30).contains(scale):
                    if let index = scales.firstIndex(of: scale) { return 3 + index }
                    scales.append(scale)
                    return 2 + scales.count
                default: return nil
                }
            }
            var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            """
            if !scales.isEmpty {
                xml += "<numFmts count=\"\(scales.count)\">"
                for (index, scale) in scales.enumerated() {
                    xml += "<numFmt numFmtId=\"\(164 + index)\" formatCode=\"0.\(String(repeating: "0", count: scale))\"/>"
                }
                xml += "</numFmts>"
            }
            xml += """
            <fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
            <font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="\(3 + scales.count)"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
            <xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
            """
            for index in scales.indices {
                xml += "<xf numFmtId=\"\(164 + index)\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
            }
            xml += "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
            self.xml = xml
        }
    }
}
