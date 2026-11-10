// Port of PptxReader.cs. Slides retain their physical size and floating object positions.
import Foundation

final class PptxReader {
    static let p = XNamespace("http://schemas.openxmlformats.org/presentationml/2006/main"), a = OoxmlColors.a,
        r = XNamespace("http://schemas.openxmlformats.org/officeDocument/2006/relationships")
    let package: OpcPackage, mediaFolder: String
    var defaultTextStyle: XElement?
    private init(_ p: OpcPackage, _ folder: String) {
        package = p
        mediaFolder = folder
    }
    static func read(_ path: String, _ folder: String) throws -> HDocument {
        try PptxReader(OpcPackage(path), folder).readPresentation()
    }
    static func emu(_ e: XElement?, _ n: String) -> Int { DocumentXML.int(e?.attributeValue(XName(n))) ?? 0 }
    static func hwp(_ value: Int) -> Int { HwpxUnits.fromEmu(Double(value)) }
    func readPresentation() throws -> HDocument {
        let path = package.mainPartPath ?? "ppt/presentation.xml"
        guard let root = try package.part(path)?.root else {
            throw ConversionError("The file is not a PowerPoint presentation (no ppt/presentation.xml).")
        }
        defaultTextStyle = root.element(Self.p + "defaultTextStyle")
        let sz = root.element(Self.p + "sldSz")
        let cx = Self.emu(sz, "cx")
        let cy = Self.emu(sz, "cy")
        let width = cx > 0 ? cx : 12_192_000
        let height = cy > 0 ? cy : 6_858_000
        let w = Self.hwp(width)
        let h = Self.hwp(height)
        let section = HSection()
        section.page = HPage(width: w, height: h, left: 0, right: 0, top: 0, bottom: 0, header: 0, footer: 0, gutter: 0)
        for id in root.element(Self.p + "sldIdLst")?.elements(Self.p + "sldId") ?? [] {
            try Task.checkCancellation()
            guard let slidePath = package.target(path, id.attributeValue(Self.r + "id")),
                let slide = try package.part(slidePath)?.root,
                !["0", "false"].contains(slide.attributeValue("show") ?? "")
            else { continue }
            let p = HParagraph()
            p.pageBreakBefore = !section.blocks.isEmpty
            p.inlines = try readSlide(slidePath, slide, width, height)
            section.blocks.append(p)
        }
        if section.blocks.isEmpty { section.blocks.append(HParagraph()) }
        let doc = HDocument()
        doc.sections.append(section)
        return doc
    }
    struct ThemeFonts {
        let majorLatin: String?, minorLatin: String?, majorEastAsian: String?, minorEastAsian: String?
        static func from(_ theme: XDocument?) -> ThemeFonts {
            let a = PptxReader.a
            let scheme = theme?.root.descendants(a + "fontScheme").first
            func latin(_ k: String) -> String? {
                DocxReader.nullIfEmpty(scheme?.element(a + k)?.element(a + "latin")?.attributeValue("typeface"))
            }
            func east(_ k: String) -> String? {
                let f = scheme?.element(a + k)
                return DocxReader.nullIfEmpty(f?.element(a + "ea")?.attributeValue("typeface"))
                    ?? DocxReader.nullIfEmpty(
                        f?.elements(a + "font").first { $0.attributeValue("script") == "Hang" }?.attributeValue(
                            "typeface"))
            }
            return ThemeFonts(
                majorLatin: latin("majorFont"), minorLatin: latin("minorFont"), majorEastAsian: east("majorFont"),
                minorEastAsian: east("minorFont"))
        }
    }
    struct SlideContext {
        let slidePath: String
        let slide: XElement
        let layout: XElement?
        let layoutPath: String?
        let master: XElement?
        let masterPath: String?
        let colors: OoxmlColors
        let fonts: ThemeFonts
        /// Slide frame in EMUs, for content with no usable local or inherited transform.
        let frame: Bounds
    }
    func readSlide(_ path: String, _ slide: XElement, _ w: Int, _ h: Int) throws -> [HInline] {
        let lp = package.targetOfType(path, "/slideLayout")
        let layout = try lp.flatMap { try package.part($0)?.root }
        let mp = lp.flatMap { package.targetOfType($0, "/slideMaster") }
        let master = try mp.flatMap { try package.part($0)?.root }
        let tp = mp.flatMap { package.targetOfType($0, "/theme") }
        let theme = try tp.flatMap { try package.part($0) }
        let map = master?.element(Self.p + "clrMap").map {
            Dictionary($0.attributes.map { ($0.name.localName, $0.value) }, uniquingKeysWith: { _, b in b })
        }
        let colors = OoxmlColors.fromTheme(theme).withMap(map)
        let c = SlideContext(
            slidePath: path, slide: slide, layout: layout, layoutPath: lp, master: master, masterPath: mp,
            colors: colors, fonts: ThemeFonts.from(theme), frame: Bounds(x: 0, y: 0, w: w, h: h))
        var output: [HInline] = []
        if let bg = Self.background(c) {
            bg.width = Self.hwp(w)
            bg.height = Self.hwp(h)
            bg.anchor = Self.anchor(0, 0)
            output.append(bg)
        }
        let show =
            !["0", "false"].contains(slide.attributeValue("showMasterSp") ?? "")
            && !["0", "false"].contains(layout?.attributeValue("showMasterSp") ?? "")
        if show, let master, let mp { output += try objects(c, mp, Self.tree(master), .identity, true) }
        if let layout, let lp { output += try objects(c, lp, Self.tree(layout), .identity, true) }
        output += try objects(c, path, Self.tree(slide), .identity, false)
        return output
    }
    static func tree(_ e: XElement?) -> XElement? { e?.element(p + "cSld")?.element(p + "spTree") }
    static func anchor(_ x: Int, _ y: Int) -> HAnchor {
        HAnchor("PAPER", "LEFT", max(0, x), "PAPER", "TOP", max(0, y), "IN_FRONT_OF_TEXT", true)
    }
    static func background(_ c: SlideContext) -> HShape? {
        for part in [c.slide, c.layout, c.master] {
            guard let bg = part?.element(p + "cSld")?.element(p + "bg") else { continue }
            let f: (String?, HGradient?)
            if let props = bg.element(p + "bgPr") {
                f = fill(props, c.colors, nil)
            } else {
                f = (c.colors.drawing(bg.element(p + "bgRef")), nil)
            }
            if f.1 == nil && (f.0 == nil || f.0?.uppercased() == "#FFFFFF") { return nil }
            let s = HShape(.rectangle)
            s.fill = f.0
            s.gradient = f.1
            s.line = .none
            return s
        }
        return nil
    }
    struct Transform {
        var scaleX = 1.0, scaleY = 1.0, offsetX = 0.0, offsetY = 0.0
        static let identity = Transform()
        func apply(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Bounds {
            Bounds(
                x: Int(offsetX + Double(x) * scaleX), y: Int(offsetY + Double(y) * scaleY), w: Int(Double(w) * scaleX),
                h: Int(Double(h) * scaleY))
        }
    }
    struct Bounds { let x: Int, y: Int, w: Int, h: Int }
    func objects(_ c: SlideContext, _ path: String, _ tree: XElement?, _ t: Transform, _ decorations: Bool) throws
        -> [HInline]
    {
        var output: [HInline] = []
        for e in tree?.elements() ?? [] {
            if decorations && Self.placeholder(e) != nil { continue }
            switch e.name.localName {
            case "sp": if let s = try shape(c, path, e, t) { output.append(s) }
            case "cxnSp":
                let props = e.element(Self.p + "spPr")
                if let b = Self.bounds(props?.element(Self.a + "xfrm"), t),
                    let s = Self.addLine(
                        e, b, Self.line(props, c.colors, e.element(Self.p + "style")?.element(Self.a + "lnRef")))
                {
                    output.append(s)
                }
            case "pic": if let image = try picture(c, path, e, t) { output.append(image) }
            case "graphicFrame": if let table = table(c, path, e, t) { output.append(table) }
            case "grpSp":
                let f = e.element(Self.p + "grpSpPr")?.element(Self.a + "xfrm")
                var inner = t
                if let f {
                    let off = f.element(Self.a + "off")
                    let ext = f.element(Self.a + "ext")
                    let co = f.element(Self.a + "chOff")
                    let ce = f.element(Self.a + "chExt")
                    let cw = Self.emu(ce, "cx")
                    let ch = Self.emu(ce, "cy")
                    let sx = cw > 0 ? Double(Self.emu(ext, "cx")) / Double(cw) : 1
                    let sy = ch > 0 ? Double(Self.emu(ext, "cy")) / Double(ch) : 1
                    inner = Transform(
                        scaleX: t.scaleX * sx, scaleY: t.scaleY * sy,
                        offsetX: t.offsetX + (Double(Self.emu(off, "x")) - Double(Self.emu(co, "x")) * sx) * t.scaleX,
                        offsetY: t.offsetY + (Double(Self.emu(off, "y")) - Double(Self.emu(co, "y")) * sy) * t.scaleY)
                }
                output += try objects(c, path, e, inner, decorations)
            case "AlternateContent":
                if let f = e.elements().first(where: { $0.name.localName == "Fallback" }) {
                    output += try objects(c, path, f, t, decorations)
                }
            default: break
            }
        }
        return output
    }
    static func placeholder(_ e: XElement) -> XElement? {
        e.elements().first { $0.name.localName.hasPrefix("nv") }?.element(p + "nvPr")?.element(p + "ph")
    }
    static func normalize(_ s: String?) -> String {
        switch s {
        case "ctrTitle", "title": return "title"
        case nil, "", "obj", "subTitle", "body": return "body"
        default: return s!
        }
    }
    static func inherited(_ c: SlideContext, _ ph: XElement?) -> (XElement?, XElement?) {
        guard let ph else { return (nil, nil) }
        let type = normalize(ph.attributeValue("type"))
        let index = ph.attributeValue("idx")
        func find(_ part: XElement?, _ byIndex: Bool) -> XElement? {
            let candidates =
                tree(part)?.descendants().filter {
                    ["sp", "pic"].contains($0.name.localName) && placeholder($0) != nil
                } ?? []
            if byIndex, let index, let e = candidates.first(where: { placeholder($0)?.attributeValue("idx") == index })
            {
                return e
            }
            return candidates.first { normalize(placeholder($0)?.attributeValue("type")) == type }
        }
        return (find(c.layout, true), find(c.master, false))
    }
    static func geometry(_ e: XElement?, _ l: XElement?, _ m: XElement?) -> XElement? {
        for n in [e, l, m] {
            if let f = n?.element(p + "spPr")?.element(a + "xfrm") ?? n?.element(p + "xfrm") { return f }
        }
        return nil
    }
    static func bounds(_ f: XElement?, _ t: Transform) -> Bounds? {
        guard let f else { return nil }
        let o = f.element(a + "off")
        let e = f.element(a + "ext")
        return t.apply(emu(o, "x"), emu(o, "y"), emu(e, "cx"), emu(e, "cy"))
    }
    func shape(_ c: SlideContext, _ path: String, _ e: XElement, _ t: Transform) throws -> HInline? {
        let ph = Self.placeholder(e)
        let (lp, mp) = path == c.slidePath ? Self.inherited(c, ph) : (nil, nil)
        let props = e.element(Self.p + "spPr")
        let style = e.element(Self.p + "style")
        let (fill, gradient) = Self.fill(props, c.colors, style?.element(Self.a + "fillRef"))
        let line = Self.line(props, c.colors, style?.element(Self.a + "lnRef"))
        let geom = props?.element(Self.a + "prstGeom")?.attributeValue("prst") ?? "rect"
        let blocks = textBody(
            c, path, e.element(Self.p + "txBody"), ph, lp, mp, c.colors.drawing(style?.element(Self.a + "fontRef")))
        let b: Bounds
        let usesSlideFrame: Bool
        if let positioned = Self.bounds(Self.geometry(e, lp, mp), t), positioned.w > 0 || positioned.h > 0 {
            b = positioned
            usesSlideFrame = false
        } else {
            // Missing geometry must not discard the text. Empty decorations still have nothing to place.
            guard !DocumentXML.trim(HDocumentWalker.text(HDocumentWalker.inlines(blocks))).isEmpty else { return nil }
            b = c.frame
            usesSlideFrame = true
        }
        let w = max(1, Self.hwp(b.w))
        let h = max(1, Self.hwp(b.h))
        if !usesSlideFrame, geom == "line" || geom == "straightConnector1" { return Self.addLine(e, b, line) }
        let kind: HShapeKind = geom == "ellipse" ? .ellipse : .rectangle
        let corners = geom == "roundRect" ? Self.cornerRatio(props) : 0
        if !blocks.isEmpty {
            var (padding, va) = Self.bodyProperties(e, lp, mp)
            if kind == .ellipse {
                let dx = Int(Double(w) * 0.146)
                let dy = Int(Double(h) * 0.146)
                padding = HInsets(padding.left + dx, padding.right + dx, padding.top + dy, padding.bottom + dy)
            }
            let box = HTextBox()
            box.width = w
            box.height = h
            box.anchor = Self.anchor(Self.hwp(b.x), Self.hwp(b.y))
            box.fill = usesSlideFrame ? nil : fill
            box.gradient = usesSlideFrame ? nil : gradient
            box.line = usesSlideFrame ? .none : line
            box.shape = kind
            box.cornerRatio = corners
            box.padding = padding
            box.verticalAlign = va
            box.blocks = blocks
            return box
        }
        if fill == nil && gradient == nil && line.style == .none { return nil }
        let s = HShape(kind)
        s.width = w
        s.height = h
        s.anchor = Self.anchor(Self.hwp(b.x), Self.hwp(b.y))
        s.fill = fill
        s.gradient = gradient
        s.line = line
        s.cornerRatio = corners
        return s
    }
    static func cornerRatio(_ e: XElement?) -> Int {
        let guide = e?.element(a + "prstGeom")?.element(a + "avLst")?.elements(a + "gd").first {
            $0.attributeValue("name") == "adj"
        }
        let parts = guide?.attributeValue("fmla")?.components(separatedBy: " ") ?? []
        let v = parts.count == 2 && parts[0] == "val" ? Int(parts[1]) ?? 16667 : 16667
        return min(max(Int((Double(v) / 1000).rounded(.toNearestOrEven)), 0), 50)
    }
    static func addLine(_ e: XElement, _ b: Bounds, _ line: HBorder) -> HShape? {
        if line.style == .none { return nil }
        let s = HShape(.line)
        let f = e.element(p + "spPr")?.element(a + "xfrm")
        s.width = max(1, hwp(b.w))
        s.height = max(1, hwp(b.h))
        s.anchor = anchor(hwp(b.x), hwp(b.y))
        s.line = line
        s.flipHorizontal = ["1", "true"].contains(f?.attributeValue("flipH") ?? "")
        s.flipVertical = ["1", "true"].contains(f?.attributeValue("flipV") ?? "")
        return s
    }
    func picture(_ c: SlideContext, _ path: String, _ e: XElement, _ t: Transform) throws -> HImage? {
        let (lp, mp) = path == c.slidePath ? Self.inherited(c, Self.placeholder(e)) : (nil, nil)
        guard let target = package.target(
                path, e.element(Self.p + "blipFill")?.element(Self.a + "blip")?.attributeValue(Self.r + "embed")),
            [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff"].contains(
                FilePath.extension(target).lowercased()), let file = try package.extract(target, mediaFolder)
        else { return nil }
        let b: Bounds
        if let geometry = Self.geometry(e, lp, mp) {
            guard let positioned = Self.bounds(geometry, t) else { return nil }
            b = positioned
        } else if let size = ImageSupport.info(file), size.width > 0 && size.height > 0 {
            // Fit an unpositioned picture to the slide without stretching it.
            let scale = min(Double(c.frame.w) / Double(size.width), Double(c.frame.h) / Double(size.height))
            b = Bounds(x: 0, y: 0, w: Int(Double(size.width) * scale), h: Int(Double(size.height) * scale))
        } else {
            b = c.frame
        }
        let image = HImage(file)
        image.width = max(1, Self.hwp(b.w))
        image.height = max(1, Self.hwp(b.h))
        image.anchor = Self.anchor(Self.hwp(b.x), Self.hwp(b.y))
        return image
    }
    static func fill(_ props: XElement?, _ colors: OoxmlColors, _ ref: XElement?) -> (String?, HGradient?) {
        if props?.element(a + "noFill") != nil { return (nil, nil) }
        if let solid = props?.element(a + "solidFill") { return (colors.drawing(solid), nil) }
        if let g = props?.element(a + "gradFill") {
            let stops = (g.element(a + "gsLst")?.elements(a + "gs") ?? []).sorted { emu($0, "pos") < emu($1, "pos") }
                .compactMap { colors.drawing($0) }
            let angle = emu(g.element(a + "lin"), "ang") / 60000
            return stops.count >= 2 ? (stops[0], HGradient(stops, angle)) : (stops.first, nil)
        }
        if props?.element(a + "blipFill") != nil || props?.element(a + "pattFill") != nil { return (nil, nil) }
        return emu(ref, "idx") > 0 ? (colors.drawing(ref), nil) : (nil, nil)
    }
    static func line(_ props: XElement?, _ colors: OoxmlColors, _ ref: XElement?) -> HBorder {
        let ln = props?.element(a + "ln")
        if ln?.element(a + "noFill") != nil { return .none }
        let w = emu(ln, "w")
        let width = w > 0 ? w : 12700
        let color =
            ln?.element(a + "solidFill").flatMap { colors.drawing($0) }
            ?? (emu(ref, "idx") > 0 ? colors.drawing(ref) : nil)
        guard let color else { return .none }
        let dash = ln?.element(a + "prstDash")?.attributeValue("val")
        let kind: HBorderStyle
        switch dash {
        case "dot", "sysDot": kind = .dot
        case "dash", "sysDash", "lgDash": kind = .dash
        case "dashDot", "lgDashDot", "sysDashDot": kind = .dashDot
        default: kind = .solid
        }
        return HBorder(kind, Double(width) / 36000, color)
    }
}
