// Port of Filee.Engines/Cad/CadRenderer.cs: draws a CadScene. One drawing routine serves every output: a vector PDF
// (CGPDFContext instead of SKDocument), SVG (written as SkSVGCanvas wrote it, see CadSkia.swift) and a CoreGraphics
// bitmap (PNG and the other image formats). Only the page setup differs.

import CoreGraphics
import CoreText
import Foundation

/// Where the drawing lands on the page: a uniform scale that fits the extents into the printable area, centred, with
/// Y pointing down as on every page.
final class CadPageLayout {
    private let offsetX: Double
    private let offsetY: Double

    /// Page width in output units (PDF points, SVG pixels, bitmap pixels).
    let width: Float
    let height: Float
    /// Output units per millimetre of paper (line weights are given in millimetres).
    let unitsPerMm: Double
    /// Output units per drawing unit.
    let scale: Double

    private init(_ width: Float, _ height: Float, _ unitsPerMm: Double, _ scale: Double, _ offsetX: Double, _ offsetY: Double) {
        self.width = width
        self.height = height
        self.unitsPerMm = unitsPerMm
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    func toPage(_ p: CadVec2) -> CadVec2 { CadVec2(p.x * scale + offsetX, -p.y * scale + offsetY) }

    func vectorToPage(_ v: CadVec2) -> CadVec2 { CadVec2(v.x * scale, -v.y * scale) }

    func point(_ p: CadVec2) -> CadSkPoint {
        let q = toPage(p)
        return CadSkPoint(Float(q.x), Float(q.y))
    }

    /// The WCS point shown at page position (x, y).
    func fromPage(_ x: Double, _ y: Double) -> CadVec2 { CadVec2((x - offsetX) / scale, -(y - offsetY) / scale) }

    /// PDF: an ISO sheet (A3 unless the preset asks for A4 or Letter), landscape when the drawing is wider than tall,
    /// 10 mm margins unless the preset sets its own.
    static func forPdf(_ extents: CadBox2, _ options: PdfOptions) -> CadPageLayout {
        let (shortMm, longMm): (Double, Double) = switch options.pageSize {
        case .a4: (210.0, 297.0)
        case .letter: (215.9, 279.4)
        default: (297.0, 420.0)
        }
        let (width, height) = size(extents)
        let landscape = width >= height
        let margin = options.marginMm > 0 ? min(options.marginMm, shortMm / 4) : 10
        return fit(extents, landscape ? longMm : shortMm, landscape ? shortMm : longMm, margin, 72 / 25.4)
    }

    /// SVG and images: a page with the drawing's aspect ratio whose long edge is an A3 sheet (420 mm) and a 6 mm
    /// margin. `unitsPerMm` sets the resolution (96/25.4 for SVG pixels, dpi/25.4 for bitmaps).
    static func forImage(_ extents: CadBox2, _ unitsPerMm: Double) -> CadPageLayout {
        let longMm = 420.0
        let marginMm = 6.0
        let (width, height) = size(extents)
        // Very thin drawings (one long line) still get a usable page: at most 20:1.
        let aspect = min(max(height / width, 1.0 / 20), 20)
        let content = longMm - 2 * marginMm
        let (contentWidth, contentHeight) = aspect <= 1 ? (content, content * aspect) : (content / aspect, content)
        return fit(extents, contentWidth + 2 * marginMm, contentHeight + 2 * marginMm, marginMm, unitsPerMm)
    }

    private static func fit(_ extents: CadBox2, _ pageWidthMm: Double, _ pageHeightMm: Double, _ marginMm: Double, _ unitsPerMm: Double) -> CadPageLayout {
        let (width, height) = size(extents)
        let availableWidth = (pageWidthMm - 2 * marginMm) * unitsPerMm
        let availableHeight = (pageHeightMm - 2 * marginMm) * unitsPerMm
        let scale = min(availableWidth / width, availableHeight / height)
        let centerX = extents.isEmpty ? 0 : (extents.minX + extents.maxX) / 2
        let centerY = extents.isEmpty ? 0 : (extents.minY + extents.maxY) / 2
        let pageWidth = pageWidthMm * unitsPerMm
        let pageHeight = pageHeightMm * unitsPerMm
        return CadPageLayout(Float(pageWidth), Float(pageHeight), unitsPerMm, scale, pageWidth / 2 - centerX * scale, pageHeight / 2 + centerY * scale)
    }

    /// Extents size with degenerate cases (a point, a horizontal line) given some room.
    private static func size(_ extents: CadBox2) -> (Double, Double) {
        let width = extents.width
        let height = extents.height
        let size = max(width, height)
        if size <= 0 { return (1, 1) }
        return (max(width, size * 1e-3), max(height, size * 1e-3))
    }
}

/// Renders scenes to PDF, SVG and bitmaps.
enum CadRenderer {
    /// Dash patterns shorter than this on paper are drawn as continuous lines (they would look solid anyway).
    private static let minDashPatternMm = 0.8

