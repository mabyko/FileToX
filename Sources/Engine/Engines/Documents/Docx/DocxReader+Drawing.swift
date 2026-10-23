// Port of DocxReader.Drawing.cs: DrawingML groups, shapes, text boxes and legacy VML.
import Foundation

extension DocxReader {
    func drawing(_ drawing: XElement) throws -> [HInline] {
        var result: [HInline] = []
        for c in drawing.elements() where c.name == Self.wp + "anchor" || c.name == Self.wp + "inline" {
            let e = c.element(Self.wp + "extent")
            let w = HwpxUnits.fromEmu(Double(Self.long(e, "cx") ?? 0))
            let h = HwpxUnits.fromEmu(Double(Self.long(e, "cy") ?? 0))
            let anchor = c.name == Self.wp + "anchor" ? Self.anchor(c) : nil
            result += try graphicObjects(
                c.element(Self.a + "graphic")?.element(Self.a + "graphicData")?.elements() ?? [], w, h, anchor)
        }
        return result
    }
    func graphicObjects(_ objects: [XElement], _ width: Int, _ height: Int, _ anchor: HAnchor?) throws -> [HInline] {
        var result: [HInline] = []
        for e in objects {
            if e.name == Self.pic + "pic" {
                if let p = try picture(e, width, height, anchor) { result.append(p) }
            } else if e.name == Self.wps + "wsp" {
                if let s = try shape(e, width, height, anchor) { result.append(s) }
            } else if [Self.wpg + "wgp", Self.wpg + "grpSp", Self.wpc + "wpc"].contains(e.name) {
                let xfrm =
                    e.element(Self.wpg + "grpSpPr")?.element(Self.a + "xfrm")
                    ?? e.element(Self.a + "grpSpPr")?.element(Self.a + "xfrm")
                let off = xfrm?.element(Self.a + "chOff")
                let ext = xfrm?.element(Self.a + "chExt")
                let cx = Self.long(ext, "cx") ?? 0
                let cy = Self.long(ext, "cy") ?? 0
                let sx = cx > 0 ? Double(width) / Double(cx) : 1 / 127.0
                let sy = cy > 0 ? Double(height) / Double(cy) : 1 / 127.0
                let ox = Self.long(off, "x") ?? 0
                let oy = Self.long(off, "y") ?? 0
                for child in e.elements() {
                    let f = child.descendants(Self.a + "xfrm").first
                    let o = f?.element(Self.a + "off")
                    let ce = f?.element(Self.a + "ext")
                    let x = Int(Double((Self.long(o, "x") ?? 0) - ox) * sx)
                    let y = Int(Double((Self.long(o, "y") ?? 0) - oy) * sy)
                    let cw = Int(Double(Self.long(ce, "cx") ?? 0) * sx)
                    let ch = Int(Double(Self.long(ce, "cy") ?? 0) * sy)
                    var a = anchor ?? HAnchor("COLUMN", "LEFT", x, "PARA", "TOP", y, "IN_FRONT_OF_TEXT", true)
                    if anchor != nil {
                        a.horizontalOffset += HwpxReader.alignedOffset(a.horizontalAlign, x, cw, width)
                        a.verticalOffset += HwpxReader.alignedOffset(a.verticalAlign, y, ch, height)
                        a.allowOverlap = true
                    }
                    result += try graphicObjects([child], cw, ch, a)
                }
            }
        }
        return result
    }
    func picture(_ e: XElement, _ w: Int, _ h: Int, _ a: HAnchor?) throws -> HImage? {
        guard let path = try extractImage(Self.attr(e.descendants(Self.a + "blip").first, "embed", Self.r)) else {
            return nil
        }
        let i = HImage(path)
        i.width = w > 0 ? w : nil
        i.height = h > 0 ? h : nil
        i.anchor = a
        return i
    }
    func shape(_ e: XElement, _ w: Int, _ h: Int, _ anchor: HAnchor?) throws -> HInline? {
        let a = Self.a
        let sp = e.element(Self.wps + "spPr")
        let style = e.element(Self.wps + "style")
        let (fill, gradient) = fillOf(sp, style)
        let geometry = Self.attr(sp?.element(a + "prstGeom"), "prst")
        if let content = e.element(Self.wps + "txbx")?.element(Self.w + "txbxContent") {
            let known = [
                "rect", "roundRect", "flowChartProcess", "flowChartAlternateProcess", "ellipse", "flowChartConnector",
            ].contains(geometry ?? "")
            if !known && DocumentXML.trim(content.value).isEmpty { return nil }
            let b = try textBox(e, content, w, h, anchor, known ? fill ?? gradient?.colors.first : nil)
            if known {
                if geometry == "ellipse" || geometry == "flowChartConnector" {
                    b.shape = .ellipse
                } else if geometry == "roundRect" || geometry == "flowChartAlternateProcess" {
                    b.cornerRatio = 20
                }
            } else {
                b.line = .none
            }
            return b
        }
        let kind: HShapeKind
        switch geometry {
        case "rect", "roundRect", "snip1Rect", "snip2SameRect", "round1Rect", "round2SameRect", "flowChartProcess",
            "flowChartAlternateProcess", "frame":
            kind = .rectangle
        case "ellipse", "flowChartConnector": kind = .ellipse
        case "line", "straightConnector1": kind = .line
        default: return nil
        }
        let s = HShape(kind)
        let f = sp?.element(a + "xfrm")
        s.width = w
        s.height = h
        s.anchor = anchor
        s.fill = kind == .line ? nil : fill
        s.gradient = kind == .line ? nil : gradient
        s.line = line(sp?.element(a + "ln"), style)
        s.cornerRatio =
            ["roundRect", "round1Rect", "round2SameRect", "flowChartAlternateProcess"].contains(geometry ?? "") ? 20 : 0
        s.flipHorizontal = ["1", "true"].contains(Self.attr(f, "flipH") ?? "")
        s.flipVertical = ["1", "true"].contains(Self.attr(f, "flipV") ?? "")
        return s
    }
    func textBox(_ e: XElement, _ content: XElement, _ w: Int, _ h: Int, _ anchor: HAnchor?, _ fill: String?) throws
        -> HTextBox
    {
        let body = e.element(Self.wps + "bodyPr")
        let b = HTextBox()
        b.width = max(w, 1000)
        b.height = max(h, 600)
        b.anchor = anchor
        b.fill = fill
        b.line = line(e.element(Self.wps + "spPr")?.element(Self.a + "ln"), e.element(Self.wps + "style"))
        func inset(_ n: String, _ fallback: Int) -> Int {
            Self.long(body, n).map { HwpxUnits.fromEmu(Double($0)) } ?? fallback
        }
        b.padding = HInsets(inset("lIns", 720), inset("rIns", 720), inset("tIns", 360), inset("bIns", 360))
        let va = Self.attr(body, "anchor")
        b.verticalAlign = va == "ctr" ? .center : va == "b" ? .bottom : .top
        b.blocks = try readTextBoxContent(content)
        return b
    }
    func readTextBoxContent(_ e: XElement) throws -> [HBlock] {
        textBoxDepth += 1
        defer { textBoxDepth -= 1 }
        return try readBlocks(e.elements())
    }
    func fillOf(_ sp: XElement?, _ style: XElement?) -> (String?, HGradient?) {
        let a = Self.a
        if sp?.element(a + "noFill") != nil { return (nil, nil) }
        if let solid = sp?.element(a + "solidFill") { return (color(solid), nil) }
        if let g = sp?.element(a + "gradFill") {
            let colors = (g.element(a + "gsLst")?.elements(a + "gs") ?? []).sorted {
                (Self.long($0, "pos") ?? 0) < (Self.long($1, "pos") ?? 0)
            }.compactMap { color($0) }
            let angle = (Self.long(g.element(a + "lin"), "ang") ?? 0) / 60000
            return colors.count >= 2 ? (nil, HGradient(colors, angle)) : (colors.first, nil)
        }
        if let ref = style?.element(a + "fillRef"), let idx = Self.attr(ref, "idx"), idx != "0" {
            return (color(ref), nil)
        }
        return (nil, nil)
    }
    func line(_ e: XElement?, _ style: XElement?) -> HBorder {
        guard let e else {
            if let ref = style?.element(Self.a + "lnRef"), let idx = Self.attr(ref, "idx"), idx != "0" {
                var b = HBorder.thin
                b.color = color(ref) ?? "#000000"
                return b
            }
            return .none
        }
        if e.element(Self.a + "noFill") != nil { return .none }
        let mm = Self.long(e, "w").map { Double($0) / 36000 } ?? 0.12
        let dash = Self.attr(e.element(Self.a + "prstDash"), "val")
        let style: HBorderStyle
        switch dash {
        case nil, "solid": style = .solid
        case "dot", "sysDot": style = .dot
        case "dashDot", "sysDashDot", "lgDashDot": style = .dashDot
        default: style = .dash
        }
        return HBorder(style, mm, color(e.element(Self.a + "solidFill")) ?? "#000000")
    }
    func color(_ fill: XElement?) -> String? {
        guard let fill else { return nil }
        if let rgb = fill.element(Self.a + "srgbClr") { return "#" + (Self.val(rgb) ?? "000000").uppercased() }
        if let sys = fill.element(Self.a + "sysClr") {
            return "#" + (Self.attr(sys, "lastClr") ?? "000000").uppercased()
        }
        if let scheme = fill.element(Self.a + "schemeClr") {
            let name = Self.val(scheme) ?? "dk1"
            let slot = ["bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"][name] ?? name
            return themeColors[slot] ?? (slot.hasPrefix("lt") ? "#FFFFFF" : "#000000")
        }
        return nil
    }
    func loadThemeColors(_ theme: Part?) {
        for c in theme?.xml.root.descendants(Self.a + "clrScheme").first?.elements() ?? [] {
            if let v = Self.val(c.element(Self.a + "srgbClr")) ?? Self.attr(c.element(Self.a + "sysClr"), "lastClr"),
                v.utf16.count == 6
            {
                themeColors[c.name.localName] = "#" + v.uppercased()
            }
        }
    }
    static func anchor(_ e: XElement) -> HAnchor {
        let h = e.element(wp + "positionH")
        let v = e.element(wp + "positionV")
        let wrap = e.elements().first { $0.name.namespace == wp && $0.name.localName.hasPrefix("wrap") }?.name.localName
        let behind = ["1", "true"].contains(attr(e, "behindDoc") ?? "")
        let hr = attr(h, "relativeFrom") ?? ""
        let vr = attr(v, "relativeFrom") ?? ""
        let ha = h?.element(wp + "align")?.value ?? "left"
        let va = v?.element(wp + "align")?.value ?? "top"
        func offset(_ p: XElement?) -> Int {
            DocumentXML.int(p?.element(wp + "posOffset")?.value).map { HwpxUnits.fromEmu(Double($0)) } ?? 0
        }
        return HAnchor(
            ["page", "leftMargin", "rightMargin", "insideMargin", "outsideMargin"].contains(hr)
                ? "PAPER" : hr == "margin" ? "PAGE" : hr == "character" ? "PARA" : "COLUMN",
            ["center", "right", "inside", "outside"].contains(ha) ? ha.uppercased() : "LEFT", offset(h),
            ["page", "topMargin", "bottomMargin", "insideMargin", "outsideMargin"].contains(vr)
                ? "PAPER" : vr == "margin" ? "PAGE" : "PARA",
            ["center", "bottom", "inside", "outside"].contains(va) ? va.uppercased() : "TOP", offset(v),
            ["wrapSquare", "wrapTight", "wrapThrough"].contains(wrap ?? "")
                ? "SQUARE"
                : wrap == "wrapTopAndBottom" ? "TOP_AND_BOTTOM" : behind ? "BEHIND_TEXT" : "IN_FRONT_OF_TEXT",
            !["0", "false"].contains(attr(e, "allowOverlap") ?? ""))
    }
    func extractImage(_ id: String?) throws -> String? {
        guard let id, let rel = part.relationships[id], !rel.external else { return nil }
        if let p = media[rel.target] { return p }
        guard let e = zip.entry(named: rel.target) else { return nil }
        try FileManager.default.createDirectoryIfNeeded(mediaFolder)
        let path = FilePath.combine(mediaFolder, "docx-media-\(media.count+1)" + FilePath.extension(rel.target))
        try zip.extract(e, to: path)
        media[rel.target] = path
        return path
    }
    func vml(_ container: XElement) throws -> [HInline] {
        var result: [HInline] = []
        for e in container.elements() where e.name.namespace == Self.v {
            if e.name.localName == "group" {
                result += try vml(e)
                continue
            }
            if e.name.localName == "shapetype" { continue }
            let style = Self.vmlStyle(e.attributeValue("style"))
            var w = HwpxUnits.parseLength(style["width"]) ?? 0
            var h = HwpxUnits.parseLength(style["height"]) ?? 0
            var anchor = style["position"] == "absolute" ? Self.vmlAnchor(e, style) : nil
            if let data = e.element(Self.v + "imagedata"), let path = try extractImage(Self.attr(data, "id", Self.r)) {
                let i = HImage(path)
                i.width = w > 0 ? w : nil
                i.height = h > 0 ? h : nil
                i.anchor = anchor
                result.append(i)
            } else if let content = e.element(Self.v + "textbox")?.element(Self.w + "txbxContent") {
                let b = HTextBox()
                b.width = max(w, 1000)
                b.height = max(h, 600)
                b.anchor = anchor
                b.fill = Self.vmlFill(e)
                b.line = Self.vmlLine(e)
                b.padding = HInsets(720, 720, 360, 360)
                b.blocks = try readTextBoxContent(content)
                result.append(b)
            } else if ["rect", "roundrect", "oval", "line"].contains(e.name.localName) {
                let kind: HShapeKind =
                    e.name.localName == "oval" ? .ellipse : e.name.localName == "line" ? .line : .rectangle
                if kind == .line {
                    let from = Self.vmlPoint(e.attributeValue("from"))
                    let to = Self.vmlPoint(e.attributeValue("to"))
                    w = abs(to.0 - from.0)
                    h = abs(to.1 - from.1)
                    var a = anchor ?? Self.vmlAnchor(e, style)
                    a.horizontalOffset += min(from.0, to.0)
                    a.verticalOffset += min(from.1, to.1)
                    anchor = a
                }
                let s = HShape(kind)
                s.width = w
                s.height = h
                s.anchor = anchor
                s.fill = kind == .line ? nil : Self.vmlFill(e)
                s.line = Self.vmlLine(e)
                s.cornerRatio = e.name.localName == "roundrect" ? 20 : 0
                result.append(s)
            }
        }
        return result
    }
    static func vmlFill(_ e: XElement) -> String? {
        ["f", "false"].contains(e.attributeValue("filled") ?? "")
            ? nil : vmlColor(e.attributeValue("fillcolor")) ?? "#FFFFFF"
    }
    static func vmlLine(_ e: XElement) -> HBorder {
        if ["f", "false"].contains(e.attributeValue("stroked") ?? "") { return .none }
        return HBorder(
            .solid,
            HwpxUnits.parseLength(e.attributeValue("strokeweight")).map { Double($0) / HwpxUnits.perMm } ?? 0.12,
            vmlColor(e.attributeValue("strokecolor")) ?? "#000000")
    }
    static func vmlPoint(_ s: String?) -> (Int, Int) {
        let parts = (s ?? "0,0").components(separatedBy: ",")
        func c(_ i: Int) -> Int {
            var s = i < parts.count ? DocumentXML.trim(parts[i]) : "0"
            if s.isEmpty { s = "0" }
            return HwpxUnits.parseLength(s.last?.isNumber == true ? s + "pt" : s) ?? 0
        }
        return (c(0), c(1))
    }
    static func vmlStyle(_ s: String?) -> [String: String] {
        var result: [String: String] = [:]
        for p in (s ?? "").split(separator: ";") {
            let pair = p.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 {
                result[DocumentXML.trim(String(pair[0])).lowercased()] = DocumentXML.trim(String(pair[1]))
            }
        }
        return result
    }
    static func vmlAnchor(_ e: XElement, _ s: [String: String]) -> HAnchor {
        let wrap = e.element(w10 + "wrap")?.attributeValue("type")
        return HAnchor(
            ["page": "PAPER", "margin": "PAGE", "char": "PARA"][s["mso-position-horizontal-relative"] ?? ""]
                ?? "COLUMN", ["center": "CENTER", "right": "RIGHT"][s["mso-position-horizontal"] ?? ""] ?? "LEFT",
            HwpxUnits.parseLength(s["margin-left"]) ?? 0,
            ["page": "PAPER", "margin": "PAGE"][s["mso-position-vertical-relative"] ?? ""] ?? "PARA",
            ["center": "CENTER", "bottom": "BOTTOM"][s["mso-position-vertical"] ?? ""] ?? "TOP",
            HwpxUnits.parseLength(s["margin-top"]) ?? 0,
            ["square", "tight", "through"].contains(wrap ?? "")
                ? "SQUARE"
                : wrap == "topAndBottom"
                    ? "TOP_AND_BOTTOM" : s["z-index"]?.hasPrefix("-") == true ? "BEHIND_TEXT" : "IN_FRONT_OF_TEXT", true
        )
    }
    static func vmlColor(_ text: String?) -> String? {
        guard var c = text?.components(separatedBy: " ").first.map(DocumentXML.trim), c.hasPrefix("#") else {
            return nil
        }
        if c.utf16.count == 4 { c = "#" + c.dropFirst().map { "\($0)\($0)" }.joined() }
        return c.utf16.count == 7 && Int(c.dropFirst(), radix: 16) != nil ? c.uppercased() : nil
    }
}
