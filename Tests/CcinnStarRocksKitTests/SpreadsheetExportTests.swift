import Foundation
import Testing
@testable import CcinnStarRocksKit

// The ZIP container and the Excel workbook writer. Verified with the system's own tools (`unzip`, `xmllint`) and by
// reading the sheet back, so the writer is never checked only against itself.

private func temporaryURL(_ fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-export-\(UUID().uuidString).\(fileExtension)")
}

private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

private func entry(_ name: String, of archive: URL) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    // unzip reads entry names as wildcard patterns: `[[]` is a literal `[` (as in `[Content_Types].xml`).
    process.arguments = ["-p", archive.path, name.replacingOccurrences(of: "[", with: "[[]")]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

/// One cell as the sheet stores it: `type` is the `t` attribute (`nil` for a number), `value` the decoded text.
struct SheetCell: Equatable {
    var reference: String
    var type: String?
    var style: String?
    var value: String
}

/// Reads `xl/worksheets/sheet1.xml` back: cells by reference, `_xHHHH_` escapes decoded.
private final class SheetReader: NSObject, XMLParserDelegate {
    var cells: [String: SheetCell] = [:]
    var frozenRows: String?
    private var current: SheetCell?
    private var text = ""
    private var collecting = false

    static func read(_ data: Data) throws -> SheetReader {
        let reader = SheetReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return reader
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "c": current = SheetCell(reference: attributes["r"] ?? "?", type: attributes["t"], style: attributes["s"], value: "")
        case "v", "t":
            collecting = true
            text = ""
        case "pane": frozenRows = attributes["ySplit"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t":
            collecting = false
            current?.value = Self.decode(text)
        case "c":
            if let current { cells[current.reference] = current }
            current = nil
        default: break
        }
    }

    /// `_x000D_` → CR, `_x005F_` → `_` (ECMA-376 ST_Xstring).
    static func decode(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "_", let end = text.index(index, offsetBy: 7, limitedBy: text.endIndex), text[text.index(before: end)] == "_",
               text[text.index(after: index)] == "x", let code = UInt32(text[text.index(index, offsetBy: 2)..<text.index(index, offsetBy: 6)], radix: 16),
               let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
                index = end
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }
}

@Suite("ZIP building blocks")
struct ZipBuildingBlockTests {
    @Test func crc32MatchesPublishedVectors() {
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
        var split = CRC32()
        split.update(Data("1234".utf8))
        split.update(Data("56789".utf8))
        #expect(split.checksum == 0xCBF4_3926)
    }

    @Test func deflateRoundTripsAcrossManyChunks() throws {
        var input = Data()
        for index in 0..<20_000 { input.append(contentsOf: Array("row \(index) – \(index * 7919 % 104_729) 吉隆坡\n".utf8)) }
        let encoder = try DeflateEncoder()
        var compressed = Data()
        var offset = 0
        while offset < input.count {
            let end = min(offset + 4_093, input.count)
            try encoder.encode(input.subdata(in: offset..<end), final: false) { compressed.append($0) }
            offset = end
        }
        try encoder.encode(Data(), final: true) { compressed.append($0) }
        #expect(compressed.count < input.count / 2)
        #expect(try (compressed as NSData).decompressed(using: .zlib) as Data == input)
    }

    @Test func archiveIsReadByUnzip() throws {
        let url = temporaryURL("zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ZipArchiveWriter(url: url)
        try writer.addEntry("a.txt", data: Data("hello".utf8))
        try writer.addEntry("dir/b.txt") { write in
            for index in 0..<5_000 { try write(Data("line \(index)\n".utf8)) }
        }
        try writer.addEntry("empty.txt", data: Data())
        try writer.finish()
        let test = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0, "\(test.output)")
        #expect(String(decoding: try entry("a.txt", of: url), as: UTF8.self) == "hello")
        let lines = String(decoding: try entry("dir/b.txt", of: url), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 5_000)
        #expect(lines.last == "line 4999")
        #expect(try entry("empty.txt", of: url).isEmpty)
    }
}

