// Port of Filee.Engines/Cad/CadScene.cs: the display list the CAD renderer draws. The scene builder resolves layers,
// colours, line weights, line types and block transforms once; the result is plain geometry in WCS, so one drawing
// routine serves PDF, SVG and PNG and the page is fitted to what is actually drawn (not to the header's EXTMIN/EXTMAX).

import Foundation

/// An sRGB colour with alpha (Skia's `SKColor`).
struct CadColor: Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8 = 255

    static let black = CadColor(r: 0, g: 0, b: 0)
    static let white = CadColor(r: 255, g: 255, b: 255)
}

/// Something to draw, in a resolved colour.
class CadScenePrimitive {
    let color: CadColor

    init(color: CadColor) { self.color = color }
}

/// Stroked figures: lines, arcs, polylines, curves, text-less outlines.
final class CadStrokePrimitive: CadScenePrimitive {
    var figures: [CadFigure] = []
    /// Line weight on paper in millimetres.
    let widthMm: Double
    /// Width in drawing units for polylines with a constant width (drawn with butt caps); 0 for normal lines, which
    /// use `widthMm`.
    let worldWidth: Double
    /// Dash pattern in drawing units (>0 dash, <0 gap, 0 dot); nil for continuous lines.
    let dashes: [Double]?

    init(color: CadColor, widthMm: Double, worldWidth: Double = 0, dashes: [Double]? = nil, figures: [CadFigure] = []) {
        self.widthMm = widthMm
        self.worldWidth = worldWidth
        self.dashes = dashes
        self.figures = figures
        super.init(color: color)
    }
}

/// Filled areas: solid hatches, SOLID/TRACE, wide polyline segments. Loops use the even-odd rule.
final class CadFillPrimitive: CadScenePrimitive {
    var figures: [CadFigure] = []
    /// Second colour of a gradient hatch, drawn as a linear gradient along `gradientAngle`.
    let gradientColor: CadColor?
    let gradientAngle: Double

    init(color: CadColor, gradientColor: CadColor? = nil, gradientAngle: Double = 0) {
        self.gradientColor = gradientColor
        self.gradientAngle = gradientAngle
        super.init(color: color)
    }
}

/// Pattern hatch lines, clipped by the hatch boundary when drawn.
final class CadHatchLinesPrimitive: CadScenePrimitive {
    var boundary: [CadFigure] = []
    var lines: [(a: CadVec2, b: CadVec2)] = []
    let widthMm: Double

    init(color: CadColor, widthMm: Double) {
        self.widthMm = widthMm
        super.init(color: color)
    }
}

/// One run of text in one typeface. Glyph coordinates at font size 1 (Skia convention, y down) map to WCS as
/// `origin + gx·xAxis + gy·yAxis`, which covers rotation, width factor, oblique angle and mirrored blocks.
final class CadTextPrimitive: CadScenePrimitive {
    let text: String
    let typeface: CadTypeface
    let origin: CadVec2
    let xAxis: CadVec2
    let yAxis: CadVec2

    init(text: String, typeface: CadTypeface, origin: CadVec2, xAxis: CadVec2, yAxis: CadVec2, color: CadColor) {
        self.text = text
        self.typeface = typeface
        self.origin = origin
        self.xAxis = xAxis
        self.yAxis = yAxis
        super.init(color: color)
    }
}

/// XLINE and RAY: clipped to the page when drawn.
final class CadInfiniteLinePrimitive: CadScenePrimitive {
    let origin: CadVec2
    let direction: CadVec2
    let isRay: Bool
    let widthMm: Double
    let dashes: [Double]?

    init(origin: CadVec2, direction: CadVec2, isRay: Bool, color: CadColor, widthMm: Double, dashes: [Double]?) {
        self.origin = origin
        self.direction = direction
        self.isRay = isRay
        self.widthMm = widthMm
        self.dashes = dashes
        super.init(color: color)
    }
}

/// A POINT, drawn as a dot of its line weight.
final class CadPointPrimitive: CadScenePrimitive {
    let location: CadVec2
    let widthMm: Double

    init(location: CadVec2, color: CadColor, widthMm: Double) {
        self.location = location
        self.widthMm = widthMm
        super.init(color: color)
    }
}

/// Everything to draw plus what was left out.
final class CadScene {
    var items: [CadScenePrimitive] = []
    /// Bounds of all finite primitives in WCS.
    var extents = CadBox2.empty
    /// Entity types that were not drawn, with their count (for the log). Sorted by `skippedTypes`.
    var skipped: [String: Int] = [:]
    /// True when a limit (primitive count, block nesting, array size) cut the drawing short.
    var truncated = false
    /// Which space was drawn: "model" or the layout name.
    var space = "model"

    /// The skipped entity types in ordinal order (Filee's SortedDictionary with StringComparer.Ordinal).
    var skippedTypes: [String] { skipped.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) } }
}
