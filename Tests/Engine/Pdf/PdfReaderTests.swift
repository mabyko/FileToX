// Port of Filee.Engines.Tests/PdfReaderTests.cs: PDF → document model / TXT with the built-in PDF reader: paragraphs in
// reading order (two-column pages too), headings from font sizes, bold / italic / colour, links, pictures (JPEG kept as
// it is), repeated headers and footers left out, scanned pages as page pictures, and a clear error for password-protected
// files. Filee checked the model through its DOCX/HWPX output; the writers are other engines here, so the tests read the
// HDocument PdfDocumentReader returns. The test PDFs use the standard 14 fonts; the Korean one is drawn with Core Text.

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import FileToXEngineKit

final class PdfReaderTests: XCTestCase {
    private static let first =
        "Filee converts files on your own computer. This paragraph is long enough to wrap over several lines, so the reader " +
        "has to join the lines again into one paragraph without losing or doubling any of the words in it."
    private static let second =
        "The second page continues the report with more details. Headers and footers repeat on every page and are left out."

    private let text = PdfTextConverter()
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }
    override func tearDown() { FileManager.default.removeIfPresent(dir) }

    private static func textOf(_ paragraph: HParagraph) -> String {
        paragraph.inlines.flatMap { ($0 as? HLink)?.content ?? [$0] }.compactMap { ($0 as? HText)?.text }.joined()
    }

    /// Text with tabs as \t and line breaks as \n.
    private static func shown(_ paragraph: HParagraph) -> String {
        paragraph.inlines.flatMap { ($0 as? HLink)?.content ?? [$0] }.map { inline -> String in
            switch inline {
            case let run as HText: return run.text
            case is HTab: return "\t"
            case is HLineBreak: return "\n"
            default: return ""
            }
        }.joined()
    }

    private static func paragraphs(_ document: HDocument) -> [HParagraph] {
        document.sections.flatMap(\.blocks).compactMap { $0 as? HParagraph }
    }

    private func txt(_ pdf: String) async throws -> String {
        let output = try await GraphicsTestKit.convert(text, pdf, to: "txt")
        let data = try Data(contentsOf: URL(fileURLWithPath: output[0]))
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 with BOM")
        return String(decoding: data.dropFirst(3), as: UTF8.self)
    }

    /// Two A4 pages: title, headings, wrapped paragraphs, coloured and italic words, a link, two pictures, and a running
    /// header and footer.
    private func report() throws -> String {
        let pdf = PdfBuilder()
        for page in 1...2 {
            pdf.newPage()
            let regular = pdf.font(), bold = pdf.font(bold: true)
            pdf.line("Filee Quarterly Report", 9, regular, 50, 30)
            pdf.line("Page \(page)", 9, regular, 280, 815)
            if page == 1 {
                pdf.line("Annual Report 2026", 24, bold, 50, 90)
                pdf.line("1. Introduction", 16, bold, 50, 135)
                let y = pdf.paragraph(Self.first, 11, regular, 50, 165, 495, 14)
                pdf.line("Warning", 11, bold, 50, y + 12, color: (255, 0, 0))
                pdf.line(" this line is italic", 11, pdf.font(italic: true), 50 + pdf.width("Warning", 11, bold), y + 12)
                pdf.line("Visit https://example.com", 11, regular, 50, y + 40)
                pdf.link("https://example.com/", 50, y + 30, 150, 14)
                try pdf.picture(PdfBuilder.photo(dir, "photo.jpg"), 50, y + 60, 200, 120)
                try pdf.picture(PdfBuilder.photo(dir, "chart.png", 100, 100), 300, y + 60, 100, 100)
            } else {
                pdf.line("2. Details", 16, bold, 50, 90)
                pdf.paragraph(Self.second, 11, regular, 50, 120, 495, 14)
            }
        }
        return try pdf.save(FilePath.combine(dir, "report.pdf"))
    }

    func testReportKeepsParagraphsHeadingsFormattingLinksAndPictures() throws {
        let media = FilePath.combine(dir, "media")
        let model = try PdfDocumentReader.read(try report(), media)
        let paragraphs = Self.paragraphs(model).filter { !Self.textOf($0).isEmpty }
        XCTAssertEqual(paragraphs.map { Self.textOf($0).trimmingCharacters(in: .whitespaces) },
                       ["Annual Report 2026", "1. Introduction", Self.first, "Warning this line is italic", "Visit https://example.com",
                        "2. Details", Self.second])
        guard paragraphs.count == 7 else { return }
        // Heading levels by size: 24 pt → 1, 16 pt → 2; body text is no heading.
        XCTAssertEqual(paragraphs.map(\.headingLevel), [1, 2, 0, 0, 0, 2, 0])

        let warning = paragraphs[3].inlines.compactMap { $0 as? HText }
        XCTAssertEqual(warning.first?.format.bold, true)
        XCTAssertEqual(warning.first?.format.color, "#FF0000")
        XCTAssertEqual(warning.last?.format.italic, true)
        XCTAssertEqual(warning.first?.format.font, "Arial") // Helvetica, as Word knows it
        let body = paragraphs[2].inlines.compactMap { $0 as? HText }.first
        XCTAssertEqual(body?.format.size, 1100)
        XCTAssertEqual(body?.format.color, "#000000")
        XCTAssertEqual(paragraphs[4].inlines.compactMap { $0 as? HLink }.map(\.target), ["https://example.com/"])

        // The second page starts on a new page; the running header and footer are gone.
        XCTAssertTrue(paragraphs[5].pageBreakBefore)
        let all = Self.paragraphs(model).map(Self.textOf).joined()
        XCTAssertFalse(all.contains("Quarterly"))
        XCTAssertFalse(all.contains("Page 1"))

        // A4 page; pictures at their size, the JPEG kept as it was.
        XCTAssertEqual(model.sections[0].page?.width, 59500)
        XCTAssertEqual(model.sections[0].page?.height, 84200)
        let pictures = Self.paragraphs(model).flatMap(\.inlines).compactMap { $0 as? HImage }
        XCTAssertEqual(pictures.map { [$0.width!, $0.height!] }, [[20000, 12000], [10000, 10000]])
        let files = try FileManager.default.contentsOfDirectory(atPath: media).sorted()
        XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") }.count, 1, "\(files)")
        XCTAssertEqual(files.filter { $0.hasSuffix(".png") }.count, 1, "\(files)")
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: FilePath.combine(dir, "photo.jpg")))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: FilePath.combine(media, files.first { $0.hasSuffix(".jpg") }!))), jpeg)
    }

    func testTwoColumnPagesAreReadColumnByColumn() async throws {
        let pdf = PdfBuilder().newPage()
        let body = pdf.font()
        pdf.line("Two Column Layout", 20, pdf.font(bold: true), 50, 70)
        func text(_ label: String) -> String { "\(label) paragraph of the column: it has enough words to wrap over a few lines inside its narrow column of text." }
        let left = pdf.paragraph(text("Left first"), 10, body, 50, 110, 230, 13)
        pdf.paragraph(text("Left second"), 10, body, 50, left + 10, 230, 13)
        var right = pdf.paragraph(text("Right first"), 10, body, 315, 110, 230, 13)
        right = pdf.paragraph(text("Right second"), 10, body, 315, right + 10, 230, 13)
        pdf.paragraph("A closing paragraph spans both columns again at the end of the page, below everything else.", 10, body, 50, right + 40, 495, 13)
        let path = try pdf.save(FilePath.combine(dir, "columns.pdf"))

        let result = try await txt(path)
        let order = ["Two Column Layout", "Left first", "Left second", "Right first", "Right second", "A closing paragraph"]
            .map { result.range(of: $0).map { result.distance(from: result.startIndex, to: $0.lowerBound) } ?? -1 }
        XCTAssertFalse(order.contains(-1), result)
        XCTAssertEqual(order, order.sorted(), result)
        // One paragraph per line, separated by empty lines.
        XCTAssertTrue(result.contains(text("Left first") + "\r\n\r\n" + text("Left second")), result)
    }

    /// Page 5 of the RFP in Filee #38: a schedule laid out with tab stops, an address block of short lines, and a form
    /// whose labels are short and long.
    private func schedule() throws -> String {
        let pdf = PdfBuilder().newPage(612, 792)
        let body = pdf.font()
        pdf.paragraph("E. PROPOSED SCHEDULE OF ACTIVITIES: the dates below may change. This paragraph is long enough to wrap, so the page has a full text width.",
                      12, body, 54, 60, 500, 15)
        let rows = [["1.", "RFP Published", "08/14/2026"], ["2.", "Proposal Submission", "10/16/2026"], ["3.", "Proposal Selection", "10/19/2026"]]
        for (r, row) in rows.enumerated() {
            pdf.line(row[0], 12, body, 76.5, 110 + Double(r) * 14.6)
            pdf.line(row[1], 12, body, 108, 110 + Double(r) * 14.6)
            pdf.line(row[2], 12, body, 432, 110 + Double(r) * 14.6)
        }
        pdf.paragraph("F. INQUIRIES: Send all inquiries (transmittal by E-Mail preferred) to the address below, which is the only one.", 12, body, 54, 170, 500, 15)
        let address = ["WESTAR", "1880 Willamette Falls Drive, Ste. 200E", "West Linn, Oregon 97068", "Attn: Jeffrey P. Gabler"]
        for (l, line) in address.enumerated() { pdf.line(line, 12, body, 144, 215 + Double(l) * 14.6) }
        let form = [["Name:", "JEFFREY P. GABLER"], ["Organization:", "WESTAR COUNCIL"], ["Phone:", "503-657-4838"]]
        for (r, row) in form.enumerated() {
            pdf.line(row[0], 11, body, 72, 300 + Double(r) * 14)
            pdf.line(row[1], 11, body, 176, 300 + Double(r) * 14)
        }
        return try pdf.save(FilePath.combine(dir, "schedule.pdf"))
    }

    func testTabbedRowsAndLineBreaksAreKept() async throws {
        let path = try schedule()
        let paragraphs = Self.paragraphs(try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))).filter { !Self.textOf($0).isEmpty }
        XCTAssertEqual(paragraphs.map(Self.shown).filter { $0.contains("\t") || $0.contains("\n") }, [
            "1.\tRFP Published\t08/14/2026", "2.\tProposal Submission\t10/16/2026", "3.\tProposal Selection\t10/19/2026",
            "1880 Willamette Falls Drive, Ste. 200E\nWest Linn, Oregon 97068",
            "Name:\tJEFFREY P. GABLER", "Organization:\tWESTAR COUNCIL", "Phone:\t503-657-4838",
        ])
        // The tab stops sit where the parts start in the PDF, from the text's left edge (54 pt): 108 - 54 and 432 - 54.
        let row = paragraphs.first { Self.shown($0).hasPrefix("1.\t") }
        XCTAssertEqual(row?.format.tabs?.map(\.position), [5400, 37800])
        XCTAssertEqual(row?.format.tabs?.map(\.kind), [.left, .left])
        // The street and the town stay apart; the short lines around them are paragraphs of their own.
        XCTAssertTrue(paragraphs.contains { Self.shown($0) == "WESTAR" })
        XCTAssertTrue(paragraphs.contains { Self.shown($0) == "Attn: Jeffrey P. Gabler" })

        let result = try await txt(path)
        XCTAssertTrue(result.contains("1.\tRFP Published\t08/14/2026\r\n\r\n2.\tProposal Submission"), result)
        XCTAssertTrue(result.contains("Ste. 200E\r\nWest Linn"), result)
    }

    func testScannedPagesBecomePagePictures() async throws {
        let pdf = PdfBuilder().newPage()
        try pdf.picture(PdfBuilder.photo(dir, "scan.jpg", 595, 842), 0, 0, 595, 842)
        pdf.newPage().line("Text after the scan", 12, pdf.font(), 50, 80)
        let path = try pdf.save(FilePath.combine(dir, "scan.pdf"))

        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(model.sections.count, 1)
        let scan = try XCTUnwrap(Self.paragraphs(model).first?.inlines.compactMap { $0 as? HImage }.first)
        XCTAssertEqual([scan.width, scan.height], [59500, 84200])
        XCTAssertEqual(scan.anchor, HAnchor("PAPER", "LEFT", 0, "PAPER", "TOP", 0, "BEHIND_TEXT", true))
        XCTAssertEqual(Self.paragraphs(model).first { Self.textOf($0) == "Text after the scan" }?.pageBreakBefore, true)

        // Nothing to extract as text from the scan, but the text page still is.
        let result = try await txt(path)
        XCTAssertEqual(result, "Text after the scan\r\n")
    }

    func testInvisibleOcrTextIsTextButNotPartOfTheLook() async throws {
        // A scan with an invisible text layer (rendering mode 3), as OCR software writes it.
        let pdf = PdfBuilder().newPage()
        try pdf.picture(PdfBuilder.photo(dir, "scan.jpg", 595, 842), 0, 0, 595, 842)
        pdf.raw("BT 3 Tr /\(pdf.font().resource) 12 Tf 50 700 Td (Recognised words) Tj ET")
        let path = try pdf.save(FilePath.combine(dir, "ocr.pdf"))

        let recognised = try await txt(path)
        XCTAssertEqual(recognised, "Recognised words\r\n")
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertTrue(Self.paragraphs(model).allSatisfy { Self.textOf($0).isEmpty }, "the page is the scan")
        XCTAssertNotNil(Self.paragraphs(model).first?.inlines.first as? HImage)
    }

    /// Hangul needs an embedded font: the PDF is drawn with Core Text and Apple SD Gothic Neo.
    func testKoreanLinesJoinIntoOneParagraph() async throws {
        let korean = "한글 문단도 읽을 수 있어야 합니다. 줄이 바뀌어도 한 문단으로 이어지고 단어 사이의 빈칸도 그대로 남습니다."
        let path = FilePath.combine(dir, "korean.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        func draw(_ text: String, _ font: CTFont, _ x: Double, _ y: Double) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: x, y: 842 - y)
            CTLineDraw(line, context)
        }
        func width(_ text: String, _ font: CTFont) -> Double {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])), nil, nil, nil)
        }
        draw("Korean", CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil), 50, 80)
        let hangul = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 11, nil)
        var y = 110.0, current = ""
        for word in korean.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if !current.isEmpty && width(candidate, hangul) > 200 { draw(current, hangul, 50, y); y += 16; current = word } else { current = candidate }
        }
        draw(current, hangul, 50, y)
        context.endPDFPage()
        context.closePDF()

        let result = try await txt(path)
        XCTAssertEqual(result, "Korean\r\n\r\n" + korean + "\r\n")
    }

    func testPasswordProtectedPdfFailsWithAClearMessage() throws {
        let pdf = PdfBuilder().newPage()
        pdf.line("Secret", 12, pdf.font(), 50, 80)
        let path = try pdf.save(FilePath.combine(dir, "locked.pdf"))
        try PdfBuilder.protect(path, "1234")
        XCTAssertThrowsError(try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))) { error in
            XCTAssertTrue("\(error)".lowercased().contains("password"), "\(error)")
        }
    }

    func testEmptyPdfsHaveNoText() async throws {
        let path = try PdfBuilder().newPage().save(FilePath.combine(dir, "empty.pdf"))
        do {
            _ = try await txt(path)
            XCTFail("no text")
        } catch {
            XCTAssertTrue("\(error)".contains("The PDF contains no text"), "\(error)")
        }
    }

    func testFontNamesBecomeFamilies() {
        let cases: [(String, String?)] = [("ABCDEF+TimesNewRomanPS-BoldMT", "Times New Roman"), ("Arial-BoldMT", "Arial"), ("Helvetica-Oblique", "Arial"),
                                          ("QWERTY+MalgunGothic,Bold", "Malgun Gothic"), ("NanumGothic", "NanumGothic"), ("F1", nil), ("T3Font_2", nil)]
        for (postScript, family) in cases { XCTAssertEqual(PdfDocumentReader.fontFamily(postScript), family, postScript) }
    }

    func testParallelTextKeepsPageOrderRepeatedHeadersAndStyleChanges() async throws {
        let pdf = PdfBuilder()
        for index in 0..<17 {
            pdf.newPage()
            let regular = pdf.font(), bold = pdf.font(bold: true), italic = pdf.font(italic: true)
            pdf.line("Repeated report header", 9, regular, 50, 30)
            pdf.line("Page \(index + 1)", 9, regular, 280, 815)
            pdf.line("Section \(index)", 18, bold, 50, 160)
            let lead = "Plain words "
            pdf.line(lead, 12, regular, 50, 200)
            pdf.line("red words", 12, regular, 50 + pdf.width(lead, 12, regular), 200, color: (255, 0, 0))
            pdf.line("Italic words", 12, italic, 50, 240)
            pdf.line("Last paragraph \(index).", 10, regular, 50, 280)
        }
        let path = try pdf.save(FilePath.combine(dir, "parallel.pdf"))
        let serial = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        let parallel = try await PdfDocumentReader.readText(path)
        let expected = (0..<17).map { "Section \($0)\r\n\r\nPlain words red words\r\n\r\nItalic words\r\n\r\nLast paragraph \($0)." }
            .joined(separator: "\r\n\r\n") + "\r\n"
        XCTAssertEqual(PdfDocumentReader.plainText(parallel), expected)
        XCTAssertEqual(PdfDocumentReader.plainText(parallel), PdfDocumentReader.plainText(serial))
        let serialParagraphs = Self.paragraphs(serial), parallelParagraphs = Self.paragraphs(parallel)
        XCTAssertEqual(serialParagraphs.map(\.format), parallelParagraphs.map(\.format))
        XCTAssertEqual(serialParagraphs.map(\.headingLevel), parallelParagraphs.map(\.headingLevel))
        XCTAssertEqual(serialParagraphs.map(\.pageBreakBefore), parallelParagraphs.map(\.pageBreakBefore))
        let serialRuns = serialParagraphs.flatMap(\.inlines).compactMap { $0 as? HText }
        let parallelRuns = parallelParagraphs.flatMap(\.inlines).compactMap { $0 as? HText }
        XCTAssertEqual(serialRuns.map(\.text), parallelRuns.map(\.text))
        XCTAssertEqual(serialRuns.map(\.format), parallelRuns.map(\.format))
        let formats = parallelRuns.map(\.format)
        XCTAssertTrue(formats.contains { $0.color == "#FF0000" })
        XCTAssertTrue(formats.contains { $0.italic == true })
        XCTAssertTrue(formats.contains { $0.bold == true })
    }

    func testCancelledParallelTextReadThrows() async throws {
        let pdf = PdfBuilder()
        for index in 0..<17 {
            pdf.newPage().line("Paragraph \(index)", 12, pdf.font(), 50, 200)
        }
        let path = try pdf.save(FilePath.combine(dir, "cancelled.pdf"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PdfDocumentReader.readText(path)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled text read must stop before returning a document")
        } catch is CancellationError {
        }
    }
}