@Suite("Excel workbook")
struct ExcelWorkbookTests {
    @Test func columnNames() {
        #expect([0, 25, 26, 51, 701, 702, 16_383].map(XLSXWriter.columnName) == ["A", "Z", "AA", "AZ", "ZZ", "AAA", "XFD"])
    }

    @Test func sheetNamesFollowExcelsRules() {
        #expect(XLSXWriter.sheetName("orders/2026:Q1 [draft]?*") == "orders2026Q1 draft")
        #expect(XLSXWriter.sheetName("") == "Result")
        #expect(XLSXWriter.sheetName("'quoted'") == "quoted")
        #expect(XLSXWriter.sheetName(String(repeating: "x", count: 40)).count == 31)
    }

    @Test func workbookIsAValidPackageWithTypedExactCells() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows: [[String?]] = [
            ["1", "Alice", "12.50", "0.30000000000000004", "1234567890123456789", "a<b & \"c\" > d", "2026-11-19 08:00:00"],
            ["-2", nil, "-0.5", "1e+20", "42", "  padded  \nline2\r\ttab\u{1}", "2026-11-19"],
            ["3", "李雷 🚀", "NaN", "Infinity", "000000000000000012", "_x0041_ literal", nil],
        ]
        let summary = try XLSXWriter.write(to: url, sheetName: "orders", header: ["id", "name", "amount", "ratio", "big_id", "note", "created"],
                                           kinds: [.integer, .text, .decimal(scale: 2), .approximateNumber, .integer, .text, .text], rows: rows)
        #expect(summary == XLSXWriter.Summary(rows: 3, truncatedCells: 0))

