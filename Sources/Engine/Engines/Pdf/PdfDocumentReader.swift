// Port of Filee.Engines/Pdf/PdfDocumentReader.cs: PDF → HDocument, so PDF → DOCX / HWPX / TXT needs no Word,
// LibreOffice or OCR engine. PdfPig is replaced by PDFKit (letters, glyph boxes, fonts, colours, links) and a
// CGPDFScanner pass (rendering modes, images); see PdfDocumentReader+Page.swift.
//
// Every page's words (with their positions, fonts, sizes and colours) become lines, lines become paragraphs, and the
// paragraphs and pictures are put in reading order, also on two-column pages (PdfDocumentReader+Layout.swift). Headings
// come from font sizes, bold / italic from the fonts, page size and margins from the page. Headers and footers that
// repeat on the pages (and bare page numbers) are left out. A page without text (a scan) becomes the rendered page as
// a picture, so the result is complete; there is no OCR.
//
// Rows laid out with tab stops (a number, a label and a date far to the right) stay one line with tabs at the PDF's
// positions, and a line that ends early although the next line's first word would have fitted (an address) keeps its
// line break.
//
// Not converted: tables (their cells come out as paragraphs in reading order), vector drawings on text pages,
// annotations other than links, form fields.

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
    private var pictures = 0

    private init(_ path: String, _ mediaFolder: String, textOnly: Bool) {
        self.path = path
        self.mediaFolder = mediaFolder
        self.textOnly = textOnly
    }

    /// Reads `path` with pictures (extracted into `mediaFolder`) and scans.
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        try PdfDocumentReader(path, mediaFolder, textOnly: false).readDocument()
    }

    /// Reads only the text, including invisible text (the OCR layer of scanned PDFs); pictures and scans are left out.
    static func readText(_ path: String) throws -> HDocument {
        try PdfDocumentReader(path, "", textOnly: true).readDocument()
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

        init(_ index: Int, _ width: Double, _ height: Double) {
            self.index = index
            self.width = width
            self.height = height
        }
    }

    // ───────────────────────── Document ─────────────────────────

    private func readDocument() throws -> HDocument {
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw ConversionError("\(FilePath.fileName(path)) is not a PDF file that can be read.")
        }
        if pdf.isLocked { throw Self.passwordProtected() }

        var pages: [PageContent] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            pages.append(try readPage(page, index))
        }

        Self.removeRepeatedHeadersAndFooters(pages)
        for page in pages where !page.scanned { page.items = Self.readingOrder(page.items) }
        let title = Self.nullIfBlank(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
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
        var words: [TextWord] = []
        for word in Self.pageWords(page, scan: scan) {
            let letters = word.letters
            guard letters.allSatisfy(\.horizontal) else { continue }
            let text = letters.map(\.text).joined()
            guard !text.allSatisfy(\.isWhitespace) else { continue }
            // Invisible text is the OCR layer of a scan: part of the text, not of the page's look.
            if !textOnly && letters.allSatisfy({ $0.mode == 3 }) { continue }
            let glyphs = letters.dropFirst().reduce(letters[0].box) { $0.union($1.box) }
            let box = Self.shift(CGRect(x: word.left, y: glyphs.minY, width: word.right - word.left, height: glyphs.height), crop)
            let size = Self.median(letters.map { Double($0.size) })
            let center = CGPoint(x: box.midX, y: box.midY)
            let link = links.first { $0.bounds.contains(center) }?.uri
            words.append(TextWord(text: Self.cleanText(text), left: Double(box.minX), right: Double(box.maxX), top: Double(box.maxY),
                                  bottom: Double(box.minY), baseline: Double(word.baseline - crop.minY), size: max(1, size),
                                  format: Self.format(letters[0], size), link: link))
        }

        if words.isEmpty || (rotated && !textOnly) {
            // A scan, a page of drawings, or a turned page: the rendered page keeps everything.
            content.scanned = true
            if !textOnly { content.scanPath = try renderScan(page) }
            return content
        }

        let lines = Self.lines(words)
        var items = Self.paragraphs(lines)
        if let joined = Self.joinTabbedRows(lines, items) { items = Self.paragraphs(joined) }
        content.items = items
        if !textOnly { content.items += try pictures(page, scan, content, crop) }
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

    /// Pictures of a text page. A picture covering the page behind text is the scan under an OCR layer: skipped.
    private func pictures(_ page: PDFPage, _ scan: ContentScan, _ content: PageContent, _ crop: CGRect) throws -> [Item] {
        var result: [Item] = []
        var rendered: CGImage?
        for image in scan.images.prefix(200) {
            try Task.checkCancellation()
            var bounds = Self.shift(image.box, crop)
            bounds = CGRect(x: max(0, bounds.minX), y: max(0, bounds.minY), width: 0, height: 0)
                .union(CGRect(x: min(CGFloat(content.width), bounds.maxX), y: min(CGFloat(content.height), bounds.maxY), width: 0, height: 0))
            guard let dictionary = CGPDFStreamGetDictionary(image.stream) else { continue }
            var mask: CGPDFBoolean = 0
            CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &mask)
            if bounds.width < 6 || bounds.height < 6 || mask != 0 { continue }
            if Double(bounds.width * bounds.height) > 0.85 * content.width * content.height { continue }

            var path: String?
            if let jpeg = Self.plainJpeg(image.stream) {
                path = try newMediaPath("jpg")
                try jpeg.write(to: URL(fileURLWithPath: path!))
            } else if let png = PdfImageSamples.png(image.stream) {
                path = try newMediaPath("png")
                try png.write(to: URL(fileURLWithPath: path!))
            } else {
                // JPEG 2000, CCITT, unusual colour spaces ...: cut the picture out of the rendered page.
                if rendered == nil { rendered = try PdfiumConverter.render(page, dpi: Self.renderDpi) }
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

    /// The whole page as a JPEG, the format of scans.
    private func renderScan(_ page: PDFPage) throws -> String {
        let image = try PdfiumConverter.render(page, dpi: Self.renderDpi)
        let path = try newMediaPath("jpg")
        var frame = ImageFrame(image: ImagePixels.flattened(image, background: (255, 255, 255)))
        frame.properties[kCGImageDestinationLossyCompressionQuality] = ImageEncoder.jpegQuality(85)
        try ImageEncoder.save([frame], to: path, format: "jpg")
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
                    let previous = Array(previousText)
                    if w > 0 && line.tabs.contains(w) {
                        pieces.append(("\t", word.format, nil))
                    } else if w > 0 {
                        pieces[pieces.count - 1] = (previousText + " ", previousFormat, previousLink)
                    } else if previousText.hasSuffix("-") && previous.count > 1 && previous[previous.count - 2].isLetter
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
