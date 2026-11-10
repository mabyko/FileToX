// Port of Filee.Engines/Cad/CadGeometry.cs: geometry for the CAD renderer — 3D affine transforms (block inserts,
// object coordinate systems), 2D paths whose arcs are stored as cubic Béziers so they stay exact under any affine
// transform, and bounding boxes.

import Foundation

/// A point or vector in the drawing plane (WCS X/Y after the top-view projection).
struct CadVec2: Equatable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    static let zero = CadVec2(0, 0)

    static func + (a: CadVec2, b: CadVec2) -> CadVec2 { CadVec2(a.x + b.x, a.y + b.y) }
    static func - (a: CadVec2, b: CadVec2) -> CadVec2 { CadVec2(a.x - b.x, a.y - b.y) }
    static prefix func - (a: CadVec2) -> CadVec2 { CadVec2(-a.x, -a.y) }
    static func * (a: CadVec2, k: Double) -> CadVec2 { CadVec2(a.x * k, a.y * k) }
    static func * (k: Double, a: CadVec2) -> CadVec2 { CadVec2(a.x * k, a.y * k) }

    var length: Double { (x * x + y * y).squareRoot() }

    /// The vector rotated by +90°.
    var perp: CadVec2 { CadVec2(-y, x) }

    var isFinite: Bool { x.isFinite && y.isFinite }

    func normalized() -> CadVec2 {
        let length = self.length
        return length > 0 ? CadVec2(x / length, y / length) : CadVec2(1, 0)
    }

    static func dot(_ a: CadVec2, _ b: CadVec2) -> Double { a.x * b.x + a.y * b.y }
}

/// A 3D point or vector (double precision) used while walking entities and blocks.
struct CadVec3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ p: ACad.XYZ) { self.init(p.x, p.y, p.z) }

    static let zero = CadVec3(0, 0, 0)

    static func + (a: CadVec3, b: CadVec3) -> CadVec3 { CadVec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: CadVec3, b: CadVec3) -> CadVec3 { CadVec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: CadVec3, k: Double) -> CadVec3 { CadVec3(a.x * k, a.y * k, a.z * k) }

    var length: Double { (x * x + y * y + z * z).squareRoot() }

    static func cross(_ a: CadVec3, _ b: CadVec3) -> CadVec3 {
        CadVec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    func normalized() -> CadVec3 {
        let length = self.length
        return length > 0 ? CadVec3(x / length, y / length, z / length) : CadVec3(0, 0, 1)
    }
}

/// A 3D affine transform from an entity's own coordinates to WCS: the images of the X, Y and Z axes plus a
/// translation. Block inserts, arrays and object coordinate systems (OCS) are chained as products of these.
struct CadAffine3 {
    let x: CadVec3
    let y: CadVec3
    let z: CadVec3
    let t: CadVec3

    init(_ x: CadVec3, _ y: CadVec3, _ z: CadVec3, _ t: CadVec3) {
        self.x = x
        self.y = y
        self.z = z
        self.t = t
    }

    static let identity = CadAffine3(CadVec3(1, 0, 0), CadVec3(0, 1, 0), CadVec3(0, 0, 1), .zero)

    static func translation(_ t: CadVec3) -> CadAffine3 { CadAffine3(CadVec3(1, 0, 0), CadVec3(0, 1, 0), CadVec3(0, 0, 1), t) }

    static func scale(_ sx: Double, _ sy: Double, _ sz: Double) -> CadAffine3 {
        CadAffine3(CadVec3(sx, 0, 0), CadVec3(0, sy, 0), CadVec3(0, 0, sz), .zero)
    }

    static func rotationZ(_ angle: Double) -> CadAffine3 {
        let (sin, cos) = (Foundation.sin(angle), Foundation.cos(angle))
        return CadAffine3(CadVec3(cos, sin, 0), CadVec3(-sin, cos, 0), CadVec3(0, 0, 1), .zero)
    }

