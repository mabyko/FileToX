// Port of Filee.Engines/Pdf/PdfDocumentReader.cs: PDF → HDocument, so PDF → DOCX / HWPX / TXT needs no Word,
// LibreOffice or OCR engine. PdfPig is replaced by PDFKit (letters, glyph boxes, fonts, colours, links) and a
// CGPDFScanner pass (rendering modes, images); see PdfDocumentReader+Page.swift.
//
// Every page's words (with their positions, fonts, sizes and colours) become lines, lines become paragraphs, and the
// paragraphs and pictures are put in reading order, also on two-column pages (PdfDocumentReader+Layout.swift). Headings
// come from font sizes, bold / italic from the fonts, page size and margins from the page. Headers and footers that
// repeat on the pages (and bare page numbers) are left out. A page without text (a scan) becomes the rendered page as
// a picture, so the result is complete. Plain text (`readText` with `recognize`) and outputs that keep every page with
// its text (`readWithScans`) also read such pages with Vision OCR.
//
// Rows laid out with tab stops (a number, a label and a date far to the right) stay one line with tabs at the PDF's
// positions, and a line that ends early although the next line's first word would have fitted (an address) keeps its
// line break.
//
// A text page's vector drawings, shadings, inline images and stencil masks can't be taken out like image XObjects: the
// page rendered without its text keeps them, with the page's other pictures in their place, as one picture behind the
// text at its place on the paper. The text stays text and is not shown twice. Visible text the extraction can't keep
// (glyphs without Unicode, also in forms) is drawn there as well, also on pages without other drawings: PDFium leaves
// out only the glyphs that are letters of the kept words (PdfiumDocument.textLeftOut); the rest stays a picture, not
// text. There, the page's image XObjects stay pictures as they are unless that ink is on them.
//
// Not converted: tables (their cells come out as paragraphs in reading order), annotations other than links (a drawing
// layer shows their appearance), form fields.

import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Reads a PDF into the document model (HWPX / DOCX writers, plain text).
final class PdfDocumentReader {
    /// Resolution of rendered scans and of pictures that can't be taken out as they are.
    private static let renderDpi = 150

    /// HWPUNIT per point.
    private static let unit = 100.0

    private static let subsetPrefix = try! NSRegularExpression(pattern: "^[A-Z]{6}\\+")

    /// PostScript names of common fonts → the family names Word and 한글 know (keys compared case-insensitively).
    private static let knownFonts: [String: String] = Dictionary(uniqueKeysWithValues: [
        ("Helvetica", "Arial"), ("Arial", "Arial"), ("ArialMT", "Arial"), ("ArialNarrow", "Arial Narrow"),
        ("Times", "Times New Roman"), ("TimesNewRoman", "Times New Roman"), ("TimesNewRomanPS", "Times New Roman"),
        ("TimesNewRomanPSMT", "Times New Roman"), ("Courier", "Courier New"), ("CourierNew", "Courier New"),
        ("CourierNewPS", "Courier New"), ("CourierNewPSMT", "Courier New"), ("MalgunGothic", "Malgun Gothic"),
        ("SegoeUI", "Segoe UI"), ("TrebuchetMS", "Trebuchet MS"), ("CenturyGothic", "Century Gothic"), ("BookAntiqua", "Book Antiqua"),
        ("ComicSansMS", "Comic Sans MS"), ("LucidaConsole", "Lucida Console"), ("PalatinoLinotype", "Palatino Linotype"),
    ].map { ($0.0.lowercased(), $0.1) })

    private let path: String
    private let mediaFolder: String
    private let textOnly: Bool
    /// Also the text that is not part of the look: invisible text (a scan's OCR layer), and turned pages read as text.
    private let allText: Bool
    private var pictures = 0
    private var raster: PdfiumDocument?

    private init(_ path: String, _ mediaFolder: String, textOnly: Bool, allText: Bool = false) {
        self.path = path
        self.mediaFolder = mediaFolder
        self.textOnly = textOnly
        self.allText = textOnly || allText
    }

    /// Reads `path` with pictures (extracted into `mediaFolder`) and scans. `allText` keeps the text that is not part of
    /// the look as well, for outputs that keep every page with its text (`ConversionStep.keepsPages`).
    static func read(_ path: String, _ mediaFolder: String, allText: Bool = false) throws -> HDocument {
        try PdfDocumentReader(path, mediaFolder, textOnly: false, allText: allText).readDocument()
    }

    /// `read` with `allText`, and its scans read with Vision as well: the recognized text comes before the page's picture,
    /// so a scanned book can be searched and copied from.
    static func readWithScans(_ path: String, _ mediaFolder: String) async throws -> HDocument {
        let reader = PdfDocumentReader(path, mediaFolder, textOnly: false, allText: true)
        let (pages, title) = try reader.readPages()
        try await recognizeScans(path, pages.filter(\.scanned), nil)
        return reader.buildDocument(pages, title)
    }

    /// A page with visible text, not turned: the words its text keeps (where they are shown, in page space, and their
    /// text), and whether it paints drawings (`ContentScan.drawings`).
    typealias TextPage = (index: Int, words: [PdfiumDocument.Word], drawn: Bool)