        let test = try run("/usr/bin/unzip", ["-t", url.path])
        #expect(test.status == 0, "\(test.output)")
        let listing = try run("/usr/bin/unzip", ["-Z1", url.path]).output.split(separator: "\n").map(String.init)
        #expect(Set(listing) == ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
                                 "xl/worksheets/sheet1.xml"])
        for part in listing {
            let xml = temporaryURL("xml")
            defer { try? FileManager.default.removeItem(at: xml) }
            try entry(part, of: url).write(to: xml)
            let lint = try run("/usr/bin/xmllint", ["--noout", xml.path])
            #expect(lint.status == 0, "\(part): \(lint.output)")
        }
        #expect(String(decoding: try entry("xl/workbook.xml", of: url), as: UTF8.self).contains("<sheet name=\"orders\""))

        let sheet = try SheetReader.read(try entry("xl/worksheets/sheet1.xml", of: url))
        #expect(sheet.frozenRows == "1", "the header row stays visible")
        #expect(sheet.cells["A1"] == SheetCell(reference: "A1", type: "inlineStr", style: "1", value: "id"))
        // Numbers where the value is a plain number Excel keeps exactly; text otherwise. Integers show every digit
        // (format `0`, never 1.2E+12), decimals their scale (`0.00`), floating point Excel's General format.
        #expect(sheet.cells["A2"] == SheetCell(reference: "A2", type: nil, style: "2", value: "1"))
        #expect(sheet.cells["C2"] == SheetCell(reference: "C2", type: nil, style: "3", value: "12.50"))
        #expect(sheet.cells["D2"]?.type == nil && sheet.cells["D2"]?.style == nil, "a double stays a number in General format")
        let styles = String(decoding: try entry("xl/styles.xml", of: url), as: UTF8.self)
        #expect(styles.contains("<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"0.00\"/></numFmts>"))
        #expect(styles.contains("<xf numFmtId=\"1\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"), "built-in `0`")
        #expect(sheet.cells["E2"] == SheetCell(reference: "E2", type: "inlineStr", style: nil, value: "1234567890123456789"),
                "more than 15 digits would be rounded by Excel")
        #expect(sheet.cells["E4"]?.type == "inlineStr", "a number cell would drop ZEROFILL's leading zeros")
        #expect(sheet.cells["E3"] == SheetCell(reference: "E3", type: nil, style: "2", value: "42"))
        #expect(sheet.cells["D3"]?.type == nil && sheet.cells["D3"]?.value == "1e+20")
        #expect(sheet.cells["C4"]?.type == "inlineStr" && sheet.cells["C4"]?.value == "NaN")
        #expect(sheet.cells["D4"]?.type == "inlineStr" && sheet.cells["D4"]?.value == "Infinity")
        // Text comes back exactly: markup characters, whitespace, CR, control characters, literal escapes, CJK and emoji.
        #expect(sheet.cells["F2"]?.value == "a<b & \"c\" > d")
        #expect(sheet.cells["F3"]?.value == "  padded  \nline2\r\ttab\u{1}")
        #expect(sheet.cells["F4"]?.value == "_x0041_ literal")
        #expect(sheet.cells["B4"]?.value == "李雷 🚀")
        #expect(sheet.cells["G2"]?.value == "2026-11-19 08:00:00" && sheet.cells["G2"]?.type == "inlineStr")
        // NULL is an empty cell.
        #expect(sheet.cells["B3"] == nil)
        #expect(sheet.cells["G4"] == nil)
    }

    // One style per distinct scale; scales beyond Excel's 30 decimals, and NOT_FIXED_DEC (31), fall back to General.
    @Test func decimalFormatsPerScale() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXWriter.write(to: url, sheetName: "t", header: ["a", "b", "c", "d", "e"],
                             kinds: [.decimal(scale: 3), .decimal(scale: 0), .decimal(scale: 3), .decimal(scale: 31), .decimal(scale: nil)],
                             rows: [["1.250", "7", "2.000", "0.5", "0.25"]])
        let sheet = try SheetReader.read(try entry("xl/worksheets/sheet1.xml", of: url))
        #expect([sheet.cells["A2"]?.style, sheet.cells["B2"]?.style, sheet.cells["C2"]?.style, sheet.cells["D2"]?.style, sheet.cells["E2"]?.style]
                == ["3", "2", "3", nil, nil])
        let styles = String(decoding: try entry("xl/styles.xml", of: url), as: UTF8.self)
        #expect(styles.contains("<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"0.000\"/></numFmts>"))
        #expect(try run("/usr/bin/unzip", ["-t", url.path]).status == 0)
    }

    @Test func longValuesAreCutToTheCellLimit() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let long = String(repeating: "吉", count: 40_000)
        let summary = try XLSXWriter.write(to: url, sheetName: "t", header: ["v"], kinds: [.text], rows: [[long], ["short"]])
        #expect(summary.truncatedCells == 1)
        let sheet = try SheetReader.read(try entry("xl/worksheets/sheet1.xml", of: url))
        #expect(sheet.cells["A2"]?.value.utf16.count == XLSXWriter.maxCellCharacters)
        #expect(sheet.cells["A3"]?.value == "short")
    }

    @Test func resultsBeyondExcelsGridAreRefusedWithoutAFile() throws {
        let url = temporaryURL("xlsx")
        #expect(throws: XLSXWriter.Failure.tooManyRows(3, limit: 2)) {
            try XLSXWriter.write(to: url, sheetName: "t", header: ["v"], kinds: [.text], rows: [["1"], ["2"], ["3"]], rowLimit: 2)
        }
        #expect(throws: XLSXWriter.Failure.tooManyColumns(16_385)) {
            try XLSXWriter.write(to: url, sheetName: "t", header: Array(repeating: "c", count: 16_385),
                                 kinds: Array(repeating: .text, count: 16_385), rows: [])
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func emptyResultStillOpens() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try XLSXWriter.write(to: url, sheetName: "t", header: ["a", "b"], kinds: [.text, .text], rows: []).rows == 0)
        #expect(try run("/usr/bin/unzip", ["-t", url.path]).status == 0)
        let sheet = try SheetReader.read(try entry("xl/worksheets/sheet1.xml", of: url))
        #expect(sheet.cells.keys.sorted() == ["A1", "B1"])
    }
}