    /// The object coordinate system of an entity with the given extrusion direction, built with AutoCAD's
    /// "arbitrary axis algorithm". Mirrored 2D entities typically carry the normal (0, 0, -1).
    static func ocs(_ normal: CadVec3) -> CadAffine3 {
        let n = normal.normalized()
        if abs(n.x) < 1e-12 && abs(n.y) < 1e-12 && n.z > 0 { return identity }
        let limit = 1.0 / 64
        var ax = abs(n.x) < limit && abs(n.y) < limit
            ? CadVec3.cross(CadVec3(0, 1, 0), n)
            : CadVec3.cross(CadVec3(0, 0, 1), n)
        ax = ax.normalized()
        let ay = CadVec3.cross(n, ax).normalized()
        return CadAffine3(ax, ay, n, .zero)
    }

    static func ocs(_ normal: ACad.XYZ) -> CadAffine3 { ocs(CadVec3(normal)) }

    func apply(_ p: CadVec3) -> CadVec3 {
        CadVec3(t.x + x.x * p.x + y.x * p.y + z.x * p.z,
                t.y + x.y * p.x + y.y * p.y + z.y * p.z,
                t.z + x.z * p.x + y.z * p.y + z.z * p.z)
    }

    func applyVector(_ v: CadVec3) -> CadVec3 {
        CadVec3(x.x * v.x + y.x * v.y + z.x * v.z,
                x.y * v.x + y.y * v.y + z.y * v.z,
                x.z * v.x + y.z * v.y + z.z * v.z)
    }

    /// Maps a point and projects it onto the drawing plane.
    func point(_ p: CadVec3) -> CadVec2 {
        let w = apply(p)
        return CadVec2(w.x, w.y)
    }

    func point(_ p: ACad.XYZ) -> CadVec2 { point(CadVec3(p)) }

    /// Maps a point given in the entity's XY plane (Z = `z`).
    func point(_ x: Double, _ y: Double, _ z: Double = 0) -> CadVec2 { point(CadVec3(x, y, z)) }

    /// Maps a direction vector and projects it onto the drawing plane.
    func vector(_ v: CadVec3) -> CadVec2 {
        let w = applyVector(v)
        return CadVec2(w.x, w.y)
    }

    func vector(_ x: Double, _ y: Double) -> CadVec2 { vector(CadVec3(x, y, 0)) }

    /// Composition: first `inner`, then this transform.
    func multiply(_ inner: CadAffine3) -> CadAffine3 {
        CadAffine3(applyVector(inner.x), applyVector(inner.y), applyVector(inner.z), apply(inner.t))
    }

    /// Average scale of the projected XY plane (square root of the area ratio), used for widths and dash lengths
    /// that are defined in the entity's units.
    var planScale: Double {
        let det = abs(x.x * y.y - x.y * y.x)
        if det > 1e-300 { return det.squareRoot() }
        // A plane seen edge-on: fall back to the longest axis image so widths do not vanish.
        return max(CadVec2(x.x, x.y).length, CadVec2(y.x, y.y).length)
    }
}

/// One segment of a `CadFigure`: a straight line or a cubic Bézier ending in `p`.
struct CadSegment: Equatable {
    var c1: CadVec2
    var c2: CadVec2
    var p: CadVec2
    var isCubic: Bool

    static func line(_ p: CadVec2) -> CadSegment { CadSegment(c1: .zero, c2: .zero, p: p, isCubic: false) }

    static func cubic(_ c1: CadVec2, _ c2: CadVec2, _ p: CadVec2) -> CadSegment { CadSegment(c1: c1, c2: c2, p: p, isCubic: true) }
}

/// A connected run of segments in WCS (a polyline, an arc, a hatch loop ...).
final class CadFigure {
    let start: CadVec2
    var segments: [CadSegment] = []
    var closed = false

    init(_ start: CadVec2) { self.start = start }

    var end: CadVec2 { segments.last?.p ?? start }

