// Port of HwpxReader.Objects.cs.
import Foundation

extension HwpxReader {
    static let shapeNames: Set<String> = [
        "pic", "rect", "ellipse", "line", "arc", "polygon", "curve", "connectLine", "container",
    ]
    struct Placement {
        let width: Int
        let height: Int
        let anchor: HAnchor?
    }
    func drawingObject(_ e: XElement, _ b: ParagraphBuilder, _ f: HCharFormat) throws {
        if Self.shapeNames.contains(e.name.localName) {
            for i in try shapes(e, Self.placementOf(e)) { b.add(i) }
            return
        }
        let value: String?
        switch e.name.localName {
        case "equation": value = Self.child(e, "script").map { DocumentXML.trim($0.value) }
        case "textart": value = Self.attr(e, "text") ?? Self.child(e, "text")?.value
        case "compose": value = Self.attr(e, "composeText") ?? Self.child(e, "composeText")?.value
        case "dutmal": value = Self.attr(e, "mainText") ?? Self.child(e, "mainText")?.value
        default:
            skip(e)
            return
        }
        if let value, !value.isEmpty { b.addText(value, f) }
    }
    func shapes(_ e: XElement, _ p: Placement) throws -> [HInline] {
        switch e.name.localName {
        case "pic":
            let img = e.descendants().first { $0.name.localName == "img" && $0.attribute("binaryItemIDRef") != nil }
            if let path = try extractBinary(Self.attr(img, "binaryItemIDRef")) {
                let image = HImage(path)
                image.width = p.width > 0 ? p.width : nil
                image.height = p.height > 0 ? p.height : nil
                image.anchor = p.anchor
                return [image]
            }
            skip("pic")
            return []
        case "rect": return [try box(e, .rectangle, p)]
        case "ellipse": return [try box(e, .ellipse, p)]
        case "line":
            let start = Self.child(e, "startPt")
            let end = Self.child(e, "endPt")
            let points = start != nil && end != nil
            let s = HShape(.line)
            s.width = points && Self.int(start, "x") == Self.int(end, "x") ? 0 : p.width
            s.height = points && Self.int(start, "y") == Self.int(end, "y") ? 0 : p.height
            s.anchor = p.anchor
            s.line = Self.lineShape(Self.child(e, "lineShape"))
            s.flipHorizontal = Self.int(start, "x") > Self.int(end, "x")
            s.flipVertical = Self.int(start, "y") > Self.int(end, "y")
            return [s]
        case "container":
            let a = p.anchor ?? HAnchor("COLUMN", "LEFT", 0, "PARA", "TOP", 0, "IN_FRONT_OF_TEXT", true)
            var result: [HInline] = []
            for member in Self.elements(e) where Self.shapeNames.contains(member.name.localName) {
                let offset = Self.child(member, "offset")
                let (w, h) = Self.memberSize(member)
                var anchor = a
                anchor.horizontalOffset += Self.alignedOffset(a.horizontalAlign, Self.int(offset, "x"), w, p.width)
                anchor.verticalOffset += Self.alignedOffset(a.verticalAlign, Self.int(offset, "y"), h, p.height)
                anchor.allowOverlap = true
                result += try shapes(member, Placement(width: w, height: h, anchor: anchor))
            }
            return result
        default:
            if Self.child(e, "drawText") != nil, let b = try box(e, .rectangle, p) as? HTextBox {
                b.line = .none
                b.fill = nil
                b.gradient = nil
                return [b]
            }
            skip(e)
            return []
        }
    }
    func box(_ e: XElement, _ kind: HShapeKind, _ p: Placement) throws -> HInline {
        let line = Self.lineShape(Self.child(e, "lineShape"))
        let (fill, gradient) = Self.fillBrush(Self.child(e, "fillBrush"))
        let ratio = kind == .rectangle ? Self.int(e, "ratio") : 0
        guard let draw = Self.child(e, "drawText") else {
            let s = HShape(kind)
            s.width = p.width
            s.height = p.height
            s.anchor = p.anchor
            s.fill = fill
            s.gradient = gradient
            s.line = line
            s.cornerRatio = ratio
            return s
        }
        let sub = Self.child(draw, "subList")
        let b = HTextBox()
        b.width = p.width
        b.height = p.height
        b.anchor = p.anchor
        b.fill = fill
        b.gradient = gradient
        b.line = line
        b.shape = kind
        b.cornerRatio = ratio
        b.verticalAlign = Self.verticalAlign(Self.attr(sub, "vertAlign"))
        if let m = Self.child(draw, "textMargin") { b.padding = Self.insets(m) }
        b.blocks = try readSubList(sub)
        return b
    }
    static func alignedOffset(_ align: String, _ position: Int, _ size: Int, _ groupSize: Int) -> Int {
        align == "CENTER"
            ? position + size / 2 - groupSize / 2
            : ["RIGHT", "BOTTOM"].contains(align) ? position + size - groupSize : position
    }
    static func memberSize(_ e: XElement) -> (Int, Int) {
        let current = child(e, "curSz")
        if int(current, "width") > 0 && int(current, "height") > 0 {
            return (int(current, "width"), int(current, "height"))
        }
        let original = child(e, "orgSz")
        let scale = child(child(e, "renderingInfo"), "scaMatrix")
        func factor(_ n: String) -> Double {
            let d = DocumentXML.double(attr(scale, n)) ?? 1
            return d == 0 ? 1 : d
        }
        return (
            Int((Double(int(original, "width")) * factor("e1")).rounded(.toNearestOrEven)),
            Int((Double(int(original, "height")) * factor("e5")).rounded(.toNearestOrEven))
        )
    }
    static func placementOf(_ e: XElement) -> Placement {
        let sz = child(e, "sz")
        var w = int(sz, "width")
        var h = int(sz, "height")
        if w <= 0 || h <= 0 { (w, h) = memberSize(e) }
        return Placement(width: w, height: h, anchor: anchor(e))
    }
    static func anchor(_ e: XElement) -> HAnchor? {
        guard let p = child(e, "pos"), !flag(p, "treatAsChar") else { return nil }
        let wrap: String
        switch attr(e, "textWrap") {
        case "SQUARE", "TIGHT", "THROUGH": wrap = "SQUARE"
        case "BEHIND_TEXT": wrap = "BEHIND_TEXT"
        case "IN_FRONT_OF_TEXT": wrap = "IN_FRONT_OF_TEXT"
        default: wrap = "TOP_AND_BOTTOM"
        }
        return HAnchor(
            attr(p, "horzRelTo") ?? "COLUMN", attr(p, "horzAlign") ?? "LEFT", int(p, "horzOffset"),
            attr(p, "vertRelTo") ?? "PARA", attr(p, "vertAlign") ?? "TOP", int(p, "vertOffset"), wrap,
            flag(p, "allowOverlap"))
    }
    static func lineShape(_ e: XElement?) -> HBorder {
        let style = lineStyle(attr(e, "style"))
        if e == nil || style == .none { return .none }
        let w = int(e, "width")
        return HBorder(style, w > 0 ? Double(w) / HwpxUnits.perMm : 0.1, color(attr(e, "color")) ?? "#000000")
    }
    static func fillBrush(_ e: XElement?) -> (String?, HGradient?) {
        if let g = child(e, "gradation") {
            let colors = children(g, "color").compactMap { color(attr($0, "value")) }
            if colors.count >= 2 { return (nil, HGradient(colors, int(g, "angle"))) }
            if colors.count == 1 { return (colors[0], nil) }
        }
        return (color(attr(child(e, "winBrush"), "faceColor")), nil)
    }
}
