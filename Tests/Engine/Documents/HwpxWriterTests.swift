import Foundation
import XCTest

@testable import FileToXEngineKit

final class HwpxWriterTests: DocumentTestCase {
    func testPlainTextNeedsNoPandoc() async throws {
        let input = try write("첫 줄\n\n세 번째 줄 <태그> & 기호\u{B}", "한글 문서.txt")
        let out = try await convert(HwpxConverter(), input, "txt", "hwpx", "memo.hwpx")
        try HwpxAssert.validPackage(out, 0)
        let text = try HwpxAssert.xml(out).value
        XCTAssertTrue(text.contains("세 번째 줄 <태그> & 기호"))
        XCTAssertFalse(text.contains("\u{B}"))
    }
    func testKoreanLegacyAndBomDecoding() throws {
        let text = "한글 텍스트 파일"
        let cp949 = Data([
            0xC7, 0xD1, 0xB1, 0xDB, 0x20, 0xC5, 0xD8, 0xBD, 0xBA, 0xC6, 0xAE, 0x20, 0xC6, 0xC4, 0xC0, 0xCF,
        ])
        XCTAssertEqual(HwpxConverter.decodeText(cp949), text)
        XCTAssertEqual(HwpxConverter.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)), text)
        let bytes = text.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
        XCTAssertEqual(HwpxConverter.decodeText(Data([0xFF, 0xFE]) + Data(bytes)), text)
    }
    func testLengthsAreConvertedToHwpunit() {
        for (s, n) in [("2in", 14400), ("96px", 7200), ("10mm", 2834), ("1cm", 2834), ("12pt", 1200)] {
            XCTAssertLessThanOrEqual(abs((HwpxUnits.parseLength(s) ?? -100000) - n), 2)
        }
        XCTAssertNil(HwpxUnits.parseLength("abc"))
        XCTAssertNil(HwpxUnits.parseLength(nil))
    }
    func testLineWidthsSnapToHangulWidths() {
        for (mm, s) in [(0.1, "0.1 mm"), (0.13, "0.12 mm"), (0.353, "0.4 mm"), (1.2, "1.0 mm"), (9, "5.0 mm")] {
            XCTAssertEqual(HwpxWriter.lineWidth(mm), s)
        }
    }
    func testInvalidXmlCharactersAreRemoved() {
        XCTAssertEqual(HwpxWriter.escape("a <b> & c\u{B}\u{1}"), "a &lt;b&gt; &amp; c")
    }
    func testHangulMeasuredWiderThanLatin() {
        XCTAssertGreaterThan(HwpxWriter.textWidth("가나다", 1000), HwpxWriter.textWidth("abc", 1000) * 1.5)
        XCTAssertEqual(HwpxWriter.textWidth("😀", 1000), 1840)
    }
    func testMergedGridAndRowHeights() throws {
        let doc = HDocument()
        let section = HSection()
        let t = HTable()
        t.columnCount = 3
        for r in 0..<3 {
            let row = HRow()
            for c in 0..<3 {
                if r == 1 && c == 0 || r == 0 && c == 2 { continue }
                let cell = HCell()
                cell.column = c
                cell.rowSpan = r == 0 && c == 0 ? 2 : 1
                cell.colSpan = r == 0 && c == 1 ? 2 : 1
                cell.blocks = [DocumentFixtures.p("셀 \(r),\(c)")]
                row.cells.append(cell)
            }
            t.rows.append(row)
        }
        section.blocks = [t]
        doc.sections = [section]
        let out = path("merged.hwpx")
        try HwpxWriter.write(doc, out)
        try HwpxAssert.validPackage(out, 0)
        let xml = try HwpxAssert.xml(out)
        var occupied: [String] = []
        for tc in xml.descendants(HwpxWriter.hp + "tc") {
            let addr = tc.element(HwpxWriter.hp + "cellAddr")
            let span = tc.element(HwpxWriter.hp + "cellSpan")
            let r = HwpxReader.int(addr, "rowAddr")
            let c = HwpxReader.int(addr, "colAddr")
            for rr in r..<(r + HwpxReader.int(span, "rowSpan")) {
                for cc in c..<(c + HwpxReader.int(span, "colSpan")) { occupied.append("\(rr),\(cc)") }
            }
        }
        XCTAssertEqual(occupied.count, 9)
        XCTAssertEqual(Set(occupied).count, 9)
    }
    func testMarkdownBecomesValidHwpx() throws {
        let doc = try markdown("# 첫 번째 제목\n\n일반 **굵게**\n\n| 이름 | 값 |\n|---|---|\n| 표 셀 | 42 |\n")
        let out = path("markdown.hwpx")
        try HwpxWriter.write(doc, out)
        try HwpxAssert.validPackage(out, 0)
        XCTAssertTrue(try HwpxAssert.xml(out).value.contains("표 셀"))
    }
    func testDocxEdgeCostsAndOrder() {
        let edges = HwpxConverter().edges
        XCTAssertEqual(edges.first, ConversionEdge("docx", "hwpx", 10))
        XCTAssertFalse(edges.contains { $0.from == "hwpx" })
        XCTAssertEqual(edges.first { $0.from == "pdf" }?.cost, 16)
    }
}

extension HwpxWriterTests {
    func testHtmlTablesKeepMergedGrid() throws {
        let input = try write(
            "<table><tr><td rowspan=\"2\">세로 병합</td><td colspan=\"2\">가로 병합</td></tr><tr><td>B</td><td>C</td></tr><tr><td>D</td><td>E</td><td>F</td></tr></table>",
            "table.html")
        let doc: HDocument
        do { doc = try HtmlReader.read(input, path("media")) } catch let e as ConversionError
            where e.message == "not ported yet"
        { throw XCTSkip("HtmlReader is pending cross-group integration") }
        let output = path("html.hwpx")
        try HwpxWriter.write(doc, output)
        try HwpxAssert.validPackage(output, 0)
        let read = try HwpxReader.read(output, path("read-media"))
        XCTAssertEqual(read.sections[0].blocks.compactMap { $0 as? HTable }[0].columnCount, 3)
    }
}