/// The parts of Filee's PdfReaderTests that go through the document writers and the route planner.
extension PdfReaderTests {
    private func catalog() -> ConverterCatalog {
        let catalog = ConverterCatalog(EngineRegistry.createAll(EngineEnvironment(dataDirectory: FilePath.combine(dir, "data"))))
        catalog.priority = AppSettings().enginePriority
        return catalog
    }

    func testPdfToDocxKeepsTheModelThroughTheWriter() async throws {
        XCTAssertEqual(catalog().createPlanner().plan("pdf", "docx")?.steps.map(\.converter.id), ["docx-writer"])
        let docx = try await GraphicsTestKit.convert(DocxWriterConverter(), try report(), to: "docx")
        let model = try DocxReader.read(docx[0], FilePath.combine(dir, "readback"))
        let paragraphs = Self.paragraphs(model).filter { !Self.textOf($0).isEmpty }
        XCTAssertEqual(paragraphs.map { Self.textOf($0).trimmingCharacters(in: .whitespaces) },
                       ["Annual Report 2026", "1. Introduction", Self.first, "Warning this line is italic", "Visit https://example.com",
                        "2. Details", Self.second])
        XCTAssertEqual(paragraphs.map(\.headingLevel), [1, 2, 0, 0, 0, 2, 0])
        XCTAssertTrue(paragraphs.count == 7 && paragraphs[5].pageBreakBefore)
        let entries = try ZipReader(path: docx[0]).entries.map(\.name).filter { $0.hasPrefix("word/media/") }
        XCTAssertEqual(entries.filter { $0.hasSuffix(".jpg") }.count, 1, "\(entries)")
        XCTAssertEqual(entries.filter { $0.hasSuffix(".png") }.count, 1, "\(entries)")
    }

    func testPdfToHwpxGoesThroughTheDocumentModel() async throws {
        let planner = catalog().createPlanner()
        XCTAssertEqual(planner.plan("pdf", "hwpx")?.steps.map(\.converter.id), ["hwpx-writer"])
        XCTAssertEqual(planner.plan("pdf", "txt")?.steps.map(\.converter.id), ["pdf-text"])

        let hwpx = try await GraphicsTestKit.convert(HwpxConverter(), try report(), to: "hwpx")
        let zip = try ZipReader(path: hwpx[0])
        let images = zip.entries.map(\.name).filter { $0.hasPrefix("BinData/") }
        XCTAssertEqual(images.count, 2, "\(images)")
        let section = try XCTUnwrap(try zip.data(named: "Contents/section0.xml"))
        XCTAssertTrue(String(decoding: section, as: UTF8.self).contains("Annual Report 2026"))
    }
}
