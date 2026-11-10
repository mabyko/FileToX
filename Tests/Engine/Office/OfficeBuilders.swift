// Test builders ported from Filee's OfficeBuilders.cs and SpreadsheetBuilders.cs.
import Foundation
import XCTest

@testable import FileToXEngineKit

class OfficeTestCase: XCTestCase {
    var folder: String!
    override func setUpWithError() throws {
        folder = FilePath.combine(FileManager.default.temporaryDirectory.path, "ftx-office-" + UUID().uuidString)
        try FileManager.default.createDirectoryIfNeeded(folder)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: folder) }
    func path(_ name: String) -> String { FilePath.combine(folder, name) }
    func convert(
        _ input: String, _ from: String, _ to: String, _ converter: Converter = SpreadsheetConverter(),
        _ pdfA: Bool = false
    ) async throws -> [String] {
        var preset = Preset()
        preset.document.pdfA = pdfA
        return try await converter.convert(
            ConversionStep(
                inputPath: input, from: from, to: to, preset: preset,
                output: OfficeOutput(folder, FilePath.fileNameWithoutExtension(input) + "-out"), workDirectory: folder),
            progress: nil)
    }
    func assertSameCells(
        _ a: Workbook, _ b: Workbook, compareFormats: Bool = true, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.sheets.map(\.name), b.sheets.map(\.name), file: file, line: line)
        for (want, got) in zip(a.sheets, b.sheets) {
            for (r, cells) in want.rows {
                for (c, cell) in cells {
                    guard let other = got.get(r, c) else {
                        XCTFail("\(want.name) R\(r + 1)C\(c + 1) missing", file: file, line: line)
                        continue
                    }
                    XCTAssertEqual(cell.text, other.text, "\(want.name) R\(r + 1)C\(c + 1)", file: file, line: line)
                    XCTAssertEqual(cell.isNumber, other.isNumber, file: file, line: line)
                    XCTAssertEqual(cell.value, other.value, file: file, line: line)
                    if compareFormats { XCTAssertEqual(cell.numberFormat, other.numberFormat, file: file, line: line) }
                    XCTAssertEqual(cell.isBoolean, other.isBoolean, file: file, line: line)
                }
            }
        }
    }
    func libreOffice() throws -> LibreOfficeConverter {
        let dev =
            ProcessInfo.processInfo.environment["FILETOX_LIBREOFFICE"]
            ?? FileManager.default.currentDirectoryPath + "/build/optional-engines/osx-arm64/libreoffice"
        guard
            let copy = EngineEnvironment.folderWithPrograms("libreoffice", dev)
                ?? EngineEnvironment.systemCopyFolder("libreoffice")
        else { throw XCTSkip("soffice missing") }
        EngineEnvironment.ownCopies = ["libreoffice": copy]
        return LibreOfficeConverter(EngineEnvironment(dataDirectory: path("engines")))
    }
}
final class OfficeOutput: OutputAllocator {
    let folder: String, stem: String
    init(_ folder: String, _ stem: String = "out") {
        self.folder = folder
        self.stem = stem
    }
    func allocate(_ ext: String, suffix: String?) throws -> String? {
        FilePath.combine(folder, stem + (suffix ?? "") + "." + ext)
    }
}
final class XlsxBuilder {
    static let namespaces =
        "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
    var strings: [String] = [], sheets: [(String, String, Bool)] = []
    var workbookProperties = ""
    func text(_ ref: String, _ text: String, _ style: Int = 0) -> String {
        let index = strings.firstIndex(of: text) ?? strings.count
        if index == strings.count { strings.append(text) }
        return "<c r=\"\(ref)\" s=\"\(style)\" t=\"s\"><v>\(index)</v></c>"
    }
    static func number(_ ref: String, _ value: Double, _ style: Int = 0) -> String {
        "<c r=\"\(ref)\" s=\"\(style)\"><v>\(SheetXML.number(value))</v></c>"
    }
    static func row(_ n: Int, _ cells: String...) -> String { "<row r=\"\(n)\">\(cells.joined())</row>" }
    func sheet(_ name: String, _ rows: String, _ before: String = "", _ after: String = "", _ hidden: Bool = false) {
        sheets.append(
            (name, "<worksheet \(Self.namespaces)>\(before)<sheetData>\(rows)</sheetData>\(after)</worksheet>", hidden))
    }
    @discardableResult func save(_ path: String) throws -> String {
        let ns = Self.namespaces
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let zip = try ZipWriter(path: path)
        func relationships(_ entries: [(String, String, String)]) -> String {
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + entries.map { "<Relationship Id=\"\($0.0)\" Type=\"\(rel)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined()
                + "</Relationships>"
        }
        try zip.add(
            "_rels/.rels", text: SheetXML.declaration + relationships([("rId1", "officeDocument", "xl/workbook.xml")]))
        try zip.add(
            "xl/workbook.xml",
            text: SheetXML.declaration + "<workbook \(ns)>\(workbookProperties)<sheets>"
                + sheets.enumerated().map {
                    "<sheet name=\"\(SheetXML.escape($0.element.0))\" sheetId=\"\($0.offset + 1)\"\($0.element.2 ? " state=\"hidden\"" : "") r:id=\"rId\($0.offset + 1)\"/>"
                }.joined() + "</sheets></workbook>")
        try zip.add(
            "xl/_rels/workbook.xml.rels",
            text: SheetXML.declaration
                + relationships(
                    sheets.indices.map { ("rId\($0 + 1)", "worksheet", "worksheets/sheet\($0 + 1).xml") } + [
                        ("rIdS", "sharedStrings", "sharedStrings.xml"), ("rIdT", "styles", "styles.xml"),
                    ]))
        try zip.add(
            "xl/sharedStrings.xml",
            text: SheetXML.declaration + "<sst \(ns) count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">"
                + strings.map { "<si><t xml:space=\"preserve\">\(SheetXML.escape($0))</t></si>" }.joined() + "</sst>")
        try zip.add("xl/styles.xml", text: SheetXML.declaration + "<styleSheet \(ns)>\(Self.styleSheet)</styleSheet>")
        for i in sheets.indices {
            try zip.add("xl/worksheets/sheet\(i + 1).xml", text: SheetXML.declaration + sheets[i].1)
        }
        let overrides =
            sheets.indices.map { ("xl/worksheets/sheet\($0 + 1).xml", "spreadsheetml.worksheet") } + [
                ("xl/workbook.xml", "spreadsheetml.sheet.main"),
                ("xl/sharedStrings.xml", "spreadsheetml.sharedStrings"), ("xl/styles.xml", "spreadsheetml.styles"),
            ]
        try zip.add(
            "[Content_Types].xml",
            text: SheetXML.declaration
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + overrides.map {
                    "<Override PartName=\"/\($0.0)\" ContentType=\"application/vnd.openxmlformats-officedocument.\($0.1)+xml\"/>"
                }.joined() + "</Types>")
        try zip.close()
        return path
    }
    static func sales(_ path: String) throws -> String {
        let b = XlsxBuilder()
        let row = Self.row
        let num = Self.number
        b.sheet(
            "매출",
            row(1, b.text("A1", "지점별 매출", 1))
                + row(2, b.text("A2", "지점", 1), b.text("B2", "매출", 1), b.text("C2", "일자", 1), b.text("D2", "성장률", 1))
                + row(3, b.text("A3", "서울 강남"), num("B3", 1_350_000, 2), num("C3", 46296, 3), num("D3", 0.128, 4))
                + row(4, b.text("A4", "부산 서면"), num("B4", 870000, 2), num("C4", 46297, 3), num("D4", 0.09, 4))
                + row(
                    5, b.text("A5", "합계"), "<c r=\"B5\" s=\"5\"><f>SUM(B3:B4)</f><v>2220000</v></c>",
                    "<c r=\"C5\" t=\"b\"><v>1</v></c>",
                    "<c r=\"D5\" t=\"inlineStr\"><is><t>메모, &quot;따옴표&quot;</t></is></c>"),
            "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"2\" topLeftCell=\"A3\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols><col min=\"1\" max=\"1\" width=\"14\" customWidth=\"1\"/><col min=\"2\" max=\"4\" width=\"12\" customWidth=\"1\"/></cols>",
            "<mergeCells count=\"1\"><mergeCell ref=\"A1:D1\"/></mergeCells>")
        b.sheet("메모", row(1, b.text("A1", "첫 줄\n둘째 줄")) + row(2, num("A2", 3.5, 0)))
        b.sheet("비밀", row(1, b.text("A1", "보이면 안 됨")), "", "", true)
        b.sheet(
            "넓은 표",
            "<row r=\"1\">" + (0..<12).map { b.text("\(XlsxWriter.columnName($0))1", "항목 \($0 + 1)") }.joined()
                + "</row>", "<cols><col min=\"1\" max=\"12\" width=\"12\" customWidth=\"1\"/></cols>")
        return try b.save(path)
    }
}

extension XlsxBuilder {
    static let styleSheet = #"""
        <numFmts count="2"><numFmt numFmtId="164" formatCode="#,##0&quot;원&quot;"/><numFmt numFmtId="165" formatCode="0.0%"/></numFmts><fonts count="3"><font><sz val="11"/><name val="맑은 고딕"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="맑은 고딕"/></font><font><b/><sz val="11"/><color rgb="FFC00000"/><name val="맑은 고딕"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="3"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color indexed="64"/></left><right style="thin"><color indexed="64"/></right><top style="thin"><color indexed="64"/></top><bottom style="thin"><color indexed="64"/></bottom><diagonal/></border><border><left/><right/><top style="thin"><color auto="1"/></top><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="2" fillId="0" borderId="2" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1"/></cellXfs>
        """#
}
