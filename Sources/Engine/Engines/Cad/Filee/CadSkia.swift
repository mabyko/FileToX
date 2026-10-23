// The parts of Skia (BSD) the C# CAD renderer relied on through SkiaSharp, reproduced so the output matches: paths in
// float coordinates (SkPath), path measuring for dashes (SkContourMeasure, SkChopCubicAt) and the SVG canvas
// (SkSVGDevice / SkXMLStreamWriter), whose element structure and number formatting the SVG output keeps.

import Foundation

/// A point in page units, in float like Skia's `SkPoint`.
struct CadSkPoint: Equatable {
    var x: Float
    var y: Float

    init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }

    static let zero = CadSkPoint(0, 0)

    static func + (a: CadSkPoint, b: CadSkPoint) -> CadSkPoint { CadSkPoint(a.x + b.x, a.y + b.y) }
    static func - (a: CadSkPoint, b: CadSkPoint) -> CadSkPoint { CadSkPoint(a.x - b.x, a.y - b.y) }

    var isFinite: Bool { x.isFinite && y.isFinite }

    /// `SkPoint::Distance`.
    static func distance(_ a: CadSkPoint, _ b: CadSkPoint) -> Float {
        let dx = b.x - a.x, dy = b.y - a.y
        let mag2 = dx * dx + dy * dy
        if mag2.isFinite { return mag2.squareRoot() }
        let xx = Double(dx), yy = Double(dy)
        return Float((xx * xx + yy * yy).squareRoot())
    }

    /// `SkScalarInterp` per coordinate.
    static func interpolate(_ a: CadSkPoint, _ b: CadSkPoint, _ t: Float) -> CadSkPoint {
        CadSkPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }
}

/// `SkPath` with the verbs the renderer uses (move, line, cubic, close).
final class CadSkPath {
    enum Verb: UInt8 { case move, line, cubic, close }

    private(set) var verbs: [Verb] = []
    private(set) var points: [CadSkPoint] = []
    var isEvenOdd = false
    /// `fLastMoveToIndex`: the last move's point index, or its complement after a close (or ~0 for a new path).
    private var lastMoveToIndex = ~0

    init(evenOdd: Bool = false) { isEvenOdd = evenOdd }

    var isEmpty: Bool { verbs.isEmpty }
    var pointCount: Int { points.count }
    var lastPoint: CadSkPoint? { points.last }

    func moveTo(_ p: CadSkPoint) {
        lastMoveToIndex = points.count
        verbs.append(.move)
        points.append(p)
    }

    private func injectMoveToIfNeeded() {
        if lastMoveToIndex < 0 { moveTo(verbs.isEmpty ? .zero : points[~lastMoveToIndex]) }
    }

    func lineTo(_ p: CadSkPoint) {
        injectMoveToIfNeeded()
        verbs.append(.line)
        points.append(p)
    }

    func cubicTo(_ c1: CadSkPoint, _ c2: CadSkPoint, _ p: CadSkPoint) {
        injectMoveToIfNeeded()
        verbs.append(.cubic)
        points.append(contentsOf: [c1, c2, p])
    }

    func close() {
        if let last = verbs.last, last != .close { verbs.append(.close) }
        if lastMoveToIndex >= 0 { lastMoveToIndex = ~lastMoveToIndex }
    }

    /// `addPath` in append mode.
    func addPath(_ source: CadSkPath) {
        if source.isEmpty { return }
        lastMoveToIndex = source.lastMoveToIndex >= 0 ? source.lastMoveToIndex + points.count : source.lastMoveToIndex - points.count
        verbs.append(contentsOf: source.verbs)
        points.append(contentsOf: source.points)
    }

    func reset() {
        verbs.removeAll(keepingCapacity: true)
        points.removeAll(keepingCapacity: true)
        lastMoveToIndex = ~0
    }

    var isFinite: Bool { points.allSatisfy(\.isFinite) }

