// Port of Filee.Engines/Fonts/Cff/CubicToQuadratic.cs.
import Foundation

enum CubicToQuadratic {
    private typealias Piece = (a: FontVec2, b: FontVec2, c: FontVec2, d: FontVec2)
    static func convert(_ p0: FontVec2, _ p1: FontVec2, _ p2: FontVec2, _ p3: FontVec2, _ tolerance: Double) -> [FontVec2] {
        if isLine(p0, p1, p2, p3, tolerance) { return [] }
        for n in 1...100 { if let spline = n == 1 ? single(p0, p1, p2, p3, tolerance) : spline(p0, p1, p2, p3, n, tolerance) { return spline } }
        return spline(p0, p1, p2, p3, 100, .infinity)!
    }
    private static func isLine(_ p0: FontVec2, _ p1: FontVec2, _ p2: FontVec2, _ p3: FontVec2, _ tolerance: Double) -> Bool {
        let chord = p3 - p0, length = chord.length
        if length < 1e-9 { return (p1 - p0).length < 1e-9 && (p2 - p0).length < 1e-9 }
        for p in [p1, p2] {
            let v = p - p0, along = FontVec2.dot(v, chord) / (length * length), distance = abs(v.x * chord.y - v.y * chord.x) / length
            if along < 0 || along > 1 || distance > tolerance * 0.01 { return false }
        }
        return true
    }
    private static func single(_ p0: FontVec2, _ p1: FontVec2, _ p2: FontVec2, _ p3: FontVec2, _ tolerance: Double) -> [FontVec2]? {
        guard let q = intersect(p0, p1, p2, p3) else { return nil }
        let c1 = p0 + (q - p0) * (2.0 / 3), c2 = p3 + (q - p3) * (2.0 / 3)
        return fitsInside(FontVec2(), c1 - p1, c2 - p2, FontVec2(), tolerance, 0) ? [q] : nil
    }
    private static func spline(_ p0: FontVec2, _ p1: FontVec2, _ p2: FontVec2, _ p3: FontVec2, _ n: Int, _ tolerance: Double) -> [FontVec2]? {
        let pieces = split(p0, p1, p2, p3, n), controls = (0..<n).map { control(Double($0) / Double(n - 1), pieces[$0]) }
        var d1 = FontVec2(), q2 = p0
        for i in 0..<n {
            let piece = pieces[i], q0 = q2, q1 = controls[i]; q2 = i + 1 < n ? (q1 + controls[i + 1]) * 0.5 : piece.d
            let d0 = d1; d1 = q2 - piece.d
            if d1.length > tolerance || !fitsInside(d0, q0 + (q1 - q0) * (2.0 / 3) - piece.b, q2 + (q1 - q2) * (2.0 / 3) - piece.c, d1, tolerance, 0) { return nil }
        }
        return controls
    }
    private static func control(_ t: Double, _ piece: Piece) -> FontVec2 {
        let start = piece.a + (piece.b - piece.a) * 1.5, end = piece.d + (piece.c - piece.d) * 1.5
        return start + (end - start) * t
    }
    private static func split(_ p0: FontVec2, _ p1: FontVec2, _ p2: FontVec2, _ p3: FontVec2, _ n: Int) -> [Piece] {
        let c = (p1 - p0) * 3, b = (p2 - p1) * 3 - c, d = p0, a = p3 - d - c - b, dt = 1.0 / Double(n)
        return (0..<n).map { i in
            let t0 = Double(i) * dt, a1 = a * (dt * dt * dt), b1 = (a * (3 * t0) + b) * (dt * dt)
            let c1 = (b * (2 * t0) + c + a * (3 * t0 * t0)) * dt, d1 = a * (t0 * t0 * t0) + b * (t0 * t0) + c * t0 + d
            let q1 = c1 * (1.0 / 3) + d1, q2 = (b1 + c1) * (1.0 / 3) + q1, q3 = a1 + d1 + c1 + b1
            return (d1, q1, q2, q3)
        }
    }
    private static func intersect(_ a: FontVec2, _ b: FontVec2, _ c: FontVec2, _ d: FontVec2) -> FontVec2? {
        let ab = b - a, cd = d - c, normal = FontVec2(-ab.y, ab.x), denominator = FontVec2.dot(normal, cd)
        if abs(denominator) < 1e-12 { return nil }
        return c + cd * (FontVec2.dot(normal, a - c) / denominator)
    }
    private static func fitsInside(_ p0: FontVec2, _ p1: FontVec2, _ p2: FontVec2, _ p3: FontVec2, _ tolerance: Double, _ depth: Int) -> Bool {
        if p2.length <= tolerance && p1.length <= tolerance { return true }
        let mid = (p0 + (p1 + p2) * 3 + p3) * 0.125
        if mid.length > tolerance { return false }
        if depth >= 24 { return true }
        let deriv = (p3 + p2 - p1 - p0) * 0.125
        return fitsInside(p0, (p0 + p1) * 0.5, mid - deriv, mid, tolerance, depth + 1) && fitsInside(mid, mid + deriv, (p2 + p3) * 0.5, p3, tolerance, depth + 1)
    }
}
