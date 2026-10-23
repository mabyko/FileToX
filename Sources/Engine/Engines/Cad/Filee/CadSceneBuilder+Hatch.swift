// Port of Filee.Engines/Cad/CadSceneBuilder.Hatch.cs: HATCH for the CAD scene — boundary loops (lines, arcs,
// ellipses, splines, polylines) become even-odd filled paths; pattern hatches draw their pattern lines clipped to the
// boundary, or a light fill when the pattern is too dense.

import Foundation

extension CadSceneBuilder {
    /// Pattern segments allowed for one hatch; denser patterns are shown as a light fill instead.
    private static let maxPatternSegmentsPerHatch = 20_000

    /// Pattern segments allowed for the whole drawing.
    private static let maxPatternSegments = 2_000_000

    func drawHatch(_ hatch: ACad.Hatch, _ layer: ACad.Layer, _ context: DrawContext) {
        let loops = hatch.paths.compactMap(CadSceneBuilder.loop)
        if loops.isEmpty { return }

        let plane = context.transform
            .multiply(.ocs(hatch.normal))
            .multiply(.translation(CadVec3(0, 0, hatch.elevation)))
        let boundary = loops.map { CadSceneBuilder.map($0, plane) }
        var color = resolveColor(hatch, layer, context)

        if hatch.isSolid {
            let gradient = hatch.gradientColor
            var second: CadColor?
            if gradient.enabled && !gradient.colors.isEmpty {
                color = resolveColor(gradient.colors[0].color, layer, context)
                second = gradient.colors.count > 1 ? resolveColor(gradient.colors[1].color, layer, context) : CadSceneBuilder.blend(color, .white, 0.8)
            }
            let fill = CadFillPrimitive(color: color, gradientColor: second, gradientAngle: gradient.angle)
            fill.figures.append(contentsOf: boundary)
            addFill(fill)
            return
        }

        var box = CadBox2.empty
        for loop in loops { loop.add(to: &box) }
        let lines = !hatch.pattern.lines.isEmpty && patternSegments < CadSceneBuilder.maxPatternSegments
            ? CadSceneBuilder.patternLines(hatch.pattern, box)
            : nil
        guard let lines else {
            // Too dense (or no pattern data): a light tint of the hatch colour keeps the area recognisable.
            let tint = CadFillPrimitive(color: CadSceneBuilder.blend(color, .white, 0.75))
            tint.figures.append(contentsOf: boundary)
            addFill(tint)
            return
        }

        patternSegments += lines.count
        let primitive = CadHatchLinesPrimitive(color: color, widthMm: min(resolveWidth(hatch, layer, context), CadSceneBuilder.defaultLineWeightMm))
        primitive.boundary.append(contentsOf: boundary)
        primitive.lines.append(contentsOf: lines.map { (plane.point($0.a.x, $0.a.y), plane.point($0.b.x, $0.b.y)) })
        if reserve() {
            for figure in boundary { figure.add(to: &scene.extents) }
            scene.items.append(primitive)
        }
    }

    /// One boundary loop in the hatch's OCS plane.
    private static func loop(_ path: ACad.Hatch.BoundaryPath) -> CadFigure? {
        var figure: CadFigure?

        func moveOrLine(_ p: CadVec2) {
            if let figure {
                if (figure.end - p).length > 1e-9 { figure.lineTo(p) }
            } else {
                figure = CadFigure(p)
            }
        }

        // Clockwise edges store their angles mirrored at the X axis: the arc runs from -start to -end.
        func edgeArc(_ center: CadVec2, _ u: CadVec2, _ v: CadVec2, _ start: Double, _ end: Double, _ counterClockwise: Bool) {
            var t0: Double, t1: Double
            if counterClockwise {
                (t0, t1) = (start, end)
                while t1 <= t0 { t1 += 2 * Double.pi }
            } else {
                (t0, t1) = (-start, -end)
                while t1 >= t0 { t1 -= 2 * Double.pi }
            }
            moveOrLine(center + u * cos(t0) + v * sin(t0))
            figure!.arcTo(center, u, v, t0, t1)
        }

        for edge in path.edges {
            switch edge {
            case let .line(start, end):
                moveOrLine(CadVec2(start.x, start.y))
                figure!.lineTo(CadVec2(end.x, end.y))
            case let .arc(center, radius, startAngle, endAngle, counterClockWise):
                edgeArc(CadVec2(center.x, center.y), CadVec2(radius, 0), CadVec2(0, radius), startAngle, endAngle, counterClockWise)
            case let .ellipse(center, majorAxisEndPoint, radiusRatio, startAngle, endAngle, counterClockWise):
                let major = CadVec2(majorAxisEndPoint.x, majorAxisEndPoint.y)
                edgeArc(CadVec2(center.x, center.y), major, major.perp * radiusRatio, startAngle, endAngle, counterClockWise)
            case let .spline(spline):
                // Rational spline edges keep each weight in the control point's Z.
                let points = spline.controlPoints.count >= 2
                    ? CadCurves.sampleNurbs(Int(spline.degree), spline.controlPoints.map { CadVec3($0.x, $0.y, 0) }, spline.knots,
                                            spline.isRational ? spline.controlPoints.map(\.z) : nil)
                    : CadCurves.throughPoints(spline.fitPoints.map { CadVec3($0.x, $0.y, 0) }, closed: false)
                for point in points { moveOrLine(CadVec2(point.x, point.y)) }
            case let .polyline(vertices, isClosed, _):
                if vertices.isEmpty { break }
                moveOrLine(CadVec2(vertices[0].x, vertices[0].y))
                let count = isClosed ? vertices.count : vertices.count - 1
                for i in 0..<max(count, 0) {
                    let a = vertices[i]
                    let b = vertices[(i + 1) % vertices.count]
                    appendSegment(figure!, .identity, PolyVertex(location: CadVec2(a.x, a.y), bulge: a.z, startWidth: 0, endWidth: 0),
                                  PolyVertex(location: CadVec2(b.x, b.y), bulge: b.z, startWidth: 0, endWidth: 0))
                }
            }
        }
        guard let figure, !figure.segments.isEmpty else { return nil }
        figure.closed = true
        return figure
    }