    /// `getBounds`: the bounds of every point, control points included.
    var bounds: (minX: Float, minY: Float, maxX: Float, maxY: Float) {
        guard let first = points.first else { return (0, 0, 0, 0) }
        var b = (minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for p in points.dropFirst() {
            b.minX = min(b.minX, p.x)
            b.minY = min(b.minY, p.y)
            b.maxX = max(b.maxX, p.x)
            b.maxY = max(b.maxY, p.y)
        }
        return b
    }

    /// `SkPath::isRect` (SkPathPriv::IsRectContour without partial rects): the rectangle when the path is one.
    func asRect() -> (left: Float, top: Float, right: Float, bottom: Float)? {
        var corners = 0
        var lineStart = CadSkPoint.zero
        var firstPt: Int?
        var lastPt: Int?
        var firstCorner = CadSkPoint.zero
        var thirdCorner = CadSkPoint.zero
        var directions = [Int](repeating: -1, count: 5)
        var closedOrMoved = false
        var autoClose = false
        var cursor = 0
        func makeDir(_ dx: Float, _ dy: Float) -> Int { (dx != 0 ? 1 : 0) | ((dx > 0 || dy > 0) ? 2 : 0) }

        for verb in verbs {
            switch verb {
            case .close, .line:
                let lineEnd: CadSkPoint
                if verb == .close {
                    autoClose = true
                    guard let firstPt else { return nil }
                    lineEnd = points[firstPt]
                } else {
                    lastPt = cursor
                    lineEnd = points[cursor]
                    cursor += 1
                }
                let delta = lineEnd - lineStart
                if delta.x != 0 && delta.y != 0 { return nil } // diagonal
                if !delta.isFinite { return nil }
                if lineStart == lineEnd { break } // single point on side OK
                let nextDirection = makeDir(delta.x, delta.y)
                if corners == 0 {
                    directions[0] = nextDirection
                    corners = 1
                    closedOrMoved = false
                    lineStart = lineEnd
                    break
                }
                if closedOrMoved { return nil } // closed followed by a line
                if autoClose && nextDirection == directions[0] { break } // colinear with first
                closedOrMoved = autoClose
                if directions[corners - 1] == nextDirection {
                    if corners == 3 && verb == .line { thirdCorner = lineEnd }
                    lineStart = lineEnd
                    break // colinear segment
                }
                directions[corners] = nextDirection
                corners += 1
                // opposite lines must point in opposite directions; xoring them should equal 2
                switch corners {
                case 2: firstCorner = lineStart
                case 3:
                    if directions[0] ^ directions[2] != 2 { return nil }
                    thirdCorner = lineEnd
                case 4:
                    if directions[1] ^ directions[3] != 2 { return nil }
                default: return nil // too many direction changes
                }
                lineStart = lineEnd
            case .cubic:
                return nil
            case .move:
                if corners == 0 {
                    firstPt = cursor
                } else if let firstPt, let lastPt {
                    let closeXY = points[firstPt] - points[lastPt]
                    if closeXY.x != 0 && closeXY.y != 0 { return nil } // we're diagonal, abort
                }
                lineStart = points[cursor]
                cursor += 1
                closedOrMoved = true
            }
        }
        // Success if 4 corners and first point equals last
        if corners < 3 || corners > 4 { return nil }
        guard let firstPt, let lastPt else { return nil }
        let closeXY = points[firstPt] - points[lastPt]
        if closeXY.x != 0 && closeXY.y != 0 { return nil }
        return (min(firstCorner.x, thirdCorner.x), min(firstCorner.y, thirdCorner.y),
                max(firstCorner.x, thirdCorner.x), max(firstCorner.y, thirdCorner.y))
    }

    /// `SkParsePath::ToSVGString` with absolute coordinates (`%g`). It walks the path with `SkPath::Iter`, which
    /// adds the closing line of a contour that does not end at its start and drops a trailing move.
    func svgString() -> String {
        var out = ""
        func append(_ command: Character, _ pts: ArraySlice<CadSkPoint>) {
            out.append(command)
            for (i, p) in pts.enumerated() {
                if i > 0 { out.append(" ") }
                out += CadSkNumbers.g(p.x)
                out.append(" ")
                out += CadSkNumbers.g(p.y)
            }
        }
        var cursor = 0
        var moveTo = CadSkPoint.zero
        var lastPoint = CadSkPoint.zero
        func autoCloseLine() {
            let nan = lastPoint.x.isNaN || lastPoint.y.isNaN || moveTo.x.isNaN || moveTo.y.isNaN
            if lastPoint != moveTo && !nan { append("L", [moveTo][...]) }
            lastPoint = moveTo
        }
        for (index, verb) in verbs.enumerated() {
            switch verb {
            case .move:
                if index == verbs.count - 1 { return out } // a trailing moveTo
                moveTo = points[cursor]
                lastPoint = moveTo
                append("M", points[cursor...cursor])
                cursor += 1
            case .line:
                append("L", points[cursor...cursor])
                lastPoint = points[cursor]
                cursor += 1
            case .cubic:
                append("C", points[cursor...(cursor + 2)])
                lastPoint = points[cursor + 2]
                cursor += 3
            case .close:
                autoCloseLine()
                out.append("Z")
            }
        }
        return out
    }

    /// Calls `body` with each verb and its points (the previous point first for lines and cubics), like Skia's
    /// raw path iterator.
    func forEachVerb(_ body: (Verb, [CadSkPoint]) -> Void) {
        var cursor = 0
        for verb in verbs {
            switch verb {
            case .move:
                body(.move, [points[cursor]])
                cursor += 1
            case .line:
                body(.line, [points[cursor - 1], points[cursor]])
                cursor += 1
            case .cubic:
                body(.cubic, [points[cursor - 1], points[cursor], points[cursor + 1], points[cursor + 2]])
                cursor += 3
            case .close:
                body(.close, [])
            }
        }
    }
}

/// Skia's number formatting: `%g` for path data and transforms, `%.8g` (`SkStrAppendScalar`) for attributes.
enum CadSkNumbers {
    static func g(_ value: Float) -> String { format(Double(value), "%g") }

