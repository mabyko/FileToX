// What PdfDocumentReader took from PdfPig, from PDFKit and Core Graphics: the letters of a page (PDFKit's text with
// glyph boxes, fonts and fill colours; baselines from the fonts' glyph metrics), grouped into words, and a content
// stream scan (CGPDFScanner) for what PDFKit doesn't tell: the text rendering mode (invisible OCR text, fill-then-
// stroke bold, rotated text), the image XObjects with their placement and data, and whether all text was shown in one
// state (then one character's attributes stand for all of them).

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
        guard let text = page.string, let attributed = attributedString(page, text, scan) else { return [] }
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
            if isBlank(character) {
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

    private static func isBlank(_ character: String) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0 }
    }

    /// The page's attributed string. When all text was shown in one state, the first letter's attributes stand for the
    /// whole string: PDFKit derives them from that state, and building its own costs a font and an attribute
    /// dictionary per character (most of the time of PDF → TXT).
    private static func attributedString(_ page: PDFPage, _ text: String, _ scan: ContentScan) -> NSAttributedString? {
        let string = text as NSString
        if scan.uniformText && page.annotations.allSatisfy({ $0.type == "Link" }) {
            var index = 0
            while index < string.length {
                let range = string.rangeOfComposedCharacterSequence(at: index)
                index = range.location + range.length
                if isBlank(string.substring(with: range)) { continue }
                guard let letter = page.selection(for: range)?.attributedString, letter.length > 0 else { break }
                return NSAttributedString(string: text, attributes: letter.attributes(at: 0, effectiveRange: nil))
            }
        }
        return attributedStringLock.withLock { page.attributedString }
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

        /// What PDFKit's character attributes come from: the font, its size and matrices, the rendering mode and colours.
        struct TextState: Equatable {
            var font: CGPDFDictionaryRef
            var size, scaling, rise: CGFloat
            var mode: Int
            var matrix, ctm: CGAffineTransform // linear parts
            var fill, stroke: ScanState.Paint
        }

        var runs: [TextRun] = []
        var images: [PlacedImage] = []
        /// The state of the text shown so far, while all of it was shown in one.
        var textState: TextState?
        /// Text was shown in more than one state, or where the scan can't tell (a Type 3 font, replacement text, ...).
        var mixedText = false

        /// All text of the page was shown in one state.
        var uniformText: Bool { textState != nil && !mixedText }

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
            var fontDictionary: CGPDFDictionaryRef?
            var fill = Paint(space: "DeviceGray", components: [0])
            var stroke = Paint(space: "DeviceGray", components: [0])
        }

        /// A fill or stroke colour: its colour space (a device space, or a named one with the resource it stands for)
        /// and the components set in it.
        struct Paint: Equatable {
            var space: String
            var resource: CGPDFObjectRef?
            var components: [CGFloat]
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
                let s = PdfDocumentReader.ScanState.state(info)
                guard let v = PdfDocumentReader.ScanState.numbers(scanner, 6) else { s.result.mixedText = true; return }
                s.graphics.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.graphics.ctm)
            }
            CGPDFOperatorTableSetCallback(table, "BT") { _, info in let s = PdfDocumentReader.ScanState.state(info); s.textMatrix = .identity; s.lineMatrix = .identity }
            CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
                let s = PdfDocumentReader.ScanState.state(info)
                var size: CGPDFReal = 0
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { s.result.mixedText = true; return }
                s.graphics.fontSize = size
                s.graphics.font = s.font(String(cString: name))
                s.graphics.fontDictionary = s.fontDictionary(String(cString: name))
            }
            CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.characterSpacing = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.wordSpacing = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in PdfDocumentReader.ScanState.state(info).setNumber(scanner) { $0.horizontalScaling = $1 / 100 } }
            CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 1) { PdfDocumentReader.ScanState.state(info).graphics.leading = v[0] } }
            CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in PdfDocumentReader.ScanState.state(info).setNumber(scanner) { $0.rise = $1 } }
            CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in PdfDocumentReader.ScanState.state(info).setNumber(scanner) { $0.mode = Int($1) } }
            CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in if let v = PdfDocumentReader.ScanState.numbers(scanner, 2) { PdfDocumentReader.ScanState.state(info).moveLine(v[0], v[1]) } }
            CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
                guard let v = PdfDocumentReader.ScanState.numbers(scanner, 2) else { return }
                let s = PdfDocumentReader.ScanState.state(info)
                s.graphics.leading = -v[1]
                s.moveLine(v[0], v[1])
            }
            CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
                let s = PdfDocumentReader.ScanState.state(info)
                guard let v = PdfDocumentReader.ScanState.numbers(scanner, 6) else { s.result.mixedText = true; return }
                s.textMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                s.lineMatrix = s.textMatrix
            }
            CGPDFOperatorTableSetCallback(table, "T*") { _, info in let s = PdfDocumentReader.ScanState.state(info); s.moveLine(0, -s.graphics.leading) }
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
                var string: CGPDFStringRef?
                let s = PdfDocumentReader.ScanState.state(info)
                if CGPDFScannerPopString(scanner, &string), let string { s.show(string) } else { s.result.mixedText = true }
            }
            CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
                var string: CGPDFStringRef?
                let s = PdfDocumentReader.ScanState.state(info)
                s.moveLine(0, -s.graphics.leading)
                if CGPDFScannerPopString(scanner, &string), let string { s.show(string) } else { s.result.mixedText = true }
            }
            CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
                var string: CGPDFStringRef?
                let s = PdfDocumentReader.ScanState.state(info)
                guard CGPDFScannerPopString(scanner, &string), let string, let v = PdfDocumentReader.ScanState.numbers(scanner, 2) else {
                    s.result.mixedText = true
                    return
                }
                (s.graphics.wordSpacing, s.graphics.characterSpacing) = (v[0], v[1])
                s.moveLine(0, -s.graphics.leading)
                s.show(string)
            }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
                var array: CGPDFArrayRef?
                let s = PdfDocumentReader.ScanState.state(info)
                guard CGPDFScannerPopArray(scanner, &array), let array else { s.result.mixedText = true; return }
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
            CGPDFOperatorTableSetCallback(table, "g") { scanner, info in PdfDocumentReader.ScanState.state(info).setColor(scanner, "DeviceGray", 1, stroke: false) }
            CGPDFOperatorTableSetCallback(table, "G") { scanner, info in PdfDocumentReader.ScanState.state(info).setColor(scanner, "DeviceGray", 1, stroke: true) }
            CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in PdfDocumentReader.ScanState.state(info).setColor(scanner, "DeviceRGB", 3, stroke: false) }
            CGPDFOperatorTableSetCallback(table, "RG") { scanner, info in PdfDocumentReader.ScanState.state(info).setColor(scanner, "DeviceRGB", 3, stroke: true) }
            CGPDFOperatorTableSetCallback(table, "k") { scanner, info in PdfDocumentReader.ScanState.state(info).setColor(scanner, "DeviceCMYK", 4, stroke: false) }
            CGPDFOperatorTableSetCallback(table, "K") { scanner, info in PdfDocumentReader.ScanState.state(info).setColor(scanner, "DeviceCMYK", 4, stroke: true) }
            CGPDFOperatorTableSetCallback(table, "sc") { scanner, info in PdfDocumentReader.ScanState.state(info).setComponents(scanner, stroke: false) }
            CGPDFOperatorTableSetCallback(table, "scn") { scanner, info in PdfDocumentReader.ScanState.state(info).setComponents(scanner, stroke: false) }
            CGPDFOperatorTableSetCallback(table, "SC") { scanner, info in PdfDocumentReader.ScanState.state(info).setComponents(scanner, stroke: true) }
            CGPDFOperatorTableSetCallback(table, "SCN") { scanner, info in PdfDocumentReader.ScanState.state(info).setComponents(scanner, stroke: true) }
            CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in PdfDocumentReader.ScanState.state(info).setColorSpace(scanner, stroke: false) }
            CGPDFOperatorTableSetCallback(table, "CS") { scanner, info in PdfDocumentReader.ScanState.state(info).setColorSpace(scanner, stroke: true) }
            CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in PdfDocumentReader.ScanState.state(info).setGraphicsState(scanner) }
            CGPDFOperatorTableSetCallback(table, "BDC") { scanner, info in PdfDocumentReader.ScanState.state(info).beginMarkedContent(scanner) }
        }

        /// Tz, Ts, Tr: one number; one that can't be read leaves the text state unknown.
        func setNumber(_ scanner: CGPDFScannerRef, _ apply: (inout Graphics, CGFloat) -> Void) {
            guard let v = Self.numbers(scanner, 1) else { result.mixedText = true; return }
            apply(&graphics, v[0])
        }

        /// g, rg, k (and G, RG, K): a device colour space with its components.
        func setColor(_ scanner: CGPDFScannerRef, _ space: String, _ count: Int, stroke: Bool) {
            guard let components = Self.numbers(scanner, count) else { result.mixedText = true; return }
            let paint = Paint(space: space, resource: nil, components: components)
            if stroke { graphics.stroke = paint } else { graphics.fill = paint }
        }

        /// sc, scn (and SC, SCN): components in the current colour space; a pattern (a name) is a colour the scan doesn't follow.
        func setComponents(_ scanner: CGPDFScannerRef, stroke: Bool) {
            var components: [CGFloat] = []
            var object: CGPDFObjectRef?
            while CGPDFScannerPopObject(scanner, &object), let object {
                var value: CGPDFReal = 0
                guard CGPDFObjectGetValue(object, .real, &value) else { result.mixedText = true; return }
                components.insert(value, at: 0)
            }
            if stroke { graphics.stroke.components = components } else { graphics.fill.components = components }
        }

        /// cs, CS: a colour space by name, a device space or a resource (with the space's initial colour until components are set).
        func setColorSpace(_ scanner: CGPDFScannerRef, stroke: Bool) {
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { result.mixedText = true; return }
            var paint = Paint(space: String(cString: name), resource: nil, components: [])
            if !["DeviceGray", "DeviceRGB", "DeviceCMYK", "Pattern"].contains(paint.space) {
                paint.resource = streams.last.flatMap { CGPDFContentStreamGetResource($0, "ColorSpace", paint.space) }
                if paint.resource == nil { result.mixedText = true }
            }
            if stroke { graphics.stroke = paint } else { graphics.fill = paint }
        }

        /// gs: a font set through the graphics state, or a soft mask (content of its own), is text the scan doesn't follow.
        func setGraphicsState(_ scanner: CGPDFScannerRef) {
            var name: UnsafePointer<CChar>?
            var state: CGPDFDictionaryRef?
            var font: CGPDFArrayRef?
            var mask: CGPDFDictionaryRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = streams.last.flatMap({ CGPDFContentStreamGetResource($0, "ExtGState", String(cString: name)) }),
                  CGPDFObjectGetValue(object, .dictionary, &state), let state,
                  !CGPDFDictionaryGetArray(state, "Font", &font), !CGPDFDictionaryGetDictionary(state, "SMask", &mask) else {
                result.mixedText = true
                return
            }
        }

        /// BDC: replacement text (ActualText, an abbreviation's expansion) may stand for the glyphs shown.
        func beginMarkedContent(_ scanner: CGPDFScannerRef) {
            var object: CGPDFObjectRef?
            var name: UnsafePointer<CChar>?
            var properties: CGPDFDictionaryRef?
            var text: CGPDFStringRef?
            guard CGPDFScannerPopObject(scanner, &object), let object else { result.mixedText = true; return }
            if CGPDFObjectGetValue(object, .name, &name), let name {
                guard let resource = streams.last.flatMap({ CGPDFContentStreamGetResource($0, "Properties", String(cString: name)) }),
                      CGPDFObjectGetValue(resource, .dictionary, &properties) else { result.mixedText = true; return }
            } else {
                CGPDFObjectGetValue(object, .dictionary, &properties)
            }
            if let properties, CGPDFDictionaryGetString(properties, "ActualText", &text) || CGPDFDictionaryGetString(properties, "E", &text) {
                result.mixedText = true
            }
        }

        /// Keeps the state text is shown in while it stays the same.
        func noteTextState() {
            if result.mixedText { return }
            guard let dictionary = graphics.fontDictionary else { result.mixedText = true; return }
            func linear(_ m: CGAffineTransform) -> CGAffineTransform { CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0) }
            let state = ContentScan.TextState(font: dictionary, size: graphics.fontSize, scaling: graphics.horizontalScaling, rise: graphics.rise,
                                              mode: graphics.mode, matrix: linear(textMatrix), ctm: linear(graphics.ctm),
                                              fill: graphics.fill, stroke: graphics.stroke)
            if result.textState == nil { result.textState = state } else if result.textState != state { result.mixedText = true }
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
            noteTextState()
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
            var xobject: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            guard let object = CGPDFContentStreamGetResource(stream, "XObject", name), CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject), CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else {
                result.mixedText = true // whatever it draws is unknown
                return
            }
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
            case "Form":
                result.mixedText = true // too deep to follow
            default:
                break
            }
        }

        /// A font resource of the current content stream, for whether all text was shown in one font; the glyphs of a Type 3
        /// font are content the scan doesn't follow.
        func fontDictionary(_ name: String) -> CGPDFDictionaryRef? {
            var dictionary: CGPDFDictionaryRef?
            var subtype: UnsafePointer<CChar>?
            guard let object = streams.last.flatMap({ CGPDFContentStreamGetResource($0, "Font", name) }),
                  CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
            if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Type3" { result.mixedText = true }
            return dictionary
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
