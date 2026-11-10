// Port of Filee.Engines.Tests/PdfReaderTests.cs: PDF → document model / TXT with the built-in PDF reader: paragraphs in
// reading order (two-column pages too), headings from font sizes, bold / italic / colour, links, pictures (JPEG kept as
// it is), repeated headers and footers left out, scanned pages as page pictures, and a clear error for password-protected
// files. Filee checked the model through its DOCX/HWPX output; the writers are other engines here, so the tests read the
// HDocument PdfDocumentReader returns. The test PDFs use the standard 14 fonts; the Korean one is drawn with Core Text.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
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

    @MainActor // so XCTest records its failures (after awaits, off the main actor, it may drop them)
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
            XCTAssertTrue(error is NoTextError, "\(error)")
            XCTAssertTrue("\(error)".contains("The PDF contains no text"), "\(error)")
        }
    }

    func testPdfWithoutReadablePagesDoesNotBecomeAnEmptyBook() async throws {
        let path = try PdfBuilder().save(FilePath.combine(dir, "no-pages.pdf"))
        do {
            _ = try await txt(path)
            XCTFail("No readable pages must not trigger the scan fallback")
        } catch {
            XCTAssertTrue(error is ConversionError, "\(error)")
        }
        let job = await coreRun(JobQueue(catalog()), [path], corePreset("epub"))
        XCTAssertEqual(job.files[0].state, .failed)
        let message = job.files[0].errorDetail ?? ""
        XCTAssertTrue(message.contains("The PDF contains no text") || message.contains("is not a PDF file that can be read"), message)
        XCTAssertTrue(job.outputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(FilePath.combine(dir, "no-pages.epub")))
    }

    func testFontNamesBecomeFamilies() {
        let cases: [(String, String?)] = [("ABCDEF+TimesNewRomanPS-BoldMT", "Times New Roman"), ("Arial-BoldMT", "Arial"), ("Helvetica-Oblique", "Arial"),
                                          ("QWERTY+MalgunGothic,Bold", "Malgun Gothic"), ("NanumGothic", "NanumGothic"), ("F1", nil), ("T3Font_2", nil)]
        for (postScript, family) in cases { XCTAssertEqual(PdfDocumentReader.fontFamily(postScript), family, postScript) }
    }

    /// A page whose text is all shown in one state takes one letter's attributes for all letters instead of PDFKit's
    /// attributed string; any change of font, size, matrix, mode or colour (or replacement text) keeps the attributed
    /// string. Either way the words are the same as from the attributed string.
    func testOneTextStatePagesKeepTheWordsOfThePagesAttributes() throws {
        let pdf = PdfBuilder()
        let words = "Plain words on a line of their own"
        let changes: [(String, Bool, (PdfBuilder, PdfBuilder.Font) -> Void)] = [
            ("one state", true, { _, _ in }),
            ("black spelled another way", true, { pdf, font in pdf.raw("/DeviceGray cs 0 sc BT /\(font.resource) 11 Tf 50 500 Td (\(words)) Tj ET") }),
            ("colour", false, { pdf, font in pdf.line(words, 11, font, 50, 300, color: (255, 0, 0)) }),
            ("size", false, { pdf, font in pdf.line(words, 12, font, 50, 300) }),
            ("font", false, { pdf, _ in pdf.line(words, 11, pdf.font(bold: true), 50, 300) }),
            ("rise", false, { pdf, font in pdf.raw("BT /\(font.resource) 11 Tf 3 Ts 50 500 Td (\(words)) Tj ET") }),
            ("scaling", false, { pdf, font in pdf.raw("BT /\(font.resource) 11 Tf 80 Tz 50 500 Td (\(words)) Tj ET") }),
            ("mode", false, { pdf, font in pdf.raw("BT 2 Tr /\(font.resource) 11 Tf 50 500 Td (\(words)) Tj ET") }),
            ("matrix", false, { pdf, font in pdf.raw("BT /\(font.resource) 1 Tf 11 0 0 11 50 500 Tm (\(words)) Tj ET") }),
            ("stroke colour", false, { pdf, font in pdf.raw("1 0 0 RG BT /\(font.resource) 11 Tf 50 500 Td (\(words)) Tj ET 0 G") }),
            ("replacement text", false, { pdf, font in pdf.raw("/Span << /ActualText (Other) >> BDC BT /\(font.resource) 11 Tf 50 500 Td (\(words)) Tj ET EMC") }),
        ]
        for (_, _, change) in changes {
            pdf.newPage()
            let font = pdf.font()
            for line in 0..<3 { pdf.line("\(words) \(line)", 11, font, 50, 100 + Double(line) * 14) }
            change(pdf, font)
        }
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: try pdf.save(FilePath.combine(dir, "states.pdf")))))
        for (index, (name, uniform, _)) in changes.enumerated() {
            let page = try XCTUnwrap(document.page(at: index))
            let scan = PdfDocumentReader.scanContent(try XCTUnwrap(page.pageRef))
            XCTAssertEqual(scan.uniformText, uniform, name)
            let words = PdfDocumentReader.pageWords(page, scan: scan)
            scan.mixedText = true // the page's own attributed string
            XCTAssertTrue(Self.sameWords(words, PdfDocumentReader.pageWords(page, scan: scan)), name)
            XCTAssertGreaterThanOrEqual(words.count, 27, name)
        }
    }

    /// Default colour spaces change what g, rg, k and the device spaces paint: a page whose resources define one (or
    /// inherit it from the page tree), or a form or nested form defining its own, keeps PDFKit's attributed string. The
    /// same pages without them are in one state.
    func testDefaultColourSpacesKeepThePagesAttributes() throws {
        func stream(_ body: String, _ dictionary: String = "") -> String { "<< \(dictionary) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream" }
        func text(_ y: Int, _ words: String, _ colour: String) -> String { "\(colour) BT /F1 11 Tf 50 \(y) Td (\(words)) Tj ET" }
        let page = "/Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R"
        let form = "/Type /XObject /Subtype /Form /BBox [0 0 612 792]"
        let calGray = "/DefaultGray [/CalGray << /WhitePoint [0.9505 1 1.089] /Gamma 2 >>]"
        let calRGB = "/DefaultRGB [/CalRGB << /WhitePoint [0.9505 1 1.089] /Gamma [2 2 2] >>]"
        let cases: [(String, (String) -> [Int: String])] = [
            ("form", { spaces in [2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                                  3: "<< \(page) /Resources << /Font << /F1 9 0 R >> /XObject << /Fm 5 0 R >> >> >>",
                                  4: stream(text(700, "Page words", "0.5 g") + " q /Fm Do Q"),
                                  5: stream(text(500, "Form words", "0.5 g"), form + " /Resources << /Font << /F1 9 0 R >> /ColorSpace << \(spaces) >> >>")] }),
            ("inherited", { spaces in [2: "<< /Type /Pages /Kids [3 0 R] /Count 1 /Resources << /Font << /F1 9 0 R >> /ColorSpace << \(spaces) >> >> >>",
                                       3: "<< \(page) >>",
                                       4: stream(text(700, "Page words", "0.5 g") + " " + text(680, "More page words", "0.5 g"))] }),
            ("nested form", { spaces in [2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                                         3: "<< \(page) /Resources << /Font << /F1 9 0 R >> /XObject << /Fa 5 0 R >> >> >>",
                                         4: stream(text(700, "Page words", "0 0 1 rg") + " q /Fa Do Q"),
                                         5: stream(text(600, "Outer words", "0 0 1 rg") + " q /Fb Do Q", form + " /Resources << /Font << /F1 9 0 R >> /XObject << /Fb 6 0 R >> >>"),
                                         6: stream(text(500, "Inner words", "0 0 1 rg"), form + " /Resources << /Font << /F1 9 0 R >> /ColorSpace << \(spaces) >> >>")] }),
        ]
        for (name, objects) in cases {
            for (spaces, uniform) in [(name == "nested form" ? calRGB : calGray, false), ("", true)] {
                var all = objects(spaces)
                all[1] = "<< /Type /Catalog /Pages 2 0 R >>"
                all[9] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
                let label = "\(name) \(uniform ? "without" : "with") a default colour space"
                let pdf = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: try Self.rawPdf(FilePath.combine(dir, "\(name)-\(uniform).pdf"), all))))
                let page = try XCTUnwrap(pdf.page(at: 0))
                let scan = PdfDocumentReader.scanContent(try XCTUnwrap(page.pageRef))
                XCTAssertEqual(scan.uniformText, uniform, label)
                let words = PdfDocumentReader.pageWords(page, scan: scan)
                scan.mixedText = true
                XCTAssertTrue(Self.sameWords(words, PdfDocumentReader.pageWords(page, scan: scan)), label)
                XCTAssertGreaterThanOrEqual(words.count, 4, label)
            }
        }
    }

    /// Words with all letter attributes equal; colours compare as Core Graphics colours (colour space included).
    private static func sameWords(_ a: [PdfDocumentReader.PageWord], _ b: [PdfDocumentReader.PageWord]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.left == y.left && x.right == y.right && x.baseline == y.baseline && x.letters.count == y.letters.count
                && zip(x.letters, y.letters).allSatisfy { p, q in
                    p.text == q.text && p.box == q.box && p.baseline == q.baseline && p.size == q.size && p.fontName == q.fontName
                        && p.bold == q.bold && p.italic == q.italic && p.mode == q.mode && p.horizontal == q.horizontal
                        && (p.color == nil ? q.color == nil : q.color.map { CFEqual(p.color, $0) } ?? false)
                }
        }
    }

    /// A PDF of numbered objects (1: catalog), for what PdfBuilder doesn't write (forms, colour space resources).
    /// `streams`: binary data of streams whose objects are their dictionaries' entries.
    private static func rawPdf(_ path: String, _ objects: [Int: String], _ streams: [Int: Data] = [:]) throws -> String {
        var file = Data("%PDF-1.5\n".utf8)
        var offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = file.count
            if let data = streams[number] {
                file += Data("\(number) 0 obj\n<< \(objects[number]!) /Length \(data.count) >>\nstream\n".utf8) + data + Data("\nendstream\nendobj\n".utf8)
            } else {
                file += Data("\(number) 0 obj\n\(objects[number]!)\nendobj\n".utf8)
            }
        }
        let count = objects.keys.max()! + 1, xref = file.count
        var table = "xref\n0 \(count)\n0000000000 65535 f \n"
        for number in 1..<count { table += String(format: "%010d 00000 %@ \n", offsets[number] ?? 0, offsets[number] == nil ? "f" : "n") }
        file += Data((table + "trailer\n<< /Size \(count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8)
        try file.write(to: URL(fileURLWithPath: path))
        return path
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
        let parallel = try await PdfDocumentReader.readText(path).document
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

    func testScannedPdfReachesEbooksThroughPagePicturesAndTextStaysExplicit() async throws {
        let scan = PdfBuilder().newPage()
        try scan.picture(PdfBuilder.photo(dir, "scan.jpg", 595, 842), 0, 0, 595, 842)
        let scanned = try scan.save(FilePath.combine(dir, "scan.pdf"))
        let ocr = PdfBuilder().newPage()
        try ocr.picture(PdfBuilder.photo(dir, "ocr.jpg", 595, 842), 0, 0, 595, 842)
        ocr.raw("BT 3 Tr /\(ocr.font().resource) 12 Tf 50 700 Td (Recognised words) Tj ET")
        let recognised = try ocr.save(FilePath.combine(dir, "ocr.pdf"))
        let queue = JobQueue(catalog())

        let books = await coreRun(queue, [scanned, recognised], corePreset("epub"))
        XCTAssertEqual(books.state, .completed, "\(books.files.map { $0.errorDetail ?? "" })")
        let scanBook = try await DocumentReaders.readAsync(FilePath.combine(dir, "scan.epub"), "epub", dir)
        XCTAssertEqual(HDocumentWalker.images(scanBook).count, 1)
        // The OCR text stays extractable alongside its scanned page.
        let ocrBook = try await DocumentReaders.readAsync(FilePath.combine(dir, "ocr.epub"), "epub", dir)
        XCTAssertTrue(PlainTextWriter.write(ocrBook).contains("Recognised words"))
        XCTAssertEqual(HDocumentWalker.images(ocrBook).count, 1)

        let txt = await coreRun(queue, [scanned], corePreset("txt"))
        XCTAssertEqual(txt.files[0].state, .failed)
        XCTAssertTrue(txt.files[0].errorDetail?.contains("The PDF contains no text") == true, "\(txt.files[0].errorDetail ?? "")")
        XCTAssertFalse(FileManager.default.fileExists(FilePath.combine(dir, "scan.txt")))
    }

    func testParallelUniformTextKeepsFontsAcrossDocuments() async throws {
        let pdf = PdfBuilder()
        for page in 0..<16 {
            pdf.newPage().line("Uniform page \(page) words", 12, pdf.font(), 50, 200)
        }
        let path = try pdf.save(FilePath.combine(dir, "uniform.pdf"))
        let expected = (0..<16).map { "Uniform page \($0) words" }.joined(separator: "\r\n\r\n") + "\r\n"
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask { PdfDocumentReader.plainText(try await PdfDocumentReader.readText(path).document) }
            }
            for try await text in group { XCTAssertEqual(text, expected) }
        }
    }

    func testInvisibleOcrOverAnImageMaskKeepsTheWholePageInRichOutputs() async throws {
        let operators = "q 200 0 0 100 0 0 cm /Scan Do Q BT 3 Tr /F1 12 Tf 20 50 Td (Recognised words) Tj ET"
        let mask = "AA55AA55AA55AA55>"
        let path = try Self.rawPdf(FilePath.combine(dir, "mask-ocr.pdf"), [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /XObject << /Scan 5 0 R >> /Font << /F1 6 0 R >> >> >>",
            4: "<< /Length \(operators.utf8.count) >>\nstream\n\(operators)\nendstream",
            5: "<< /Type /XObject /Subtype /Image /Width 8 /Height 8 /ImageMask true /BitsPerComponent 1 /Filter /ASCIIHexDecode /Length \(mask.utf8.count) >>\nstream\n\(mask)\nendstream",
            6: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
        let original = try PdfDocumentReader.read(path, FilePath.combine(dir, "original"))
        let expected = try XCTUnwrap(HDocumentWalker.images(original).first)
        let pixels = try ImagePixels.bitmap(GraphicsTestKit.decode(expected.path).frames[0]).pixels
        // ODT needs the external office engine and is checked through the full host catalog.
        for format in ["epub", "fb2", "htmlz", "txtz"] {
            let job = await coreRun(JobQueue(catalog()), [path], corePreset(format))
            XCTAssertEqual(job.state, .completed, "\(format): \(job.files.map { $0.errorDetail ?? "" })")
            let result = try await DocumentReaders.readAsync(try XCTUnwrap(job.outputs.first), format, FilePath.combine(dir, format))
            XCTAssertTrue(PlainTextWriter.write(result).contains("Recognised words"), format)
            let images = HDocumentWalker.images(result)
            XCTAssertEqual(images.count, 1, format)
            let image = try XCTUnwrap(images.first, format)
            XCTAssertTrue(try ImagePixels.bitmap(GraphicsTestKit.decode(image.path).frames[0]).pixels == pixels, format)
        }
        let extracted = try await txt(path)
        XCTAssertEqual(extracted, "Recognised words\r\n")
    }

    func testSvgPdfKeepsItsDrawingAndSearchableTextInEpub() async throws {
        let source = FilePath.combine(dir, "drawing.svg"), path = FilePath.combine(dir, "drawing.pdf")
        try "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><rect width='200' height='100' fill='#0c6'/><text x='20' y='50'>Drawing words</text></svg>"
            .write(toFile: source, atomically: true, encoding: .utf8)
        try SvgRenderer.writePdf(SvgRenderer.load(source), path, title: "Drawing", pdfA: false)
        let detected = try await PdfDocumentReader.readText(path)
        XCTAssertTrue(detected.needsPictures)
        let job = await coreRun(JobQueue(catalog()), [path], corePreset("epub"))
        XCTAssertEqual(job.state, .completed, "\(job.files.map { $0.errorDetail ?? "" })")
        let result = try await DocumentReaders.readAsync(try XCTUnwrap(job.outputs.first), "epub", FilePath.combine(dir, "book"))
        XCTAssertTrue(PlainTextWriter.write(result).contains("Drawing words"))
        let image = try XCTUnwrap(HDocumentWalker.images(result).first)
        let original = try PdfDocumentReader.read(path, FilePath.combine(dir, "original"))
        let expected = try XCTUnwrap(HDocumentWalker.images(original).first)
        XCTAssertTrue(try ImagePixels.bitmap(GraphicsTestKit.decode(image.path).frames[0]).pixels
                      == ImagePixels.bitmap(GraphicsTestKit.decode(expected.path).frames[0]).pixels)
    }

    /// Text on pages 1 and 3 and only a scan on page 2: the rich outputs keep the text and the scan's page picture in page
    /// order, TXT the text. An OCR'd scan keeps its text next to a scan without any; a blank page needs no picture.
    func testTextAndScannedPagesBothReachRichOutputsInPageOrder() async throws {
        let mixed = PdfBuilder().newPage()
        mixed.line("First page words", 12, mixed.font(), 50, 80)
        try mixed.newPage().picture(PdfBuilder.photo(dir, "scan.jpg", 595, 842), 0, 0, 595, 842)
        mixed.newPage().line("Third page words", 12, mixed.font(), 50, 80)
        let ocr = PdfBuilder().newPage()
        try ocr.picture(PdfBuilder.photo(dir, "ocr.jpg", 595, 842), 0, 0, 595, 842)
        ocr.raw("BT 3 Tr /\(ocr.font().resource) 12 Tf 50 700 Td (Recognised words) Tj ET")
        try ocr.newPage().picture(PdfBuilder.photo(dir, "photo.jpg", 595, 842), 0, 0, 595, 842)
        let blank = PdfBuilder().newPage()
        blank.line("Only text words", 12, blank.font(), 50, 80)
        blank.newPage()
        let paths = try [mixed.save(FilePath.combine(dir, "mixed.pdf")), ocr.save(FilePath.combine(dir, "ocr.pdf")),
                         blank.save(FilePath.combine(dir, "blank.pdf"))]
        let queue = JobQueue(catalog())
        func readBack(_ name: String, _ format: String) async throws -> [String] {
            let document = try await DocumentReaders.readAsync(FilePath.combine(dir, name), format, dir)
            return try Self.content(document).filter { $0.hasSuffix("words") || $0.hasSuffix("picture") }
        }

        let books = await coreRun(queue, paths, corePreset("epub"))
        XCTAssertEqual(books.state, .completed, "\(books.files.map { $0.errorDetail ?? "" })")
        let documents = await coreRun(queue, [paths[0]], corePreset("docx"))
        XCTAssertEqual(documents.state, .completed, "\(documents.files.map { $0.errorDetail ?? "" })")
        for format in ["epub", "docx"] {
            let pages = try await readBack("mixed." + format, format)
            XCTAssertEqual(pages, ["First page words", "picture", "Third page words"], format)
        }
        let recognised = try await readBack("ocr.epub", "epub"), textOnly = try await readBack("blank.epub", "epub")
        XCTAssertEqual(recognised.filter { $0 != "picture" }, ["Recognised words"])
        XCTAssertEqual(recognised.filter { $0 == "picture" }.count, 2)
        XCTAssertEqual(recognised.last, "picture")
        XCTAssertEqual(textOnly, ["Only text words"])

        let texts = await coreRun(queue, Array(paths.prefix(2)), corePreset("txt"))
        XCTAssertEqual(texts.state, .completed, "\(texts.files.map { $0.errorDetail ?? "" })")
        func written(_ name: String) throws -> String {
            String(decoding: try Data(contentsOf: URL(fileURLWithPath: FilePath.combine(dir, name))).dropFirst(3), as: UTF8.self)
        }
        XCTAssertEqual(try written("mixed.txt"), "First page words\r\n\r\nThird page words\r\n")
        XCTAssertEqual(try written("ocr.txt"), "Recognised words\r\n")
    }

    func testStampedAndRotatedScansKeepTextAndPictures() async throws {
        let queue = JobQueue(catalog())
        for angle in [0, 90, 180, 270] {
            let pdf = PdfBuilder().newPage()
            pdf.line("First page words", 12, pdf.font(), 50, 80)
            try pdf.newPage().picture(PdfBuilder.photo(dir, "stamp.jpg", 595, 842), 0, 0, 595, 842)
            pdf.line("Stamped page words", 12, pdf.font(), 50, 160)
            pdf.newPage().line("Third page words", 12, pdf.font(), 50, 80)
            let path = try pdf.save(FilePath.combine(dir, "stamped-\(angle).pdf"))
            if angle != 0 {
                let rotated = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
                let page = try XCTUnwrap(rotated.page(at: 1))
                page.rotation = angle
                XCTAssertTrue(rotated.write(to: URL(fileURLWithPath: path)))
            }
            let job = await coreRun(queue, [path], corePreset("epub"))
            XCTAssertEqual(job.state, .completed, "\(angle): \(job.files.map { $0.errorDetail ?? "" })")
            let book = try await DocumentReaders.readAsync(FilePath.combine(dir, "stamped-\(angle).epub"), "epub", dir)
            let content = try Self.content(book)
            let first = try XCTUnwrap(content.firstIndex(of: "First page words"))
            let stamp = try XCTUnwrap(content.firstIndex(of: "Stamped page words"))
            let third = try XCTUnwrap(content.firstIndex(of: "Third page words"))
            let picture = try XCTUnwrap(content.firstIndex(of: "picture"))
            XCTAssertEqual(content.filter { $0 == "picture" }.count, 1, "\(angle)")
            XCTAssertTrue(first < stamp && stamp < third && first < picture && picture < third, "\(angle): \(content)")
        }
    }

    func testPagePictureProbePropagatesErrorsAndCancellation() async throws {
        let pdf = PdfBuilder().newPage()
        pdf.newPage().raw("0 g 50 50 2 2 re f")
        let path = try pdf.save(FilePath.combine(dir, "probe.pdf"))
        XCTAssertFalse(try PdfDocumentReader.showsAnything(path, [0]))
        XCTAssertTrue(try PdfDocumentReader.showsAnything(path, [1]))
        XCTAssertThrowsError(try PdfDocumentReader.showsAnything(path, [2]))
        XCTAssertThrowsError(try PdfDocumentReader.showsAnything(path + ".missing", [0]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PdfDocumentReader.showsAnything(path, [1])
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled picture detection must not become an empty page")
        } catch is CancellationError {}
    }

    /// Which of blue, red, green and dark (text) pixels a picture shows.
    private static func colours(_ image: HImage) throws -> Set<String> {
        let bitmap = ImagePixels.bitmap(try GraphicsTestKit.decode(image.path).frames[0])
        var found = Set<String>()
        for i in stride(from: 0, to: bitmap.pixels.count, by: 4) {
            let (r, g, b) = (Int(bitmap.pixels[i]), Int(bitmap.pixels[i + 1]), Int(bitmap.pixels[i + 2]))
            if b > 200 && r < 60 && g < 60 { found.insert("blue") }
            if r > 200 && g < 60 && b < 60 { found.insert("red") }
            if g > 200 && r < 60 && b < 60 { found.insert("green") }
            if r < 90 && g < 90 && b < 90 { found.insert("dark") }
        }
        return found
    }

    /// A text page with a vector chart (a blue box under its black caption, a red rule), a green inline image and, in a
    /// form, a blue box with black text over it.
    private func drawingPage() throws -> String {
        let chart = "0 0 1 rg 100 500 300 150 re f 1 0 0 RG 4 w 100 450 m 400 450 l S "
            + "q 60 0 0 40 420 520 cm BI /W 2 /H 2 /BPC 8 /CS /RGB /F /AHx ID 00FF0000FF0000FF0000FF00> EI Q "
            + "0 g BT /F1 12 Tf 120 570 Td (Chart caption words) Tj ET BT /F1 12 Tf 50 330 Td (Body text after the chart) Tj ET "
            + "q /Fm Do Q"
        let form = "0 0 1 rg 100 100 200 60 re f 0 g BT /F1 12 Tf 110 120 Td (Form label words) Tj ET"
        return try Self.rawPdf(FilePath.combine(dir, "drawing.pdf"), [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /XObject << /Fm 5 0 R >> /Font << /F1 6 0 R >> >> >>",
            4: "<< /Length \(chart.utf8.count) >>\nstream\n\(chart)\nendstream",
            5: "<< /Type /XObject /Subtype /Form /BBox [0 0 595 842] /Resources << /Font << /F1 6 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream",
            6: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
    }

    func testTextPagesKeepVectorDrawingsAndInlineImagesWithoutDoublingTheText() async throws {
        let path = try drawingPage()
        let words = ["Chart caption words", "Body text after the chart", "Form label words"]
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(Set(Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }), Set(words))
        let pictures = HDocumentWalker.images(model)
        XCTAssertEqual(pictures.count, 1)
        // The drawing without its text: the text stays text and is not shown twice.
        XCTAssertEqual(try Self.colours(try XCTUnwrap(pictures.first)), ["blue", "red", "green"])
        let extracted = try await txt(path)
        XCTAssertEqual(Set(extracted.components(separatedBy: "\r\n").filter { !$0.isEmpty }), Set(words), "TXT stays the text")

        let queue = JobQueue(catalog())
        // ODT needs the external office engine and is checked through the full host catalog.
        for format in ["docx", "hwpx", "epub", "fb2", "htmlz", "txtz"] {
            let job = await coreRun(queue, [path], corePreset(format))
            XCTAssertEqual(job.state, .completed, "\(format): \(job.files.map { $0.errorDetail ?? "" })")
            let output = try XCTUnwrap(job.outputs.first, format)
            if format == "hwpx" {
                XCTAssertEqual(try ZipReader(path: output).entries.map(\.name).filter { $0.hasPrefix("BinData/") }.count, 1)
                continue
            }
            let result = try await DocumentReaders.readAsync(output, format, FilePath.combine(dir, format))
            let text = PlainTextWriter.write(result)
            for word in words { XCTAssertEqual(text.components(separatedBy: word).count, 2, "\(format): \(word) once") }
            let images = HDocumentWalker.images(result)
            XCTAssertEqual(images.count, 1, format)
            XCTAssertEqual(try Self.colours(try XCTUnwrap(images.first, format)), ["blue", "red", "green"], format)
        }
    }

    func testPaintThatShowsNothingAddsNoPicture() async throws {
        let pdf = PdfBuilder().newPage()
        pdf.raw("1 g 0 0 595 842 re f q 0 0 1 rg 100 100 50 50 re W n Q 0 g")
        pdf.line("Only text words", 12, pdf.font(), 50, 80)
        let path = try pdf.save(FilePath.combine(dir, "white.pdf"))
        let drawn = try await PdfDocumentReader.readText(path)
        XCTAssertFalse(drawn.needsPictures)
        XCTAssertEqual(drawn.textPages.map(\.index), [0])
        XCTAssertEqual(drawn.textPages.map(\.drawn), [true])
        XCTAssertFalse(try PdfDocumentReader.showsAnything(path, textPages: drawn.textPages), "white paper and a clip show nothing")
        XCTAssertTrue(try PdfDocumentReader.showsAnything(path, [0]), "the text is visible")
        let chart = try drawingPage()
        let chartPages = try await PdfDocumentReader.readText(chart).textPages
        XCTAssertTrue(try PdfDocumentReader.showsAnything(chart, textPages: chartPages))
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertTrue(HDocumentWalker.images(model).isEmpty)
        XCTAssertEqual(Self.paragraphs(model).map(Self.textOf), ["Only text words"])
    }

    func testStencilMasksOnTextPagesAreKeptBesideTheText() throws {
        let operators = "0 0 1 rg q 200 0 0 100 0 0 cm /Logo Do Q 0 g BT /F1 12 Tf 20 120 Td (Logo words) Tj ET"
        let mask = "AA55AA55AA55AA55>"
        let path = try Self.rawPdf(FilePath.combine(dir, "stencil.pdf"), [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 150] /Contents 4 0 R /Resources << /XObject << /Logo 5 0 R >> /Font << /F1 6 0 R >> >> >>",
            4: "<< /Length \(operators.utf8.count) >>\nstream\n\(operators)\nendstream",
            5: "<< /Type /XObject /Subtype /Image /Width 8 /Height 8 /ImageMask true /BitsPerComponent 1 /Filter /ASCIIHexDecode /Length \(mask.utf8.count) >>\nstream\n\(mask)\nendstream",
            6: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }, ["Logo words"])
        let pictures = HDocumentWalker.images(model)
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(try Self.colours(try XCTUnwrap(pictures.first)), ["blue"])
    }

    private static func stream(_ body: String, _ dictionary: String = "") -> String {
        "<< \(dictionary) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
    }

    private static let normal = "0 g BT /F1 12 Tf 20 250 Td (Normal words here) Tj ET "
    private static let glyphFonts = "/Font << /F1 5 0 R /T3 6 0 R /F2 9 0 R >>"

    /// A 400 × 300 page with visible text PDFKit can't all read: Helvetica (F1), Type 3 glyphs without Unicode (T3: A a
    /// square, B a triangle) and Helvetica whose ToUnicode map makes B a space (F2). The text the reader keeps is black and
    /// the glyphs are coloured, so a dark pixel in a page picture is text shown twice. `extra` objects start at 11.
    private func glyphPdf(_ name: String, _ content: String, _ resources: String = "", _ extra: [Int: String] = [:],
                          _ streams: [Int: Data] = [:]) throws -> String {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def "
            + "/CMapName /Adobe-Identity-UCS def /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <0041> <42> <0020> endbfchar "
            + "endcmap CMapName currentdict /CMap defineresource pop end end"
        let objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << \(Self.glyphFonts) \(resources) >> >>",
            4: Self.stream(content),
            5: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            6: "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /g1 7 0 R /g2 8 0 R >>"
                + " /Encoding << /Type /Encoding /Differences [65 /g1 /g2] >> /FirstChar 65 /LastChar 66 /Widths [1000 1000] /Resources << >> >>",
            7: Self.stream("1000 0 0 0 1000 1000 d1 0 0 1000 1000 re f"),
            8: Self.stream("1000 0 0 0 1000 1000 d1 0 0 m 1000 0 l 500 1000 l f"),
            9: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 10 0 R >>",
            10: Self.stream(cmap),
        ]
        return try Self.rawPdf(FilePath.combine(dir, name), objects.merging(extra) { $1 }, streams)
    }

    /// The colour at a point of a 400 × 300 page (y up) in a picture placed on its paper; nil outside the picture.
    private static func colour(_ picture: HImage, _ x: Double, _ y: Double) throws -> String? {
        let anchor = try XCTUnwrap(picture.anchor)
        let image = try GraphicsTestKit.decode(picture.path).frames[0]
        let width = Double(try XCTUnwrap(picture.width)), height = Double(try XCTUnwrap(picture.height))
        let column = Int(((x * 100 - Double(anchor.horizontalOffset)) / width * Double(image.width)).rounded(.down))
        let row = Int((((300 - y) * 100 - Double(anchor.verticalOffset)) / height * Double(image.height)).rounded(.down))
        guard (0..<image.width).contains(column), (0..<image.height).contains(row) else { return nil }
        let p = GraphicsTestKit.pixel(image, column, row)
        switch (p.r, p.g, p.b) {
        case let (r, g, b) where r > 200 && g < 60 && b < 60: return "red"
        case let (r, g, b) where g > 200 && r < 60 && b < 60: return "green"
        case let (r, g, b) where b > 200 && r < 60 && g < 60: return "blue"
        case let (r, g, b) where r < 90 && g < 90 && b < 90: return "dark"
        case let (r, g, b) where r > 240 && g > 240 && b > 240: return "white"
        default: return "other"
        }
    }

    /// A page picture's place on the 400 × 300 paper (x, y up), in points.
    private static func place(_ picture: HImage) throws -> CGRect {
        let anchor = try XCTUnwrap(picture.anchor)
        let width = CGFloat(try XCTUnwrap(picture.width)) / 100, height = CGFloat(try XCTUnwrap(picture.height)) / 100
        return CGRect(x: CGFloat(anchor.horizontalOffset) / 100, y: 300 - CGFloat(anchor.verticalOffset) / 100 - height, width: width, height: height)
    }

    private static func assertPlace(_ picture: HImage, _ expected: CGRect, _ message: String = "", line: UInt = #line) throws {
        let place = try place(picture)
        for (a, b) in [(place.minX, expected.minX), (place.minY, expected.minY), (place.maxX, expected.maxX), (place.maxY, expected.maxY)] {
            XCTAssertEqual(a, b, accuracy: 1.5, "\(message) \(place) ≠ \(expected)", line: line)
        }
    }

    /// Rich outputs through the queue: completed, the input unchanged, each word once, and the model's pictures, each with
    /// its pixels (for HWPX, as many pictures).
    @MainActor // see txt
    private func assertRichOutputs(_ path: String, _ words: [String], _ pictures: [HImage], line: UInt = #line) async throws {
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let pixels = try pictures.map { ImagePixels.bitmap(try GraphicsTestKit.decode($0.path).frames[0]).pixels }
        let queue = JobQueue(catalog())
        // ODT needs the external office engine and is checked through the full host catalog.
        for format in ["docx", "hwpx", "epub", "fb2", "htmlz", "txtz"] {
            let job = await coreRun(queue, [path], corePreset(format))
            XCTAssertEqual(job.state, .completed, "\(format): \(job.files.map { $0.errorDetail ?? "" })", line: line)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original, format, line: line)
            let output = try XCTUnwrap(job.outputs.first, format, line: line)
            if format == "hwpx" {
                XCTAssertEqual(try ZipReader(path: output).entries.map(\.name).filter { $0.hasPrefix("BinData/") }.count, pictures.count, line: line)
                continue
            }
            let result = try await DocumentReaders.readAsync(output, format, FilePath.combine(dir, format))
            let text = PlainTextWriter.write(result)
            for word in words { XCTAssertEqual(text.components(separatedBy: word).count, 2, "\(format): \(word) once", line: line) }
            let images = try HDocumentWalker.images(result).map { ImagePixels.bitmap(try GraphicsTestKit.decode($0.path).frames[0]).pixels }
            XCTAssertEqual(images.count, pictures.count, format, line: line)
            for (i, picture) in pixels.enumerated() { XCTAssertTrue(images.contains(picture), "\(format): picture \(i)", line: line) }
            try FileManager.default.removeItem(atPath: output)
        }
    }

    /// Visible text PDFKit can't read (Type 3 glyphs without Unicode) on a page without any painted path: the page picture
    /// keeps the glyphs where they are; the text PDFKit reads stays text and isn't drawn again, also turned text, which
    /// PDFKit reads in its own frame (its words come out as text, as before).
    func testGlyphsWithoutUnicodeStayOnThePagePictureAndTheTextStaysText() async throws {
        let path = try glyphPdf("unread.pdf", Self.normal + "1 0 0 rg BT /T3 20 Tf 20 150 Td (ABAB) Tj ET "
                                    + "0 0 1 rg BT /F1 12 Tf 0 1 -1 0 300 50 Tm (Vertical words) Tj ET 0 g")
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }.sorted(), ["Normal words here", "Vertical", "words"])
        let pictures = HDocumentWalker.images(model)
        XCTAssertEqual(pictures.count, 1)
        let drawing = try XCTUnwrap(pictures.first)
        try Self.assertPlace(drawing, CGRect(x: 20, y: 150, width: 80, height: 20), "the glyph row")
        XCTAssertEqual(try Self.colours(drawing), ["red"], "neither the black nor the blue text twice")
        for (x, y, expected) in [(30.0, 160.0, "red"), (50, 152, "red"), (41, 169, "white"), (70, 168, "red"), (90, 152, "red"), (99, 169, "white")] {
            XCTAssertEqual(try Self.colour(drawing, x, y), expected, "(\(x), \(y))")
        }
        let extracted = try await txt(path)
        XCTAssertEqual(extracted, "Normal words here\r\n\r\nwords\r\n\r\nVertical\r\n", "TXT as before")
        try await assertRichOutputs(path, ["Normal words here", "Vertical"], [drawing])
    }

    /// Forms in forms (the inner one moved by its matrix): their words are text once, their glyphs stay in place, and
    /// their turned text isn't drawn again.
    func testGlyphsInNestedFormsStayInPlace() async throws {
        let inner = "0 1 0 rg BT /T3 20 Tf 100 100 Td (BA) Tj ET 0 0 1 rg BT /F1 12 Tf 0 1 -1 0 60 60 Tm (Turned) Tj ET 0 g BT /F1 12 Tf 20 180 Td (Inner words) Tj ET"
        let outer = "0 g BT /F1 12 Tf 20 200 Td (Outer form words) Tj ET q /Fb Do Q"
        let form = "/Type /XObject /Subtype /Form /BBox [0 0 400 300]"
        let path = try glyphPdf("nested.pdf", Self.normal + "q /Fa Do Q", "/XObject << /Fa 11 0 R >>", [
            11: Self.stream(outer, form + " /Resources << \(Self.glyphFonts) /XObject << /Fb 12 0 R >> >>"),
            12: Self.stream(inner, form + " /Matrix [1 0 0 1 150 -20] /Resources << \(Self.glyphFonts) >>"),
        ])
        let words = ["Normal words here", "Outer form words", "Inner words"]
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }.sorted(), (words + ["Turned"]).sorted())
        let pictures = HDocumentWalker.images(model)
        XCTAssertEqual(pictures.count, 1)
        let drawing = try XCTUnwrap(pictures.first)
        try Self.assertPlace(drawing, CGRect(x: 250, y: 80, width: 40, height: 20), "the inner form's glyphs")
        XCTAssertEqual(try Self.colours(drawing), ["green"])
        for (x, y, expected) in [(260.0, 82.0, "green"), (251, 99, "white"), (280, 90, "green")] {
            XCTAssertEqual(try Self.colour(drawing, x, y), expected, "(\(x), \(y))")
        }
        let extracted = try await txt(path)
        XCTAssertEqual(extracted, "Normal words here\r\n\r\nOuter form words\r\n\r\nInner words\r\n\r\nTurned\r\n", "TXT as before")
        try await assertRichOutputs(path, words + ["Turned"], [drawing])
    }

    /// Text the reader can't read that shows nothing (invisible, white on white, clipped away) adds no picture, nor does a
    /// blank page beside it in reflowable outputs.
    func testUnreadTextThatShowsNothingAddsNoPicture() async throws {
        let content = Self.normal + "BT 3 Tr /T3 20 Tf 20 150 Td (AB) Tj ET 1 g BT /T3 20 Tf 120 150 Td (AB) Tj ET 0 g "
            + "q 0 0 1 1 re W n 1 0 0 rg BT /T3 20 Tf 220 150 Td (AB) Tj ET Q 0 g"
        let path = try glyphPdf("hidden.pdf", content, "", [
            2: "<< /Type /Pages /Kids [3 0 R 11 0 R] /Count 2 >>",
            11: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 12 0 R >>",
            12: Self.stream(""),
        ])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(try Self.content(model), ["Normal words here", "blank picture"], "the blank page stays a page")
        let extracted = try await txt(path)
        XCTAssertEqual(extracted, "Normal words here\r\n")
        let job = await coreRun(JobQueue(catalog()), [path], corePreset("epub"))
        XCTAssertEqual(job.state, .completed, "\(job.files.map { $0.errorDetail ?? "" })")
        let book = try await DocumentReaders.readAsync(try XCTUnwrap(job.outputs.first), "epub", FilePath.combine(dir, "book"))
        XCTAssertEqual(try Self.content(book), ["Normal words here"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    /// On a page with a vector chart, the glyphs inside the chart stay on its drawing, the caption over it doesn't.
    func testDrawnPagesKeepTheGlyphsTheTextLeavesOut() async throws {
        let path = try glyphPdf("chart-glyphs.pdf", "0 0 1 rg 20 40 200 100 re f 0 g BT /F1 12 Tf 30 120 Td (Chart caption words) Tj ET "
                                    + "1 0 0 rg BT /T3 20 Tf 30 60 Td (ABAB) Tj ET 0 g " + Self.normal)
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }, ["Normal words here", "Chart caption words"])
        let pictures = HDocumentWalker.images(model)
        XCTAssertEqual(pictures.count, 1)
        let drawing = try XCTUnwrap(pictures.first)
        try Self.assertPlace(drawing, CGRect(x: 20, y: 40, width: 200, height: 100), "the chart")
        XCTAssertEqual(try Self.colours(drawing), ["blue", "red"])
        for (x, y, expected) in [(40.0, 70.0, "red"), (60, 62, "red"), (51, 79, "blue"), (34, 124, "blue"), (200, 100, "blue")] {
            XCTAssertEqual(try Self.colour(drawing, x, y), expected, "(\(x), \(y))")
        }
        let extracted = try await txt(path)
        XCTAssertEqual(extracted, "Normal words here\r\n\r\nChart caption words\r\n")
        try await assertRichOutputs(path, ["Normal words here", "Chart caption words"], [drawing])
    }

    /// One show whose glyphs the text keeps only in part (its ToUnicode map makes B a space): the text stays text, and the
    /// page's drawing has the two B's at their places and nothing of the A's beside them, which are text. TXT is the text.
    func testGlyphsLeftOutOfAShowKeptInPartAreDrawnAlone() async throws {
        let path = try glyphPdf("partial.pdf", Self.normal + "BT /F2 24 Tf 20 150 Td (ABAAB) Tj ET")
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }, ["Normal words here", "A AA"])
        let pictures = HDocumentWalker.images(model)
        XCTAssertEqual(pictures.count, 1)
        let drawing = try XCTUnwrap(pictures.first)
        // Helvetica's A and B advance 16 points at 24 points; B's ink spans 1.78–15.05 of that, 0–17.23 high.
        try Self.assertPlace(drawing, CGRect(x: 37.78, y: 150, width: 61.27, height: 17.23), "from the first B to the last")
        XCTAssertEqual(try Self.colours(drawing), ["dark"])
        for (x, y, expected) in [(38.9, 158.0, "dark"), (86.9, 158.0, "dark"), (60, 165, "white"), (53.5, 151, "white"), (76, 165, "white")] {
            XCTAssertEqual(try Self.colour(drawing, x, y), expected, "(\(x), \(y)): B stems dark, the A's between them not drawn")
        }
        let extracted = try await txt(path)
        XCTAssertEqual(extracted, "Normal words here\r\n\r\nA AA\r\n")
        try await assertRichOutputs(path, ["Normal words here", "A AA"], [drawing])
    }

    /// After a glyph that stands for two characters (a ligature: its ToUnicode map gives "fi"), PDFKit's characterBounds
    /// runs a letter ahead and has no box past the page's last glyph: such letters take their own selection's box, so the
    /// last word stays whole, and the page's text all counts as kept (no drawing).
    func testLettersPastALigatureStayText() async throws {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def "
            + "/CMapName /Adobe-Identity-UCS def /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange 1 beginbfrange <20> <7E> <0020> endbfrange "
            + "1 beginbfchar <AE> <00660069> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end"
        let path = try glyphPdf("ligature.pdf", "0 g BT /F4 12 Tf 20 250 Td (A de\\256ned word) Tj ET BT /F4 12 Tf 20 230 Td (The last line) Tj ET", "", [
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F4 11 0 R >> >> >>",
            11: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 12 0 R >>",
            12: Self.stream(cmap),
        ])
        let extracted = try await txt(path)
        XCTAssertTrue(extracted.hasSuffix("last line\r\n"), extracted)
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertTrue(HDocumentWalker.images(model).isEmpty, "no drawing")
        XCTAssertTrue(Self.paragraphs(model).map(Self.textOf).joined(separator: " ").contains("last line"))
    }

    /// A detached accent trimmed from extracted text must still be visible on the drawing.
    func testDetachedCombiningMarkStaysOnTheDrawing() async throws {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def "
            + "/CMapName /Adobe-Identity-UCS def /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <0041> <B4> <0301> endbfchar "
            + "endcmap CMapName currentdict /CMap defineresource pop end end"
        let widths = (["667"] + Array(repeating: "500", count: 114) + ["0"]).joined(separator: " ")
        let path = try glyphPdf("mark.pdf", Self.normal + "BT /F3 24 Tf 20 150 Td [(A) -200 (\\264)] TJ ET", "", [
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /F3 11 0 R >> >> >>",
            11: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /FirstChar 65 /LastChar 180 /Widths [\(widths)] /ToUnicode 12 0 R >>",
            12: Self.stream(cmap),
        ])
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        XCTAssertEqual(HDocumentWalker.images(model).count, 1, "the detached accent is not in the text")
        let texts = Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }
        XCTAssertEqual(texts.first, "Normal words here")
        // PDFKit puts the mark on a space after the A, which the paragraph's end trims, as before.
        XCTAssertEqual(texts.last, "A", "\(texts)")
    }

    /// The page's drawing (`content` after the normal words) against a twin page that shows only the glyphs the text
    /// leaves out (`expected`), pixel by pixel at 150 dpi: every dark pixel of those glyphs survives, overlapped stems too,
    /// and at most `twice` dark pixels show where the twin is white (kept text drawn again: where glyphs overlap, both stay).
    @discardableResult
    private func assertUnreadInk(_ name: String, _ content: String, _ expected: String, twice: Int = 3, _ extra: [Int: String] = [:],
                                 line: UInt = #line) throws -> (path: String, model: HDocument, drawing: HImage) {
        let path = try glyphPdf(name + ".pdf", Self.normal + content, "", extra)
        let page = ImagePixels.bitmap(try PdfiumDocument(try glyphPdf(name + "-expected.pdf", expected, "", extra)).render(0, dpi: 150))
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, name + "-media"))
        let pictures = HDocumentWalker.images(model)
        XCTAssertEqual(pictures.count, 1, name, line: line)
        let drawing = try XCTUnwrap(pictures.first, name, line: line)
        let picture = ImagePixels.bitmap(try GraphicsTestKit.decode(drawing.path).frames[0])
        // Cut from the same rendering of the 400 × 300 page: its place in whole pixels.
        let anchor = try XCTUnwrap(drawing.anchor, line: line)
        let left = Int((Double(anchor.horizontalOffset) / 100 * Double(page.width) / 400).rounded())
        let top = Int((Double(anchor.verticalOffset) / 100 * Double(page.height) / 300).rounded())
        var ink = 0, lost = 0, again = 0
        for y in 0..<page.height {
            for x in 0..<page.width {
                let i = (y * page.width + x) * 4, (column, row) = (x - left, y - top)
                let want = min(page.pixels[i], page.pixels[i + 1], page.pixels[i + 2])
                var have: UInt8 = 255
                if (0..<picture.width).contains(column), (0..<picture.height).contains(row) {
                    let j = (row * picture.width + column) * 4
                    have = min(picture.pixels[j], picture.pixels[j + 1], picture.pixels[j + 2])
                }
                if want < 100 { ink += 1; if have > 220 { lost += 1 } }
                if have < 100 && want > 220 { again += 1 }
            }
        }
        XCTAssertGreaterThan(ink, 100, name, line: line)
        XCTAssertEqual(lost, 0, "\(name): lost unreadable ink", line: line)
        XCTAssertLessThanOrEqual(again, twice, "\(name): kept text drawn again", line: line)
        return (path, model, drawing)
    }

    func testUnreadTrailingGlyphIsNotRemovedWithItsTextObject() throws {
        try assertUnreadInk("trailing", "BT /F2 24 Tf 20 150 Td (AAB) Tj ET",
                           "BT /F2 24 Tf 20 150 Td [-1334 (B)] TJ ET")
    }

    func testUnreadKernedGlyphKeepsItsStem() throws {
        // B is kerned into the A before it: their overlap stays, with that sliver of the A.
        try assertUnreadInk("kerned", "BT /F2 24 Tf 20 150 Td [(A) 200 (B) (A)] TJ ET",
                           "BT /F2 24 Tf 20 150 Td [-667 200 (B) -667] TJ ET", twice: 40)
    }

    func testAdjacentTextObjectsDoNotEraseUnreadInk() throws {
        try assertUnreadInk("adjacent", "BT /F2 24 Tf 20 150 Td (AB) Tj ET BT /F2 24 Tf 48 150 Td (ABA) Tj ET",
                           "BT /F2 24 Tf 20 150 Td [-667 (B)] TJ ET BT /F2 24 Tf 48 150 Td [-667 (B) -667] TJ ET", twice: 40)
    }

    func testExtremeOffPageTextCoordinatesDoNotCrashRichConversion() async throws {
        let path = try glyphPdf("huge.pdf", Self.normal + "q 100000000000000.0 0 0 100000000000000.0 0 0 cm BT /T3 1 Tf 0 1000000.0 Td (A) Tj ET Q")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        for format in ["docx", "epub"] {
            let job = await coreRun(JobQueue(catalog()), [path], corePreset(format))
            XCTAssertEqual(job.state, .completed, "\(format): \(job.files.map { $0.errorDetail ?? "" })")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    func testStrayMarkAfterALineBreakDoesNotHideUnrelatedGlyphs() throws {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def "
            + "/CMapName /Adobe-Identity-UCS def /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange 1 beginbfchar <B4> <0301> endbfchar "
            + "endcmap CMapName currentdict /CMap defineresource pop end end"
        let path = try glyphPdf("mark-far.pdf", Self.normal + "1 0 0 rg BT /T3 20 Tf 180 190 Td (A) Tj ET 0 1 0 rg BT /F3 24 Tf 300 150 Td (\\264) Tj ET", "", [
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /T3 6 0 R /F2 9 0 R /F3 11 0 R >> >> >>",
            11: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 12 0 R >>",
            12: Self.stream(cmap),
        ])
        let model = try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))
        let drawing = try XCTUnwrap(HDocumentWalker.images(model).first)
        XCTAssertEqual(try Self.colour(drawing, 190, 200), "red", "the stray mark must not hide the unreadable square")
    }

    /// "(ABAAB)" turned by `degrees` at (x, y), and its twin showing only the B's (blanks to PDFKit with ink).
    private static func turned(_ degrees: Double, _ x: Double, _ y: Double, _ text: String = "(ABAAB) Tj", twin: String = "[-667 (B) -1334 (B)] TJ")
        -> (content: String, expected: String) {
        let (c, s) = (cos(degrees * .pi / 180), sin(degrees * .pi / 180))
        let matrix = String(format: "%.4f %.4f %.4f %.4f %g %g Tm", c, s, -s, c, x, y)
        return ("BT /F2 24 Tf \(matrix) \(text) ET ", "BT /F2 24 Tf \(matrix) \(twin) ET ")
    }

    /// A show kept in part and turned (45° and other angles): its unread glyphs keep all their ink, although the upright
    /// boxes of the turned words beside them reach over them, and the kept letters aren't drawn again; the words stay
    /// text, once. Close lines (upright and turned) don't take each other's ink.
    @MainActor
    func testTurnedShowsKeptInPartKeepTheirUnreadGlyphs() async throws {
        for (degrees, x, y) in [(45.0, 150.0, 60.0), (30, 120, 60), (135, 300, 60), (-45, 150, 200)] {
            let show = Self.turned(degrees, x, y)
            let page = try assertUnreadInk("turned\(Int(degrees))", show.content, show.expected)
            let text = Self.paragraphs(page.model).map(Self.textOf).joined(separator: " ")
            XCTAssertEqual(text.filter { $0 == "A" }.count, 3, "\(degrees)°: \(text)")
            XCTAssertFalse(text.contains("B"), "\(degrees)°: \(text)")
            if degrees == 45 {
                let extracted = try await txt(page.path)
                XCTAssertEqual(extracted.filter { $0 == "A" }.count, 3, extracted)
                try await assertRichOutputs(page.path, ["Normal words here", "AA"], [page.drawing])
            }
        }
        let first = Self.turned(45, 150, 60), second = Self.turned(45, 135, 75, "(AABAA) Tj", twin: "[-1334 (B) -1334] TJ")
        try assertUnreadInk("turned-lines", first.content + second.content, first.expected + second.expected)
        try assertUnreadInk("close-lines", "BT /F2 24 Tf 20 150 Td (ABAAB) Tj ET BT /F2 24 Tf 20 171 Td (AABAA) Tj ET",
                            "BT /F2 24 Tf 20 150 Td [-667 (B) -1334 (B)] TJ ET BT /F2 24 Tf 20 171 Td [-1334 (B) -1334] TJ ET")
        // Slanted, not turned; filled and stroked (the stroke's mitred corners may reach past the glyphs' boxes).
        try assertUnreadInk("slanted", "BT /F2 24 Tf 1 0 0.5 1 20 150 Tm (ABAAB) Tj ET", "BT /F2 24 Tf 1 0 0.5 1 20 150 Tm [-667 (B) -1334 (B)] TJ ET")
        let stroked = Self.turned(45, 150, 60)
        try assertUnreadInk("stroked", "1 w 2 Tr " + stroked.content + "0 Tr ", "1 w 2 Tr " + stroked.expected + "0 Tr ", twice: 20)
    }

    /// Turned text the text keeps whole leaves nothing out: its blanks, whose boxes turned are no thin lines, show nothing.
    func testTurnedTextKeptWholeLeavesNothingOut() throws {
        let path = try glyphPdf("turned-whole.pdf", Self.normal + "BT /F1 24 Tf 0.7071 0.7071 -0.7071 0.7071 150 60 Tm (Turned words) Tj ET "
                                    + "BT /F1 12 Tf 0.8660 0.5000 -0.5000 0.8660 250 40 Tm (Thirty degrees) Tj ET ")
        let page = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path))?.page(at: 0))
        let words = PdfDocumentReader.pageWords(page, scan: PdfDocumentReader.scanContent(try XCTUnwrap(page.pageRef)))
            .map { (bounds: $0.bounds, text: $0.letters.map(\.text).joined()) }
        XCTAssertEqual(words.map(\.text).sorted(), ["Normal", "Thirty", "Turned", "degrees", "here", "words", "words"])
        XCTAssertFalse(try PdfiumDocument(path).textLeftOut(0, keeping: words))
        XCTAssertTrue(HDocumentWalker.images(try PdfDocumentReader.read(path, FilePath.combine(dir, "media"))).isEmpty)
    }

    /// Glyphs without text drawn over kept words (upright, turned, and one whose code is the letter under it, which PDFium
    /// reads with no Unicode) stay whole on the drawing, and the words stay text, once.
    @MainActor
    func testGlyphsDrawnOverKeptWordsStayOnTheDrawing() async throws {
        let over = "1 0 0 rg BT /T3 6 Tf 38 251 Td (A) Tj ET BT /T3 3 Tf 59.6 252 Td (B) Tj ET 0 g "
        let page = try assertUnreadInk("overlay", over, over, twice: 0)
        XCTAssertEqual(Self.paragraphs(page.model).map(Self.textOf).filter { !$0.isEmpty }, ["Normal words here"])
        let extracted = try await txt(page.path)
        XCTAssertEqual(extracted, "Normal words here\r\n")
        try await assertRichOutputs(page.path, ["Normal words here"], [page.drawing])
        let square = "1 0 0 rg BT /T3 8 Tf 0.7071 0.7071 -0.7071 0.7071 175 95 Tm (A) Tj ET 0 g "
        let turned = try assertUnreadInk("overlay-turned", "0 g BT /F1 24 Tf 0.7071 0.7071 -0.7071 0.7071 150 60 Tm (Turned words) Tj ET " + square,
                                         square, twice: 0)
        XCTAssertEqual(Self.paragraphs(turned.model).map(Self.textOf).joined(separator: " ").components(separatedBy: "Turned").count, 2)
        let letter = "1 0 0 rg BT /T3 6 Tf 29 251 Td (o) Tj ET 0 g "
        try assertUnreadInk("overlay-letter", letter, letter, twice: 0, [
            6: "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /g1 7 0 R >>"
                + " /Encoding << /Type /Encoding /Differences [111 /g1] >> /FirstChar 111 /LastChar 111 /Widths [1000] /Resources << >> >>",
        ])
    }

    /// A glyph without text in a kept word's box is kept when the word has a letter no glyph there reads (PDFKit read the
    /// glyph another way); while PDFium reads every letter of the word, the glyph is left out.
    func testGlyphWithoutTextStandsForALetterNoGlyphReads() throws {
        let path = try glyphPdf("unread-letter.pdf", Self.normal + "1 0 0 rg BT /T3 6 Tf 38 251 Td (A) Tj ET 0 g ")
        let page = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path))?.page(at: 0))
        let words = PdfDocumentReader.pageWords(page, scan: PdfDocumentReader.scanContent(try XCTUnwrap(page.pageRef)))
            .map { (bounds: $0.bounds, text: $0.letters.map(\.text).joined()) }
        XCTAssertEqual(words.map(\.text).sorted(), ["Normal", "here", "words"])
        let raster = try PdfiumDocument(path)
        XCTAssertTrue(try raster.textLeftOut(0, keeping: words), "every letter read: the square is left out")
        let other = words.map { (bounds: $0.bounds, text: $0.text == "Normal" ? "Normal■" : $0.text) }
        XCTAssertFalse(try raster.textLeftOut(0, keeping: other), "PDFKit's ■, which no glyph reads: the square is that letter")
    }

    /// A glyph without text under a combining mark of its own (PDFKit gives such a mark a word whose box is a line high)
    /// stays on the drawing; the mark is text.
    func testGlyphUnderALoneCombiningMarkStaysOnTheDrawing() throws {
        let cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def "
            + "/CMapName /Adobe-Identity-UCS def /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange 1 beginbfchar <B4> <0301> endbfchar "
            + "endcmap CMapName currentdict /CMap defineresource pop end end"
        let square = "1 0 0 rg BT /T3 20 Tf 20 150 Td (A) Tj ET 0 g "
        try assertUnreadInk("mark-over", square + "0 1 0 rg BT /F3 24 Tf 22 160 Td (\\264) Tj ET 0 g ", square, twice: 0, [
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /T3 6 0 R /F3 11 0 R >> >> >>",
            11: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 12 0 R >>",
            12: Self.stream(cmap),
        ])
    }

    /// Pictures beside a glyph the text can't read stay the pictures they are (the JPEG its bytes, samples their pixels, at
    /// their size and place), and the drawing shows only the glyph. A picture with such a glyph on it stays in the drawing,
    /// in its place, and isn't taken out as well.
    @MainActor
    func testPicturesBesideUnreadGlyphsStayAsTheyAre() async throws {
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: try PdfBuilder.photo(dir, "photo.jpg", 64, 48)))
        let samples: [UInt8] = (0..<40).flatMap { y in (0..<40).flatMap { x in [UInt8(x * 6), UInt8(y * 6), UInt8(180)] } }
        let images = [11: "/Type /XObject /Subtype /Image /Width 64 /Height 48 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode",
                      12: "/Type /XObject /Subtype /Image /Width 40 /Height 40 /ColorSpace /DeviceRGB /BitsPerComponent 8"]
        /// The page's drawing (behind the text) and its pictures taken out, by type.
        func read(_ name: String, _ glyph: String, pictures count: Int) throws -> (path: String, drawing: HImage?, photo: HImage?, samples: HImage?) {
            let path = try glyphPdf(name, Self.normal + "q 128 0 0 96 250 50 cm /Im1 Do Q q 60 0 0 60 250 180 cm /Im2 Do Q " + glyph,
                                    "/XObject << /Im1 11 0 R /Im2 12 0 R >>", images, [11: jpeg, 12: Data(samples)])
            let model = try PdfDocumentReader.read(path, FilePath.combine(dir, name + "-media"))
            XCTAssertEqual(Self.paragraphs(model).map(Self.textOf).filter { !$0.isEmpty }, ["Normal words here"], name)
            let pictures = HDocumentWalker.images(model)
            XCTAssertEqual(pictures.count, count, name)
            XCTAssertLessThanOrEqual(pictures.filter { $0.anchor != nil }.count, 1, name)
            return (path, pictures.first { $0.anchor != nil }, pictures.first { $0.anchor == nil && $0.path.hasSuffix(".jpg") },
                    pictures.first { $0.anchor == nil && $0.path.hasSuffix(".png") })
        }
        for (name, glyph) in [("plain.pdf", ""), ("beside.pdf", "1 0 0 rg BT /T3 20 Tf 20 150 Td (A) Tj ET 0 g")] {
            let page = try read(name, glyph, pictures: glyph.isEmpty ? 2 : 3)
            let photo = try XCTUnwrap(page.photo, name), picture = try XCTUnwrap(page.samples, name)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: photo.path)), jpeg, "\(name): the JPEG as it is")
            XCTAssertEqual([photo.width, photo.height], [12800, 9600], name)
            XCTAssertEqual([picture.width, picture.height], [6000, 6000], name)
            let decoded = try GraphicsTestKit.decode(picture.path).frames[0]
            XCTAssertEqual([decoded.width, decoded.height], [40, 40], name)
            for (x, y) in [(0, 0), (39, 0), (17, 23), (39, 39)] {
                let p = GraphicsTestKit.pixel(decoded, x, y)
                XCTAssertEqual([p.r, p.g, p.b], [x * 6, y * 6, 180], "\(name): (\(x), \(y))")
            }
            let extracted = try await txt(page.path)
            XCTAssertEqual(extracted, "Normal words here\r\n", name)
            guard !glyph.isEmpty else { XCTAssertNil(page.drawing, name); continue }
            let drawing = try XCTUnwrap(page.drawing, name)
            try Self.assertPlace(drawing, CGRect(x: 20, y: 150, width: 20, height: 20), "only the glyph")
            XCTAssertEqual(try Self.colours(drawing), ["red"], name)
            try await assertRichOutputs(page.path, ["Normal words here"], [drawing, photo, picture])
        }
        let over = try read("over.pdf", "1 0 0 rg BT /T3 20 Tf 280 80 Td (A) Tj ET 0 g", pictures: 2)
        XCTAssertNil(over.photo, "the JPEG is in the drawing")
        let drawing = try XCTUnwrap(over.drawing), picture = try XCTUnwrap(over.samples)
        try Self.assertPlace(drawing, CGRect(x: 250, y: 50, width: 128, height: 96), "the JPEG with the glyph on it")
        XCTAssertEqual(try Self.colour(drawing, 290, 90), "red")
        try await assertRichOutputs(over.path, ["Normal words here"], [drawing, picture])
    }

    func testCompatibilityCharactersDoNotHideAnUnreadOverlay() throws {
        let square = "1 0 0 rg BT /T3 6 Tf 50 152 Td (A) Tj ET 0 g "
        try assertUnreadInk("ellipsis-overlay", "BT /F4 24 Tf 20 150 Td (Wait\\205) Tj ET " + square,
                            square, twice: 0, [
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R /T3 6 0 R /F4 11 0 R >> >> >>",
            11: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
    }

    /// Compare the composed picture with a twin that has no extracted text, including colour and clipping.
    private func assertComposedPicture(_ name: String, _ content: String, _ resources: String, _ extra: [Int: String],
                                       _ streams: [Int: Data], rotation: Int = 0, line: UInt = #line) throws {
        var extra = extra
        extra[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Rotate \(rotation) /Contents 4 0 R /Resources << \(Self.glyphFonts) \(resources) >> >>"
        let path = try glyphPdf(name + ".pdf", Self.normal + content, resources, extra, streams)
        let twin = try glyphPdf(name + "-expected.pdf", content, resources, extra, streams)
        let expected = ImagePixels.bitmap(try PdfiumDocument(twin).render(0, dpi: 150))
        for allText in [false, true] {
            let model = try PdfDocumentReader.read(path, FilePath.combine(dir, name + "-\(allText)-media"), allText: allText)
            let pictures = HDocumentWalker.images(model)
            XCTAssertEqual(pictures.count, 1, "\(name): composition must stay together", line: line)
            guard pictures.count == 1, let drawing = pictures.first, let anchor = drawing.anchor else { continue }
            let actual = ImagePixels.bitmap(try GraphicsTestKit.decode(drawing.path).frames[0])
            let left = Int((Double(anchor.horizontalOffset) / 100 * Double(expected.width) / 400).rounded())
            let top = Int((Double(anchor.verticalOffset) / 100 * Double(expected.height) / 300).rounded())
            var different = 0
            for y in 0..<expected.height {
                for x in 0..<expected.width {
                    let (column, row) = (x - left, y - top), i = (y * expected.width + x) * 4
                    for channel in 0..<3 {
                        let have = (0..<actual.width).contains(column) && (0..<actual.height).contains(row)
                            ? actual.pixels[(row * actual.width + column) * 4 + channel] : 255
                        if abs(Int(have) - Int(expected.pixels[i + channel])) > 1 { different += 1; break }
                    }
                }
            }
            XCTAssertEqual(different, 0, "\(name): mask, opacity, crop and stacking pixels (allText=\(allText))", line: line)
        }
    }

    func testPicturesWithCompositingStayInTheDrawing() throws {
        let blue = Data([[UInt8]](repeating: [20, 40, 230], count: 8 * 8).flatMap { $0 })
        let green = Data([[UInt8]](repeating: [20, 220, 40], count: 8 * 8).flatMap { $0 })
        let image = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8"
        let glyph = "1 0 0 rg BT /T3 20 Tf 20 150 Td (A) Tj ET 0 g "
        let resources = "/XObject << /Im1 11 0 R /Im2 12 0 R /Fx 14 0 R >> /ExtGState << /GS1 13 0 R >>"
        let cases: [(String, String, String, [Int: String], [Int: Data])] = [
            ("soft-mask", "q 80 0 0 80 250 150 cm /Im1 Do Q ", " /SMask 12 0 R",
             [12: "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"],
             [12: Data((0..<64).map { $0 % 8 < 4 ? 0 : 255 })]),
            ("colour-mask", "q 80 0 0 80 250 150 cm /Im1 Do Q ", " /Mask [20 20 40 40 230 230]", [:], [:]),
            ("opacity", "q /GS1 gs 80 0 0 80 250 150 cm /Im1 Do Q ", "", [13: "<< /Type /ExtGState /ca 0.3 /CA 0.3 >>"], [:]),
            ("clipped", "q 270 170 40 40 re W n 80 0 0 80 250 150 cm /Im1 Do Q ", "", [:], [:]),
            ("off-page", "q 120 0 0 80 340 150 cm /Im1 Do Q ", "", [:], [:]),
            ("overlap", "q 80 0 0 80 250 150 cm /Im1 Do Q q 80 0 0 80 290 110 cm /Im2 Do Q ", "", [12: image], [12: green]),
            ("hidden", "q 80 0 0 80 250 150 cm /Im1 Do Q q 80 0 0 80 250 150 cm /Im2 Do Q ", "", [12: image], [12: green]),
            ("form-opacity", "q /GS1 gs /Fx Do Q ", "", [13: "<< /Type /ExtGState /ca 0.3 /CA 0.3 >>",
                14: Self.stream("q 80 0 0 80 0 0 cm /Im1 Do Q", "/Type /XObject /Subtype /Form /BBox [0 0 80 80] /Matrix [1 0 0 1 250 150] /Resources << /XObject << /Im1 11 0 R >> >>")], [:]),
        ]
        for (name, placement, mask, extra, streams) in cases {
            try assertComposedPicture(name, placement + glyph, resources, extra.merging([11: image + mask]) { $1 }, streams.merging([11: blue]) { $1 })
        }
    }

    func testTurnedPictureAndItsUnreadGlyphStayTogether() throws {
        let samples = Data([[UInt8]](repeating: [20, 40, 230], count: 8 * 8).flatMap { $0 })
        try assertComposedPicture("turned-image", "q 80 0 0 80 250 150 cm /Im1 Do Q 1 0 0 rg BT /T3 20 Tf 280 180 Td (A) Tj ET 0 g ",
                                  "/XObject << /Im1 11 0 R >>", [11: "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8"],
                                  [11: samples], rotation: 180)
    }

    /// Each block's pictures and text in order; "picture" is one that decodes to more than white paper.
    private static func content(_ document: HDocument) throws -> [String] {
        try document.sections.flatMap(\.blocks).flatMap { block -> [String] in
            let pictures = try HDocumentWalker.inlines([block]).compactMap { $0 as? HImage }.map { image -> String in
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: image.path) as CFURL, nil), image.path)
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), image.path)
                return ImagePixels.bitmap(decoded).pixels.contains { $0 < 200 } ? "picture" : "blank picture"
            }
            let text = (block as? HParagraph).map { HDocumentWalker.text($0.inlines) } ?? ""
            return pictures + (text.isEmpty ? [] : [text])
        }
    }
}