    static func scalar(_ value: Float) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        return format(Double(value), "%.8g")
    }

    private static func format(_ value: Double, _ pattern: String) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            // The process keeps the C locale (nothing calls setlocale), so the decimal point is always ".".
            _ = withVaList([value]) { vsnprintf(buffer.baseAddress!, 64, pattern, $0) }
            return String(cString: buffer.baseAddress!)
        }
    }
}

// ───────────────────────── Path measure (dashes) ─────────────────────────

/// One measured contour (`SkContourMeasure`).
final class CadContourMeasure {
    fileprivate struct Segment {
        var distance: Float
        var pointIndex: Int
        var tValue: Int
        var isCubic: Bool

        var scalarT: Float { CadContourMeasure.tValueToScalar(tValue) }
    }

    fileprivate static let maxTValue = 0x3FFF_FFFF

    fileprivate static func tValueToScalar(_ t: Int) -> Float {
        // 1/kMaxTValue can't be represented as a float, but it's close and the limits work fine.
        let reciprocal: Float = 1.0 / Float(maxTValue)
        return Float(t) * reciprocal
    }

    fileprivate let segments: [Segment]
    fileprivate let points: [CadSkPoint]
    let length: Float

    fileprivate init(segments: [Segment], points: [CadSkPoint], length: Float) {
        self.segments = segments
        self.points = points
        self.length = length
    }

    /// `getSegment`: appends the piece between the two distances to `destination`.
    @discardableResult
    func segment(from startD: Float, to stopD: Float, into destination: CadSkPath, startWithMoveTo: Bool) -> Bool {
        var startD = startD, stopD = stopD
        if startD < 0 { startD = 0 }
        if stopD > length { stopD = length }
        if !(startD <= stopD) { return false } // catch NaN values as well
        if segments.isEmpty { return false }

        let (startIndex, startT) = distanceToSegment(startD)
        if !startT.isFinite { return false }
        let (stopIndex, stopT) = distanceToSegment(stopD)
        if !stopT.isFinite { return false }
        if startWithMoveTo {
            let seg = segments[startIndex]
            destination.moveTo(position(seg.pointIndex, seg.isCubic, startT))
        }
        var seg = segments[startIndex]
        let stopSeg = segments[stopIndex]
        if seg.pointIndex == stopSeg.pointIndex {
            segTo(seg.pointIndex, seg.isCubic, startT, stopT, destination)
        } else {
            var index = startIndex
            var t = startT
            repeat {
                segTo(seg.pointIndex, seg.isCubic, t, 1, destination)
                index += 1
                seg = segments[index]
                t = 0
            } while seg.pointIndex < stopSeg.pointIndex
            segTo(seg.pointIndex, seg.isCubic, 0, stopT, destination)
        }
        return true
    }

    /// `getPosTan` (position only).
    func position(at distance: Float) -> CadSkPoint? {
        if distance.isNaN { return nil }
        let distance = distance < 0 ? 0 : distance > length ? length : distance
        let (index, t) = distanceToSegment(distance)
        if !t.isFinite { return nil }
        let seg = segments[index]
        return position(seg.pointIndex, seg.isCubic, t)
    }

    private func distanceToSegment(_ distance: Float) -> (Int, Float) {
        // SkTSearch: the first segment whose distance is not below `distance`.
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = lo + ((hi - lo) >> 1)
            if segments[mid].distance < distance { lo = mid + 1 } else { hi = mid }
        }
        var index = hi
        if segments[hi].distance < distance { index = hi + 1 }
        index = min(index, segments.count - 1)
        let seg = segments[index]