    /// The pattern's line families across the boundary's bounding box (in the hatch plane). Each family repeats every
    /// `offset`; dashes start at the family's base point. Returns nil when the pattern is too dense.
    private static func patternLines(_ pattern: ACad.HatchPattern, _ box: CadBox2) -> [(a: CadVec2, b: CadVec2)]? {
        var result: [(a: CadVec2, b: CadVec2)] = []
        let corners = [CadVec2(box.minX, box.minY), CadVec2(box.maxX, box.minY), CadVec2(box.minX, box.maxY), CadVec2(box.maxX, box.maxY)]
        let size = max(max(box.width, box.height), 1e-9)

        for line in pattern.lines {
            let d = CadVec2(cos(line.angle), sin(line.angle))
            let n = d.perp
            let basePoint = CadVec2(line.basePoint.x, line.basePoint.y)
            let offset = CadVec2(line.offset.x, line.offset.y)
            let spacing = CadVec2.dot(offset, n)
            let c0 = CadVec2.dot(basePoint, n)
            let low = corners.map { CadVec2.dot($0, n) }.min()!
            let high = corners.map { CadVec2.dot($0, n) }.max()!

            let first: Int64, last: Int64
            if abs(spacing) < size * 1e-9 {
                if c0 < low || c0 > high { continue }
                first = 0
                last = 0
            } else {
                let k1 = (low - c0) / spacing
                let k2 = (high - c0) / spacing
                first = CadSceneBuilder.int64(min(k1, k2).rounded(.down))
                last = CadSceneBuilder.int64(max(k1, k2).rounded(.up))
            }
            if last &- first > Int64(maxPatternSegmentsPerHatch) { return nil }

            let dashes = line.dashLengths.filter(\.isFinite)
            let period = dashes.reduce(0) { $0 + abs($1) }
            var k = first
            while k <= last {
                let origin = basePoint + offset * Double(k)
                let tMin = corners.map { CadVec2.dot($0 - origin, d) }.min()!
                let tMax = corners.map { CadVec2.dot($0 - origin, d) }.max()!
                if dashes.isEmpty || period <= 0 || dashes.allSatisfy({ $0 > 0 }) {
                    result.append((origin + d * tMin, origin + d * tMax))
                } else {
                    if (tMax - tMin) / period * Double(dashes.count) + Double(result.count) > Double(maxPatternSegmentsPerHatch) { return nil }
                    var t = (tMin / period).rounded(.down) * period
                    while t < tMax {
                        for dash in dashes {
                            if dash > 0 && t + dash > tMin && t < tMax {
                                result.append((origin + d * max(t, tMin), origin + d * min(t + dash, tMax)))
                            } else if dash == 0 && t >= tMin && t <= tMax {
                                result.append((origin + d * t, origin + d * t))
                            }
                            t += abs(dash)
                        }
                    }
                }
                if result.count > maxPatternSegmentsPerHatch { return nil }
                k += 1
            }
        }
        return result
    }

    /// `(long)value` on .NET 9+: truncation with saturation, NaN → 0.
    private static func int64(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }

    /// A figure built in a plane's own coordinates, mapped to WCS (exact for the Bézier arcs).
    private static func map(_ local: CadFigure, _ plane: CadAffine3) -> CadFigure {
        let mapped = CadFigure(plane.point(local.start.x, local.start.y))
        mapped.closed = local.closed
        for s in local.segments {
            let p = plane.point(s.p.x, s.p.y)
            mapped.segments.append(s.isCubic ? .cubic(plane.point(s.c1.x, s.c1.y), plane.point(s.c2.x, s.c2.y), p) : .line(p))
        }
        return mapped
    }

    private static func blend(_ color: CadColor, _ toward: CadColor, _ amount: Double) -> CadColor {
        func channel(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(truncatingIfNeeded: CadMath.int(Double(a) + (Double(b) - Double(a)) * amount)) }
        return CadColor(r: channel(color.r, toward.r), g: channel(color.g, toward.g), b: channel(color.b, toward.b))
    }
}
