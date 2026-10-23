import Foundation
import PDFKit
import XCTest

@testable import FileToXEngineKit

final class DocumentEngineTests: DocumentTestCase {
    func testRhwpEdgesAndUnhwpEdges() {
        XCTAssertEqual(
            RhwpConverter().edges.map { $0.from + ">" + $0.to }, ["hwp>pdf", "hwpx>pdf", "hwp>hwpx", "hwpx>hwp"])
        XCTAssertEqual(UnhwpConverter().edges.map(\.cost), [10, 10, 10, 10, 14, 14])
        // Registered in Filee's order relative to each other (other engines sit between them).
        XCTAssertEqual(
            EngineRegistry.createAll(EngineEnvironment(dataDirectory: folder)).map(\.id)
                .filter { ["rhwp", "unhwp", "hwpx-writer", "docx-writer"].contains($0) },
            ["rhwp", "unhwp", "hwpx-writer", "docx-writer"])
    }
    func testHwpxToPdf() async throws {
        try requireRhwp()
        let h = path("input.hwpx")
        try HwpxWriter.write(DocumentReaders.textDocument(Data("안녕하세요\n두 번째 줄".utf8)), h)
        let pdf = try await convert(RhwpConverter(), h, "hwpx", "pdf", "out.pdf")
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf))).pageCount, 0)
    }
    func testHwpxToTextMarkdownHtml() async throws {
        let input = path("input.hwpx")
        try HwpxWriter.write(DocumentReaders.textDocument(Data("안녕하세요\n두 번째 줄".utf8)), input)
        for ext in ["txt", "md", "html"] {
            let out = try await convert(UnhwpConverter(), input, "hwpx", ext, "out." + ext)
            let data = try Data(contentsOf: URL(fileURLWithPath: out))
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("안녕하세요"))
            XCTAssertEqual(data.starts(with: [0xEF, 0xBB, 0xBF]), ext == "txt")
        }
    }
    func testRhwpConvertsHwpxHwpAndHwpText() async throws {
        try requireRhwp()
        let input = path("input.hwpx")
        try HwpxWriter.write(DocumentReaders.textDocument(Data("한글 변환\n두 번째 줄".utf8)), input)
        let hwp = try await convert(RhwpConverter(), input, "hwpx", "hwp", "out.hwp")
        let hwpx = try await convert(RhwpConverter(), hwp, "hwp", "hwpx", "back.hwpx")
        XCTAssertTrue(try HwpxAssert.xml(hwpx).value.contains("한글 변환"))
        for ext in ["txt", "md", "html"] {
            let out = try await convert(UnhwpConverter(), hwp, "hwp", ext, "hwp-text." + ext)
            XCTAssertTrue(try String(contentsOfFile: out, encoding: .utf8).contains("한글 변환"))
        }
    }
    func testAllocationSkipAndProgress() async throws {
        let input = try write("본문", "input.txt")
        let recorder = ProgressRecorder()
        let step = ConversionStep(
            inputPath: input, from: "txt", to: "hwpx", preset: Preset(), output: DocumentFixedPath(nil), workDirectory: folder)
        let outputs = try await HwpxConverter().convert(step, progress: { recorder.add($0) })
        XCTAssertTrue(outputs.isEmpty)
        XCTAssertEqual(recorder.values, [0.1, 0.6])
    }
    func testCancellationBeforeReading() async throws {
        let input = try write("본문", "input.txt")
        let task = Task {
            try Task.checkCancellation()
            return try await DocumentReaders.readAsync(input, "txt", folder)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }
    func testSheetLayoutHiddenCellsAndMerge() {
        let b = DocumentFixtures.workbook()
        let s = b.sheets[0]
        s.hiddenRows.insert(1)
        s.hiddenColumns.insert(1)
        let doc = SheetDocument.build(b)
        let t = doc.sections[0].blocks[0] as! HTable
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.columnCount, 1)
        XCTAssertEqual(t.rows[0].cells[0].colSpan, 1)
    }
    func testTextMarkdownAndXhtmlWriters() {
        let doc = HDocument()
        let s = HSection()
        let numbering = HNumbering()
        numbering.levels = [HNumberingLevel("DIGIT", "^1.", 3, false)]
        let p = DocumentFixtures.p(" 제목 ", HCharFormat(bold: true))
        p.headingLevel = 1
        let item = DocumentFixtures.p("항목")
        item.list = HListRef(numbering, 0, true)
        let code = DocumentFixtures.p("let x = 1", HCharFormat(shade: HtmlReader.codeShade))
        let note = HNote(false)
        note.blocks = [DocumentFixtures.p("각주")]
        let body = DocumentFixtures.p("본문")
        body.inlines.append(note)
        s.blocks = [p, item, code, body]
        doc.sections = [s]
        XCTAssertTrue(PlainTextWriter.write(doc).contains("3. 항목"))
        let md = MarkdownWriter.write(doc) { _ in nil }
        XCTAssertTrue(md.contains("#  **제목** "))
        XCTAssertTrue(md.contains("```\nlet x = 1\n```"))
        XCTAssertTrue(md.contains("[^1]: 각주"))
        let html = XhtmlWriter.write(doc, XhtmlOptions(imageSource: { _ in nil }))[0]
        XCTAssertTrue(html.body.contains("<h1"))
        XCTAssertTrue(html.body.contains("<ol start=\"3\">"))
        XCTAssertTrue(html.body.contains("id=\"_fn1\""))
        XCTAssertTrue(XhtmlWriter.page("title", html.body, "ko", nil, false).contains("<style>"))
    }
    func testXhtmlChapterBookmarksAndNotes() {
        let doc = HDocument()
        let s = HSection()
        let p1 = DocumentFixtures.p("첫 장")
        let p2 = DocumentFixtures.p("둘째 장")
        let link = HLink("#도착")
        p1.headingLevel = 1
        p2.headingLevel = 1
        link.content = [HText("이동")]
        p1.inlines.append(link)
        p2.inlines.insert(HBookmark("도착"), at: 0)
        s.blocks = [p1, p2]
        doc.sections = [s]
        let chapters = XhtmlWriter.write(doc, XhtmlOptions(splitChapters: true, imageSource: { _ in nil }, epub: true))
        XCTAssertEqual(chapters.count, 2)
        XCTAssertTrue(chapters[0].body.contains("ch002.xhtml#"))
        XCTAssertTrue(chapters[1].body.contains("<a id="))
    }
}
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func add(_ n: Double) {
        lock.lock()
        storage.append(n)
        lock.unlock()
    }
}