        // now interpolate t-values with the prev segment (if possible)
        var startT: Float = 0, startD: Float = 0
        // check if the prev segment is legal, and references the same set of points
        if index > 0 {
            startD = segments[index - 1].distance
            if segments[index - 1].pointIndex == seg.pointIndex { startT = segments[index - 1].scalarT }
        }
        let t = startT + (seg.scalarT - startT) * (distance - startD) / (seg.distance - startD)
        return (index, t)
    }

    private func position(_ pointIndex: Int, _ isCubic: Bool, _ t: Float) -> CadSkPoint {
        if !isCubic { return CadSkPoint.interpolate(points[pointIndex], points[pointIndex + 1], t) }
        return CadContourMeasure.evalCubic(Array(points[pointIndex...(pointIndex + 3)]), t)
    }

    /// `SkContourMeasure_segTo`.
    private func segTo(_ pointIndex: Int, _ isCubic: Bool, _ startT: Float, _ stopT: Float, _ destination: CadSkPath) {
        if startT == stopT {
            if let last = destination.lastPoint {
                // if the dash as a zero-length on segment, add a corresponding zero-length line.
                destination.lineTo(last)
            }
            return
        }
        if !isCubic {
            if stopT == 1 {
                destination.lineTo(points[pointIndex + 1])
            } else {
                destination.lineTo(CadSkPoint.interpolate(points[pointIndex], points[pointIndex + 1], stopT))
            }
            return
        }
        let cubic = Array(points[pointIndex...(pointIndex + 3)])
        if startT == 0 {
            if stopT == 1 {
                destination.cubicTo(cubic[1], cubic[2], cubic[3])
            } else {
                let tmp = CadContourMeasure.chopCubic(cubic, stopT)
                destination.cubicTo(tmp[1], tmp[2], tmp[3])
            }
        } else {
            let tmp0 = CadContourMeasure.chopCubic(cubic, startT)
            if stopT == 1 {
                destination.cubicTo(tmp0[4], tmp0[5], tmp0[6])
            } else {
                let tmp1 = CadContourMeasure.chopCubic(Array(tmp0[3...6]), (stopT - startT) / (1 - startT))
                destination.cubicTo(tmp1[1], tmp1[2], tmp1[3])
            }
        }
    }

    /// `SkChopCubicAt`.
    fileprivate static func chopCubic(_ src: [CadSkPoint], _ t: Float) -> [CadSkPoint] {
        if t == 1 { return [src[0], src[1], src[2], src[3], src[3], src[3], src[3]] }
        func mix(_ a: CadSkPoint, _ b: CadSkPoint) -> CadSkPoint { CadSkPoint((b.x - a.x) * t + a.x, (b.y - a.y) * t + a.y) }
        let ab = mix(src[0], src[1])
        let bc = mix(src[1], src[2])
        let cd = mix(src[2], src[3])
        let abc = mix(ab, bc)
        let bcd = mix(bc, cd)
        let abcd = mix(abc, bcd)
        return [src[0], ab, abc, abcd, bcd, cd, src[3]]
    }

    /// `SkEvalCubicAt` (SkCubicCoeff).
    private static func evalCubic(_ src: [CadSkPoint], _ t: Float) -> CadSkPoint {
        func coordinate(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
            let a = p3 + 3 * (p1 - p2) - p0
            let b = 3 * (p2 - (p1 + p1) + p0)
            let c = 3 * (p1 - p0)
            return ((a * t + b) * t + c) * t + p0
        }
        return CadSkPoint(coordinate(src[0].x, src[1].x, src[2].x, src[3].x), coordinate(src[0].y, src[1].y, src[2].y, src[3].y))
    }
}

/// `SkContourMeasureIter` with `forceClosed = false` and `resScale = 1`.
final class CadContourMeasureIterator {
    private let path: CadSkPath
    private var items: [(CadSkPath.Verb, [CadSkPoint])] = []
    private var position = 0
    /// `CHEAP_DIST_LIMIT / resScale`.
    private let tolerance: Float = 0.5
    private static let maxRecursionDepth = 8

    init(_ path: CadSkPath) {
        self.path = path
        path.forEachVerb { items.append(($0, $1)) }
    }

    func next() -> CadContourMeasure? {
        while position < items.count {
            if let measure = buildSegments() { return measure }
        }
        return nil
    }