    /// Reads only the text, including invisible text (the OCR layer of scanned PDFs); pictures and scans are left out.
    /// With `recognize`, Vision reads the pages without text (`TextRecognition`), and their text joins in reading order.
    /// `pagesWithoutText` are the indexes of the pages that had no text to read (scans, drawings, blank pages);
    /// `textPages` the pages with visible text, to look at without it (see `showsAnything(_:textPages:)`).
    static func readText(_ path: String, recognize: Bool = false, progress: ProgressHandler? = nil) async throws
        -> (document: HDocument, pagesWithoutText: [Int], needsPictures: Bool, textPages: [TextPage]) {
        try Task.checkCancellation()
        let reader = PdfDocumentReader(path, "", textOnly: true)
        let pdf = try reader.openDocument()
        let title = nullIfBlank(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        let pageCount = pdf.pageCount
        let workers = min(8, ProcessInfo.processInfo.activeProcessorCount, pageCount)
        let pages = try await withThrowingTaskGroup(of: [PageContent].self) { group in
            for worker in 0..<workers {
                group.addTask {
                    // PDFKit documents and their page caches stay on one worker.
                    let reader = PdfDocumentReader(path, "", textOnly: true)
                    let pdf = try reader.openDocument()
                    var pages: [PageContent] = []
                    for index in (worker * pageCount / workers)..<((worker + 1) * pageCount / workers) {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            if let page = pdf.page(at: index) { pages.append(try reader.readPage(page, index)) }
                        }
                    }
                    return pages
                }
            }
            var pages: [PageContent] = []
            for try await batch in group { pages += batch }
            return pages.sorted { $0.index < $1.index }
        }
        try Task.checkCancellation()
        // No page could be read: unlike a scan without text, there is nothing page pictures could keep.
        guard !pages.isEmpty else { throw ConversionError("\(FilePath.fileName(path)) is not a PDF file that can be read.") }
        if recognize { try await recognizeScans(path, pages.filter(\.scanned), progress) }
        return (reader.buildDocument(pages, title), pages.filter(\.scanned).map(\.index), pages.contains { $0.needsPictures },
                pages.compactMap { page in page.keptWords.map { (page.index, $0, page.drawn) } })
    }

    /// Reads the scans' text with Vision, four pages at a time, rendered at 300 dpi and at most 4,000 pixels high or wide.
    /// A page with recognized text becomes a text page.
    private static func recognizeScans(_ path: String, _ scans: [PageContent], _ progress: ProgressHandler?) async throws {
        guard !scans.isEmpty else { return }
        let raster = try PdfiumDocument(path)
        var found = [(lines: [TextRecognition.Line], sideways: Bool)](repeating: ([], false), count: scans.count)
        try await withThrowingTaskGroup(of: (Int, (lines: [TextRecognition.Line], sideways: Bool)).self) { group in
            var next = 0, done = 0
            while done < scans.count {
                while next < scans.count && next - done < 4 {
                    let (s, index) = (next, scans[next].index)
                    let dpi = max(1, min(300, Int(4000 * 72 / max(1, max(scans[next].width, scans[next].height)))))
                    group.addTask { (s, try await TextRecognition.lines(in: try raster.render(index, dpi: dpi))) }
                    next += 1
                }
                guard let (s, read) = try await group.next() else { break }
                found[s] = read
                done += 1
                progress?(Double(done) / Double(scans.count))
            }
        }
        for (page, read) in zip(scans, found) where !read.lines.isEmpty {
            // A page on its side is read as turned upright: its lines run across the paper's height.
            page.items = paragraphs(recognizedLines(read.lines, read.sideways ? page.height : page.width, read.sideways ? page.width : page.height))
            page.scanned = false
            if let scan = page.scanPath {
                // The page's look stays, after its text (like a page with only an invisible text layer).
                let picture = Item()
                picture.picturePath = scan
                picture.pictureBounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
                page.items.append(picture)
            }
        }
    }

    /// Recognized lines as the lines of a page `width` × `height` points large, top to bottom like `lines(_:)` gives them.
    /// Vision's boxes of one paragraph's lines differ by a few points, so a height near the page's usual one counts as it.
    private static func recognizedLines(_ lines: [TextRecognition.Line], _ width: Double, _ height: Double) -> [TextLine] {
        let boxes = lines.map { line in line.dropFirst().reduce(line[0].box) { $0.union($1.box) } }
        let usual = median(boxes.map { Double($0.height) * height })
        return zip(lines, boxes).map { line, box -> TextLine in
            let (top, bottom) = (Double(box.maxY) * height, Double(box.minY) * height)
            let size = max(1, 0.8 * (abs(top - bottom - usual) <= 0.25 * usual ? usual : top - bottom)) // a line box is ~1.25 em
            let baseline = (top + bottom) / 2 - 0.3 * size
            let format = HCharFormat(size: Int((size * 2).rounded(.toNearestOrEven) * 50))
            return TextLine(line.map {
                TextWord(text: $0.text, left: Double($0.box.minX) * width, right: Double($0.box.maxX) * width, top: top, bottom: bottom,
                         baseline: baseline, size: size, format: format, link: nil)
            })
        }.sorted { $0.baseline != $1.baseline ? $0.baseline > $1.baseline : $0.left < $1.left }
    }

    /// Use the output's resolution so a smaller preview cannot classify visible content as blank.
    static func showsAnything(_ path: String, _ pages: [Int]) throws -> Bool {
        try Task.checkCancellation()
        guard !pages.isEmpty else { return false }
        let raster = try PdfiumDocument(path)
        for index in pages {
            try Task.checkCancellation()
            if try shows(raster.render(index, dpi: renderDpi)) { return true }
        }
        return false
    }

    /// The text pages without the text they keep: whether one shows anything, drawings or visible text the extraction
    /// leaves out.
    static func showsAnything(_ path: String, textPages: [TextPage]) throws -> Bool {
        try Task.checkCancellation()
        guard !textPages.isEmpty else { return false }
        let raster = try PdfiumDocument(path)
        for page in textPages {
            if try page.drawn || raster.textLeftOut(page.index, keeping: page.words),
               try shows(raster.render(page.index, dpi: renderDpi, withoutTextAt: page.words)) { return true }
        }
        return false
    }

