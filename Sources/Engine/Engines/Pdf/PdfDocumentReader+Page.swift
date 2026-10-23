// What PdfDocumentReader took from PdfPig, from PDFKit and Core Graphics: the letters of a page (PDFKit's text with
// glyph boxes, fonts and fill colours; baselines from the fonts' glyph metrics), grouped into words, and a content
// stream scan (CGPDFScanner) for what PDFKit doesn't tell: the text rendering mode (invisible OCR text, fill-then-
// stroke bold, rotated text) and the image XObjects with their placement and data.

import CoreGraphics
import CoreText
import Foundation
import PDFKit

extension PdfDocumentReader {
    // PDFKit constructs attributes through a shared Foundation table; concurrent construction contends on every glyph.
    private static let attributedStringLock = NSLock()

    /// A letter of the page: one character (or composed sequence) with its glyph box in page space.
    struct PageLetter {
        var text: String
        var box: CGRect
        var baseline: CGFloat
        var size: CGFloat
        var fontName: String
        var bold: Bool
        var italic: Bool
        var color: CGColor?
        /// PDF text rendering mode (3 = invisible, 2 = fill then stroke).
        var mode: Int
        var horizontal: Bool
    }

    /// A word: its letters, and from PDFKit's selection of it the pen positions where it starts and ends (PdfPig's word
    /// boxes for the standard fonts start at the glyph origin) and the baseline.
    struct PageWord {
        var letters: [PageLetter]
        var left: CGFloat
        var right: CGFloat
        var baseline: CGFloat
    }