    private func buildSegments() -> CadContourMeasure? {
        var pointIndex = -1
        var distance: Float = 0
        var haveSeenClose = false
        var haveSeenMoveTo = false
        var segments: [CadContourMeasure.Segment] = []
        var points: [CadSkPoint] = []

        while position < items.count {
            let (verb, pts) = items[position]
            if haveSeenMoveTo && verb == .move { break }
            switch verb {
            case .move:
                pointIndex += 1
                points.append(pts[0])
                haveSeenMoveTo = true
            case .line:
                let previous = distance
                distance = lineSegment(pts[0], pts[1], distance, pointIndex, &segments)
                if distance > previous {
                    points.append(pts[1])
                    pointIndex += 1
                }
            case .cubic:
                let previous = distance
                distance = cubicSegments(pts, distance, 0, CadContourMeasure.maxTValue, pointIndex, 0, &segments)
                if distance > previous {
                    points.append(contentsOf: pts[1...3])
                    pointIndex += 3
                }
            case .close:
                haveSeenClose = true
            }
            position += 1
        }

        if !distance.isFinite || segments.isEmpty { return nil }
        if haveSeenClose {
            let previous = distance
            let first = points[0]
            distance = lineSegment(points[pointIndex], first, distance, pointIndex, &segments)
            if distance > previous { points.append(first) }
        }
        return CadContourMeasure(segments: segments, points: points, length: distance)
    }

    private func lineSegment(_ p0: CadSkPoint, _ p1: CadSkPoint, _ distance: Float, _ pointIndex: Int,
                             _ segments: inout [CadContourMeasure.Segment]) -> Float {
        let d = CadSkPoint.distance(p0, p1)
        let previous = distance
        let distance = distance + d
        if distance > previous {
            segments.append(.init(distance: distance, pointIndex: pointIndex, tValue: CadContourMeasure.maxTValue, isCubic: false))
        }
        return distance
    }

    private func cubicSegments(_ pts: [CadSkPoint], _ distance: Float, _ mint: Int, _ maxt: Int, _ pointIndex: Int, _ depth: Int,
                               _ segments: inout [CadContourMeasure.Segment]) -> Float {
        var depth = depth
        if depth < CadContourMeasureIterator.maxRecursionDepth && (maxt - mint) >> 10 != 0 && tooCurvy(pts) {
            let tmp = CadContourMeasure.chopCubic(pts, 0.5)
            let half = (mint + maxt) >> 1
            depth += 1
            var distance = cubicSegments(Array(tmp[0...3]), distance, mint, half, pointIndex, depth, &segments)
            distance = cubicSegments(Array(tmp[3...6]), distance, half, maxt, pointIndex, depth, &segments)
            return distance
        }
        let d = CadSkPoint.distance(pts[0], pts[3])
        let previous = distance
        let distance = distance + d
        if distance > previous {
            segments.append(.init(distance: distance, pointIndex: pointIndex, tValue: maxt, isCubic: true))
        }
        return distance
    }

    /// `cubic_too_curvy`.
    private func tooCurvy(_ pts: [CadSkPoint]) -> Bool {
        func exceeds(_ pt: CadSkPoint, _ x: Float, _ y: Float) -> Bool { max(abs(x - pt.x), abs(y - pt.y)) > tolerance }
        let third: Float = 1.0 / 3
        let twoThirds: Float = 2.0 / 3
        return exceeds(pts[1], pts[0].x + (pts[3].x - pts[0].x) * third, pts[0].y + (pts[3].y - pts[0].y) * third)
            || exceeds(pts[2], pts[0].x + (pts[3].x - pts[0].x) * twoThirds, pts[0].y + (pts[3].y - pts[0].y) * twoThirds)
    }
}

// ───────────────────────── SVG canvas ─────────────────────────

/// A 2D affine matrix in Skia's layout (`SkMatrix` without perspective), floats.
struct CadSkMatrix {
    var scaleX: Float
    var skewX: Float
    var transX: Float
    var skewY: Float
    var scaleY: Float
    var transY: Float

    /// `svg_transform` from SkSVGDevice: the transform attribute for this matrix (by its type mask).
    var svgTransform: String {
        let translates = transX != 0 || transY != 0
        let skews = (skewX != 0) || (skewY != 0) // -0 compares equal to 0, like SkScalarAs2sCompliment
        let scales = skews || scaleX != 1 || scaleY != 1
        if !skews && !scales && translates {
            return "translate(\(CadSkNumbers.g(transX)) \(CadSkNumbers.g(transY)))"
        }
        if scales && !skews && !translates {
            return "scale(\(CadSkNumbers.g(scaleX)) \(CadSkNumbers.g(scaleY)))"
        }
        return "matrix(\(CadSkNumbers.g(scaleX)) \(CadSkNumbers.g(skewY)) \(CadSkNumbers.g(skewX)) \(CadSkNumbers.g(scaleY)) "
            + "\(CadSkNumbers.g(transX)) \(CadSkNumbers.g(transY)))"
    }