    /// Upper bound for dashes of one figure; beyond it the line is drawn continuous.
    private static let maxDashesPerFigure: Float = 20_000

    /// A one-page vector PDF.
    static func pdf(_ scene: CadScene, _ options: PdfOptions, _ title: String) throws -> Data {
        let page = CadPageLayout.forPdf(scene.extents, options)
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: CGFloat(page.width), height: CGFloat(page.height))
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Filee"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ConversionError("Could not create the PDF document.")
        }
        context.beginPDFPage(nil)
        let canvas = CadGraphicsCanvas(context, height: CGFloat(page.height))
        draw(canvas, scene, page, background: false)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// An SVG (pixel units at 96 dpi) with a white background.
    static func svg(_ scene: CadScene) -> Data {
        let page = CadPageLayout.forImage(scene.extents, 96 / 25.4)
        let canvas = CadSvgCanvas(width: page.width, height: page.height)
        draw(canvas, scene, page, background: true)
        return canvas.finish()
    }

    /// Renders a white-background bitmap at `dpi` (for the virtual A3 page), limited to a sensible pixel count.
    static func renderBitmap(_ scene: CadScene, _ dpi: Double) throws -> CGImage {
        let maxEdge = 12_000.0
        let maxPixels = 80_000_000.0
        var page = CadPageLayout.forImage(scene.extents, dpi / 25.4)
        let reduce = min(1, min(maxEdge / Double(max(page.width, page.height)), (maxPixels / (Double(page.width) * Double(page.height))).squareRoot()))
        if reduce < 1 { page = CadPageLayout.forImage(scene.extents, dpi * reduce / 25.4) }

        let width = max(1, CadMath.int(Double(page.width).rounded(.toNearestOrEven)))
        let height = max(1, CadMath.int(Double(page.height).rounded(.toNearestOrEven)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError("The drawing is too large to render (\(width) × \(height) pixels).")
        }
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        let canvas = CadGraphicsCanvas(context, height: CGFloat(height))
        draw(canvas, scene, page, background: true)
        guard let image = context.makeImage() else { throw ConversionError("Could not render the drawing.") }
        return image
    }

    /// Draws every primitive in order. Consecutive strokes with the same pen are merged into one path.
    static func draw(_ canvas: CadCanvas, _ scene: CadScene, _ page: CadPageLayout, background: Bool) {
        if background { canvas.drawRect(width: page.width, height: page.height, .fill(.white)) }

        let batch = StrokeBatch(canvas)
        for item in scene.items {
            switch item {
            case let stroke as CadStrokePrimitive:
                drawStroke(batch, stroke, page)
            case let line as CadInfiniteLinePrimitive:
                drawInfinite(batch, line, page)
            case let fill as CadFillPrimitive:
                batch.flush()
                drawFill(canvas, fill, page)
            case let hatch as CadHatchLinesPrimitive:
                batch.flush()
                drawHatchLines(canvas, hatch, page)
            case let text as CadTextPrimitive:
                batch.flush()
                drawText(canvas, text, page)
            case let point as CadPointPrimitive:
                batch.flush()
                drawPoint(canvas, point, page)
            default:
                break
            }
        }
        batch.flush()
    }

    private static func drawStroke(_ batch: StrokeBatch, _ stroke: CadStrokePrimitive, _ page: CadPageLayout) {
        let penWidth = stroke.widthMm * page.unitsPerMm
        let wide = stroke.worldWidth > 0 && stroke.worldWidth * page.scale > penWidth
        let width = wide ? stroke.worldWidth * page.scale : penWidth
        let path = CadSkPath()
        for figure in stroke.figures { addFigure(path, figure, page) }
        guard let dashes = pageDashes(stroke.dashes, page) else {
            batch.add(path, stroke.color, Float(width), wide)
            return
        }
        batch.add(dash(path, dashes) ?? path, stroke.color, Float(width), wide)
    }

    private static func drawInfinite(_ batch: StrokeBatch, _ line: CadInfiniteLinePrimitive, _ page: CadPageLayout) {
        // Clip to the page: the lines only need to reach its corners.
        let w = Double(page.width), h = Double(page.height)
        let corners = [page.fromPage(0, 0), page.fromPage(w, 0), page.fromPage(0, h), page.fromPage(w, h)]
        let tMax = corners.map { CadVec2.dot($0 - line.origin, line.direction) }.max()!
        let tMin = line.isRay ? 0 : corners.map { CadVec2.dot($0 - line.origin, line.direction) }.min()!
        if tMax <= tMin { return }
        let figure = CadFigure(line.origin + line.direction * tMin)
        figure.lineTo(line.origin + line.direction * tMax)
        drawStroke(batch, CadStrokePrimitive(color: line.color, widthMm: line.widthMm, dashes: line.dashes, figures: [figure]), page)
    }

    private static func drawFill(_ canvas: CadCanvas, _ fill: CadFillPrimitive, _ page: CadPageLayout) {
        let path = CadSkPath(evenOdd: true)
        for figure in fill.figures { addFigure(path, figure, page, close: true) }
        var paint = CadSkPaint.fill(fill.color)
        if let second = fill.gradientColor {
            let bounds = path.bounds
            let boundsWidth = bounds.maxX - bounds.minX, boundsHeight = bounds.maxY - bounds.minY
            let (sin, cos) = (Foundation.sin(fill.gradientAngle), Foundation.cos(fill.gradientAngle))
            let half = Float(abs(cos) * Double(boundsWidth) + abs(sin) * Double(boundsHeight)) / 2
            let direction = CadSkPoint(Float(cos) * half, Float(-sin) * half)
            let midX = bounds.minX + boundsWidth / 2, midY = bounds.minY + boundsHeight / 2
            paint.gradient = (CadSkPoint(midX - direction.x, midY - direction.y), CadSkPoint(midX + direction.x, midY + direction.y), [fill.color, second])
        }
        canvas.drawPath(path, paint)
    }

    private static func drawHatchLines(_ canvas: CadCanvas, _ hatch: CadHatchLinesPrimitive, _ page: CadPageLayout) {
        let clip = CadSkPath(evenOdd: true)
        for figure in hatch.boundary { addFigure(clip, figure, page, close: true) }
        let lines = CadSkPath()
        for line in hatch.lines {
            lines.moveTo(page.point(line.a))
            lines.lineTo(page.point(line.b))
        }
        canvas.saveClip(clip)
        canvas.drawPath(lines, .pen(hatch.color, Float(hatch.widthMm * page.unitsPerMm), wide: false))
        canvas.restore()
    }

    private static func drawText(_ canvas: CadCanvas, _ text: CadTextPrimitive, _ page: CadPageLayout) {
        let origin = page.toPage(text.origin)
        let x = page.vectorToPage(text.xAxis)
        let y = page.vectorToPage(text.yAxis)
        // Draw at a font size equal to the em height on the page and put only the direction into the matrix: PDF
        // and SVG viewers handle normal font sizes better than tiny ones blown up by a transform.
        let size = y.length
        if size < 0.01 || !size.isFinite || size > 1e6 { return }
        let matrix = CadSkMatrix(scaleX: Float(x.x / size), skewX: Float(y.x / size), transX: Float(origin.x),
                                 skewY: Float(x.y / size), scaleY: Float(y.y / size), transY: Float(origin.y))
        canvas.drawText(text.text, text.typeface, size: Float(size), matrix, .fill(text.color))
    }

    private static func drawPoint(_ canvas: CadCanvas, _ point: CadPointPrimitive, _ page: CadPageLayout) {
        let radius = Float(max(point.widthMm * page.unitsPerMm, 0.3 * page.unitsPerMm)) / 2
        canvas.drawCircle(page.point(point.location), radius: radius, .fill(point.color))
    }

    private static func addFigure(_ path: CadSkPath, _ figure: CadFigure, _ page: CadPageLayout, close: Bool = false) {
        path.moveTo(page.point(figure.start))
        if figure.segments.isEmpty {
            path.lineTo(page.point(figure.start)) // zero-length: a dot with round caps
            return
        }
        for segment in figure.segments {
            if segment.isCubic {
                path.cubicTo(page.point(segment.c1), page.point(segment.c2), page.point(segment.p))
            } else {
                path.lineTo(page.point(segment.p))
            }
        }
        if figure.closed || close { path.close() }
    }

    /// The dash pattern in page units, or nil to draw a continuous line.
    private static func pageDashes(_ dashes: [Double]?, _ page: CadPageLayout) -> [Float]? {
        guard let dashes else { return nil }
        let scaled = dashes.map { Float($0 * page.scale) }
        let period = floatSum(scaled)
        if !period.isFinite || Double(period) < minDashPatternMm * page.unitsPerMm { return nil }
        return scaled
    }

    /// LINQ `Sum(Math.Abs)` over floats: accumulated in double, returned as float.
    private static func floatSum(_ values: [Float]) -> Float { Float(values.reduce(0.0) { $0 + Double(abs($1)) }) }

    /// Applies a dash pattern by cutting the path into pieces. Doing it here (not with a path effect) gives PDF, SVG
    /// and bitmaps the same result. Returns nil when the pattern would create too many pieces.
    private static func dash(_ source: CadSkPath, _ pattern: [Float]) -> CadSkPath? {
        let period = floatSum(pattern)
        let result = CadSkPath()
        let contours = CadContourMeasureIterator(source)
        while let contour = contours.next() {
            let length = contour.length
            if length <= 0 { continue }
            if length / period * Float(pattern.count) > maxDashesPerFigure { return nil }
            var position: Float = 0
            var index = 0
            while position < length {
                let element = pattern[index]
                if element > 0 {
                    contour.segment(from: position, to: min(position + element, length), into: result, startWithMoveTo: true)
                } else if element == 0, let dot = contour.position(at: position) {
                    result.moveTo(dot)
                    result.lineTo(dot)
                }
                position += abs(element)
                index = (index + 1) % pattern.count
            }
        }
        return result
    }

    /// Merges consecutive strokes with the same colour and width into one path (smaller PDF / SVG, faster), up to a
    /// size that keeps viewers and the SVG writer responsive.
    private final class StrokeBatch {
        private static let maxPoints = 4096

        private let canvas: CadCanvas
        private let path = CadSkPath()
        private var color = CadColor.black
        private var width: Float = 0
        private var wide = false
        private var empty = true

        init(_ canvas: CadCanvas) { self.canvas = canvas }

        func add(_ source: CadSkPath, _ color: CadColor, _ width: Float, _ wide: Bool) {
            if !empty && (color != self.color || width != self.width || wide != self.wide || path.pointCount > StrokeBatch.maxPoints) { flush() }
            self.color = color
            self.width = width
            self.wide = wide
            path.addPath(source)
            empty = false
        }

        func flush() {
            if empty { return }
            canvas.drawPath(path, .pen(color, width, wide: wide))
            path.reset()
            empty = true
        }
    }
}

/// CoreGraphics drawing (PDF pages and bitmaps), with page coordinates (y down) like Skia's canvas.
final class CadGraphicsCanvas: CadCanvas {
    private let context: CGContext
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    init(_ context: CGContext, height: CGFloat) {
        self.context = context
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
    }