    /// Whether a rendering shows anything but white paper (in `area`: pixels, y down; all of it when nil).
    private static func shows(_ image: CGImage, in area: CGRect? = nil) throws -> Bool {
        guard let pixels = image.dataProvider?.data as Data? else { throw ConversionError("The page could not be rendered.") }
        guard let area = area?.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)) else { return pixels.contains { $0 != 0xFF } }
        return !area.isNull && pixels.withUnsafeBytes { bytes in
            (Int(area.minY)..<Int(area.maxY)).contains { y in
                bytes[(y * image.bytesPerRow + 4 * Int(area.minX))..<(y * image.bytesPerRow + 4 * Int(area.maxX))].contains { $0 != 0xFF }
            }
        }
    }

    // ───────────────────────── Model of a page ─────────────────────────

    /// A word with its box (points, y upwards from the bottom of the visible page) and formatting.
    struct TextWord {
        let text: String
        let left: Double, right: Double, top: Double, bottom: Double, baseline: Double, size: Double
        let format: HCharFormat
        let link: String?
    }

    /// A text line (or the part of it in one column).
    final class TextLine {
        let words: [TextWord]
        /// The row of the page the line is on: the parts of a line split at wide gaps share it.
        let row: Int
        /// Indexes of the words a tab leads to (the start of each part after the first of a tabbed row).
        var tabs: [Int] = []

        init(_ words: [TextWord], _ row: Int = 0) {
            self.words = words
            self.row = row
        }

        var left: Double { words[0].left }
        var right: Double { words[words.count - 1].right }
        var top: Double { words.map(\.top).max()! }
        var bottom: Double { words.map(\.bottom).min()! }
        var baseline: Double { words[0].baseline }
        var size: Double { words.map(\.size).max()! }
        var text: String { words.map(\.text).joined(separator: " ") }
    }

    /// A paragraph or a picture on a page, the unit of reading order.
    final class Item {
        var lines: [TextLine] = []
        var picturePath: String?
        var pictureBounds: CGRect?

        var left: Double { pictureBounds.map { Double($0.minX) } ?? lines.map(\.left).min()! }
        var right: Double { pictureBounds.map { Double($0.maxX) } ?? lines.map(\.right).max()! }
        var top: Double { pictureBounds.map { Double($0.maxY) } ?? lines[0].top }
        var bottom: Double { pictureBounds.map { Double($0.minY) } ?? lines[lines.count - 1].bottom }
        var width: Double { right - left }
        var isPicture: Bool { picturePath != nil }

        /// Size of most of the text (by characters).
        var size: Double { PdfDocumentReader.mostUsedSize(lines.flatMap(\.words)) }

        var text: String { lines.map(\.text).joined(separator: " ") }

        /// Left and right edges of the column (or the text area) the item sits in, set by the reading order.
        var containerLeft = 0.0
        var containerRight = 0.0
    }

    final class PageContent {
        let index: Int
        let width: Double
        let height: Double
        var items: [Item] = []
        var scanned = false
        var scanPath: String?
        var needsPictures = false
        /// Visible text with drawings (`ContentScan.drawings`); `drawing` is the page without the text it keeps, if that
        /// shows anything (drawings, visible text the extraction leaves out).
        var drawn = false
        var drawing: (path: String, bounds: CGRect)?
        /// Visible text, not turned: the words its text keeps (where they are shown, in page space, and their text).
        var keptWords: [PdfiumDocument.Word]?

        init(_ index: Int, _ width: Double, _ height: Double) {
            self.index = index
            self.width = width
            self.height = height
        }
    }

    // ───────────────────────── Document ─────────────────────────

    private func openDocument() throws -> PDFDocument {
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw ConversionError("\(FilePath.fileName(path)) is not a PDF file that can be read.")
        }
        if pdf.isLocked { throw Self.passwordProtected() }
        return pdf
    }

    private func readDocument() throws -> HDocument {
        let (pages, title) = try readPages()
        return buildDocument(pages, title)
    }

    private func readPages() throws -> (pages: [PageContent], title: String?) {
        let pdf = try openDocument()
        var pages: [PageContent] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            pages.append(try readPage(page, index))
        }

        return (pages, Self.nullIfBlank(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String))
    }

    private func buildDocument(_ pages: [PageContent], _ title: String?) -> HDocument {
        Self.removeRepeatedHeadersAndFooters(pages)
        for page in pages where !page.scanned { page.items = Self.readingOrder(page.items) }
        return build(pages, title)
    }

    private static func passwordProtected() -> ConversionError {
        ConversionError("The PDF is password-protected. Open it with its password and save a copy without one, then convert that copy.")
    }

    private func readPage(_ page: PDFPage, _ index: Int) throws -> PageContent {
        let crop = page.bounds(for: .cropBox)
        // A page turned by 90° is shown (and rendered) with width and height swapped.
        let rotated = page.rotation % 180 != 0
        let content = PageContent(index, Double(rotated ? crop.height : crop.width), Double(rotated ? crop.width : crop.height))

        let links: [(bounds: CGRect, uri: String)] = page.annotations.compactMap { annotation in
            guard let uri = (annotation.url ?? (annotation.action as? PDFActionURL)?.url)?.absoluteString else { return nil }
            let lower = uri.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") else { return nil }
            return (Self.shift(annotation.bounds, crop), uri)
        }

        let scan = page.pageRef.map(Self.scanContent) ?? ContentScan()
        content.needsPictures = !scan.images.isEmpty || rotated
        var words: [TextWord] = []
        var kept: [PdfiumDocument.Word] = [] // where the words are shown, in page space, and their text
        var hasVisibleText = false
        var previousFormat: (letter: PageLetter, size: Double, format: HCharFormat)?
        for word in Self.pageWords(page, scan: scan) {
            let letters = word.letters
            guard letters.allSatisfy(\.horizontal) else { continue }
            let text = letters.map(\.text).joined()
            guard !text.allSatisfy(\.isWhitespace) else { continue }
            // Invisible text is the OCR layer of a scan: part of the text, not of the page's look.
            let invisible = letters.allSatisfy { $0.mode == 3 }
            if !allText && invisible { continue }
            hasVisibleText = hasVisibleText || !invisible
            kept.append((word.bounds, text))
            let glyphs = letters.dropFirst().reduce(letters[0].box) { $0.union($1.box) }
            let box = Self.shift(CGRect(x: word.left, y: glyphs.minY, width: word.right - word.left, height: glyphs.height), crop)
            let size = Self.median(letters.map { Double($0.size) })
            let center = CGPoint(x: box.midX, y: box.midY)
            let link = links.first { $0.bounds.contains(center) }?.uri
            let letter = letters[0]
            let format: HCharFormat
            if let previous = previousFormat, previous.size == size, previous.letter.fontName == letter.fontName,
               previous.letter.bold == letter.bold, previous.letter.italic == letter.italic,
               previous.letter.mode == letter.mode, previous.letter.color == letter.color {
                format = previous.format
            } else {
                format = Self.format(letter, size)
                previousFormat = (letter, size, format)
            }
            words.append(TextWord(text: Self.cleanText(text), left: Double(box.minX), right: Double(box.maxX), top: Double(box.maxY),
                                  bottom: Double(box.minY), baseline: Double(word.baseline - crop.minY), size: max(1, size),
                                  format: format, link: link))
        }

        if words.isEmpty || (rotated && !allText) {
            // A scan, a page of drawings, or a turned page (unless all text is read): the rendered page keeps everything.
            content.scanned = true
            if !textOnly { content.scanPath = try renderScan(index) }
            return content
        }

        content.needsPictures = content.needsPictures || !hasVisibleText
        content.drawn = scan.drawings && hasVisibleText && !rotated
        if hasVisibleText && !rotated { content.keptWords = kept }
        let lines = Self.lines(words)
        var items = Self.paragraphs(lines)
        if let joined = Self.joinTabbedRows(lines, items) { items = Self.paragraphs(joined) }
        content.items = items
        if !textOnly {
            if rotated || !hasVisibleText {
                // Render OCR-only pages whole: image extraction alone loses masks and vector outlines.
                let picture = Item()
                picture.picturePath = try renderScan(index)
                picture.pictureBounds = CGRect(x: 0, y: 0, width: content.width, height: content.height)
                content.items.append(picture)
            } else if content.drawn {
                content.drawing = try drawing(content, kept).drawing
            } else if try pdfium().textLeftOut(index, keeping: kept) {
                // Visible text the extraction leaves out, drawn where it is; the pictures it isn't on stay as they are.
                let drawn = try drawing(content, kept, apart: page.rotation % 360 == 0 ? images(scan, content, crop, separating: true) : [])
                content.drawing = drawn.drawing
                content.items += try pictures(drawn.apart, content)
            } else {
                content.items += try pictures(images(scan, content, crop), content)
            }
        }
        return content
    }

    private static func shift(_ box: CGRect, _ crop: CGRect) -> CGRect {
        box.offsetBy(dx: -crop.minX, dy: -crop.minY)
    }

    // ───────────────────────── Text formatting ─────────────────────────

    private static func format(_ letter: PageLetter, _ size: Double) -> HCharFormat {
        let name = letter.fontName
        let bold = letter.bold || letter.mode == 2 || matches(name, "Bold|Black|Heavy|Semibold|SemiBold|Demi")
        let italic = letter.italic || matches(name, "Italic|Oblique")
        return HCharFormat(bold: bold, italic: italic, size: Int((size * 2).rounded(.toNearestOrEven) * 50), font: fontFamily(name),
                           color: color(letter.color))
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// "ABCDEF+TimesNewRomanPS-BoldMT" → "Times New Roman"; nil for names that are no family (F1, T3Font_0).
    static func fontFamily(_ postScriptName: String) -> String? {
        var name = subsetPrefix.stringByReplacingMatches(in: postScriptName, range: NSRange(postScriptName.startIndex..., in: postScriptName),
                                                         withTemplate: "")
        if let cut = name.firstIndex(where: { $0 == "-" || $0 == "," }), cut != name.startIndex { name = String(name[..<cut]) }
        for suffix in ["PSMT", "MT", "PS"] where name.utf16.count > suffix.utf16.count + 2 && name.hasSuffix(suffix) {
            if let mapped = knownFonts[name.lowercased()] { return mapped }
            name = String(name.dropLast(suffix.count))
        }
        if let known = knownFonts[name.lowercased()] { return known }
        return name.utf16.count < 3 || matches(name, "^(F|T3Font_?|Font)\\d+$") ? nil : name
    }

    /// "#RRGGBB" of a text colour, black included: heading styles of the HWPX template are coloured, the PDF's text was not.
    private static func color(_ color: CGColor?) -> String? {
        guard let color, let components = color.components else { return nil }
        let rgb: [CGFloat]
        switch color.colorSpace?.model {
        case .monochrome?: rgb = [components[0], components[0], components[0]]
        case .rgb?: rgb = Array(components.prefix(3))
        case .cmyk?:
            let (c, m, y, k) = (components[0], components[1], components[2], components[3])
            rgb = [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)]
        default: return nil // pattern and other colours without an RGB value
        }
        guard rgb.count == 3 else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(Double(value), 0), 1) * 255).rounded(.toNearestOrEven)) }
        return String(format: "#%02X%02X%02X", channel(rgb[0]), channel(rgb[1]), channel(rgb[2]))
    }

    /// Latin ligatures (ﬁ, ﬂ, ...) as letters, so the text can be searched and edited.
    private static func cleanText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) }) else { return text }
        return text.unicodeScalars.map { (0xFB00...0xFB06).contains($0.value) ? String($0).precomposedStringWithCompatibilityMapping : String($0) }.joined()
    }

    // ───────────────────────── Pictures ─────────────────────────

    /// An image XObject to take out as a picture, and its place on the paper.
    private typealias Picture = (image: ContentScan.PlacedImage, bounds: CGRect)

    /// The page's image XObjects to take out as pictures. Full-page scans remain alongside their extracted text when the
    /// output must keep page content.
    private func images(_ scan: ContentScan, _ content: PageContent, _ crop: CGRect, separating: Bool = false) -> [Picture] {
        guard !separating || !scan.imagesNeedComposition else { return [] }
        return scan.images.prefix(200).enumerated().compactMap { index, image in
            var bounds = Self.shift(image.box, crop)
            if separating {
                let page = CGRect(x: 0, y: 0, width: content.width, height: content.height)
                guard page.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
                      !scan.images.enumerated().contains(where: { $0.offset != index && $0.element.box.intersects(image.box) }) else { return nil }
            }
            bounds = CGRect(x: max(0, bounds.minX), y: max(0, bounds.minY), width: 0, height: 0)
                .union(CGRect(x: min(CGFloat(content.width), bounds.maxX), y: min(CGFloat(content.height), bounds.maxY), width: 0, height: 0))
            guard let dictionary = CGPDFStreamGetDictionary(image.stream) else { return nil }
            if separating {
                var mask: CGPDFObjectRef?
                var inData: CGPDFInteger = 0
                guard !CGPDFDictionaryGetObject(dictionary, "SMask", &mask), !CGPDFDictionaryGetObject(dictionary, "Mask", &mask),
                      !CGPDFDictionaryGetInteger(dictionary, "SMaskInData", &inData) || inData == 0 else { return nil }
            }
            var mask: CGPDFBoolean = 0
            CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &mask)
            if bounds.width < 6 || bounds.height < 6 || mask != 0 { return nil }
            if !allText && Double(bounds.width * bounds.height) > 0.85 * content.width * content.height { return nil }
            return (image, bounds)
        }
    }

    private func pictures(_ images: [Picture], _ content: PageContent) throws -> [Item] {
        var result: [Item] = []
        var rendered: CGImage?
        for (image, bounds) in images {
            try Task.checkCancellation()
            var path: String?
            if let jpeg = Self.plainJpeg(image.stream) {
                path = try newMediaPath("jpg")
                try FileManager.default.writeFile(path!, jpeg)
            } else if let png = PdfImageSamples.png(image.stream) {
                path = try newMediaPath("png")
                try FileManager.default.writeFile(path!, png)
            } else {
                // JPEG 2000, CCITT, unusual colour spaces ...: cut the picture out of the rendered page.
                if rendered == nil { rendered = try renderPage(content.index) }
                path = try self.crop(rendered!, bounds, content)
            }
            if let path {
                let item = Item()
                item.picturePath = path
                item.pictureBounds = bounds
                result.append(item)
            }
        }
        return result
    }

    /// The page rendered without the text it keeps (the `words`), cut to what isn't white paper: its drawings, pictures and
    /// the text left out, each in its place; nil when nothing is left. Also without the pictures `apart` (taken out as they
    /// are instead), except those something it shows is on; it returns the ones it leaves out.
    private func drawing(_ content: PageContent, _ words: [PdfiumDocument.Word], apart pictures: [Picture] = []) throws
        -> (drawing: (path: String, bounds: CGRect)?, apart: [Picture]) {
        var apart = pictures
        var page = try pdfium().render(content.index, dpi: Self.renderDpi, withoutTextAt: words, withoutImagesAt: apart.map(\.image.box))
        let alone = try apart.map { picture in
            let (scaleX, scaleY) = (Double(page.width) / content.width, Double(page.height) / content.height)
            return try !Self.shows(page, in: CGRect(x: Double(picture.bounds.minX) * scaleX, y: (content.height - Double(picture.bounds.maxY)) * scaleY,
                                                    width: Double(picture.bounds.width) * scaleX, height: Double(picture.bounds.height) * scaleY))
        }
        if alone.contains(false) {
            // Ink on a picture (a glyph over it, a picture not taken out under it) can't be put apart: such a picture stays
            // in the drawing, in its place (one more rendering).
            apart = zip(apart, alone).filter(\.1).map(\.0)
            page = try pdfium().render(content.index, dpi: Self.renderDpi, withoutTextAt: words, withoutImagesAt: apart.map(\.image.box))
        }
        guard let pixels = page.dataProvider?.data as Data? else { throw ConversionError("The page could not be rendered.") }
        var (left, top, right, bottom) = (page.width, page.height, -1, -1)
        pixels.withUnsafeBytes { bytes in
            for y in 0..<page.height {
                let row = y * page.bytesPerRow
                for x in 0..<page.width where bytes[row + 4 * x] != 0xFF || bytes[row + 4 * x + 1] != 0xFF || bytes[row + 4 * x + 2] != 0xFF {
                    (left, top, right, bottom) = (min(left, x), min(top, y), max(right, x), max(bottom, y))
                }
            }
        }
        guard right >= 0 else { return (nil, apart) }
        // A pixel of white around it, so a hairline rule is still wide enough to cut out.
        (left, top, right, bottom) = (max(0, left - 1), max(0, top - 1), min(page.width, right + 2), min(page.height, bottom + 2))
        let (scaleX, scaleY) = (content.width / Double(page.width), content.height / Double(page.height))
        let bounds = CGRect(x: Double(left) * scaleX, y: content.height - Double(bottom) * scaleY,
                            width: Double(right - left) * scaleX, height: Double(bottom - top) * scaleY)
        return (try crop(page, bounds, content).map { ($0, bounds) }, apart)
    }

    /// A DCT (JPEG) stream in gray or RGB without a decode array: the bytes are a JPEG file as they are.
    private static func plainJpeg(_ stream: CGPDFStreamRef) -> Data? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var name: UnsafePointer<CChar>?
        var filters: CGPDFArrayRef?
        var filter: String?
        if CGPDFDictionaryGetName(dictionary, "Filter", &name), let name {
            filter = String(cString: name)
        } else if CGPDFDictionaryGetArray(dictionary, "Filter", &filters), let filters, CGPDFArrayGetCount(filters) == 1,
                  CGPDFArrayGetName(filters, 0, &name), let name {
            filter = String(cString: name)
        }
        var decode: CGPDFArrayRef?
        guard filter == "DCTDecode" || filter == "DCT", !CGPDFDictionaryGetArray(dictionary, "Decode", &decode) else { return nil }
        let components = PdfImageSamples.componentCount(dictionary) ?? 3
        guard components == 1 || components == 3 else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded else { return nil }
        return data as Data
    }

    private func newMediaPath(_ ext: String) throws -> String {
        try FileManager.default.createDirectoryIfNeeded(mediaFolder)
        pictures += 1
        return FilePath.combine(mediaFolder, "pdf-\(pictures).\(ext)")
    }

    private func pdfium() throws -> PdfiumDocument {
        if raster == nil { raster = try PdfiumDocument(path) }
        return raster!
    }

    private func renderPage(_ index: Int) throws -> CGImage {
        try pdfium().render(index, dpi: Self.renderDpi)
    }

    /// The whole page as a JPEG, the format of scans.
    private func renderScan(_ index: Int) throws -> String {
        let image = try renderPage(index)
        let path = try newMediaPath("jpg")
        try JpegEncoder.writeSkia(ImagePixels.flattened(image, background: (255, 255, 255)), quality: 85, to: path) // Filee: Encode(Jpeg, 85)
        return path
    }

    private func crop(_ page: CGImage, _ bounds: CGRect, _ content: PageContent) throws -> String? {
        let scaleX = Double(page.width) / content.width
        let scaleY = Double(page.height) / content.height
        func round(_ value: Double) -> Int { Int(value.rounded(.toNearestOrEven)) }
        var left = round(Double(bounds.minX) * scaleX), top = round((content.height - Double(bounds.maxY)) * scaleY)
        var right = round(Double(bounds.maxX) * scaleX), bottom = round((content.height - Double(bounds.minY)) * scaleY)
        (left, top, right, bottom) = (max(left, 0), max(top, 0), min(right, page.width), min(bottom, page.height))
        guard right - left >= 2, bottom - top >= 2, let part = page.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else {
            return nil
        }
        let path = try newMediaPath("png")
        try ImageEncoder.save([ImageFrame(image: part)], to: path, format: "png")
        return path
    }

    // ───────────────────────── Headers and footers ─────────────────────────

    private static let pageNumber = try! NSRegularExpression(
        pattern: "^[\\s\\-–—(\\[]*(page|p\\.|페이지|第)?\\s*\\d+\\s*(/|of|페이지|쪽|页)?\\s*\\d*[\\s\\-–—)\\]]*$", options: [.caseInsensitive])

    /// Leaves out paragraphs at the top or bottom edge that repeat on most pages (running heads, footers; digits are
    /// ignored so "Page 3" matches "Page 4") and bare page numbers there.
    private static func removeRepeatedHeadersAndFooters(_ pages: [PageContent]) {
        let textPages = pages.filter { !$0.scanned }
        guard textPages.count >= 2 else { return }
        func atEdge(_ item: Item, _ page: PageContent) -> Bool { item.top > page.height * 0.9 || item.bottom < page.height * 0.1 }
        func key(_ item: Item) -> String {
            let text = item.text
            return digits.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "#")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var counts: [String: Int] = [:]
        for page in textPages {
            var seen = Set<String>()
            for item in page.items where !item.isPicture && atEdge(item, page) && seen.insert(key(item)).inserted {
                counts[key(item), default: 0] += 1
            }
        }
        let needed = max(2, Int((Double(textPages.count) * 0.5).rounded(.up)))
        for page in textPages {
            page.items.removeAll { item in
                !item.isPicture && atEdge(item, page) && item.lines.count <= 2
                    && ((counts[key(item)] ?? 0) >= needed || isMatch(pageNumber, item.text))
            }
        }
    }

    private static let digits = try! NSRegularExpression(pattern: "\\d+")

    static func isMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // ───────────────────────── Building the document ─────────────────────────

    private func build(_ pages: [PageContent], _ title: String?) -> HDocument {
        let document = HDocument()
        document.title = title
        let items = pages.flatMap { $0.items.filter { !$0.isPicture } }
        let bodySize = Self.bodySize(items)
        let headingLevels = Self.headingLevels(items, bodySize)
        let (left, right, top, bottom) = Self.margins(pages)
        let lineRatio = Self.typicalLineRatio(items)

        var section: HSection?
        for page in pages {
            let hpage = HPage(width: Self.hwp(page.width), height: Self.hwp(page.height), left: Self.hwp(left), right: Self.hwp(right),
                              top: Self.hwp(top), bottom: Self.hwp(bottom), header: 0, footer: 0, gutter: 0)
            let newSection = section == nil || section!.page != hpage
            if newSection {
                section = HSection()
                section!.page = hpage
                document.sections.append(section!)
            }
            let current = section!
            let first = current.blocks.count

            if page.scanned {
                if let scan = page.scanPath {
                    // Floating behind the (empty) paragraph at the paper's corner: the page image never pushes text.
                    let picture = HImage(scan)
                    picture.width = hpage.width
                    picture.height = hpage.height
                    picture.anchor = HAnchor("PAPER", "LEFT", 0, "PAPER", "TOP", 0, "BEHIND_TEXT", true)
                    let paragraph = HParagraph()
                    paragraph.markFormat = HCharFormat(size: 100)
                    paragraph.inlines.append(picture)
                    current.blocks.append(paragraph)
                } else {
                    current.blocks.append(HParagraph())
                }
            } else {
                var previous: Item?
                for item in page.items {
                    current.blocks.append(item.isPicture ? Self.pictureParagraph(item, previous) : Self.textParagraph(item, previous, headingLevels, lineRatio))
                    previous = item
                }
                if current.blocks.count == first { current.blocks.append(HParagraph()) }
                if let drawing = page.drawing, let paragraph = current.blocks[first] as? HParagraph {
                    // Behind the text at its place on the paper: the drawings never push the text or change its order.
                    let picture = HImage(drawing.path)
                    picture.width = Self.hwp(Double(drawing.bounds.width))
                    picture.height = Self.hwp(Double(drawing.bounds.height))
                    picture.anchor = HAnchor("PAPER", "LEFT", Self.hwp(Double(drawing.bounds.minX)), "PAPER", "TOP",
                                             Self.hwp(page.height - Double(drawing.bounds.maxY)), "BEHIND_TEXT", true)
                    paragraph.inlines.insert(picture, at: 0)
                }
            }

            if !newSection, let startOfPage = current.blocks[first] as? HParagraph { startOfPage.pageBreakBefore = true }
        }
        if document.sections.isEmpty {
            let empty = HSection()
            empty.blocks.append(HParagraph())
            document.sections.append(empty)
        }
        return document
    }

    private static func hwp(_ points: Double) -> Int { Int((points * unit).rounded(.toNearestOrEven)) }

    /// The size of most text (by characters, rounded to half points); 10 when there is none.
    static func mostUsedSize(_ words: [TextWord]) -> Double {
        var keys: [Double] = []
        var lengths: [Double: Int] = [:]
        for word in words {
            let key = (word.size * 2).rounded(.toNearestOrEven) / 2
            if lengths[key] == nil { keys.append(key) }
            lengths[key, default: 0] += word.text.utf16.count
        }
        // OrderByDescending is stable: the first size of equal counts wins.
        var best: Double?
        for key in keys where best == nil || lengths[key]! > lengths[best!]! { best = key }
        return best ?? 10
    }

    /// The size of most body text (by characters, rounded to half points).
    private static func bodySize(_ items: [Item]) -> Double {
        mostUsedSize(items.flatMap(\.lines).flatMap(\.words))
    }

    /// Heading level by size: short paragraphs clearly larger than the body text, the largest size first.
    private static func headingLevels(_ items: [Item], _ bodySize: Double) -> [Double: Int] {
        var sizes: [Double] = []
        for item in items where isHeadingCandidate(item, bodySize) {
            let size = item.size.rounded(.toNearestOrEven)
            if !sizes.contains(size) { sizes.append(size) }
        }
        sizes.sort(by: >)
        var levels: [Double: Int] = [:]
        for (i, size) in sizes.enumerated() { levels[size] = min(6, i + 1) }
        return levels
    }

    private static func isHeadingCandidate(_ item: Item, _ bodySize: Double) -> Bool {
        !item.isPicture && item.lines.count <= 3 && item.text.utf16.count <= 200 && item.size >= bodySize * 1.15 && item.size >= bodySize + 1
    }

    /// Margins shared by the text pages: the smallest distances from the paper edges to any text or picture.
    private static func margins(_ pages: [PageContent]) -> (Double, Double, Double, Double) {
        let minimum = 18.0, maximum = 108.0, fallback = 72.0
        var left: Double?, right: Double?, top: Double?, bottom: Double?
        for page in pages where !page.scanned && !page.items.isEmpty {
            left = min(left ?? .greatestFiniteMagnitude, page.items.map(\.left).min()!)
            right = min(right ?? .greatestFiniteMagnitude, page.width - page.items.map(\.right).max()!)
            top = min(top ?? .greatestFiniteMagnitude, page.height - page.items.map(\.top).max()!)
            bottom = min(bottom ?? .greatestFiniteMagnitude, page.items.map(\.bottom).min()!)
        }
        func clamp(_ value: Double?) -> Double { min(max(value ?? fallback, minimum), maximum) }
        return (clamp(left), clamp(right), clamp(top), clamp(bottom))
    }

    /// Distance between baselines relative to the font size in multi-line paragraphs (1.2 when unknown).
    private static func typicalLineRatio(_ items: [Item]) -> Double {
        let ratios = items.filter { $0.lines.count >= 2 }.map { pitch($0) / $0.size }.filter { $0 > 0.8 && $0 < 3 }
        return ratios.isEmpty ? 1.2 : median(ratios)
    }

    static func pitch(_ item: Item) -> Double {
        var gaps: [Double] = []
        for i in 1..<max(1, item.lines.count) { gaps.append(item.lines[i - 1].baseline - item.lines[i].baseline) }
        return gaps.isEmpty ? item.size * 1.2 : median(gaps)
    }

    private static func pictureParagraph(_ item: Item, _ previous: Item?) -> HParagraph {
        let bounds = item.pictureBounds!
        let paragraph = HParagraph()
        let containerCenter = (item.containerLeft + item.containerRight) / 2
        let centered = abs(Double(bounds.minX + bounds.maxX) / 2 - containerCenter) < max(6, (item.containerRight - item.containerLeft) * 0.05)
            && Double(bounds.width) < (item.containerRight - item.containerLeft) * 0.9
        paragraph.format = HParaFormat(align: centered ? .center : .left, before: spaceBefore(item, previous), after: 0,
                                       // Word's single line spacing (130 % in the model): a smaller multiple would cut off the top of the picture.
                                       lineSpacing: HLineSpacing(.percent, 130))
        let image = HImage(item.picturePath!)
        image.width = hwp(Double(bounds.width))
        image.height = hwp(Double(bounds.height))
        paragraph.inlines.append(image)
        return paragraph
    }

    private static func textParagraph(_ item: Item, _ previous: Item?, _ headingLevels: [Double: Int], _ lineRatio: Double) -> HParagraph {
        let size = item.size
        let paragraph = HParagraph()
        if let level = headingLevels[size.rounded(.toNearestOrEven)], item.lines.count <= 3, item.text.utf16.count <= 200 {
            paragraph.headingLevel = level
        }

        // Alignment and indents relative to the column (or text area) the paragraph is in.
        let containerWidth = max(1, item.containerRight - item.containerLeft)
        let lefts = item.lines.map { $0.left - item.containerLeft }
        let rights = item.lines.map { item.containerRight - $0.right }
        let tolerance = max(3, containerWidth * 0.03)
        let align: HAlign
        if item.lines.allSatisfy({ abs(($0.left - item.containerLeft) - (item.containerRight - $0.right)) < tolerance }) && lefts.min()! > containerWidth * 0.04 {
            align = .center
        } else if rights.allSatisfy({ $0 < 3 }) && lefts.min()! > containerWidth * 0.15 {
            align = .right
        } else if item.lines.count >= 2 && rights.dropLast().allSatisfy({ $0 < 2.5 }) && item.width > containerWidth * 0.5 {
            align = .justify
        } else {
            align = .left
        }

        var left: Int?, firstLine: Int?
        if align == .left || align == .justify {
            let body = item.lines.count > 1 ? lefts.dropFirst().min()! : lefts[0]
            if body > 2 { left = hwp(body) }
            let first = lefts[0] - max(0, body)
            if abs(first) > 2 { firstLine = hwp(first) }
        }

        // A tabbed row: a left tab stop where each part starts in the PDF.
        var positions: [Int] = []
        for line in item.lines {
            for tab in line.tabs {
                let position = hwp(line.words[tab].left - item.containerLeft)
                if !positions.contains(position) { positions.append(position) }
            }
        }
        let tabs = positions.sorted().map { HTabStop($0, .left, "NONE") }

        let pitch = item.lines.count >= 2 ? pitch(item) : size * lineRatio
        paragraph.format = HParaFormat(align: align, left: left, firstLine: firstLine, before: spaceBefore(item, previous, lineRatio), after: 0,
                                       // "At least" the PDF's line distance: close to the original and never cuts off a larger font.
                                       lineSpacing: HLineSpacing(.atLeast, hwp(min(max(pitch, size), size * 3))),
                                       tabs: tabs.isEmpty ? nil : tabs)
        paragraph.markFormat = HCharFormat(size: Int((size * 2).rounded(.toNearestOrEven) * 50))
        runs(item, &paragraph.inlines)
        return paragraph
    }

    /// Extra space above an item: its distance to the item right above it (in the same column) minus what a line (or a
    /// picture's own height) takes anyway. Items at the top of a column get none.
    private static func spaceBefore(_ item: Item, _ previous: Item?, _ lineRatio: Double = 1.2) -> Int {
        guard let previous, !(previous.bottom <= item.top - 1 || previous.right <= item.left || previous.left >= item.right) else { return 0 }
        // Edges of the line boxes: a text line reaches about 0.25 em below its baseline and 0.95 em above it.
        let above = previous.isPicture ? previous.bottom : previous.lines[previous.lines.count - 1].baseline - 0.25 * previous.size
        let top = item.isPicture ? item.top : item.lines[0].baseline + 0.95 * item.size
        let normal = item.isPicture || previous.isPicture ? 0 : (lineRatio - 1.2) * item.size
        let extra = above - top - normal
        return extra > 1 ? hwp(min(extra, 72)) : 0
    }

    /// Words joined into runs of equal formatting; line ends become spaces (not inside CJK text or after a hyphen), or
    /// line breaks where the line ended early on purpose. Tabs of a tabbed row stay tabs.
    private static func runs(_ item: Item, _ output: inout [HInline]) {
        var pieces: [(text: String, format: HCharFormat, link: String?)] = []
        for (l, line) in item.lines.enumerated() {
            for (w, word) in line.words.enumerated() {
                let text = word.text
                if let (previousText, previousFormat, previousLink) = pieces.last {
                    if w > 0 && line.tabs.contains(w) {
                        pieces.append(("\t", word.format, nil))
                    } else if w > 0 {
                        pieces[pieces.count - 1] = (previousText + " ", previousFormat, previousLink)
                    } else if previousText.hasSuffix("-") && previousText.dropLast().last?.isLetter == true
                                && text.first?.isLowercase == true {
                        pieces[pieces.count - 1] = (String(previousText.dropLast()), previousFormat, previousLink) // hyphenated at the line end
                    } else if endedEarly(item, l) {
                        pieces.append(("\n", word.format, nil))
                    } else if !(isCjk(previousText.utf16.last!) || isCjk(text.utf16.first!)) {
                        pieces[pieces.count - 1] = (previousText + " ", previousFormat, previousLink)
                    }
                }
                pieces.append((text, word.format, word.link))
            }
        }

        var link: HLink?
        for group in merge(pieces) {
            if group.text == "\t" || group.text == "\n" {
                link = nil
                output.append(group.text == "\t" ? HTab(group.format) : HLineBreak(group.format))
                continue
            }
            let text = HText(group.text, group.format)
            if let target = group.link {
                if link == nil || link!.target != target {
                    link = HLink(target)
                    output.append(link!)
                }
                link!.content.append(text)
            } else {
                link = nil
                output.append(text)
            }
        }
    }

    /// Whether line `l` − 1 of the item ended although the first word of line `l` would have fitted after it: a line
    /// break the author made (an address, a poem). Wrapped text never ends like that within its own width; past it only
    /// when the paragraph is clearly narrower than its column (an indented block of short lines), not a quote with a
    /// right indent.
    private static func endedEarly(_ item: Item, _ l: Int) -> Bool {
        let previous = item.lines[l - 1]
        let line = item.lines[l]
        if previous.words[previous.words.count - 1].text.hasSuffix("-") { return false }
        let em = line.size
        let end = previous.right + 0.3 * em + (line.words[0].right - line.words[0].left)
        if end < item.right - 0.5 * em { return true }
        let column = item.containerRight - item.containerLeft
        return end < item.containerRight - 0.5 * em && item.containerRight - item.right > 0.25 * column
    }

    private static func merge(_ pieces: [(text: String, format: HCharFormat, link: String?)]) -> [(text: String, format: HCharFormat, link: String?)] {
        var result: [(text: String, format: HCharFormat, link: String?)] = []
        var text = ""
        var format = HCharFormat()
        var link: String?
        var open = false
        for piece in pieces {
            if open && (piece.format != format || piece.link != link || piece.text == "\t" || piece.text == "\n" || text == "\t" || text == "\n") {
                result.append((text, format, link))
                text = ""
            }
            text += piece.text
            (format, link, open) = (piece.format, piece.link, true)
        }
        if open {
            let isMark = text == "\t" || text == "\n"
            result.append((isMark ? text : trimEnd(text), format, link))
        }
        return result
    }

    /// .NET's TrimEnd(): white space removed from the end.
    private static func trimEnd(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }

    /// Chinese and Japanese text has no spaces between words (Korean does).
    private static func isCjk(_ unit: UInt16) -> Bool {
        (0x3040...0x30FF).contains(unit) || (0x3400...0x9FFF).contains(unit) || (0xF900...0xFAFF).contains(unit)
            || (0xFF00...0xFF60).contains(unit) || (0x3000...0x303F).contains(unit)
    }

    // ───────────────────────── Helpers ─────────────────────────

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func nullIfBlank(_ text: String?) -> String? {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text of a document read by `readText`: paragraphs separated by an empty line.
    static func plainText(_ document: HDocument) -> String {
        var text = ""
        for paragraph in document.sections.flatMap(\.blocks).compactMap({ $0 as? HParagraph }) {
            let inlines = paragraph.inlines.flatMap { ($0 as? HLink)?.content ?? [$0] }
            let content = inlines.map { inline -> String in
                switch inline {
                case let run as HText: return run.text
                case is HTab: return "\t"
                case is HLineBreak: return "\r\n"
                default: return ""
                }
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            if !text.isEmpty { text += "\r\n\r\n" }
            text += content
        }
        return text.isEmpty ? "" : text + "\r\n"
    }
}