    var isIdentity: Bool { scaleX == 1 && skewX == 0 && transX == 0 && skewY == 0 && scaleY == 1 && transY == 0 }
}

/// How a shape is painted (the parts of `SKPaint` the renderer sets).
struct CadSkPaint {
    enum Style { case fill, stroke }

    var style: Style
    var color: CadColor
    var strokeWidth: Float = 0
    /// Butt caps and mitred joins (wide polylines) instead of round ones.
    var squareEnds = false
    /// A two-colour linear gradient from `gradientStart` to `gradientEnd` (clamped).
    var gradient: (start: CadSkPoint, end: CadSkPoint, colors: [CadColor])?

    static func fill(_ color: CadColor) -> CadSkPaint { CadSkPaint(style: .fill, color: color) }

    static func pen(_ color: CadColor, _ width: Float, wide: Bool) -> CadSkPaint {
        CadSkPaint(style: .stroke, color: color, strokeWidth: width, squareEnds: wide)
    }
}

/// The drawing operations of the CAD renderer (a subset of `SKCanvas`).
protocol CadCanvas: AnyObject {
    func drawRect(width: Float, height: Float, _ paint: CadSkPaint)
    func drawPath(_ path: CadSkPath, _ paint: CadSkPaint)
    /// `Save` + `ClipPath(path, Intersect, antialias: true)`.
    func saveClip(_ path: CadSkPath)
    func restore()
    /// `Save` + `Concat(matrix)` + `DrawText(text, 0, 0, font, paint)` + `Restore`.
    func drawText(_ text: String, _ typeface: CadTypeface, size: Float, _ matrix: CadSkMatrix, _ paint: CadSkPaint)
    func drawCircle(_ center: CadSkPoint, radius: Float, _ paint: CadSkPaint)
}

/// `SkSVGCanvas` / `SkSVGDevice` writing through `SkXMLStreamWriter` (pretty printed with tabs).
final class CadSvgCanvas: CadCanvas {
    private var out = ""
    private var elements: [(name: String, hasChildren: Bool, hasText: Bool)] = []
    /// The clip of the canvas (one level: the renderer never nests clips) and its generation.
    private var canvasClip: (path: CadSkPath, id: Int)?
    /// The clip whose `<g>` group is open in the output.
    private var deviceClipId: Int?
    private var clipGeneration = 0
    // SkSVGDevice's clip counter; the C# renderer's first clip is cl_3 (canvas set-up accounts for the others).
    private var clipCount = 3
    private var gradientCount = 0

    init(width: Float, height: Float) {
        out += "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n"
        startElement("svg")
        attribute("xmlns", "http://www.w3.org/2000/svg")
        attribute("xmlns:xlink", "http://www.w3.org/1999/xlink")
        // SkSVGCanvas::Make takes the bounds rounded out to whole pixels.
        attribute("width", String(Int(width.rounded(.up))))
        attribute("height", String(Int(height.rounded(.up))))
    }

    /// Closes open groups and the root element (the device destructor) and returns the document.
    func finish() -> Data {
        if deviceClipId != nil {
            endElement()
            deviceClipId = nil
        }
        while !elements.isEmpty { endElement() }
        return Data(out.utf8)
    }

    func drawRect(width: Float, height: Float, _ paint: CadSkPaint) {
        beginElement("rect", paint, nil)
        attribute("width", CadSkNumbers.scalar(width))
        attribute("height", CadSkNumbers.scalar(height))
        endElement()
    }

    func drawPath(_ path: CadSkPath, _ paint: CadSkPaint) {
        if !path.isFinite { return }
        beginElement("path", paint, nil)
        attribute("d", path.svgString())
        if path.isEvenOdd { attribute("fill-rule", "evenodd") }
        endElement()
    }

    func saveClip(_ path: CadSkPath) {
        clipGeneration += 1
        canvasClip = (path, clipGeneration)
    }

    func restore() { canvasClip = nil }

