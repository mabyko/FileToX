import CoreGraphics

enum PanelPlacement {
    static func frame(near point: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
        let x = min(max(point.x - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(point.y - size.height / 2, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
