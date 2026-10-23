// Port of Filee.Engines/Cad/CadCurves.cs: curve math for the CAD renderer — NURBS evaluation (SPLINE entities,
// spline hatch edges, spline-fit polylines), smooth curves through fit points, and polyline bulge arcs.

import Foundation

/// Curve evaluation helpers. Everything works in the entity's own coordinates.
enum CadCurves {
    /// Upper bound for the points generated for one curve, so a broken knot vector cannot explode.
    private static let maxSamples = 4000

    /// Samples a (rational) B-spline with de Boor's algorithm. Missing or inconsistent knots are replaced by a
    /// clamped uniform knot vector; missing weights mean 1. Returns an empty list for unusable input.
    static func sampleNurbs(_ degree: Int, _ controlPoints: [CadVec3], _ knots: [Double], _ weights: [Double]?) -> [CadVec3] {
        let n = controlPoints.count
        var result: [CadVec3] = []
        if n < 2 { return result }

        let p = min(max(degree, 1), n - 1)
        let t = knots.count == n + p + 1 && isNonDecreasing(knots) ? knots : clampedUniform(n, p)
        let w: [Double]? = if let weights, !weights.isEmpty, weights.count == n, weights.allSatisfy({ $0 > 0 && $0.isFinite }) {
            weights
        } else {
            nil
        }

        var spans: [Int] = []
        for k in p..<n where t[k + 1] > t[k] { spans.append(k) }
        if spans.isEmpty { return result }

        // Straight segments need only their end points; curved spans get up to 32 points (smooth in vector output).
        let perSpan = p == 1 ? 1 : min(max(maxSamples / spans.count, 1), 32)
        var homogeneous = [(x: Double, y: Double, z: Double, w: Double)](repeating: (0, 0, 0, 0), count: p + 1)

        func evaluate(_ u: Double, _ k: Int) -> CadVec3 {
            for j in 0...p {
                let point = controlPoints[k - p + j]
                let weight = w?[k - p + j] ?? 1
                homogeneous[j] = (point.x * weight, point.y * weight, point.z * weight, weight)
            }
            if p >= 1 {
                for r in 1...p {
                    var j = p
                    while j >= r {
                        let denominator = t[j + 1 + k - r] - t[j + k - p]
                        let alpha = denominator == 0 ? 0 : (u - t[j + k - p]) / denominator
                        let a = homogeneous[j - 1]
                        let b = homogeneous[j]
                        homogeneous[j] = ((1 - alpha) * a.x + alpha * b.x,
                                          (1 - alpha) * a.y + alpha * b.y,
                                          (1 - alpha) * a.z + alpha * b.z,
                                          (1 - alpha) * a.w + alpha * b.w)
                        j -= 1
                    }
                }
            }
            let h = homogeneous[p]
            return h.w == 0 ? CadVec3(h.x, h.y, h.z) : CadVec3(h.x / h.w, h.y / h.w, h.z / h.w)
        }

        for k in spans {
            for s in 0..<perSpan {
                result.append(evaluate(t[k] + (t[k + 1] - t[k]) * Double(s) / Double(perSpan), k))
            }
        }
        result.append(evaluate(t[spans[spans.count - 1] + 1], spans[spans.count - 1]))
        return result
    }

    /// A smooth curve through fit points (centripetal Catmull-Rom), used for splines stored only as fit points and
    /// for spline leaders. Close to what AutoCAD draws, without solving the interpolation system.
    static func throughPoints(_ points: [CadVec3], closed: Bool) -> [CadVec3] {
        let count = points.count
        var result: [CadVec3] = []
        if count < 3 {
            result.append(contentsOf: points)
            return result
        }

        func get(_ index: Int) -> CadVec3 {
            if closed { return points[((index % count) + count) % count] }
            // Open ends: mirror the neighbour so the tangent at the end points follows the polygon.
            if index < 0 { return points[0] + (points[0] - points[1]) }
            if index >= count { return points[count - 1] + (points[count - 1] - points[count - 2]) }
            return points[index]
        }

        let segments = closed ? count : count - 1
        let perSegment = min(max(maxSamples / segments, 1), 10)
        for i in 0..<segments {
            let p0 = get(i - 1)
            let p1 = get(i)
            let p2 = get(i + 1)
            let p3 = get(i + 2)
            for s in 0..<perSegment {
                result.append(catmullRom(p0, p1, p2, p3, Double(s) / Double(perSegment)))
            }
        }
        result.append(closed ? points[0] : points[count - 1])
        return result
    }

    /// The arc of a polyline segment with bulge `bulge` (tan of a quarter of the included angle, positive =
    /// counter-clockwise) from `p0` to `p1`.
    static func bulgeArc(_ p0: CadVec2, _ p1: CadVec2, _ bulge: Double) -> (center: CadVec2, radius: Double, startAngle: Double, sweep: Double) {
        let chord = p1 - p0
        let center = p0 + chord * 0.5 + chord.perp * ((1 - bulge * bulge) / (4 * bulge))
        let radius = (p0 - center).length
        let start = atan2(p0.y - center.y, p0.x - center.x)
        return (center, radius, start, 4 * atan(bulge))
    }

    private static func catmullRom(_ p0: CadVec3, _ p1: CadVec3, _ p2: CadVec3, _ p3: CadVec3, _ u: Double) -> CadVec3 {
        // Centripetal parameterisation (alpha = 0.5) avoids loops and cusps on unevenly spaced points.
        let t0 = 0.0
        let t1 = t0 + max((p1 - p0).length, 1e-12).squareRoot()
        let t2 = t1 + max((p2 - p1).length, 1e-12).squareRoot()
        let t3 = t2 + max((p3 - p2).length, 1e-12).squareRoot()
        let t = t1 + (t2 - t1) * u

        func lerp(_ a: CadVec3, _ b: CadVec3, _ ta: Double, _ tb: Double, _ t: Double) -> CadVec3 {
            a * ((tb - t) / (tb - ta)) + b * ((t - ta) / (tb - ta))
        }
        let a1 = lerp(p0, p1, t0, t1, t)
        let a2 = lerp(p1, p2, t1, t2, t)
        let a3 = lerp(p2, p3, t2, t3, t)
        let b1 = lerp(a1, a2, t0, t2, t)
        let b2 = lerp(a2, a3, t1, t3, t)
        return lerp(b1, b2, t1, t2, t)
    }

    private static func isNonDecreasing(_ values: [Double]) -> Bool {
        for i in values.indices.dropFirst() {
            if !(values[i] >= values[i - 1]) || !values[i].isFinite { return false }
        }
        return !values.isEmpty && values[values.count - 1] > values[0]
    }

    private static func clampedUniform(_ n: Int, _ p: Int) -> [Double] {
        (0..<(n + p + 1)).map { i in i <= p ? 0 : i >= n ? 1 : Double(i - p) / Double(n - p) }
    }
}