    func drawText(_ text: String, _ typeface: CadTypeface, size: Float, _ matrix: CadSkMatrix, _ paint: CadSkPaint) {
        let glyphs = typeface.glyphs(Array(text.utf16))
        if glyphs.isEmpty { return }
        let advances = typeface.advances(glyphs, size: size)
        // SVGTextBuilder: glyphs back to characters, whitespace consolidated, positions of dropped glyphs skipped.
        var content = ""
        var xs = ""
        var ys = ""
        var lastWasWhitespace = true
        var x: Float = 0
        for (glyph, advance) in zip(glyphs, advances) {
            defer { x += advance }
            let unichar = typeface.unicode(of: glyph)
            var discard = false
            var isWhitespace = false
            switch unichar {
            case 0x20, 0x09:
                if lastWasWhitespace { discard = true } else { content.unicodeScalars.append(Unicode.Scalar(unichar)!) }
                isWhitespace = true
            case 0:
                discard = true
                isWhitespace = lastWasWhitespace
            case 0x26: content += "&amp;"
            case 0x22: content += "&quot;"
            case 0x27: content += "&apos;"
            case 0x3C: content += "&lt;"
            case 0x3E: content += "&gt;"
            default:
                if let scalar = Unicode.Scalar(unichar) { content.unicodeScalars.append(scalar) }
            }
            lastWasWhitespace = isWhitespace
            if discard { continue }
            xs += CadSkNumbers.format8(x) + ", "
            if ys.isEmpty { ys = CadSkNumbers.format8(0) + ", " }
        }

        // Concatenating with the canvas' identity matrix turns negative zeros into zeros.
        let ctm = CadSkMatrix(scaleX: matrix.scaleX + 0, skewX: matrix.skewX + 0, transX: matrix.transX + 0,
                              skewY: matrix.skewY + 0, scaleY: matrix.scaleY + 0, transY: matrix.transY + 0)
        beginElement("text", paint, ctm)
        attribute("font-size", CadSkNumbers.scalar(size))
        if typeface.isItalic { attribute("font-style", "italic") }
        let weightIndex = (min(max(typeface.weight, 100), 900) - 50) / 100
        if weightIndex != 3 {
            let weights = ["100", "200", "300", "normal", "400", "500", "600", "bold", "800", "900"]
            attribute("font-weight", weights[weightIndex])
        }
        if typeface.width != 5 {
            let stretches = ["ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "normal", "semi-expanded", "expanded",
                             "extra-expanded", "ultra-expanded"]
            attribute("font-stretch", stretches[min(max(typeface.width, 1), 9) - 1])
        }
        if !typeface.svgFamilyNames.isEmpty { attribute("font-family", typeface.svgFamilyNames) }
        attribute("x", xs)
        attribute("y", ys)
        addText(content)
        endElement()
    }

    func drawCircle(_ center: CadSkPoint, radius: Float, _ paint: CadSkPaint) {
        let radius = max(radius, 0)
        let left = center.x - radius, top = center.y - radius, right = center.x + radius, bottom = center.y + radius
        beginElement("ellipse", paint, nil)
        attribute("cx", CadSkNumbers.scalar(Float((Double(left) + Double(right)) * 0.5)))
        attribute("cy", CadSkNumbers.scalar(Float((Double(top) + Double(bottom)) * 0.5)))
        attribute("rx", CadSkNumbers.scalar((right - left) / 2))
        attribute("ry", CadSkNumbers.scalar((bottom - top) / 2))
        endElement()
    }

    // ───────────────────────── SkSVGDevice::AutoElement ─────────────────────────

    private func beginElement(_ name: String, _ paint: CadSkPaint, _ matrix: CadSkMatrix?) {
        syncClip()
        var paintServer = CadSvgCanvas.color(paint.color)
        if let gradient = paint.gradient {
            paintServer = "url(#\(addLinearGradient(gradient)))"
        }
        startElement(name)
        switch paint.style {
        case .fill:
            if paintServer != "black" { attribute("fill", paintServer) }
            if paint.color.a != 255 { attribute("fill-opacity", CadSkNumbers.scalar(Float(paint.color.a) / 255)) }
        case .stroke:
            attribute("fill", "none")
            attribute("stroke", paintServer)
            if paint.strokeWidth == 0 {
                attribute("stroke-width", "1")
                attribute("vector-effect", "non-scaling-stroke")
            } else {
                attribute("stroke-width", CadSkNumbers.scalar(paint.strokeWidth))
            }
            if !paint.squareEnds {
                attribute("stroke-linecap", "round")
                attribute("stroke-linejoin", "round")
            } else {
                attribute("stroke-miterlimit", "4")
            }
            if paint.color.a != 255 { attribute("stroke-opacity", CadSkNumbers.scalar(Float(paint.color.a) / 255)) }
        }
        if let matrix, !matrix.isIdentity { attribute("transform", matrix.svgTransform) }
    }