final class DocumentOoxmlVariantTests: DocumentTestCase {
    func testDocumentVariantsReadDirectly() async throws {
        let input = try DocumentFixtures.richDocx(folder)
        for ext in ["docx", "docm", "dotx", "dotm"] {
            let doc = try await DocumentReaders.readAsync(input, ext, folder)
            XCTAssertEqual(doc.sections.count, 2)
            XCTAssertTrue(HwpxConverter().edges.contains { $0.from == ext && $0.to == "hwpx" })
        }
    }
    func testPresentationVariantsReadDirectly() async throws {
        let input = try DocumentFixtures.slides(path("slides.pptx"))
        for ext in ["pptx", "pptm", "potx", "ppsx"] {
            let doc = try await DocumentReaders.readAsync(input, ext, folder)
            XCTAssertEqual(doc.sections[0].blocks.count, 2)
            XCTAssertTrue(DocxWriterConverter().edges.contains { $0.from == ext && $0.to == "docx" })
        }
    }
}

extension DocumentEngineTests {
    func testCsvThroughSheetDocument() async throws {
        let input = try write("지점,매출\n서울,1350000\n", "매출.csv")
        do {
            let out = try await convert(HwpxConverter(), input, "csv", "hwpx", "csv.hwpx")
            try HwpxAssert.validPackage(out)
            XCTAssertTrue(try HwpxAssert.xml(out).value.contains("서울"))
        } catch let e as ConversionError where e.message == "not ported yet" {
            throw XCTSkip("CsvFormat is pending cross-group integration")
        }
    }
    func testXlsxThroughSheetDocument() async throws {
        let input = path("매출.xlsx")
        let zip = try ZipWriter(path: input)
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = DocxWriter.relationshipBase
        try zip.add(
            "_rels/.rels",
            text:
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        )
        try zip.add(
            "xl/workbook.xml",
            text:
                "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel.dropLast())\"><sheets><sheet name=\"매출\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        )
        try zip.add(
            "xl/_rels/workbook.xml.rels",
            text:
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"
        )
        try zip.add(
            "xl/worksheets/sheet1.xml",
            text:
                "<worksheet xmlns=\"\(main)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>서울</t></is></c><c r=\"B1\"><v>1350000</v></c></row></sheetData></worksheet>"
        )
        try zip.close()
        do {
            let out = try await convert(HwpxConverter(), input, "xlsx", "hwpx", "xlsx.hwpx")
            try HwpxAssert.validPackage(out)
            XCTAssertTrue(try HwpxAssert.xml(out).value.contains("서울"))
        } catch let e as ConversionError where e.message == "not ported yet" {
            throw XCTSkip("XlsxReader is pending cross-group integration")
        }
    }
    func testPlainTextNumberingContinuesAcrossSections() {
        let d = HDocument()
        let n = HNumbering()
        n.levels = [HNumberingLevel("DIGIT", "^1.", 3, false)]
        for t in ["첫째", "둘째"] {
            let s = HSection()
            let p = DocumentFixtures.p(t)
            p.list = HListRef(n, 0, true)
            s.blocks = [p]
            d.sections.append(s)
        }
        XCTAssertEqual(PlainTextWriter.write(d), "3. 첫째\n\n4. 둘째\n")
    }
    func testUnhwpEmbedsImages() async throws {
        let d = HDocument()
        let s = HSection()
        let p = HParagraph()
        let imagePath = path("image.png")
        _ = try DocumentFixtures.png(imagePath)
        p.inlines = [HImage(imagePath)]
        s.blocks = [p]
        d.sections = [s]
        let h = path("images.hwpx")
        try HwpxWriter.write(d, h)
        for ext in ["md", "html"] {
            let out = try await convert(UnhwpConverter(), h, "hwpx", ext, "out." + ext)
            XCTAssertTrue(try String(contentsOfFile: out, encoding: .utf8).contains("data:image/png;base64,"))
        }
    }
}