    /// The words of a page in PDFKit's text order: letters between white space, a large gap or a new line.
    /// `characterBounds(at:)` counts the text without the line separators PDFKit puts between lines (its spaces between
    /// words do count), so its index runs behind the string's by the separators seen so far.
    static func pageWords(_ page: PDFPage, scan: ContentScan) -> [PageWord] {
        guard let text = page.string, let attributed = attributedStringLock.withLock({ page.attributedString }) else { return [] }
        let string = text as NSString
        guard string.length == attributed.length else { return [] }
        var words: [PageWord] = []
        var current: [PageLetter] = []
        var start = 0, end = 0
        func finish() {
            defer { current = [] }
            guard let first = current.first else { return }
            var word = PageWord(letters: current, left: first.box.minX, right: current.last!.box.maxX, baseline: first.baseline)
            if let selection = page.selection(for: NSRange(location: start, length: end - start)) {
                // The selection box spans the letters' advances, from the font's descender up.
                let box = selection.bounds(for: page)
                if box.width > 0 && box.height > 0 {
                    (word.left, word.right) = (box.minX, box.maxX)
                    if let font = (attributed.attribute(.font, at: start, effectiveRange: nil) as? NSFont) { word.baseline = box.minY - font.descender }
                }
            }
            words.append(word)
        }
        var index = 0
        var separators = 0
        var attributeRange = NSRange()
        var font: NSFont?
        var fontName = ""
        var traits: CTFontSymbolicTraits = []
        var color: CGColor?
        while index < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: index)
            index = range.location + range.length
            let character = string.substring(with: range)
            if character == "\n" || character == "\r" || character == "\r\n" {
                separators += range.length
                finish()
                continue
            }
            if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0 }) {
                finish()
                continue
            }
            let box = page.characterBounds(at: range.location - separators)
            guard box.width.isFinite, box.height.isFinite, !(box.width == 0 && box.height == 0) else { continue }
            if !NSLocationInRange(range.location, attributeRange) {
                let attributes = attributed.attributes(at: range.location, effectiveRange: &attributeRange)
                font = attributes[.font] as? NSFont
                fontName = font?.fontName ?? ""
                traits = font.map { CTFontGetSymbolicTraits($0) } ?? []
                color = fillColor(attributes)
            }
            let size = font?.pointSize ?? max(1, box.height)
            var letter = PageLetter(text: character, box: box, baseline: box.minY, size: size, fontName: fontName,
                                    bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic),
                                    color: color, mode: 0, horizontal: true)
            if let run = scan.run(at: CGPoint(x: box.midX, y: box.midY)) {
                letter.mode = run.mode
                letter.horizontal = run.horizontal
            }
            if let previous = current.last {
                // A new word where the text jumps to another line or far to the right.
                let gap = box.minX - previous.box.maxX
                if abs(previous.box.midY - box.midY) > 0.6 * max(previous.size, size) || gap > 1.5 * min(previous.size, size) || gap < -2 * size {
                    finish()
                }
            }
            if current.isEmpty { start = range.location }
            end = range.location + range.length
            current.append(letter)
        }
        finish()
        return words
    }

    private static func fillColor(_ attributes: [NSAttributedString.Key: Any]) -> CGColor? {
        if let value = attributes[NSAttributedString.Key("kCPfillColor")], CFGetTypeID(value as CFTypeRef) == CGColor.typeID {
            return (value as! CGColor)
        }
        return (attributes[.foregroundColor] as? NSColor)?.cgColor
    }

    // ───────────────────────── Content stream scan ─────────────────────────

    /// What a scan of the page's content streams found.
    final class ContentScan {
        /// Text shown with a rendering mode other than plain fill, or turned: the area it covers.
        struct TextRun {
            var box: CGRect
            var mode: Int
            var horizontal: Bool
        }

        /// An image XObject drawn on the page.
        struct PlacedImage {
            var box: CGRect
            var stream: CGPDFStreamRef
        }

        var runs: [TextRun] = []
        var images: [PlacedImage] = []

        /// The special run covering a point (nil: ordinary, upright filled text).
        func run(at point: CGPoint) -> TextRun? {
            runs.first { $0.box.insetBy(dx: -1, dy: -1).contains(point) }
        }
    }

    /// Scans the page's content (and form XObjects) for text runs and images.
    static func scanContent(_ page: CGPDFPage) -> ContentScan {
        let state = ScanState()
        let table = CGPDFOperatorTableCreate()!
        ScanState.register(table)
        let stream = CGPDFContentStreamCreateWithPage(page)
        state.scan(stream, table: table)
        return state.result
    }

    /// Graphics and text state while scanning (the parts that place text and images).
    final class ScanState {
        struct Graphics {
            var ctm = CGAffineTransform.identity
            var fontSize: CGFloat = 0
            var characterSpacing: CGFloat = 0
            var wordSpacing: CGFloat = 0
            var horizontalScaling: CGFloat = 1
            var leading: CGFloat = 0
            var rise: CGFloat = 0
            var mode = 0
            var font: FontInfo?
        }

        struct FontInfo {
            var twoByte: Bool
            var firstChar = 0
            var widths: [CGFloat] = []
            var defaultWidth: CGFloat = 500
            var cidWidths: [Int: CGFloat] = [:]
        }

        let result = ContentScan()
        var graphics = Graphics()
        var stack: [Graphics] = []
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var streams: [CGPDFContentStreamRef] = []
        var fonts: [String: FontInfo] = [:]
        var depth = 0

        func scan(_ stream: CGPDFContentStreamRef, table: CGPDFOperatorTableRef) {
            streams.append(stream)
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            streams.removeLast()
        }

        static func state(_ info: UnsafeMutableRawPointer?) -> ScanState { Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue() }

        static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
            var values = [CGFloat](repeating: 0, count: count)
            for i in (0..<count).reversed() {
                var value: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
                values[i] = value
            }
            return values
        }

        static func register(_ table: CGPDFOperatorTableRef) {
            CGPDFOperatorTableSetCallback(table, "q") { _, info in let s = PdfDocumentReader.ScanState.state(info); s.stack.append(s.graphics) }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in let s = PdfDocumentReader.ScanState.state(info); if let g = s.stack.popLast() { s.graphics = g } }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
                guard let v = PdfDocumentReader.ScanState.numbers(scanner, 6) else { return }
                let s = PdfDocumentReader.ScanState.state(info)
                s.graphics.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.graphics.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "BT") { _, info in let s = PdfDocumentReader.ScanState.state(info); s.textMatrix = .identity; s.lineMatrix = .identity }
            CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
                let s = PdfDocumentReader.ScanState.state(info)
                var size: CGPDFReal = 0
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
                s.graphics.fontSize = size
                s.graphics.font = s.font(String(cString: name))
            }
            CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.characterSpacing = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.wordSpacing = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.horizontalScaling = v[0] / 100 } }
            CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.leading = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.rise = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.mode = Int(v[0]) } }
            CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 2) { PdfDocumentReader.ScanState.state(info).moveLine(v[0], v[1]) } }
            CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
                guard let v = PdfDocumentReader.ScanState.numbers(scanner, 2) else { return }
                let s = PdfDocumentReader.ScanState.state(info)
                s.graphics.leading = -v[1]
                s.moveLine(v[0], v[1])
            }
            CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
                guard let v = PdfDocumentReader.ScanState.numbers(scanner, 6) else { return }
                let s = PdfDocumentReader.ScanState.state(info)
                s.textMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                s.lineMatrix = s.textMatrix
            }
            CGPDFOperatorTableSetCallback(table, "T*") { _, info in let s = PdfDocumentReader.ScanState.state(info); s.moveLine(0, -s.graphics.leading) }
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                var string: CGPDFStringRef?
                if CGPDFScannerPopString(scanner, &string), let string { PdfDocumentReader.ScanState.state(info).show(string) }
            }
            CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                var string: CGPDFStringRef?
                let s = PdfDocumentReader.ScanState.state(info)
                s.moveLine(0, -s.graphics.leading)
                if CGPDFScannerPopString(scanner, &string), let string { s.show(string) }
            }
            CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                var string: CGPDFStringRef?
                let s = PdfDocumentReader.ScanState.state(info)
                guard CGPDFScannerPopString(scanner, &string), let string, let v = PdfDocumentReader.ScanState.numbers(scanner, 2) else { return }
                (s.graphics.wordSpacing, s.graphics.characterSpacing) = (v[0], v[1])
                s.moveLine(0, -s.graphics.leading)
                s.show(string)
            }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                var array: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &array), let array else { return }
                let s = PdfDocumentReader.ScanState.state(info)
                for i in 0..<CGPDFArrayGetCount(array) {
                    var string: CGPDFStringRef?
                    var number: CGPDFReal = 0
                    if CGPDFArrayGetString(array, i, &string), let string {
                        s.show(string)
                    } else if CGPDFArrayGetNumber(array, i, &number) {
                        s.advance(-number / 1000 * s.graphics.fontSize * s.graphics.horizontalScaling)
                    }
                }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name else { return }
                PdfDocumentReader.ScanState.state(info).drawObject(String(cString: name), table: CGPDFScannerGetContentStream(scanner))
            }
        }

        func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
            lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
            textMatrix = lineMatrix
        }

        func advance(_ tx: CGFloat) {
            textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
        }

        /// Shows a string: records the covered area for special runs and moves the text position past it.
        func show(_ string: CGPDFStringRef) {
            guard let bytes = CGPDFStringGetBytePtr(string) else { return }
            let count = CGPDFStringGetLength(string)
            let start = textMatrix.concatenating(graphics.ctm)
            let font = graphics.font ?? FontInfo(twoByte: false)
            var i = 0
            while i < count {
                let code = font.twoByte && i + 1 < count ? Int(bytes[i]) << 8 | Int(bytes[i + 1]) : Int(bytes[i])
                i += font.twoByte ? 2 : 1
                let width = font.width(code) / 1000 * graphics.fontSize
                let spacing = graphics.characterSpacing + (!font.twoByte && code == 32 ? graphics.wordSpacing : 0)
                advance((width + spacing) * graphics.horizontalScaling)
            }
            let end = textMatrix.concatenating(graphics.ctm)
            let horizontal = abs(start.b) < 1e-3 * abs(start.a) && start.a > 0 && start.d > 0
            guard graphics.mode != 0 || !horizontal else { return }
            // From the start to the end point, from a quarter of the size below the baseline to the size above it.
            let up = CGPoint(x: start.c * graphics.fontSize, y: start.d * graphics.fontSize)
            let origin = CGPoint(x: 0, y: graphics.rise).applying(start)
            let finish = CGPoint(x: 0, y: graphics.rise).applying(end)
            let corners = [origin, finish, CGPoint(x: origin.x + up.x, y: origin.y + up.y), CGPoint(x: finish.x + up.x, y: finish.y + up.y),
                           CGPoint(x: origin.x - 0.25 * up.x, y: origin.y - 0.25 * up.y), CGPoint(x: finish.x - 0.25 * up.x, y: finish.y - 0.25 * up.y)]
            let box = CGRect(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!, width: 0, height: 0)
                .union(CGRect(x: corners.map(\.x).max()!, y: corners.map(\.y).max()!, width: 0, height: 0))
            result.runs.append(ContentScan.TextRun(box: box, mode: graphics.mode, horizontal: horizontal))
        }

        func drawObject(_ name: String, table stream: CGPDFContentStreamRef) {
            guard let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject, let dictionary = CGPDFStreamGetDictionary(xobject) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                let box = CGRect(x: 0, y: 0, width: 1, height: 1).applying(graphics.ctm)
                result.images.append(ContentScan.PlacedImage(box: box, stream: xobject))
            case "Form" where depth < 8:
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(array, i, &v[i]) }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                let saved = (graphics, stack, textMatrix, lineMatrix)
                graphics.ctm = matrix.concatenating(graphics.ctm)
                depth += 1
                let form = CGPDFContentStreamCreateWithStream(xobject, resources ?? CGPDFStreamGetDictionary(xobject)!, stream)
                let table = CGPDFOperatorTableCreate()!
                ScanState.register(table)
                scan(form, table: table)
                CGPDFContentStreamRelease(form)
                depth -= 1
                (graphics, stack, textMatrix, lineMatrix) = saved
            default:
                break
            }
        }

        /// Widths of a font resource of the current content stream (cached per name and stream).
        func font(_ name: String) -> FontInfo? {
            guard let stream = streams.last else { return nil }
            let key = "\(UInt(bitPattern: Unmanaged.passUnretained(stream as AnyObject).toOpaque().hashValue)):\(name)"
            if let cached = fonts[key] { return cached }
            guard let object = CGPDFContentStreamGetResource(stream, "Font", name) else { return nil }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            var info: FontInfo
            if let subtype, String(cString: subtype) == "Type0" {
                info = FontInfo(twoByte: true, defaultWidth: 1000)
                var descendants: CGPDFArrayRef?
                var cid: CGPDFDictionaryRef?
                if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
                   CGPDFArrayGetDictionary(descendants, 0, &cid), let cid {
                    var dw: CGPDFReal = 1000
                    if CGPDFDictionaryGetNumber(cid, "DW", &dw) { info.defaultWidth = dw }
                    var w: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(cid, "W", &w), let w { info.cidWidths = Self.cidWidths(w) }
                }
            } else {
                info = FontInfo(twoByte: false)
                var first: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dictionary, "FirstChar", &first)
                info.firstChar = first
                var widths: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Widths", &widths), let widths {
                    info.widths = (0..<CGPDFArrayGetCount(widths)).map { i in
                        var value: CGPDFReal = 0
                        CGPDFArrayGetNumber(widths, i, &value)
                        return value
                    }
                }
                // Standard 14 fonts come without widths: about half an em per letter.
                info.defaultWidth = 500
            }
            fonts[key] = info
            return info
        }

        /// A CID font's W array: [c [w1 w2 …]] and [cFirst cLast w] entries.
        static func cidWidths(_ array: CGPDFArrayRef) -> [Int: CGFloat] {
            var result: [Int: CGFloat] = [:]
            var i = 0
            let count = CGPDFArrayGetCount(array)
            while i < count {
                var first: CGPDFInteger = 0
                guard CGPDFArrayGetInteger(array, i, &first) else { break }
                var list: CGPDFArrayRef?
                if CGPDFArrayGetArray(array, i + 1, &list), let list {
                    for k in 0..<CGPDFArrayGetCount(list) {
                        var width: CGPDFReal = 0
                        if CGPDFArrayGetNumber(list, k, &width) { result[first + k] = width }
                    }
                    i += 2
                } else {
                    var last: CGPDFInteger = 0
                    var width: CGPDFReal = 0
                    guard CGPDFArrayGetInteger(array, i + 1, &last), CGPDFArrayGetNumber(array, i + 2, &width), last >= first, last - first < 65536 else { break }
                    for code in first...last { result[code] = width }
                    i += 3
                }
            }
            return result
        }
    }
}

extension PdfDocumentReader.ScanState.FontInfo {
    /// Width of a glyph in thousandths of the font size.
    func width(_ code: Int) -> CGFloat {
        if twoByte { return cidWidths[code] ?? defaultWidth }
        let index = code - firstChar
        return index >= 0 && index < widths.count ? widths[index] : defaultWidth
    }
}