    func lineTo(_ p: CadVec2) { segments.append(.line(p)) }

    /// Appends the elliptical arc `C + U·cos t + V·sin t` for t from `t0` to `t1` as cubic Béziers of at most 90°
    /// each. The figure should already end at the arc start. Because U and V are the images of the original axes,
    /// this is exact for circles seen through any affine transform (non-uniform block scales, tilted planes).
    func arcTo(_ center: CadVec2, _ u: CadVec2, _ v: CadVec2, _ t0: Double, _ t1: Double) {
        let sweep = t1 - t0
        let count = max(1, CadMath.int((abs(sweep) / (Double.pi / 2) - 1e-9).rounded(.up)))
        let step = sweep / Double(count)
        let k = 4.0 / 3.0 * tan(step / 4)
        for i in 0..<count {
            let a = t0 + step * Double(i)
            let b = a + step
            let (sa, ca) = (sin(a), cos(a))
            let (sb, cb) = (sin(b), cos(b))
            let p0 = center + u * ca + v * sa
            let p3 = center + u * cb + v * sb
            let d0 = u * -sa + v * ca
            let d3 = u * -sb + v * cb
            segments.append(.cubic(p0 + d0 * k, p3 - d3 * k, p3))
        }
    }

    /// Includes every point of the figure (not just the Bézier control points) in `box`.
    func add(to box: inout CadBox2) {
        box.add(start)
        var previous = start
        for segment in segments {
            if segment.isCubic {
                CadFigure.addCubic(&box, previous, segment.c1, segment.c2, segment.p)
            } else {
                box.add(segment.p)
            }
            previous = segment.p
        }
    }

    /// Exact bounds of a cubic Bézier: its end points and the roots of the derivative per axis.
    private static func addCubic(_ box: inout CadBox2, _ p0: CadVec2, _ p1: CadVec2, _ p2: CadVec2, _ p3: CadVec2) {
        box.add(p3)
        var roots: [Double] = []
        derivativeRoots(p0.x, p1.x, p2.x, p3.x, &roots)
        derivativeRoots(p0.y, p1.y, p2.y, p3.y, &roots)
        for t in roots {
            let mt = 1 - t
            let a = mt * mt * mt
            let b = 3 * mt * mt * t
            let c = 3 * mt * t * t
            let d = t * t * t
            box.add(CadVec2(a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                            a * p0.y + b * p1.y + c * p2.y + d * p3.y))
        }
    }

    private static func derivativeRoots(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ roots: inout [Double]) {
        // B'(t)/3 = a t² + b t + c
        let a = -p0 + 3 * p1 - 3 * p2 + p3
        let b = 2 * (p0 - 2 * p1 + p2)
        let c = p1 - p0
        func keep(_ t: Double) {
            if t > 0 && t < 1 { roots.append(t) }
        }
        if abs(a) < 1e-12 {
            if abs(b) > 1e-12 { keep(-c / b) }
            return
        }
        let disc = b * b - 4 * a * c
        if disc < 0 { return }
        let sq = disc.squareRoot()
        keep((-b + sq) / (2 * a))
        keep((-b - sq) / (2 * a))
    }
}

/// An axis-aligned bounding box in WCS; empty until the first point is added.
struct CadBox2 {
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    var isEmpty = true

    static var empty: CadBox2 { CadBox2() }

    var width: Double { isEmpty ? 0 : maxX - minX }
    var height: Double { isEmpty ? 0 : maxY - minY }

    mutating func add(_ p: CadVec2) {
        // Garbage coordinates (NaN, 1e300 from corrupt files) must not blow up the page fit.
        if !p.isFinite || abs(p.x) > 1e15 || abs(p.y) > 1e15 { return }
        minX = min(minX, p.x)
        minY = min(minY, p.y)
        maxX = max(maxX, p.x)
        maxY = max(maxY, p.y)
        isEmpty = false
    }
}
