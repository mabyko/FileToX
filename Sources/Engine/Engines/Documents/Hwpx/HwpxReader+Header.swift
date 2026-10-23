// Port of HwpxReader.Header.cs.
import Foundation

extension HwpxReader {
    func loadHeader(_ head: XElement) {
        for e in head.descendants() {
            guard let id = Self.attr(e, "id") else { continue }
            switch e.name.localName {
            case "font" where e.parent?.name.localName == "fontface":
                fonts[(Self.attr(e.parent, "lang") ?? "") + "\0" + id] = Self.attr(e, "face") ?? ""
            case "charPr": if charPrs[id] == nil { charPrs[id] = e }
            case "paraPr": if paraPrs[id] == nil { paraPrs[id] = e }
            case "borderFill": if borderElements[id] == nil { borderElements[id] = e }
            case "tabPr": if tabPrs[id] == nil { tabPrs[id] = e }
            case "numbering" where e.parent?.name.localName == "numberings":
                if numberingElements[id] == nil { numberingElements[id] = e }
            case "bullet" where e.parent?.name.localName == "bullets":
                if bulletElements[id] == nil { bulletElements[id] = e }
            case "style": if styles[id] == nil { styles[id] = e }
            default: break
            }
        }
    }
    func charFormat(_ id: String?) -> HCharFormat {
        let id = id ?? "0"
        if let f = charFormats[id] { return f }
        guard let e = charPrs[id] ?? charPrs["0"] else {
            charFormats[id] = HCharFormat()
            return HCharFormat()
        }
        func face(_ lang: String) -> String? {
            guard let ref = Self.attr(Self.child(e, "fontRef"), lang.lowercased()), let f = fonts[lang + "\0" + ref],
                !f.isEmpty
            else { return nil }
            return f
        }
        let strike = Self.attr(Self.child(e, "strikeout"), "shape")
        let f = HCharFormat(
            bold: Self.child(e, "bold") != nil, italic: Self.child(e, "italic") != nil,
            underline: Self.attr(Self.child(e, "underline"), "type") == "BOTTOM",
            strike: strike != nil && strike != "NONE" && strike != "3D", superscript: Self.child(e, "supscript") != nil,
            subscript: Self.child(e, "subscript") != nil, size: Self.int(e, "height", 1000), font: face("LATIN"),
            eastAsianFont: face("HANGUL"), color: Self.color(Self.attr(e, "textColor")) ?? "#000000",
            shade: Self.color(Self.attr(e, "shadeColor")), spacing: Self.int(Self.child(e, "spacing"), "hangul"))
        charFormats[id] = f
        return f
    }
    func paraShapeOf(_ id: String?) -> ParaShape {
        let id = id ?? "0"
        if let f = paraShapes[id] { return f }
        guard let e = paraPrs[id] ?? paraPrs["0"] else {
            return ParaShape(format: HParaFormat(), headingType: "NONE", headingId: nil, level: 0, pageBreak: false)
        }
        let heading = Self.child(e, "heading")
        let breaks = Self.child(e, "breakSetting")
        let (intent, left, right, before, after, line) = Self.spacing(e)
        let align: HAlign
        switch Self.attr(Self.child(e, "align"), "horizontal") {
        case "CENTER": align = .center
        case "RIGHT": align = .right
        case "JUSTIFY": align = .justify
        case "DISTRIBUTE", "DISTRIBUTE_SPACE": align = .distribute
        default: align = .left
        }
        let f = HParaFormat(
            align: align, left: intent < 0 ? left - intent : left, right: right, firstLine: intent, before: before,
            after: after, lineSpacing: line, keepWithNext: Self.flag(breaks, "keepWithNext"),
            keepLines: Self.flag(breaks, "keepLines"), widowOrphan: Self.flag(breaks, "widowOrphan"),
            tabs: tabStops(Self.attr(e, "tabPrIDRef")))
        let shape = ParaShape(
            format: f, headingType: Self.attr(heading, "type") ?? "NONE", headingId: Self.attr(heading, "idRef"),
            level: max(0, Self.int(heading, "level")), pageBreak: Self.flag(breaks, "pageBreakBefore"))
        paraShapes[id] = shape
        return shape
    }
    static func spacing(_ e: XElement) -> (Int, Int, Int, Int, Int, HLineSpacing) {
        var margin: XElement?
        var line: XElement?
        var marginExact = false
        var lineExact = false
        for c in e.elements() {
            switch c.name.localName {
            case "switch":
                let (b, exact) = branch(c)
                if let m = b?.elements().first(where: { $0.name.localName == "margin" }) {
                    margin = m
                    marginExact = exact
                }
                if let l = b?.elements().first(where: { $0.name.localName == "lineSpacing" }) {
                    line = l
                    lineExact = exact
                }
            case "margin" where margin == nil: margin = c
            case "lineSpacing" where line == nil: line = c
            default: break
            }
        }
        func length(_ name: String, _ attribute: String) -> Int {
            let e = margin?.elements().first { $0.name.localName == name }
            let value = e.map { int($0, "value") } ?? int(margin, attribute)
            return marginExact ? value : Int((Double(value) / 2).rounded(.toNearestOrEven))
        }
        let type = attr(line, "type") ?? "PERCENT"
        let value = int(line, "value", 160)
        let len = lineExact ? value : Int((Double(value) / 2).rounded(.toNearestOrEven))
        let ls: HLineSpacing
        switch type {
        case "FIXED": ls = HLineSpacing(.fixed, len)
        case "AT_LEAST", "MINIMUM": ls = HLineSpacing(.atLeast, len)
        case "BETWEEN_LINES", "SPACE_ONLY", "SPACEONLY": ls = HLineSpacing(.atLeast, 1000 + len)
        default: ls = HLineSpacing(.percent, value)
        }
        return (
            length("intent", "indent"), length("left", "left"), length("right", "right"), length("prev", "prev"),
            length("next", "next"), ls
        )
    }
    func tabStops(_ id: String?) -> [HTabStop]? {
        guard let id, let e = tabPrs[id] else { return nil }
        var stops: [HTabStop] = []
        for c in e.elements() {
            let items: [XElement]
            let exact: Bool
            if c.name.localName == "switch" {
                let (b, x) = Self.branch(c)
                items = b?.elements() ?? []
                exact = x
            } else if c.name.localName == "tabItem" {
                items = [c]
                exact = Self.attr(c, "unit") == "HWPUNIT"
            } else {
                continue
            }
            for item in items where item.name.localName == "tabItem" {
                let p = Self.int(item, "pos")
                let type = Self.attr(item, "type")
                stops.append(
                    HTabStop(
                        exact ? p : p / 2,
                        type == "RIGHT" ? .right : type == "CENTER" ? .center : type == "DECIMAL" ? .decimal : .left,
                        Self.attr(item, "leader") ?? "NONE"))
            }
        }
        return stops.isEmpty ? nil : stops
    }
    func numbering(_ id: String?) -> HNumbering? {
        guard let id else { return nil }
        if let n = numberings["n" + id] { return n }
        var n: HNumbering?
        if let e = numberingElements[id] {
            let result = HNumbering()
            let start = Self.int(e, "start", 1)
            for h in Self.children(e, "paraHead").sorted(by: { Self.int($0, "level", 1) < Self.int($1, "level", 1) }) {
                let text = h.value
                result.levels.append(
                    HNumberingLevel(
                        Self.attr(h, "numFormat") ?? "DIGIT", text, Self.int(h, "start", max(start, 1)),
                        !text.isEmpty && !Self.hasCounter(text)))
            }
            n = result
        }
        numberings["n" + id] = .some(n)
        return n
    }
    func bullet(_ id: String?) -> HNumbering? {
        guard let id else { return nil }
        if let n = numberings["b" + id] { return n }
        var n: HNumbering?
        if let e = bulletElements[id] {
            let t = Self.attr(e, "char")
            let symbol = t?.isEmpty == false && !Self.flag(e, "useImage") ? Self.bulletSymbol(t!) : "●"
            let result = HNumbering()
            result.levels = [HNumberingLevel](repeating: HNumberingLevel("DIGIT", symbol, 1, true), count: 10)
            n = result
        }
        numberings["b" + id] = .some(n)
        return n
    }
    static func hasCounter(_ text: String) -> Bool {
        let a = Array(text.utf16)
        return a.indices.dropLast().contains { a[$0] == 94 && DocumentXML.isDigit(a[$0 + 1]) }
    }
    static func bulletSymbol(_ text: String) -> String {
        text.utf16.first.map { (0xE000...0xF8FF).contains($0) ? "●" : text } ?? text
    }
    func borderFill(_ id: String?) -> (borders: HBorders, fill: String?)? {
        guard let id else { return nil }
        if let b = borderFills[id] { return b }
        var result: (HBorders, String?)?
        if let e = borderElements[id] {
            let brush = Self.child(e, "fillBrush")
            let borders = HBorders(
                Self.border(Self.child(e, "leftBorder")), Self.border(Self.child(e, "rightBorder")),
                Self.border(Self.child(e, "topBorder")), Self.border(Self.child(e, "bottomBorder")))
            let fill =
                Self.color(Self.attr(Self.child(brush, "winBrush"), "faceColor"))
                ?? Self.children(Self.child(brush, "gradation"), "color").compactMap {
                    Self.color(Self.attr($0, "value"))
                }.first
            result = (borders, fill)
        }
        borderFills[id] = .some(result)
        return result
    }
    static func border(_ edge: XElement?) -> HBorder {
        let style = lineStyle(attr(edge, "type"))
        if edge == nil || style == .none { return .none }
        let n = String((attr(edge, "width") ?? "0.12").prefix { $0.isNumber || $0 == "." })
        let mm = Double(n) ?? 0.12
        return HBorder(style, mm > 0 ? mm : 0.12, color(attr(edge, "color")) ?? "#000000")
    }
    static func lineStyle(_ type: String?) -> HBorderStyle {
        switch type {
        case nil, "NONE": return .none
        case "DASH", "LONG_DASH": return .dash
        case "DOT", "CIRCLE": return .dot
        case "DASH_DOT", "DASH_DOT_DOT": return .dashDot
        case "DOUBLE_SLIM", "SLIM_THICK", "THICK_SLIM", "SLIM_THICK_SLIM", "DOUBLE_WAVE": return .double
        default: return .solid
        }
    }
    func styleHeadingLevel(_ id: String?) -> Int {
        guard let id, let s = styles[id], let n = Self.attr(s, "engName"), n.lowercased().hasPrefix("heading "),
            let level = Int(n.dropFirst(8)), (1...9).contains(level)
        else { return 0 }
        return level
    }
}
