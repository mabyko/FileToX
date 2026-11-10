// PDFtoImage 5.2.1's PdfFile / PdfDocument call sequence, without the managed/Skia wrappers.
import CPDFium
import CoreGraphics
import Foundation

/// All PDFium entry points, including lifetime operations, share this lock across every conversion route.
final class PdfiumDocument {
    static let version = "PDFium 147.0.7690.0"
    private static let lock = NSLock()
    private static let initialized: Void = FPDF_InitLibrary()

    private let bytes: NSData // FPDF_LoadMemDocument64 borrows these bytes until CloseDocument.
    private let document: FPDF_DOCUMENT
    private let form: FPDF_FORMHANDLE
    private let formInfo: UnsafeMutablePointer<FPDF_FORMFILLINFO>
    let pageCount: Int

    init(_ path: String, unreadableMessage: String? = nil) throws {
        let cannotRead = unreadableMessage ?? "\(FilePath.fileName(path)) is not a PDF file that can be read."
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw ConversionError(cannotRead) }
        bytes = data as NSData
        Self.lock.lock()
        defer { Self.lock.unlock() }
        _ = Self.initialized
        guard let loaded = FPDF_LoadMemDocument64(bytes.bytes, bytes.length, nil) else {
            if FPDF_GetLastError() == FPDF_ERR_PASSWORD {
                throw ConversionError("The PDF is password-protected. Open it with its password and save a copy without one, then convert that copy.")
            }
            throw ConversionError(cannotRead)
        }
        let info = UnsafeMutablePointer<FPDF_FORMFILLINFO>.allocate(capacity: 1)
        info.initialize(to: FPDF_FORMFILLINFO())
        info.pointee.version = 1 // PDFtoImage supplies no callbacks, JavaScript or XFA.
        guard let environment = FPDFDOC_InitFormFillEnvironment(loaded, info) else {
            info.deinitialize(count: 1)
            info.deallocate()
            FPDF_CloseDocument(loaded)
            throw ConversionError("The page could not be rendered.")
        }
        document = loaded
        form = environment
        formInfo = info
        pageCount = Int(FPDF_GetPageCount(loaded))
        FPDF_SetFormFieldHighlightColor(form, 0, 0xFFE4DD)
        FPDF_SetFormFieldHighlightAlpha(form, 100)
    }

    deinit {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        FPDFDOC_ExitFormFillEnvironment(form)
        FPDF_CloseDocument(document)
        formInfo.deinitialize(count: 1)
        formInfo.deallocate()
    }

    /// PDFium resolves crop/media box intersection and intrinsic page rotation itself.
    func pageSize(_ index: Int) throws -> CGSize {
        try Self.lock.withLock { try sizeUnlocked(index) }
    }

    private func sizeUnlocked(_ index: Int) throws -> CGSize {
        guard index >= 0, index < pageCount else { throw ConversionError("The page could not be rendered.") }
        var width = 0.0, height = 0.0
        guard FPDF_GetPageSizeByIndex(document, Int32(index), &width, &height) != 0 else {
            throw ConversionError("The page could not be rendered.")
        }
        return CGSize(width: width, height: height)
    }

    /// A word text extraction keeps: where it shows it (page space) and its text.
    typealias Word = (bounds: CGRect, text: String)

    /// Whether text extraction leaves out visible text of the page (rendered without the text it keeps, see `keptText`, the
    /// page still shows some), given the words it keeps.
    func textLeftOut(_ index: Int, keeping words: [Word]) throws -> Bool {
        try Self.lock.withLock {
            try Task.checkCancellation()
            guard index >= 0, index < pageCount, let page = FPDF_LoadPage(document, Int32(index)) else { throw ConversionError("The page could not be rendered.") }
            defer { FPDF_ClosePage(page) }
            return Self.keptText(page, words).leftOut
        }
    }

    /// `withoutTextAt` leaves out the page's text (also the text inside forms) that text extraction keeps, given the words
    /// it keeps (see `keptText`): the text it leaves out stays, of an object it keeps only in part just the glyphs it leaves
    /// out. `withoutImagesAt` leaves out the images drawn at these boxes (page space).
    func render(_ index: Int, dpi: Int, withoutTextAt words: [Word]? = nil, withoutImagesAt images: [CGRect] = []) throws -> CGImage {
        try Self.lock.withLock {
            try Task.checkCancellation()
            let size = try sizeUnlocked(index)
            let scale = Float(dpi) / 72
            let w = Float(size.width) * scale, h = Float(size.height) * scale
            guard w.isFinite, h.isFinite, w > 0, h > 0, w < Float(Int32.max / 4), h < Float(Int32.max) else {
                throw ConversionError("The page could not be rendered.")
            }
            let width = max(1, Int(w)), height = max(1, Int(h))
            guard width * height <= Int32.max / 4,
                  let bitmap = FPDFBitmap_CreateEx(Int32(width), Int32(height), FPDFBitmap_BGRA, nil, Int32(width * 4)) else {
                throw ConversionError("The page is too large to render (\(width) × \(height) pixels).")
            }
            defer { FPDFBitmap_Destroy(bitmap) }
            guard let page = FPDF_LoadPage(document, Int32(index)) else { throw ConversionError("The page could not be rendered.") }
            // Before the text page: removing text objects invalidates it. Only this loaded copy changes.
            let kept = words.map { Self.keptText(page, $0) }
            if kept != nil || !images.isEmpty { Self.remove(page, nil, (kept?.kept ?? []).union(Self.images(page, at: images))) }
            let text = kept == nil ? FPDFText_LoadPage(page) : nil
            FORM_OnAfterLoadPage(page, form)
            defer {
                FORM_OnBeforeClosePage(page, form)
                if let text { FPDFText_ClosePage(text) }
                FPDF_ClosePage(page)
            }
            // Bitmap dimensions truncate; the drawing rectangle uses Ceiling, even with no explicit Bounds.
            let drawWidth = Int32(ceil(w)), drawHeight = Int32(ceil(h))
            func draw() {
                FPDFBitmap_FillRect(bitmap, 0, 0, Int32(width), Int32(height), 0xFFFFFFFF)
                FPDF_RenderPageBitmap(bitmap, page, 0, 0, drawWidth, drawHeight, 0, FPDF_ANNOT)
                FPDF_RemoveFormFieldHighlight(form)
                FPDF_FFLDraw(form, bitmap, page, 0, 0, drawWidth, drawHeight, 0, FPDF_ANNOT)
            }
            draw()
            guard let buffer = FPDFBitmap_GetBuffer(bitmap) else { throw ConversionError("The page could not be rendered.") }
            let stride = Int(FPDFBitmap_GetStride(bitmap))
            if let kept, !kept.partly.isEmpty {
                // Objects kept in part: what they show outside their kept glyphs, from this rendering; the rest of the page
                // from one without them.
                let bytes = buffer.assumingMemoryBound(to: UInt8.self)
                func pixels(_ box: CGRect, by pad: Int) -> (columns: Range<Int>, rows: Range<Int>) {
                    var x0: Int32 = 0, y0: Int32 = 0, x1: Int32 = 0, y1: Int32 = 0
                    FPDF_PageToDevice(page, 0, 0, drawWidth, drawHeight, 0, Double(box.minX), Double(box.minY), &x0, &y0)
                    FPDF_PageToDevice(page, 0, 0, drawWidth, drawHeight, 0, Double(box.maxX), Double(box.maxY), &x1, &y1)
                    let left = max(0, Int(min(x0, x1)) - pad), right = max(left, min(width, Int(max(x0, x1)) + pad))
                    let top = max(0, Int(min(y0, y1)) - pad), bottom = max(top, min(height, Int(max(y0, y1)) + pad))
                    return (left..<right, top..<bottom)
                }
                func copy(_ area: (columns: Range<Int>, rows: Range<Int>)) -> [UInt8] {
                    area.rows.flatMap { Array(UnsafeBufferPointer(start: bytes + $0 * stride + area.columns.lowerBound * 4, count: area.columns.count * 4)) }
                }
                // Device pixels to the page (PDFium maps them affinely), for glyphs with a frame of their own.
                var x0 = 0.0, y0 = 0.0, x1 = 0.0, y1 = 0.0, x2 = 0.0, y2 = 0.0
                FPDF_DeviceToPage(page, 0, 0, drawWidth, drawHeight, 0, 0, 0, &x0, &y0)
                FPDF_DeviceToPage(page, 0, 0, drawWidth, drawHeight, 0, drawWidth, 0, &x1, &y1)
                FPDF_DeviceToPage(page, 0, 0, drawWidth, drawHeight, 0, 0, drawHeight, &x2, &y2)
                let toPage = CGAffineTransform(a: (x1 - x0) / Double(drawWidth), b: (y1 - y0) / Double(drawWidth),
                                               c: (x2 - x0) / Double(drawHeight), d: (y2 - y0) / Double(drawHeight), tx: x0, ty: y0)
                /// `inside`: only the pixels in that box of the glyph's frame (and a pixel around it).
                func paste(_ saved: [UInt8], _ area: (columns: Range<Int>, rows: Range<Int>), inside frame: Frame? = nil) {
                    let count = area.columns.count * 4
                    saved.withUnsafeBufferPointer { saved in
                        guard let frame else {
                            for (i, row) in area.rows.enumerated() { (bytes + row * stride + area.columns.lowerBound * 4).update(from: saved.baseAddress! + i * count, count: count) }
                            return
                        }
                        let toText = toPage.concatenating(frame.toText)
                        let pad = max(hypot(toText.a, toText.b), hypot(toText.c, toText.d))
                        let box = frame.rect.insetBy(dx: -pad, dy: -pad)
                        for (i, row) in area.rows.enumerated() {
                            for (j, column) in area.columns.enumerated() where box.contains(CGPoint(x: Double(column) + 0.5, y: Double(row) + 0.5).applying(toText)) {
                                (bytes + row * stride + column * 4).update(from: saved.baseAddress! + i * count + j * 4, count: 4)
                            }
                        }
                    }
                }
                let shown = kept.partly.values.map { object in (area: pixels(object.bounds, by: 1), kept: object.kept.map { (area: pixels($0.box, by: 1), frame: $0.frame) }) }
                let objects = shown.map { copy($0.area) }
                let ink = kept.partly.values.flatMap { $0.left.map { (area: pixels($0.box, by: 1), frame: $0.frame) } }
                let glyphs = ink.map { copy($0.area) }
                Self.remove(page, nil, Set(kept.partly.keys))
                draw()
                // Under the kept glyphs (also those of another object kept in part) stays what is under them.
                let beneath = shown.map { $0.kept.map { copy($0.area) } }
                for (object, saved) in zip(shown, objects) { paste(saved, object.area) }
                for (object, saved) in zip(shown, beneath) { for (glyph, pixels) in zip(object.kept, saved) { paste(pixels, glyph.area, inside: glyph.frame) } }
                for (glyph, saved) in zip(ink, glyphs) { paste(saved, glyph.area, inside: glyph.frame) } // the glyphs left out stay whole
            }
            try Task.checkCancellation()
            let pixels = Data(bytes: buffer, count: stride * height)
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw ConversionError("The page could not be rendered.")
            }
            return image
        }
    }

    /// Removes these objects from a loaded page (`form` nil) or from a form object on it, and from the forms inside.
    private static func remove(_ page: FPDF_PAGE, _ form: FPDF_PAGEOBJECT?, _ objects: Set<FPDF_PAGEOBJECT>) {
        let count = form == nil ? Int(FPDFPage_CountObjects(page)) : Int(FPDFFormObj_CountObjects(form))
        for index in stride(from: count - 1, through: 0, by: -1) {
            guard let object = form == nil ? FPDFPage_GetObject(page, Int32(index)) : FPDFFormObj_GetObject(form, UInt(index)) else { continue }
            if objects.contains(object) {
                let removed = form == nil ? FPDFPage_RemoveObject(page, object) : FPDFFormObj_RemoveObject(form, object)
                if removed != 0 { FPDFPageObj_Destroy(object) }
            } else if FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM {
                remove(page, object, objects)
            }
        }
    }

    /// Visits each object of a loaded page and of the forms on it, with the matrix from the space it is in to the page's.
    private static func walk(_ page: FPDF_PAGE, _ form: FPDF_PAGEOBJECT? = nil, _ toPage: CGAffineTransform = .identity,
                             _ visit: (FPDF_PAGEOBJECT, CGAffineTransform) -> Void) {
        let count = form == nil ? Int(FPDFPage_CountObjects(page)) : Int(FPDFFormObj_CountObjects(form))
        for index in 0..<max(0, count) {
            guard let object = form == nil ? FPDFPage_GetObject(page, Int32(index)) : FPDFFormObj_GetObject(form, UInt(index)) else { continue }
            visit(object, toPage)
            var matrix = FS_MATRIX()
            if FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM {
                walk(page, object, FPDFPageObj_GetMatrix(object, &matrix) != 0 ? transform(matrix).concatenating(toPage) : toPage, visit)
            }
        }
    }

    private static func transform(_ m: FS_MATRIX) -> CGAffineTransform {
        CGAffineTransform(a: CGFloat(m.a), b: CGFloat(m.b), c: CGFloat(m.c), d: CGFloat(m.d), tx: CGFloat(m.e), ty: CGFloat(m.f))
    }

    /// The image objects of a loaded page (in forms too) drawn at one of these boxes (page space, to half a point).
    private static func images(_ page: FPDF_PAGE, at boxes: [CGRect]) -> Set<FPDF_PAGEOBJECT> {
        var found = Set<FPDF_PAGEOBJECT>()
        guard !boxes.isEmpty else { return found }
        walk(page) { object, toPage in
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_IMAGE, FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0 else { return }
            let box = CGRect(x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left), height: CGFloat(top - bottom)).applying(toPage)
            if boxes.contains(where: { max(abs($0.minX - box.minX), abs($0.minY - box.minY), abs($0.maxX - box.maxX), abs($0.maxY - box.maxY)) < 0.5 }) {
                found.insert(object)
            }
        }
        return found
    }

    /// A box in a glyph's own frame (text space) and the matrix from the page to that frame.
    private typealias Frame = (rect: CGRect, toText: CGAffineTransform)

    /// Where a glyph is: a box on the page and, for turned or slanted text, the box in the glyph's frame it is within.
    private struct Place {
        var box: CGRect
        var frame: Frame?
    }

    /// A glyph's loose box, no further than the ink of its show (`ink`: the corners of its box), so it doesn't reach a close
    /// line; for turned or slanted text that box in its frame too: from its origin over its advance, the font's box high
    /// (PDFium's loose box is that rectangle's box on the page), cut to the show's ink. Not when the page box is no such
    /// box: ink past the advance widens it.
    private static func place(_ loose: CGRect, _ matrix: CGAffineTransform, _ origin: CGPoint, within ink: [CGPoint]) -> Place {
        let shown = ink.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.intersection(loose)
        let (a, b, c, d) = (abs(matrix.a), abs(matrix.b), abs(matrix.c), abs(matrix.d))
        guard b > 1e-6 * a || c > 1e-6 * d, a > 1e-6 * b || d > 1e-6 * c, abs(matrix.a * matrix.d - matrix.b * matrix.c) > 1e-12 else {
            return Place(box: shown.isNull ? loose : shown) // upright or turned by a right angle: the page box is the box
        }
        let toText = matrix.inverted()
        let center = CGPoint(x: loose.midX, y: loose.midY).applying(toText), start = origin.applying(toText).x
        let width = 2 * (center.x - start)
        let height = d >= c ? (loose.height - b * width) / d : (loose.width - a * width) / c
        let rect = CGRect(x: start, y: center.y - height / 2, width: width, height: height), back = rect.applying(matrix)
        guard width > 0, height > 0, max(abs(back.minX - loose.minX), abs(back.minY - loose.minY), abs(back.maxX - loose.maxX),
                                         abs(back.maxY - loose.maxY)) <= 0.01 * max(loose.width, loose.height) else { return Place(box: loose) }
        let heights = ink.map { $0.applying(toText).y }
        guard let low = heights.min(), let high = heights.max(), low < rect.maxY, high > rect.minY else { return Place(box: loose, frame: (rect, toText)) }
        return Place(box: loose, frame: (CGRect(x: rect.minX, y: max(low, rect.minY), width: rect.width, height: min(high, rect.maxY) - max(low, rect.minY)), toText))
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        [.nonspacingMark, .spacingMark, .enclosingMark].contains(scalar.properties.generalCategory)
    }

    /// A text's letters, to compare glyphs with words: its characters without marks after compatibility decomposition
    /// (é is e, ﬁ f i).
    private static func letters(_ text: String) -> [Unicode.Scalar] {
        (text.unicodeScalars.allSatisfy(\.isASCII) ? text : text.decomposedStringWithCompatibilityMapping).unicodeScalars.filter { !isMark($0) }
    }

    /// The text objects of a loaded page (in forms too) that text extraction keeps, given the words it keeps; those it
    /// keeps in part with their bounds and the places of their glyphs it keeps and leaves out (PDFium's text page doesn't
    /// read every glyph: a closing blank, say); and whether it leaves out any visible text. A glyph PDFium reads is kept
    /// when a word's box holds its loose box's centre (or, in no box, that centre turned back by the glyph's angle: PDFKit
    /// may give turned text in that frame). One it reads as no letter (no Unicode, or white space: with ink, it's no blank)
    /// only while such a word has letters, or combining marks of its own, no glyph reads as (PDFKit read it another way):
    /// so a glyph without text drawn over a word, or a blank with ink amid turned words (whose boxes reach over their
    /// neighbours), stays. An object is kept when all its glyphs with ink (combining marks aside) are; invisible text
    /// (modes 3 and 7) always is. One PDFium reads no glyph of (shown twice in one place) or reads as its ActualText is
    /// kept when words cover half its bounds.
    private static func keptText(_ page: FPDF_PAGE, _ words: [Word])
        -> (kept: Set<FPDF_PAGEOBJECT>, partly: [FPDF_PAGEOBJECT: (bounds: CGRect, kept: [Place], left: [Place])], leftOut: Bool) {
        let words = words.filter { !$0.bounds.isNull && abs($0.bounds.minY) < 1e12 && abs($0.bounds.maxY) < 1e12 && $0.bounds.height < 100_000 }
            .map { (bounds: $0.bounds.insetBy(dx: -0.5, dy: -0.5), text: $0.text) }
        var bands: [Int: [Int]] = [:] // the words by 8-point bands of the page's height
        for (index, word) in words.enumerated() {
            for band in Int((word.bounds.minY / 8).rounded(.down))...Int((word.bounds.maxY / 8).rounded(.down)) { bands[band, default: []].append(index) }
        }
        func band(_ point: CGPoint) -> [Int] { abs(point.y) < 1e12 ? bands[Int((point.y / 8).rounded(.down))] ?? [] : [] }
        /// The words whose box holds a glyph's loose box's centre, or in none that centre turned back by the glyph's angle.
        func shown(_ box: CGRect, turnedBy angle: CGFloat) -> (words: [Int], turned: Bool) {
            let center = CGPoint(x: box.midX, y: box.midY), found = band(center).filter { words[$0].bounds.contains(center) }
            guard found.isEmpty, angle != 0 else { return (found, false) }
            let back = center.applying(CGAffineTransform(rotationAngle: -angle))
            return (band(back).filter { words[$0].bounds.contains(back) }, true)
        }
        func isShown(_ box: CGRect, turnedBy angle: CGFloat) -> Bool {
            let center = CGPoint(x: box.midX, y: box.midY), back = center.applying(CGAffineTransform(rotationAngle: -angle))
            return band(center).contains { words[$0].bounds.contains(center) } || (angle != 0 && band(back).contains { words[$0].bounds.contains(back) })
        }
        func covered(_ bounds: CGRect, turnedBy angle: CGFloat) -> Bool {
            func covered(_ bounds: CGRect) -> Bool {
                words.reduce(0) { area, word in let common = bounds.intersection(word.bounds); return area + (common.isNull ? 0 : common.width * common.height) }
                    >= bounds.width * bounds.height / 2
            }
            return covered(bounds) || (angle != 0 && covered(bounds.applying(CGAffineTransform(rotationAngle: -angle))))
        }
        var kept = Set<FPDF_PAGEOBJECT>()
        var visible: [FPDF_PAGEOBJECT: (bounds: CGRect, angle: CGFloat, ink: [CGPoint])] = [:] // on the page
        var replaced = Set<FPDF_PAGEOBJECT>()
        walk(page) { object, toPage in
            guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT else { return }
            let mode = FPDFTextObj_GetTextRenderMode(object)
            if mode == FPDF_TEXTRENDERMODE_INVISIBLE || mode == FPDF_TEXTRENDERMODE_CLIP {
                kept.insert(object)
                return
            }
            var matrix = FS_MATRIX()
            let own = FPDFPageObj_GetMatrix(object, &matrix) != 0 ? transform(matrix).concatenating(toPage) : toPage
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top)
            let bounds = CGRect(x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left), height: CGFloat(top - bottom))
            // The glyphs' box (not for stroked text: the stroke reaches past it).
            var quad = FS_QUADPOINTSF()
            let stroked = [FPDF_TEXTRENDERMODE_STROKE, FPDF_TEXTRENDERMODE_FILL_STROKE, FPDF_TEXTRENDERMODE_STROKE_CLIP, FPDF_TEXTRENDERMODE_FILL_STROKE_CLIP].contains(mode)
            let ink = stroked || FPDFPageObj_GetRotatedBounds(object, &quad) == 0 ? []
                : [(quad.x1, quad.y1), (quad.x2, quad.y2), (quad.x3, quad.y3), (quad.x4, quad.y4)].map { CGPoint(x: CGFloat($0.0), y: CGFloat($0.1)).applying(toPage) }
            visible[object] = (bounds.applying(toPage), atan2(own.b, own.a), ink)
            if (0..<max(0, Int(FPDFPageObj_CountMarks(object)))).contains(where: {
                FPDFPageObjMark_GetParamValueType(FPDFPageObj_GetMark(object, UInt($0)), "ActualText") != FPDF_OBJECT_UNKNOWN
            }) { replaced.insert(object) }
        }
        var read: [FPDF_PAGEOBJECT: CGRect] = [:] // where the glyphs PDFium reads are
        var letter: [Unicode.Scalar: [Unicode.Scalar]] = [:] // the letters each character reads as (white space none)
        var marks: [(box: CGRect, angle: CGFloat)] = [] // the combining marks PDFium reads in words
        var found: [(object: FPDF_PAGEOBJECT, loose: Place, ink: Place, letters: [Unicode.Scalar], box: CGRect, angle: CGFloat, shown: Bool)] = [] // with ink
        if let text = FPDFText_LoadPage(page) {
            for index in 0..<max(0, FPDFText_CountChars(text)) {
                guard FPDFText_IsGenerated(text, index) == 0, let object = FPDFText_GetTextObject(text, index), let shape = visible[object],
                      !replaced.contains(object) else { continue }
                var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0, x = 0.0, y = 0.0
                var loose = FS_RECTF(), matrix = FS_MATRIX()
                guard FPDFText_GetCharBox(text, index, &left, &right, &bottom, &top) != 0, FPDFText_GetLooseCharBox(text, index, &loose) != 0,
                      FPDFText_GetMatrix(text, index, &matrix) != 0, FPDFText_GetCharOrigin(text, index, &x, &y) != 0 else { continue }
                let box = CGRect(x: CGFloat(loose.left), y: CGFloat(loose.bottom), width: CGFloat(loose.right - loose.left), height: CGFloat(loose.top - loose.bottom))
                let ink = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
                read[object] = (read[object] ?? .null).union(box).union(ink)
                let m = transform(matrix), glyph = place(box, m, CGPoint(x: x, y: y), within: shape.ink)
                // A glyph without ink (a blank) gets a box a thousandth of the size high, along its advance (turned, the
                // page box of that line); whatever its Unicode, it shows nothing.
                if let frame = glyph.frame {
                    let line = CGRect(x: frame.rect.minX, y: CGPoint(x: ink.midX, y: ink.midY).applying(frame.toText).y, width: frame.rect.width, height: 0).applying(m)
                    if max(abs(line.minX - ink.minX), abs(line.minY - ink.minY), abs(line.maxX - ink.maxX), abs(line.maxY - ink.maxY)) < 0.01 * max(box.width, box.height) { continue }
                } else if min(ink.width, ink.height) < 0.01 * max(box.width, box.height) { continue }
                // No Unicode: none it maps, or a NUL (a blank to PDFKit).
                let unicode = FPDFText_HasUnicodeMapError(text, index) == 0 ? Unicode.Scalar(FPDFText_GetUnicode(text, index)).flatMap { $0.value == 0 ? nil : $0 } : nil
                let angle = atan2(m.b, m.a)
                // A combining mark is part of its letter's cluster, which PDFKit gives one box (at the letter's glyph).
                if let unicode, isMark(unicode), words.contains(where: { $0.bounds.intersects(ink) }) {
                    marks.append((box, angle))
                    continue
                }
                let reads: [Unicode.Scalar] = unicode.map { unicode in
                    if let known = letter[unicode] { return known }
                    let all = Self.letters(String(unicode)), reads = all.first?.properties.isWhitespace == false ? all : []
                    letter[unicode] = reads
                    return reads
                } ?? []
                found.append((object, glyph, Place(box: ink, frame: glyph.frame), reads, box, angle, isShown(box, turnedBy: angle)))
            }
            FPDFText_ClosePage(text)
        }
        var held = found.map { $0.shown && !$0.letters.isEmpty }
        if found.contains(where: { $0.shown && $0.letters.isEmpty }) {
            // Each word's letters (marks aside) no glyph reads as yet, and its own combining marks (PDFKit's, not those of
            // decomposed letters) no mark PDFium reads there is, which any glyph may be. Glyphs in one word's box go first,
            // then those in several (turned words' boxes overlap), then those only turned back into one.
            let over = found.map { shown($0.box, turnedBy: $0.angle) }
            var letters = words.map { Self.letters($0.text).reduce(into: [Unicode.Scalar: Int]()) { $0[$1, default: 0] += 1 } }
            var ownMarks = words.map { $0.text.unicodeScalars.filter(isMark).count }
            for mark in marks { if let word = shown(mark.box, turnedBy: mark.angle).words.first(where: { ownMarks[$0] > 0 }) { ownMarks[word] -= 1 } }
            var unread = zip(letters, ownMarks).map { $0.values.reduce(0, +) + $1 }
            let order = found.indices.sorted { (over[$0].turned ? 2 : over[$0].words.count == 1 ? 0 : 1, $0) < (over[$1].turned ? 2 : over[$1].words.count == 1 ? 0 : 1, $1) }
            for i in order where held[i] {
                guard let first = found[i].letters.first, let word = over[i].words.first(where: { letters[$0][first, default: 0] > 0 }) else { continue }
                for letter in found[i].letters where letters[word][letter, default: 0] > 0 { // all of a glyph's letters (… is ..., 한 is 한)
                    letters[word][letter]! -= 1
                    unread[word] -= 1
                }
            }
            for i in order where !held[i] {
                guard let word = over[i].words.first(where: { unread[$0] > 0 }) else { continue }
                unread[word] -= 1
                held[i] = true
            }
        }
        var glyphs: [FPDF_PAGEOBJECT: (kept: [Place], left: [Place])] = [:]
        for (i, glyph) in found.enumerated() {
            if held[i] { glyphs[glyph.object, default: ([], [])].kept.append(glyph.loose) } else { glyphs[glyph.object, default: ([], [])].left.append(glyph.ink) }
        }
        var partly: [FPDF_PAGEOBJECT: (bounds: CGRect, kept: [Place], left: [Place])] = [:]
        var leftOut = false
        for (object, place) in visible {
            if let read = read[object] {
                let glyphs = glyphs[object] ?? ([], [])
                // Ink past the glyphs PDFium reads (it drops a closing or repeated blank, whatever it shows) is left out too.
                if glyphs.left.isEmpty && (place.bounds.width * place.bounds.height == 0 || read.insetBy(dx: -1, dy: -1).contains(place.bounds)) {
                    kept.insert(object)
                } else if !glyphs.kept.isEmpty { partly[object] = (place.bounds, glyphs.kept, glyphs.left) } else { leftOut = true }
            } else if place.bounds.width * place.bounds.height == 0 || covered(place.bounds, turnedBy: place.angle) {
                kept.insert(object)
            } else {
                leftOut = true
            }
        }
        return (kept, partly, leftOut || !partly.isEmpty)
    }
}