    private func cgColor(_ c: CadColor) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, CGFloat(c.a) / 255])!
    }

    private func cgPath(_ path: CadSkPath) -> CGPath {
        let result = CGMutablePath()
        let points = path.points
        var cursor = 0
        func point(_ i: Int) -> CGPoint { CGPoint(x: CGFloat(points[i].x), y: CGFloat(points[i].y)) }
        for verb in path.verbs {
            switch verb {
            case .move:
                result.move(to: point(cursor))
                cursor += 1
            case .line:
                result.addLine(to: point(cursor))
                cursor += 1
            case .cubic:
                result.addCurve(to: point(cursor + 2), control1: point(cursor), control2: point(cursor + 1))
                cursor += 3
            case .close:
                result.closeSubpath()
            }
        }
        return result
    }

    func drawRect(width: Float, height: Float, _ paint: CadSkPaint) {
        context.setFillColor(cgColor(paint.color))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }

    func drawPath(_ path: CadSkPath, _ paint: CadSkPaint) {
        if path.isEmpty || !path.isFinite { return }
        let shape = cgPath(path)
        let rule: CGPathFillRule = path.isEvenOdd ? .evenOdd : .winding
        switch paint.style {
        case .fill:
            if let gradient = paint.gradient,
               let shading = CGGradient(colorsSpace: space, colors: gradient.colors.map(cgColor) as CFArray, locations: nil) {
                context.saveGState()
                context.addPath(shape)
                context.clip(using: rule)
                context.drawLinearGradient(shading, start: CGPoint(x: CGFloat(gradient.start.x), y: CGFloat(gradient.start.y)),
                                           end: CGPoint(x: CGFloat(gradient.end.x), y: CGFloat(gradient.end.y)),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            } else {
                context.addPath(shape)
                context.setFillColor(cgColor(paint.color))
                context.fillPath(using: rule)
            }
        case .stroke:
            context.addPath(shape)
            context.setLineWidth(CGFloat(paint.strokeWidth))
            // Line weights plot with round ends; wide polylines have square ends and mitred corners like in AutoCAD.
            context.setLineCap(paint.squareEnds ? .butt : .round)
            context.setLineJoin(paint.squareEnds ? .miter : .round)
            context.setMiterLimit(4)
            context.setStrokeColor(cgColor(paint.color))
            context.strokePath()
        }
    }

    func saveClip(_ path: CadSkPath) {
        context.saveGState()
        context.addPath(cgPath(path))
        context.clip(using: path.isEvenOdd ? .evenOdd : .winding)
    }

    func restore() { context.restoreGState() }

    func drawText(_ text: String, _ typeface: CadTypeface, size: Float, _ matrix: CadSkMatrix, _ paint: CadSkPaint) {
        let glyphs = typeface.glyphs(Array(text.utf16))
        // Skia rejects text whose placement is not finite.
        let values = [matrix.scaleX, matrix.skewX, matrix.transX, matrix.skewY, matrix.scaleY, matrix.transY]
        if glyphs.isEmpty || !values.allSatisfy(\.isFinite) { return }
        var positions: [CGPoint] = []
        var x: Float = 0
        for advance in typeface.advances(glyphs, size: size) {
            positions.append(CGPoint(x: CGFloat(x), y: 0))
            x += advance
        }
        context.saveGState()
        context.concatenate(CGAffineTransform(a: CGFloat(matrix.scaleX), b: CGFloat(matrix.skewY), c: CGFloat(matrix.skewX),
                                              d: CGFloat(matrix.scaleY), tx: CGFloat(matrix.transX), ty: CGFloat(matrix.transY)))
        // Glyph outlines are y-up; the page is y-down.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setFillColor(cgColor(paint.color))
        CTFontDrawGlyphs(typeface.font(size: size), glyphs, positions, glyphs.count, context)
        context.restoreGState()
    }

    func drawCircle(_ center: CadSkPoint, radius: Float, _ paint: CadSkPaint) {
        let r = max(radius, 0)
        if !(center.isFinite && r.isFinite) { return }
        context.setFillColor(cgColor(paint.color))
        context.fillEllipse(in: CGRect(x: CGFloat(center.x - r), y: CGFloat(center.y - r), width: CGFloat(2 * r), height: CGFloat(2 * r)))
    }
}
