// Vision text recognition of pages without text: scanned pages join the PDF's text in reading order (two columns
// too), pictures reach TXT through their PDF page, and the recognition languages follow the user's languages.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class TextRecognitionTests: XCTestCase {
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }
    override func tearDown() { FileManager.default.removeIfPresent(dir) }

    /// A white A4 page scanned at 200 dpi, each text drawn at (x, y from the top) in points with its size, as a PNG.
    private func scan(_ name: String, _ texts: [(String, Double, Double, Double)], font: String = "Helvetica") throws -> String {
        let scale = 200.0 / 72, width = 595.0, height = 842.0
        let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        for (text, x, y, size) in texts {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            context.textPosition = CGPoint(x: x, y: height - y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        let path = FilePath.combine(dir, name)
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return path
    }

    @MainActor // so XCTest records its failures after the awaits
    private func txt(_ pdf: String) async throws -> String {
        let output = try await GraphicsTestKit.convert(PdfTextConverter(), pdf, to: "txt")
        return String(decoding: try Data(contentsOf: URL(fileURLWithPath: output[0])).dropFirst(3), as: UTF8.self)
    }

    func testScannedPageIsReadInReadingOrderBeforeTheNextTextPage() async throws {
        var texts: [(String, Double, Double, Double)] = [("Scanned Report Title", 72, 100, 20)]
        let left = ["Left column first paragraph. The quick", "brown fox jumps over the lazy dog, and", "the text keeps going across several",
                    "lines to fill the column."]
        let right = ["Right column starts here. More text", "follows on these lines of the right", "column before it ends."]
        texts += left.enumerated().map { ($1, 72, 160 + Double($0) * 15, 11) }
        texts += [("Left column second paragraph with", 72, 250, 11), ("more words to read in order.", 72, 265, 11)]
        texts += right.enumerated().map { ($1, 313, 160 + Double($0) * 15, 11) }
        texts += [("Right column ends here.", 313, 235, 11)]
        let footnote = "Footnote in small seven point type that runs across the gutter between the two columns."
        texts += [(footnote, 72, 300, 7)]
        let pdf = PdfBuilder().newPage()
        try pdf.picture(try scan("columns.png", texts), 0, 0, 595, 842)
        pdf.newPage().line("A text page after the scan.", 12, pdf.font(), 72, 100)
        let text = try await txt(try pdf.save(FilePath.combine(dir, "mixed.pdf")))

        // Columns first, then the footnote that spans them, then the next page; the small footnote is read in full.
        let order = ["Scanned Report Title", "Left column first paragraph", "lines to fill the column", "Left column second paragraph",
                     "Right column starts here", "Right column ends here", footnote, "A text page after the scan."]
        let positions = order.compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, order.count, text)
        XCTAssertEqual(positions, positions.sorted(), text)
        // The lines of a paragraph join into one with spaces; paragraphs stay apart.
        let paragraphs = text.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(paragraphs.count, 7, text)
        XCTAssertTrue(paragraphs.contains { $0.hasPrefix("Left column first") && $0.contains("quick brown") && $0.contains("the column.") }, text)
        XCTAssertTrue(paragraphs.contains { $0.hasPrefix("Right column starts") && $0.contains("text follows") && $0.hasSuffix("ends.") }, text)
        XCTAssertFalse(paragraphs.dropLast().contains { $0.contains("\r\n") }, text)
    }

    func testBlankScanStillHasNoText() async throws {
        let pdf = PdfBuilder().newPage()
        try pdf.picture(try scan("blank.png", []), 0, 0, 595, 842)
        do {
            _ = try await txt(try pdf.save(FilePath.combine(dir, "blank.pdf")))
            XCTFail("a blank scan has no text")
        } catch {
            XCTAssertTrue(error is NoTextError, "\(error)")
            XCTAssertTrue("\(error)".contains("The PDF contains no text"), "\(error)")
        }
    }

    func testKoreanModelKeepsLatinWordsWithTheirParticles() async throws {
        let path = try scan("korean.png", [("한글과 English가 섞인 문장도 읽어요.", 72, 100, 14)], font: "AppleSDGothicNeo-Regular")
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil)!
        let (lines, sideways) = try await TextRecognition.lines(in: image, languages: [Locale.Language(identifier: "ko-KR"), Locale.Language(identifier: "en-US")])
        XCTAssertFalse(sideways)
        let words = lines.flatMap { $0.map(\.text) }
        XCTAssertTrue(words.contains("한글과") && words.contains("English가") && words.contains("섞인"), "\(words)")
        // Word boxes run left to right inside the page.
        let lefts = lines[0].map(\.box.minX)
        XCTAssertEqual(lefts, lefts.sorted())
        XCTAssertTrue(lines[0].allSatisfy { $0.box.minX >= 0 && $0.box.maxX <= 1 && $0.box.width > 0 })
    }

    func testPageOnItsSideIsReadInReadingOrder() async throws {
        let texts = [("Sideways Report Title", 72.0, 100.0, 20.0), ("First paragraph of the turned page keeps", 72, 160, 12),
                     ("going on its second line here.", 72, 176, 12), ("Second paragraph comes after the first.", 72, 230, 12)]
        let upright = try await txt(try PdfBuilder().newPage().picture(try scan("upright.png", texts), 0, 0, 595, 842).save(FilePath.combine(dir, "upright.pdf")))
        XCTAssertTrue(upright.contains("going on its second line"), upright)
        let source = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: FilePath.combine(dir, "upright.png")) as CFURL, nil)!, 0, nil)!
        for turns in 1...3 {
            let (width, height) = turns == 2 ? (source.width, source.height) : (source.height, source.width)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: CGFloat(turns) * .pi / 2)
            context.draw(source, in: CGRect(x: -source.width / 2, y: -source.height / 2, width: source.width, height: source.height))
            let path = FilePath.combine(dir, "turned\(turns).png")
            let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let (w, h) = turns == 2 ? (595.0, 842.0) : (842.0, 595.0)
            let turned = try await txt(try PdfBuilder().newPage(w, h).picture(path, 0, 0, w, h).save(FilePath.combine(dir, "turned\(turns).pdf")))
            XCTAssertEqual(turned, upright, "turned by \(turns) quarter turns")
        }
    }

    func testBoxesOfATurnedPageAreGivenUpright() {
        // A line near the image's left edge running up is, upright, a line near the top running right.
        let box = TextRecognition.upright(CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.6), 1)
        XCTAssertEqual([box.minX, box.minY, box.width, box.height].map { ($0 * 100).rounded() }, [20, 85, 60, 5])
        XCTAssertEqual([TextRecognition.quarterTurns(1, 0.1), TextRecognition.quarterTurns(0.1, 1), TextRecognition.quarterTurns(-1, 0), TextRecognition.quarterTurns(0, -1)], [0, 1, 2, 3])
        for turns in 0..<4 {
            let back = (0..<(4 - turns) % 4).reduce(TextRecognition.upright(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05), turns)) { box, _ in TextRecognition.upright(box, 1) }
            XCTAssertEqual([back.minX, back.minY, back.width, back.height].map { ($0 * 100).rounded() }, [10, 20, 30, 5], "\(turns)")
        }
    }

    func testPageThatMixesScriptsIsReadByEachScriptsModel() async throws {
        let texts = [("\u{D55C}\u{AD6D}\u{C5B4} \u{BB38}\u{B2E8}\u{C785}\u{B2C8}\u{B2E4}. \u{D30C}\u{C77C} \u{BCC0}\u{D658} \u{C571}\u{C758} \u{AE00}\u{C790} \u{C778}\u{C2DD}\u{C744} \u{C2DC}\u{D5D8}\u{D569}\u{B2C8}\u{B2E4}.", 72.0, 100.0, 14.0),
                     ("\u{65E5}\u{672C}\u{8A9E}\u{306E}\u{6BB5}\u{843D}\u{3067}\u{3059}\u{3002}\u{30D5}\u{30A1}\u{30A4}\u{30EB}\u{5909}\u{63DB}\u{30A2}\u{30D7}\u{30EA}\u{306E}\u{6587}\u{5B57}\u{8A8D}\u{8B58}\u{3092}\u{8A66}\u{9A13}\u{3057}\u{307E}\u{3059}\u{3002}", 72, 140, 14),
                     ("This is an English paragraph for the same recognition test.", 72, 180, 14)]
        let path = try scan("mixed.png", texts, font: "AppleSDGothicNeo-Regular")
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil)!
        let korean = [Locale.Language(identifier: "ko-KR"), Locale.Language(identifier: "en-US")]
        func text(_ allScripts: Bool) async throws -> String {
            try await TextRecognition.lines(in: image, languages: korean, allScripts: allScripts).lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        }
        let one = try await text(false), all = try await text(true)
        XCTAssertFalse(one.contains("\u{65E5}\u{672C}\u{8A9E}"), one) // the Korean model alone leaves the Japanese line out
        XCTAssertTrue(all.contains("\u{D55C}\u{AD6D}\u{C5B4}") && all.contains("\u{65E5}\u{672C}\u{8A9E}") && all.contains("\u{6587}\u{5B57}\u{8A8D}\u{8B58}") && all.contains("English paragraph"), all)
        XCTAssertEqual(all.components(separatedBy: "\n").count, 3, all)
        // The other models: each script but the first's, with the Latin languages kept.
        let supported = ["en-US", "ko-KR", "ja-JP", "zh-Hans", "zh-Hant"].map { Locale.Language(identifier: $0) }
        XCTAssertEqual(TextRecognition.otherScripts(korean, supported: supported).map { $0.map(\.minimalIdentifier) }, [["ja", "en"], ["zh", "en"]])
        XCTAssertEqual(TextRecognition.otherScripts([Locale.Language(identifier: "en-US")], supported: supported).count, 3)
        XCTAssertEqual(TextRecognition.otherScripts(korean, supported: [Locale.Language(identifier: "en-US")]).count, 0)
    }

    func testRecognitionLanguagesPutChineseJapaneseKoreanFirstAndEndWithEnglish() {
        let ids = ["en-US", "fr-FR", "ko-KR", "ja-JP", "zh-Hans", "zh-Hant"]
        let supported = ids.map { Locale.Language(identifier: $0) }
        func chosen(_ preferred: [String]) -> [String] {
            TextRecognition.languages(preferred, supported: supported).map { ids[supported.firstIndex(of: $0)!] }
        }
        XCTAssertEqual(chosen(["en-KR", "ko-KR"]), ["ko-KR", "en-US"])
        XCTAssertEqual(chosen(["fr-FR", "ja-JP"]), ["ja-JP", "fr-FR", "en-US"])
        XCTAssertEqual(chosen(["zh-Hant-TW", "zh-TW"]), ["zh-Hant", "en-US"])
        XCTAssertEqual(chosen(["zh-CN"]), ["zh-Hans", "en-US"])
        XCTAssertEqual(chosen(["de-DE"]), ["en-US"])
        XCTAssertEqual(chosen([]), ["en-US"])
    }

    func testScannedBookKeepsItsPagesWithTheirRecognizedText() async throws {
        let pdf = PdfBuilder().newPage()
        try pdf.picture(try scan("page.png", [("Scanned chapter heading", 72, 100, 20), ("Body text of the scanned page.", 72, 160, 12)]), 0, 0, 595, 842)
        let path = try pdf.save(FilePath.combine(dir, "book.pdf"))
        func blocks(_ document: HDocument) -> (text: String, pictures: Int) {
            let paragraphs = document.sections.flatMap(\.blocks).compactMap { $0 as? HParagraph }
            return (paragraphs.map { $0.inlines.compactMap { ($0 as? HText)?.text }.joined() }.joined(separator: "\n"),
                    paragraphs.reduce(0) { $0 + $1.inlines.filter { $0 is HImage }.count })
        }
        // DOCX and HWPX keep the page as its picture only; outputs that keep pages get the text before it.
        let plain = blocks(try PdfDocumentReader.read(path, FilePath.combine(dir, "plain")))
        XCTAssertEqual(plain.pictures, 1)
        XCTAssertFalse(plain.text.contains("Scanned chapter"), plain.text)
        let read = blocks(try await PdfDocumentReader.readWithScans(path, FilePath.combine(dir, "read")))
        XCTAssertEqual(read.pictures, 1)
        XCTAssertTrue(read.text.contains("Scanned chapter heading") && read.text.contains("Body text of the scanned page."), read.text)
    }

    func testPictureBecomesTextThroughItsPdfPage() async throws {
        let picture = try scan("note.png", [("Picture text read by recognition", 72, 100, 18)])
        let catalog = ConverterCatalog(EngineRegistry.createAll(EngineEnvironment(dataDirectory: FilePath.combine(dir, "data"))))
        catalog.priority = AppSettings().enginePriority
        let job = await coreRun(JobQueue(catalog), [picture], corePreset("txt"))
        XCTAssertEqual(job.state, .completed, "\(job.files.map { $0.errorDetail ?? "" })")
        let text = try String(contentsOfFile: FilePath.combine(dir, "note.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Picture text read by recognition"), text)
    }
}
