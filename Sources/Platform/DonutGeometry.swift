import CoreGraphics

// Donut slice geometry; the first slice is centred at 12 o'clock.
enum DonutGeometry {
    static func segment(at point: CGPoint, center: CGPoint, innerRadius: Double, outerRadius: Double, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= outerRadius else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let span = 2 * Double.pi / Double(count)
        return Int(floor((angle + span / 2) / span)) % count
    }
}
