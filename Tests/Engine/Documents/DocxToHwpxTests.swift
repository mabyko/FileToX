import Foundation
import XCTest

@testable import FileToXEngineKit

final class DocxToHwpxTests: DocumentTestCase {
    func converted() throws -> (HDocument, String) {
        let input = try DocumentFixtures.richDocx(folder)
        let doc = try DocxReader.read(input, path("media"))
        let output = path("rich.hwpx")
        try HwpxWriter.write(doc, output)
        try HwpxAssert.validPackage(output, 1)
        return (doc, output)
    }
    func testPageSetupHeadersFootersAndPageNumbers() throws {
        let (doc, out) = try converted()
        XCTAssertEqual(doc.sections.count, 2)
        let s = doc.sections[0]
        XCTAssertEqual(s.headers.map(\.pages), [.odd, .even])
        XCTAssertEqual(s.startPageNumber, 3)
        XCTAssertTrue(s.hideFirstHeader)
        XCTAssertEqual(
            HDocumentWalker.inlines(s.footers[0].blocks).compactMap { ($0 as? HField)?.kind },
            [.pageNumber, .totalPages])
        let second = doc.sections[1]
        XCTAssertTrue(second.page!.landscape)
        XCTAssertEqual(second.columns, HColumns(count: 2, gap: 3600, separator: true))
        let page = try HwpxAssert.xml(out, "Contents/section1.xml").descendants(HwpxWriter.hp + "pagePr")[0]
        XCTAssertEqual(page.attributeValue("landscape"), "NARROWLY")
        XCTAssertEqual(page.attributeValue("width"), "59530")
    }
    func testParagraphCharacterFormattingListsAndGrid() throws {
        let (doc, out) = try converted()
        let paragraphs = doc.sections[0].blocks.compactMap { $0 as? HParagraph }
        let formatted = try XCTUnwrap(paragraphs.first { DocxAssert.textOf($0).hasPrefix("굵은 빨강") })
        XCTAssertEqual(formatted.format.left, 3600)
        XCTAssertEqual(formatted.format.firstLine, -1800)
        let red = try XCTUnwrap(formatted.inlines.first as? HText)
        XCTAssertEqual(red.format.bold, true)
        XCTAssertEqual(red.format.size, 1400)
        XCTAssertEqual(red.format.font, "Arial")
        XCTAssertEqual(red.format.eastAsianFont, "굴림")
        XCTAssertEqual(red.format.color, "#FF0000")
        XCTAssertTrue(formatted.inlines.compactMap { $0 as? HText }.contains { $0.format.shade == "#BFBFBF" })
        let item = try XCTUnwrap(paragraphs.first { DocxAssert.textOf($0) == "하위 항목" }?.list)
        XCTAssertEqual(item.level, 1)
        XCTAssertEqual(item.numbering.levels[1].format, "HANGUL_SYLLABLE")
        let section = try HwpxAssert.xml(out)
        let p = try HwpxAssert.paragraphWith(section, "굵은 빨강")
        let shape = try HwpxAssert.headItem(out, "paraPr", p.attributeValue("paraPrIDRef")!)
        let margin = shape.descendants(HwpxWriter.hp + "case").first!.descendants(HwpxWriter.hc + "left")[0]
        XCTAssertEqual(margin.attributeValue("value"), "1800")
    }
    func testDocumentGridSnapsToPitch() throws {
        let d = DocxBuilder()
        d.sectionProperties += "<w:docGrid w:type=\"lines\" w:linePitch=\"360\"/>"
        d.paragraph(DocxBuilder.p(DocxBuilder.r("10 pt")))
        d.paragraph(DocxBuilder.p(DocxBuilder.r("14 pt", "<w:sz w:val=\"28\"/>")))
        let doc = try DocxReader.read(d.save(path("grid.docx")), path("media"))
        let p = doc.sections[0].blocks.compactMap { $0 as? HParagraph }
        XCTAssertEqual(p.map { $0.format.lineSpacing }, [HLineSpacing(.atLeast, 1800), HLineSpacing(.atLeast, 3600)])
    }
    func testTablesKeepMergedCellsBordersShading() throws {
        let (doc, _) = try converted()
        let t = try XCTUnwrap(doc.sections[0].blocks.compactMap { $0 as? HTable }.first)
        XCTAssertEqual(t.columnCount, 3)
        XCTAssertEqual(t.columnWidths, [10000, 15000, 10000])
        XCTAssertEqual(t.rows[0].cells[0].colSpan, 2)
        XCTAssertEqual(t.rows[0].cells[1].rowSpan, 2)
        XCTAssertEqual(t.rows[0].cells[0].fill, "#E6E6E6")
        XCTAssertEqual(t.rows[2].cells[0].borders?.bottom.style, .double)
        XCTAssertTrue(t.rows[0].header)
        XCTAssertTrue(t.rows[1].cells[0].blocks[0] is HTable)
    }
    func testTextBoxesAndFloatingPictures() throws {
        let (doc, _) = try converted()
        let list = HDocumentWalker.inlines(doc.sections[0].blocks)
        let images = list.compactMap { $0 as? HImage }
        let box = try XCTUnwrap(list.compactMap { $0 as? HTextBox }.first)
        XCTAssertEqual(images.count, 3)
        XCTAssertNil(images[0].anchor)
        XCTAssertEqual(images[1].anchor?.horizontalRelativeTo, "PAPER")
        XCTAssertEqual(images[1].width, 7200)
        XCTAssertEqual(box.fill, "#FFF2CC")
        XCTAssertEqual(box.verticalAlign, .center)
        XCTAssertEqual(HDocumentAssert.text(box.blocks), "글상자 안의 글")
    }
    func testNotesLinksBookmarksAndPageBreaks() throws {
        let (doc, out) = try converted()
        let items = HDocumentWalker.inlines(doc.sections[0].blocks)
        XCTAssertEqual(items.compactMap { ($0 as? HLink)?.target }, ["https://example.com/a?b=1", "#intro"])
        XCTAssertEqual(items.compactMap { ($0 as? HNote)?.endnote }, [false, true])
        XCTAssertEqual(items.compactMap { ($0 as? HBookmark)?.name }, ["intro"])
        let xml = try HwpxAssert.xml(out)
        XCTAssertEqual(xml.descendants(HwpxWriter.hp + "fieldEnd").count, 2)
        let next = try HwpxAssert.paragraphWith(xml, "다음 쪽")
        XCTAssertEqual(next.attributeValue("pageBreak"), "1")
    }
    func testColumnsChangeWithinSection() throws {
        let d = DocxBuilder()
        d.paragraph(DocxBuilder.p(DocxBuilder.r("첫 구역"), "<w:sectPr>\(DocxBuilder.defaultPage)</w:sectPr>"))
        d.paragraph(DocxBuilder.p(DocxBuilder.r("두 단")))
        d.sectionProperties =
            "<w:type w:val=\"continuous\"/>\(DocxBuilder.defaultPage)<w:cols w:num=\"2\" w:space=\"720\"/>"
        let doc = try DocxReader.read(d.save(path("columns.docx")), path("media"))
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertEqual((doc.sections[0].blocks[1] as? HParagraph)?.columnsChange?.count, 2)
    }
}

extension DocxToHwpxTests {
    func testShapesGradientsNegativeOffsetsAndVml() throws {
        let (doc, out) = try converted()
        let items = HDocumentWalker.inlines(doc.sections[0].blocks)
        let shapes = items.compactMap { $0 as? HShape }
        XCTAssertTrue(
            shapes.contains {
                $0.kind == .ellipse && $0.gradient?.angle == 90 && $0.gradient?.colors == ["#99CCFF", "#FFFFFF"]
            })
        XCTAssertTrue(shapes.contains { $0.kind == .line && $0.line.style == .dash && $0.line.color == "#4F81BD" })
        XCTAssertTrue(
            items.compactMap { $0 as? HTextBox }.contains {
                HDocumentAssert.text($0.blocks) == "옛 글상자" && $0.fill == "#AABBCC"
            })
        let positions = try HwpxAssert.xml(out).descendants(HwpxWriter.hp + "pos")
        XCTAssertTrue(
            positions.allSatisfy { HwpxReader.int($0, "horzOffset") >= 0 && HwpxReader.int($0, "vertOffset") >= 0 })
    }
}
