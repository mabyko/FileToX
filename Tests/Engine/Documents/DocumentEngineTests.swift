import Foundation
import PDFKit
import XCTest

@testable import FileToXEngineKit

final class DocumentEngineTests: DocumentTestCase {
    func testSlideTablesKeepContentWithoutGeometryOrGrid() async throws {
        let rows = "<a:tr h=\"254000\">" + slideCell("왼쪽") + slideCell("가운데") + slideCell("오른쪽") + "</a:tr>"
        for (name, geometry, grid) in [("missing", "", true), ("zero", #"<p:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></p:xfrm>"#, true), ("no-grid", "", false)] {
            let input = try minimalSlide("table-" + name, slideTable(geometry, rows, grid: grid))
            let doc = try PptxReader.read(input, path("table-media-" + name))
            let box = try XCTUnwrap(HDocumentWalker.inlines(doc.sections[0].blocks).compactMap { $0 as? HTextBox }.first)
            XCTAssertNil(box.anchor)
            XCTAssertEqual(box.width, grid ? 30000 : 96000)
            XCTAssertEqual(box.height, 2000)
            let table = try XCTUnwrap(box.blocks.first as? HTable)
            XCTAssertEqual(table.columnCount, 3)
            let docx = path("table-" + name + ".docx"); try DocxWriter.write(doc, docx)
            let epub = try await convert(EbookConverter(), docx, "docx", "epub", "table-" + name + ".epub")
            for read in [doc, try DocxAssert.readBack(docx), try EpubReader.readBook(epub, folder).document] {
                let text = PlainTextWriter.write(read)
                for expected in ["왼쪽", "가운데", "오른쪽"] { XCTAssertTrue(text.contains(expected), name + ": " + text) }
            }
        }
    }

    func testSlideTableGroupScaleAndMergedGridPositionsSurviveDocx() throws {
        let geometry = #"<p:xfrm><a:off x="127000" y="254000"/><a:ext cx="3810000" cy="635000"/></p:xfrm>"#
        let rows = "<a:tr h=\"254000\">" + slideCell("Merged", "gridSpan=\"2\" rowSpan=\"2\"") + slideCell("", "hMerge=\"1\" rowSpan=\"2\"") + slideCell("Top right") + "</a:tr>"
            + "<a:tr h=\"381000\">" + slideCell("", "vMerge=\"1\" gridSpan=\"2\"") + slideCell("", "hMerge=\"1\" vMerge=\"1\"") + slideCell("Bottom right") + "</a:tr>"
        let group = #"<p:grpSp><p:grpSpPr><a:xfrm><a:off x="381000" y="508000"/><a:ext cx="7620000" cy="1905000"/><a:chOff x="0" y="0"/><a:chExt cx="3810000" cy="635000"/></a:xfrm></p:grpSpPr>"#
            + slideTable(geometry, rows) + "</p:grpSp>"
        let input = try minimalSlide("merged-table", group)
        let doc = try PptxReader.read(input, path("merged-table-media"))
        let docx = path("merged-table.docx"); try DocxWriter.write(doc, docx)
        for read in [doc, try DocxAssert.readBack(docx)] {
            let box = try XCTUnwrap(HDocumentWalker.inlines(read.sections[0].blocks).compactMap { $0 as? HTextBox }.first)
            XCTAssertEqual(box.width, 60000); XCTAssertEqual(box.height, 15000)
            let table = try XCTUnwrap(box.blocks.first as? HTable)
            XCTAssertEqual(table.columnWidths, [20000, 20000, 20000])
            XCTAssertEqual(table.rows.map(\.height), [6000, 9000])
            XCTAssertEqual(table.rows.map { $0.cells.map(\.column) }, [[0, 2], [2]])
            let merged = try XCTUnwrap(table.rows.first?.cells.first)
            XCTAssertEqual(merged.colSpan, 2); XCTAssertEqual(merged.rowSpan, 2)
            for expected in ["Merged", "Top right", "Bottom right"] { XCTAssertTrue(PlainTextWriter.write(read).contains(expected)) }
        }
    }

    private func slideCell(_ text: String, _ attributes: String = "") -> String {
        "<a:tc \(attributes)><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>"
    }

    private func slideTable(_ geometry: String, _ rows: String, grid: Bool = true) -> String {
        let columns = grid ? "<a:tblGrid>" + String(repeating: "<a:gridCol w=\"1270000\"/>", count: 3) + "</a:tblGrid>" : ""
        return "<p:graphicFrame>\(geometry)<a:graphic><a:graphicData><a:tbl>\(columns)\(rows)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    func testSlidesWithoutGeometryKeepTheirTextThroughDocxAndEbooks() async throws {
        let expected = "FileToX sample 안녕하세요"
        for (name, geometry) in [("missing", ""), ("zero", #"<a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></a:xfrm>"#)] {
            let shape = "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(geometry)</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(expected)</a:t></a:r></a:p></p:txBody></p:sp>"
            let input = try minimalSlide(name, shape)
            let doc = try PptxReader.read(input, path(name + "-media"))
            let boxes = HDocumentWalker.inlines(doc.sections[0].blocks).compactMap { $0 as? HTextBox }
            guard boxes.count == 1, let box = boxes.first else { XCTFail("\(name): text shape was discarded"); continue }
            XCTAssertEqual(box.width, 96000); XCTAssertEqual(box.height, 54000)
            XCTAssertTrue(PlainTextWriter.write(doc).contains(expected))
            let docx = path(name + ".docx")
            try DocxWriter.write(doc, docx)
            XCTAssertTrue(PlainTextWriter.write(try DocxAssert.readBack(docx)).contains(expected))
            for format in ["epub", "fb2", "htmlz", "txtz"] {
                let output = try await convert(EbookConverter(), docx, "docx", format, name + "." + format)
                let book = try await DocumentReaders.readAsync(output, format, folder)
                XCTAssertTrue(PlainTextWriter.write(book).contains(expected), format)
            }
        }
    }
    func testSlidePicturesUseAspectFitOnlyWhenGeometryIsMissing() throws {
        let picture = try DocumentFixtures.png(path("picture.png"), 120, 60)
        for (name, geometry) in [("missing", ""), ("zero", #"<a:xfrm><a:ext cx="0" cy="0"/></a:xfrm>"#)] {
            let input = try minimalSlide("picture-" + name, "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Picture\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"pic\"/></p:blipFill><p:spPr>\(geometry)</p:spPr></p:pic>", picture)
            let doc = try PptxReader.read(input, path("picture-media-" + name))
            let images = HDocumentWalker.images(doc)
            guard images.count == 1, let image = images.first else { XCTFail("\(name): picture was discarded"); continue }
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image.path)), picture)
            let width = try XCTUnwrap(image.width), height = try XCTUnwrap(image.height)
            if name == "zero" {
                XCTAssertEqual(width, 1); XCTAssertEqual(height, 1, "An explicitly invisible picture must not cover other content")
            } else {
                XCTAssertLessThanOrEqual(width, 96000); XCTAssertLessThanOrEqual(height, 54000)
                XCTAssertEqual(Double(width) / Double(height), 2, accuracy: 0.001)
            }
        }
    }
    func testUnpositionedTextBoxesDoNotCoverEarlierPictures() throws {
        let picture = try DocumentFixtures.png(path("background.png"), 120, 60)
        let geometry = #"<a:xfrm><a:off x="1000" y="2000"/><a:ext cx="1000000" cy="500000"/></a:xfrm>"#
        let image = #"<p:pic><p:nvPicPr><p:cNvPr id="2" name="Picture"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="pic"/></p:blipFill><p:spPr>"# + geometry + "</p:spPr></p:pic>"
        let fills = [
            #"<a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>"#,
            #"<a:gradFill><a:gsLst><a:gs pos="0"><a:srgbClr val="FF0000"/></a:gs><a:gs pos="100000"><a:srgbClr val="0000FF"/></a:gs></a:gsLst><a:lin ang="0"/></a:gradFill>"#,
        ]
        for (index, fill) in fills.enumerated() {
            for positioned in [false, true] {
                let name = "box-\(index)-\(positioned)"
                let shape = "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Text\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(positioned ? geometry : "")\(fill)<a:ln w=\"12700\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill></a:ln></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Visible text</a:t></a:r></a:p></p:txBody></p:sp>"
                let input = try minimalSlide(name, image + shape, picture)
                let doc = try PptxReader.read(input, path(name + "-media"))
                let docx = path(name + ".docx"); try DocxWriter.write(doc, docx)
                for read in [doc, try DocxAssert.readBack(docx)] {
                    let box = try XCTUnwrap(HDocumentWalker.inlines(read.sections[0].blocks).compactMap { $0 as? HTextBox }.first)
                    XCTAssertEqual(HDocumentWalker.images(read).count, 1)
                    if positioned {
                        XCTAssertTrue(box.fill != nil || box.gradient != nil)
                        XCTAssertEqual(box.line.style, .solid)
                    } else {
                        XCTAssertNil(box.fill); XCTAssertNil(box.gradient); XCTAssertEqual(box.line.style, .none)
                    }
                    XCTAssertTrue(PlainTextWriter.write(read).contains("Visible text"))
                }
            }
        }
    }
    func testImageOnlyDocumentsKeepLinkedPicturesInEbookOutputsIncludingTxtz() async throws {
        let picture = path("page.png"), bytes = try DocumentFixtures.png(picture, 120, 60)
        let doc = HDocument(), section = HSection(), paragraph = HParagraph()
        paragraph.inlines = [HImage(picture)]; section.blocks = [paragraph]; doc.sections = [section]
        let docx = path("page.docx"); try DocxWriter.write(doc, docx)
        for format in ["epub", "fb2", "htmlz", "txtz"] {
            let output = try await convert(EbookConverter(), docx, "docx", format, "page." + format)
            let read = try await DocumentReaders.readAsync(output, format, folder)
            let image = try XCTUnwrap(HDocumentWalker.images(read).first, format)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image.path)), bytes, format)
        }
    }
    func testEmptyShapesWithoutGeometryRemainEmpty() throws {
        let input = try minimalSlide("empty", #"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Empty"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>"#)
        let doc = try PptxReader.read(input, path("empty-media"))
        XCTAssertTrue(HDocumentWalker.inlines(doc.sections[0].blocks).isEmpty)
        let positioned = try PptxReader.read(DocumentFixtures.slides(path("positioned.pptx")), path("positioned-media"))
        let box = try XCTUnwrap(HDocumentWalker.inlines(positioned.sections[0].blocks).compactMap { $0 as? HTextBox }.first)
        XCTAssertEqual(box.width, 62992); XCTAssertEqual(box.height, 11811)
    }
    func testRasterPageRoutesEmbedRenderedImagesThroughDocx() async throws {
        let source = path("page-source.png")
        _ = try DocumentFixtures.png(source, 120, 60)
        let pdf = try await convert(PdfSharpConverter(), source, "png", "pdf", "page-source.pdf")
        let docx = try await convert(DocxWriterConverter(), pdf, "pdf", "docx", "page-rendered.docx")
        for format in ["epub", "fb2", "htmlz", "txtz"] {
            let output = try await convert(EbookConverter(), docx, "docx", format, "page-rendered." + format)
            let doc = try await DocumentReaders.readAsync(output, format, folder)
            let images = HDocumentWalker.images(doc)
            XCTAssertEqual(images.count, 1, format)
            for image in images {
                let size = try XCTUnwrap(ImageSupport.info(image.path), format)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertEqual(Double(size.width) / Double(size.height), 2, accuracy: 0.02, format)
            }
        }
    }
    private func minimalSlide(_ name: String, _ objects: String, _ picture: Data? = nil) throws -> String {
        let input = path(name + ".pptx"), zip = try ZipWriter(path: input)
        let relationship = "http://schemas.openxmlformats.org/package/2006/relationships"
        let r = PptxReader.r.namespaceName
        try zip.add("_rels/.rels", text: "<Relationships xmlns=\"\(relationship)\"><Relationship Id=\"r1\" Type=\"\(r)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        try zip.add("ppt/presentation.xml", text: "<p:presentation xmlns:p=\"\(PptxReader.p.namespaceName)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"s1\"/></p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/></p:presentation>")
        try zip.add("ppt/_rels/presentation.xml.rels", text: "<Relationships xmlns=\"\(relationship)\"><Relationship Id=\"s1\" Type=\"\(r)/slide\" Target=\"slides/slide1.xml\"/></Relationships>")
        try zip.add("ppt/slides/slide1.xml", text: "<p:sld xmlns:p=\"\(PptxReader.p.namespaceName)\" xmlns:a=\"\(PptxReader.a.namespaceName)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree>\(objects)</p:spTree></p:cSld></p:sld>")
        if let picture {
            try zip.add("ppt/media/picture.png", data: picture)
            try zip.add("ppt/slides/_rels/slide1.xml.rels", text: "<Relationships xmlns=\"\(relationship)\"><Relationship Id=\"pic\" Type=\"\(r)/image\" Target=\"../media/picture.png\"/></Relationships>")
        }
        try zip.close(); return input
    }
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
            // The small text read can finish before the caller cancels; enter the reader already cancelled.
            while !Task.isCancelled { await Task.yield() }
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
    func testUnhwpWritesMarkdownSidecarAndEmbedsHtmlImages() async throws {
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
            XCTAssertTrue(try String(contentsOfFile: out, encoding: .utf8)
                .contains(ext == "md" ? "out_files/img0001.png" : "data:image/png;base64,"))
        }
    }
}
