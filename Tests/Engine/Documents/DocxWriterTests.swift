import Foundation
import XCTest

@testable import FileToXEngineKit

final class DocxWriterTests: DocumentTestCase {
    func testBuiltInWriterPreferredForDocx() {
        let e = DocxWriterConverter().edges
        for f in ["md", "txt", "xlsx", "csv", "pptx"] { XCTAssertEqual(e.first { $0.from == f }?.cost, 8) }
        XCTAssertEqual(e.first { $0.from == "pdf" }?.cost, 14)
        XCTAssertFalse(e.contains { ["docx", "docm", "dotx", "dotm"].contains($0.from) })
    }
    func testTextOneParagraphPerLineOnA4() async throws {
        let input = try write("첫 줄 한글\n\n文件转换 Hello\tTab 😀 e\u{301}", "메모.txt")
        let out = try await convert(DocxWriterConverter(), input, "txt", "docx", "memo.docx")
        try DocxAssert.validPackage(out)
        let doc = try DocxAssert.readBack(out)
        let section = doc.sections[0]
        let p = section.blocks.compactMap { $0 as? HParagraph }
        XCTAssertEqual(p.map(DocxAssert.textOf), ["첫 줄 한글", "", "文件转换 HelloTab 😀 e\u{301}"])
        XCTAssertEqual(p[2].inlines.filter { $0 is HTab }.count, 1)
        XCTAssertEqual(section.page?.width, 59530)
        XCTAssertEqual(section.page?.height, 84190)
    }
    func testMarkdownRealHeadingsListsTablesAndNotes() throws {
        let doc = try markdown(
            "# 주간 회의\n\n**배포**, *문서 정리*\n\n1. 설치\n   - 서명\n\n| 항목 | 담당 |\n|---|---|\n| 설치 | 민지 |\n\n각주[^1]\n\n[^1]: 각주 내용"
        )
        let out = path("markdown.docx")
        try DocxWriter.write(doc, out)
        try DocxAssert.validPackage(out)
        let read = try DocxAssert.readBack(out)
        XCTAssertTrue(DocxAssert.paragraphs(read.sections.flatMap(\.blocks)).contains { $0.headingLevel == 1 })
        XCTAssertTrue(HDocumentWalker.inlines(read.sections.flatMap(\.blocks)).contains { $0 is HNote })
    }
    func testSheetsAndSlidesBecomeTablesAndFloatingObjects() throws {
        let sheet = SheetDocument.build(DocumentFixtures.workbook())
        let out = path("sheets.docx")
        try DocxWriter.write(sheet, out)
        try DocxAssert.validPackage(out)
        let table = try XCTUnwrap(DocxAssert.readBack(out).sections[0].blocks.compactMap { $0 as? HTable }.first)
        XCTAssertEqual(table.rows[0].cells[0].colSpan, 2)
        XCTAssertEqual(table.rows[0].cells[0].fill, "#1F4E79")
        let slides = try PptxReader.read(DocumentFixtures.slides(path("slides.pptx")), path("media"))
        let slidesPath = path("slides.docx")
        try DocxWriter.write(slides, slidesPath)
        try DocxAssert.validPackage(slidesPath)
        let read = try DocxAssert.readBack(slidesPath)
        XCTAssertTrue(read.sections[0].page!.landscape)
        XCTAssertEqual(HDocumentWalker.inlines(read.sections[0].blocks).compactMap { $0 as? HTextBox }.count, 2)
    }
    func testLayoutSurvivesDocxModelDocx() throws {
        let original = try DocxReader.read(DocumentFixtures.richDocx(folder), path("media"))
        let out = path("rewritten.docx")
        try DocxWriter.write(original, out)
        try DocxAssert.validPackage(out)
        let copy = try DocxAssert.readBack(out)
        XCTAssertEqual(original.sections.count, copy.sections.count)
        for (a, b) in zip(original.sections, copy.sections) {
            XCTAssertEqual(a.page, b.page)
            XCTAssertEqual(a.columns, b.columns)
            XCTAssertEqual(a.hideFirstHeader, b.hideFirstHeader)
            XCTAssertEqual(a.startPageNumber, b.startPageNumber)
        }
        let ap = DocxAssert.paragraphs(original.sections.flatMap(\.blocks))
        let bp = DocxAssert.paragraphs(copy.sections.flatMap(\.blocks))
        for text in ["가운데 제목", "굵은 빨강", "첫 항목", "본문", "다음 쪽"] {
            let a = try XCTUnwrap(ap.first { DocxAssert.textOf($0).contains(text) })
            let b = try XCTUnwrap(bp.first { DocxAssert.textOf($0).contains(text) })
            XCTAssertEqual(a.format, b.format, text)
            XCTAssertEqual(a.headingLevel, b.headingLevel)
            XCTAssertEqual(a.pageBreakBefore, b.pageBreakBefore)
        }
        XCTAssertEqual(HDocumentWalker.images(original).count, HDocumentWalker.images(copy).count)
        XCTAssertEqual(
            HDocumentWalker.inlines(original.sections[0].blocks).compactMap { ($0 as? HNote)?.endnote },
            HDocumentWalker.inlines(copy.sections[0].blocks).compactMap { ($0 as? HNote)?.endnote })
    }
    func testBookmarkNamesAndExternalUris() throws {
        let doc = HDocument()
        let s = HSection()
        let p = HParagraph()
        let l = HLink("https://example.com/?q=한글")
        l.content = [HText("웹")]
        p.inlines = [HBookmark("1 한글"), HBookmark("1_한글"), l]
        s.blocks = [p]
        doc.sections = [s]
        let out = path("bookmarks.docx")
        try DocxWriter.write(doc, out)
        try DocxAssert.validPackage(out)
        let names = try DocxAssert.body(out).descendants(DocxReader.w + "bookmarkStart").compactMap {
            DocxReader.attr($0, "name")
        }
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("b") })
        let links = HDocumentWalker.inlines(try DocxAssert.readBack(out).sections[0].blocks).compactMap {
            ($0 as? HLink)?.target
        }
        XCTAssertEqual(links, ["https://example.com/?q=%ED%95%9C%EA%B8%80"])
    }
}

extension DocxWriterTests {
    func testUrisNormalizeLikeDotNet() {
        XCTAssertEqual(
            DocxWriter.safeUri("HTTPS://EXAMPLE.COM:443/a/../?q=한글"), "https://example.com/?q=%ED%95%9C%EA%B8%80")
        XCTAssertEqual(DocxWriter.safeUri("http://example.com"), "http://example.com/")
        XCTAssertEqual(DocxWriter.safeUri("https://example.com/a b"), "https://example.com/a%20b")
        XCTAssertEqual(DocxWriter.safeUri("mailto:user@example.com"), "mailto:user@example.com")
        XCTAssertEqual(DocxWriter.safeUri("file:///tmp/a b"), "file:///tmp/a%20b")
    }
}