    private func addLinearGradient(_ gradient: (start: CadSkPoint, end: CadSkPoint, colors: [CadColor])) -> String {
        let id = "gradient_\(gradientCount)"
        gradientCount += 1
        startElement("defs")
        startElement("linearGradient")
        attribute("id", id)
        attribute("gradientUnits", "userSpaceOnUse")
        attribute("x1", CadSkNumbers.scalar(gradient.start.x))
        attribute("y1", CadSkNumbers.scalar(gradient.start.y))
        attribute("x2", CadSkNumbers.scalar(gradient.end.x))
        attribute("y2", CadSkNumbers.scalar(gradient.end.y))
        for (i, color) in gradient.colors.enumerated() {
            startElement("stop")
            attribute("offset", CadSkNumbers.scalar(gradient.colors.count == 1 ? 0 : Float(i) / Float(gradient.colors.count - 1)))
            attribute("stop-color", CadSvgCanvas.color(color))
            if color.a != 255 { attribute("stop-opacity", CadSkNumbers.scalar(Float(color.a) / 255)) }
            endElement()
        }
        endElement()
        endElement()
        return id
    }

    /// `syncClipStack`: the open `<g clip-path>` group follows the canvas clip.
    private func syncClip() {
        if let open = deviceClipId, open != canvasClip?.id {
            endElement()
            deviceClipId = nil
        }
        guard let canvasClip, deviceClipId == nil else { return }
        let id = "cl_" + String(clipCount, radix: 16)
        clipCount += 1
        startElement("clipPath")
        attribute("id", id)
        if let rect = canvasClip.path.asRect() {
            startElement("rect")
            if rect.left != 0 { attribute("x", CadSkNumbers.scalar(rect.left)) }
            if rect.top != 0 { attribute("y", CadSkNumbers.scalar(rect.top)) }
            attribute("width", CadSkNumbers.scalar(rect.right - rect.left))
            attribute("height", CadSkNumbers.scalar(rect.bottom - rect.top))
            endElement()
        } else {
            startElement("path")
            attribute("d", canvasClip.path.svgString())
            if canvasClip.path.isEvenOdd { attribute("clip-rule", "evenodd") }
            endElement()
        }
        endElement()
        startElement("g")
        attribute("clip-path", "url(#\(id))")
        deviceClipId = canvasClip.id
    }

    /// `svg_color`: CSS named colours, then #RGB when every channel repeats its nibble, else #RRGGBB.
    static func color(_ c: CadColor) -> String {
        switch (UInt32(c.r) << 16) | (UInt32(c.g) << 8) | UInt32(c.b) {
        case 0x000000: return "black"
        case 0x000080: return "navy"
        case 0x0000FF: return "blue"
        case 0x008000: return "green"
        case 0x008080: return "teal"
        case 0x00FF00: return "lime"
        case 0x00FFFF: return "aqua"
        case 0x800000: return "maroon"
        case 0x800080: return "purple"
        case 0x808000: return "olive"
        case 0x808080: return "gray"
        case 0xC0C0C0: return "silver"
        case 0xFF0000: return "red"
        case 0xFF00FF: return "fuchsia"
        case 0xFFFF00: return "yellow"
        case 0xFFFFFF: return "white"
        default: break
        }
        func hex(_ v: UInt8, _ width: Int) -> String {
            let s = String(v, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        if c.r >> 4 == c.r & 0xF && c.g >> 4 == c.g & 0xF && c.b >> 4 == c.b & 0xF {
            return "#" + hex(c.r & 0xF, 1) + hex(c.g & 0xF, 1) + hex(c.b & 0xF, 1)
        }
        return "#" + hex(c.r, 2) + hex(c.g, 2) + hex(c.b, 2)
    }

    // ───────────────────────── SkXMLStreamWriter ─────────────────────────

    private func tab(_ level: Int) { out += String(repeating: "\t", count: level) }

    private func startElement(_ name: String) {
        let level = elements.count
        if level > 0 && !elements[level - 1].hasChildren && !elements[level - 1].hasText {
            out += ">\n" // the first child closes the parent's start tag
        }
        if level > 0 { elements[level - 1].hasChildren = true }
        tab(level)
        out += "<" + name
        elements.append((name, false, false))
    }

    private func attribute(_ name: String, _ value: String) {
        out += " \(name)=\"\(value)\""
    }

    private func addText(_ text: String) {
        let index = elements.count - 1
        if !elements[index].hasChildren && !elements[index].hasText { out += ">\n" }
        tab(elements.count + 1)
        out += text + "\n"
        elements[index].hasText = true
    }

    private func endElement() {
        let element = elements.removeLast()
        if element.hasChildren || element.hasText {
            tab(elements.count)
            out += "</\(element.name)>"
        } else {
            out += "/>"
        }
        out += "\n"
    }
}

extension CadSkNumbers {
    /// `%.8g` without Skia's NaN / infinity handling (`SkString::appendf`).
    static func format8(_ value: Float) -> String { scalar(value) }
}
