// Port of DocxReader.Styles.cs. Swift value property bags preserve Filee's Clone semantics.
import Foundation

extension DocxReader {
    struct ParaProps {
        var jc: String?, left: Int?, right: Int?, firstLine: Int?, hanging: Int?, before: Int?, after: Int?, line: Int?,
            lineRule: String?, keepNext: Bool?, keepLines: Bool?, pageBreakBefore: Bool?, widowControl: Bool?,
            snapToGrid: Bool?, outlineLevel: Int?, numId: String?, ilvl: Int?
        var tabs: [(position: Int, kind: String, leader: String)] = []
        mutating func apply(_ p: XElement?) {
            guard let p else { return }
            let w = DocxReader.w
            if let e = p.element(w + "jc") { jc = DocxReader.val(e) }
            if let e = p.element(w + "ind") {
                left = DocxReader.twips(e, "left") ?? DocxReader.twips(e, "start") ?? left
                right = DocxReader.twips(e, "right") ?? DocxReader.twips(e, "end") ?? right
                if let v = DocxReader.twips(e, "hanging") {
                    hanging = v
                    firstLine = nil
                }
                if let v = DocxReader.twips(e, "firstLine") {
                    firstLine = v
                    hanging = nil
                }
            }
            if let e = p.element(w + "spacing") {
                before = DocxReader.bool(e, "beforeAutospacing") == true ? 280 : DocxReader.twips(e, "before") ?? before
                after = DocxReader.bool(e, "afterAutospacing") == true ? 280 : DocxReader.twips(e, "after") ?? after
                if let v = DocxReader.twips(e, "line") {
                    line = v
                    lineRule = DocxReader.attr(e, "lineRule") ?? "auto"
                }
            }
            keepNext = DocxReader.toggle(p, "keepNext") ?? keepNext
            keepLines = DocxReader.toggle(p, "keepLines") ?? keepLines
            pageBreakBefore = DocxReader.toggle(p, "pageBreakBefore") ?? pageBreakBefore
            widowControl = DocxReader.toggle(p, "widowControl") ?? widowControl
            snapToGrid = DocxReader.toggle(p, "snapToGrid") ?? snapToGrid
            if let v = DocumentXML.int(DocxReader.val(p.element(w + "outlineLvl"))) { outlineLevel = v }
            if let e = p.element(w + "numPr") {
                if let v = e.element(w + "numId") { numId = DocxReader.val(v) }
                if let v = DocumentXML.int(DocxReader.val(e.element(w + "ilvl"))) { ilvl = v }
            }
            if let e = p.element(w + "tabs") {
                for t in e.elements(w + "tab") {
                    let pos = DocxReader.twips(t, "pos") ?? 0
                    tabs.removeAll { $0.position == pos }
                    if let kind = DocxReader.val(t), kind != "clear" {
                        tabs.append((pos, kind, DocxReader.attr(t, "leader") ?? "none"))
                    }
                }
                tabs.sort { $0.position < $1.position }
            }
        }
    }
    struct RunProps {
        var bold: Bool?, italic: Bool?, underline: Bool?, strike: Bool?, hidden: Bool?, vertAlign: String?,
            color: String?, highlight: String?, shade: String?, ascii: String?, eastAsia: String?, asciiTheme: String?,
            eastAsiaTheme: String?, size: Int?, spacing: Int?
        mutating func apply(_ p: XElement?) {
            guard let p else { return }
            let w = DocxReader.w
            bold = DocxReader.toggle(p, "b") ?? bold
            italic = DocxReader.toggle(p, "i") ?? italic
            strike = DocxReader.toggle(p, "strike") ?? DocxReader.toggle(p, "dstrike") ?? strike
            hidden = DocxReader.toggle(p, "vanish") ?? hidden
            if let e = p.element(w + "u") { underline = DocxReader.val(e) != nil && DocxReader.val(e) != "none" }
            if let e = p.element(w + "vertAlign") { vertAlign = DocxReader.val(e) }
            if let e = p.element(w + "color") {
                color = DocxReader.val(e).flatMap { $0.utf16.count == 6 ? "#" + $0.uppercased() : nil }
            }
            if let e = p.element(w + "highlight") { highlight = DocxReader.highlightColor(DocxReader.val(e)) }
            if let e = p.element(w + "shd") { shade = DocxReader.shadingColor(e) }
            if let v = DocumentXML.int(DocxReader.val(p.element(w + "sz"))) { size = v }
            if let v = DocumentXML.int(DocxReader.val(p.element(w + "spacing"))) { spacing = v }
            if let e = p.element(w + "rFonts") {
                if let v = DocxReader.attr(e, "ascii") ?? DocxReader.attr(e, "hAnsi") {
                    ascii = v
                    asciiTheme = nil
                }
                if let v = DocxReader.attr(e, "asciiTheme") ?? DocxReader.attr(e, "hAnsiTheme") { asciiTheme = v }
                if let v = DocxReader.attr(e, "eastAsia") {
                    eastAsia = v
                    eastAsiaTheme = nil
                }
                if let v = DocxReader.attr(e, "eastAsiaTheme") { eastAsiaTheme = v }
            }
        }
    }
    struct Style {
        let id: String, type: String
        let name: String?, basedOn: String?
        let pPr: XElement?, rPr: XElement?, tblPr: XElement?, tcPr: XElement?
        let tableConditions: [XElement]
    }
    struct NumberingLevel {
        var start = 1, format = "decimal", text = "%1."
        var pPr: XElement?, rPr: XElement?
    }
    func loadStyles(_ part: Part?) {
        guard let root = part?.xml.root else { return }
        let w = Self.w
        let defaults = root.element(w + "docDefaults")
        defaultPara.apply(defaults?.element(w + "pPrDefault")?.element(w + "pPr"))
        defaultRun.apply(defaults?.element(w + "rPrDefault")?.element(w + "rPr"))
        for e in root.elements(w + "style") {
            let style = Style(
                id: Self.attr(e, "styleId") ?? "", type: Self.attr(e, "type") ?? "paragraph",
                name: Self.val(e.element(w + "name")), basedOn: Self.val(e.element(w + "basedOn")),
                pPr: e.element(w + "pPr"), rPr: e.element(w + "rPr"), tblPr: e.element(w + "tblPr"),
                tcPr: e.element(w + "tcPr"), tableConditions: e.elements(w + "tblStylePr"))
            styles[style.id] = style
            if Self.bool(e, "default") == true {
                if style.type == "paragraph" {
                    defaultParagraphStyle = style.id
                } else if style.type == "table" {
                    defaultTableStyle = style.id
                }
            }
        }
    }
    func loadTheme(_ part: Part?) {
        let fonts = part?.xml.root.descendants(Self.a + "fontScheme").first
        func read(_ name: String) -> (String?, String?) {
            let f = fonts?.element(Self.a + name)
            let latin = Self.attr(f?.element(Self.a + "latin"), "typeface")
            var east = Self.attr(f?.element(Self.a + "ea"), "typeface")
            if east?.isEmpty != false {
                east = Self.attr(f?.elements(Self.a + "font").first { Self.attr($0, "script") == "Hang" }, "typeface")
            }
            return (Self.nullIfEmpty(latin), Self.nullIfEmpty(east))
        }
        minorFont = read("minorFont")
        majorFont = read("majorFont")
    }
    func loadNumbering(_ part: Part?) {
        guard let root = part?.xml.root else { return }
        let w = Self.w
        var abstracts: [String: XElement] = [:]
        for a in root.elements(w + "abstractNum") { abstracts[Self.attr(a, "abstractNumId") ?? ""] = a }
        func apply(_ levels: inout [NumberingLevel], _ e: XElement) {
            guard let i = DocumentXML.int(Self.attr(e, "ilvl")), (0...8).contains(i) else { return }
            if let start = DocumentXML.int(Self.val(e.element(w + "start"))) { levels[i].start = start }
            levels[i].format = Self.val(e.element(w + "numFmt")) ?? levels[i].format
            levels[i].text = Self.val(e.element(w + "lvlText")) ?? levels[i].text
            levels[i].pPr = e.element(w + "pPr") ?? levels[i].pPr
            levels[i].rPr = e.element(w + "rPr") ?? levels[i].rPr
        }
        for num in root.elements(w + "num") {
            guard let a = abstracts[Self.val(num.element(w + "abstractNumId")) ?? ""] else { continue }
            var levels = (0..<9).map { i -> NumberingLevel in
                var l = NumberingLevel()
                l.text = "%\(i+1)."
                return l
            }
            for e in a.elements(w + "lvl") { apply(&levels, e) }
            for e in num.elements(w + "lvlOverride") {
                guard let i = DocumentXML.int(Self.attr(e, "ilvl")), (0...8).contains(i) else { continue }
                if let l = e.element(w + "lvl") { apply(&levels, l) }
                if let start = DocumentXML.int(Self.val(e.element(w + "startOverride"))) { levels[i].start = start }
            }
            numberingLevels[Self.attr(num, "numId") ?? ""] = levels
        }
    }
    func resolveStyle(_ id: String?) -> (ParaProps, RunProps) {
        guard let id, let s = styles[id] else { return (defaultPara, defaultRun) }
        if let cached = resolvedStyles[id] { return cached }
        resolvedStyles[id] = (defaultPara, defaultRun)
        var (p, r) = s.basedOn.flatMap { $0 != id ? resolveStyle($0) : nil } ?? (defaultPara, defaultRun)
        p.apply(s.pPr)
        r.apply(s.rPr)
        resolvedStyles[id] = (p, r)
        return (p, r)
    }
    func paragraphProperties(_ e: XElement?) -> (ParaProps, RunProps) {
        var (p, r) = resolveStyle(Self.val(e?.element(Self.w + "pStyle")) ?? defaultParagraphStyle)
        var direct = ParaProps()
        direct.apply(e)
        let numId = direct.numId ?? p.numId
        let ilvl = direct.ilvl ?? p.ilvl ?? 0
        if let id = numId, let levels = numberingLevels[id] { p.apply(levels[min(max(ilvl, 0), 8)].pPr) }
        p.apply(e)
        p.numId = numId
        p.ilvl = ilvl
        r.apply(e?.element(Self.w + "rPr"))
        return (p, r)
    }
    func styleChain(_ s: Style?) -> [Style] {
        var chain: [Style] = []
        var current = s
        while let c = current, chain.count < 20 {
            chain.insert(c, at: 0)
            current = c.basedOn.flatMap { styles[$0] }
        }
        return chain
    }
    func runProperties(_ e: XElement?, _ paragraph: RunProps) -> RunProps {
        var r = paragraph
        if let id = Self.val(e?.element(Self.w + "rStyle")), let s = styles[id] {
            for layer in styleChain(s) { r.apply(layer.rPr) }
        }
        r.apply(e)
        return r
    }
    func headingLevel(_ p: ParaProps, _ pPr: XElement?) -> Int {
        if let level = p.outlineLevel, (0...8).contains(level) { return level + 1 }
        let n = styles[Self.val(pPr?.element(Self.w + "pStyle")) ?? ""]?.name ?? ""
        return n.lowercased().hasPrefix("heading ")
            ? Int(n.dropFirst(8)).flatMap { (1...9).contains($0) ? $0 : nil } ?? 0 : 0
    }
    func paraFormat(_ p: ParaProps) -> HParaFormat {
        func u(_ v: Int) -> Int { HwpxUnits.fromTwips(Double(v)) }
        let first = p.hanging.map { -$0 } ?? p.firstLine ?? 0
        let line = p.line.map {
            HLineSpacing(
                p.lineRule == "exact" ? .fixed : p.lineRule == "atLeast" ? .atLeast : .percent,
                p.lineRule == "exact" || p.lineRule == "atLeast"
                    ? u($0) : Int((Double($0) / 240 * 130).rounded(.toNearestOrEven)))
        }
        let align: HAlign
        switch p.jc {
        case "center": align = .center
        case "right", "end": align = .right
        case "both", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute": align = .justify
        case "distribute": align = .distribute
        default: align = .left
        }
        let tabs = p.tabs.filter { $0.kind != "bar" && $0.kind != "num" }.map { t in
            HTabStop(
                u(t.position),
                t.kind == "right" || t.kind == "end"
                    ? .right : t.kind == "center" ? .center : t.kind == "decimal" ? .decimal : .left,
                ["dot": "DOT", "middleDot": "DOT", "hyphen": "DASH", "underscore": "SOLID", "heavy": "SOLID"][t.leader]
                    ?? "NONE")
        }
        return HParaFormat(
            align: align, left: u(p.left ?? 0), right: u(p.right ?? 0), firstLine: u(first), before: u(p.before ?? 0),
            after: u(p.after ?? 0), lineSpacing: line ?? HLineSpacing(.percent, 130), keepWithNext: p.keepNext ?? false,
            keepLines: p.keepLines ?? false, widowOrphan: p.widowControl ?? true, tabs: p.tabs.isEmpty ? nil : tabs)
    }
    func charFormat(_ r: RunProps) -> HCharFormat {
        func theme(_ name: String?) -> String? {
            guard let n = name else { return nil }
            let f = n.hasPrefix("major") ? majorFont : minorFont
            return n.hasSuffix("EastAsia") ? f.1 : f.0
        }
        let latin = theme(r.asciiTheme) ?? r.ascii
        let east = theme(r.eastAsiaTheme) ?? r.eastAsia
        let size = r.size ?? 20
        return HCharFormat(
            bold: r.bold ?? false, italic: r.italic ?? false, underline: r.underline ?? false,
            strike: r.strike ?? false, superscript: r.vertAlign == "superscript", subscript: r.vertAlign == "subscript",
            size: size * 50, font: latin, eastAsianFont: east ?? latin, color: r.color ?? "#000000",
            shade: r.highlight ?? r.shade,
            spacing: r.spacing.flatMap {
                $0 != 0 && size != 0
                    ? min(max(Int((Double($0) * 10 / Double(size)).rounded(.toNearestOrEven)), -50), 50) : nil
            } ?? 0)
    }
    func numbering(_ id: String?) -> HNumbering? {
        guard let id, id != "0", let levels = numberingLevels[id] else { return nil }
        if let n = numberings[id] { return n }
        let n = HNumbering()
        for l in levels {
            let b = l.format == "bullet"
            n.levels.append(
                HNumberingLevel(
                    b ? "DIGIT" : Self.numberFormat(l.format),
                    b ? Self.bulletText(l.text) : Self.numberText(l.text, l.format), l.start, b))
        }
        numberings[id] = n
        return n
    }
    static func numberFormat(_ f: String) -> String {
        switch f {
        case "upperRoman": return "ROMAN_CAPITAL"
        case "lowerRoman": return "ROMAN_SMALL"
        case "upperLetter": return "LATIN_CAPITAL"
        case "lowerLetter": return "LATIN_SMALL"
        case "ganada": return "HANGUL_SYLLABLE"
        case "chosung": return "HANGUL_JAMO"
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese": return "CIRCLED_DIGIT"
        case "koreanDigital", "koreanCounting", "koreanLegal", "koreanDigital2": return "HANGUL_PHONETIC"
        case "ideographDigital", "chineseCounting", "chineseCountingThousand", "japaneseCounting",
            "ideographTraditional":
            return "IDEOGRAPH"
        default: return "DIGIT"
        }
    }
    static func numberText(_ text: String, _ format: String) -> String {
        if format == "none" { return text.filter { $0 != "%" && !$0.isNumber } }
        var a = Array(text.utf16)
        for i in a.indices.dropLast() where a[i] == 37 && DocumentXML.isDigit(a[i + 1]) { a[i] = 94 }
        return String(decoding: a, as: UTF16.self)
    }
    static func bulletText(_ text: String) -> String {
        switch text {
        case "", "\u{F0B7}", "\u{F09F}", "•": return "●"
        case "o", "\u{F06F}": return "○"
        case "\u{F0A7}", "\u{F06E}", "▪": return "■"
        case "\u{F0D8}": return "➢"
        case "\u{F076}": return "❖"
        case "\u{F0FC}": return "✓"
        case "\u{F071}": return "❑"
        case "\u{F075}", "\u{F0A8}": return "◆"
        case "-", "–", "\u{F02D}": return "-"
        default: return (text.utf16.first ?? 0) >= 0xF000 ? "●" : text
        }
    }
    static func shadingColor(_ e: XElement) -> String? {
        func rgb(_ text: String?) -> [Int]? {
            guard let s = text, s.utf16.count == 6, let n = Int(s, radix: 16) else { return nil }
            return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
        }
        func hex(_ c: [Int]) -> String { String(format: "#%02X%02X%02X", c[0], c[1], c[2]) }
        let fill = rgb(attr(e, "fill"))
        let color = rgb(attr(e, "color"))
        let pattern = val(e)
        if pattern == nil || pattern == "clear" || pattern == "nil" { return fill.map(hex) }
        if pattern == "solid" { return hex(color ?? [0, 0, 0]) }
        if let pattern, pattern.hasPrefix("pct"), let n = Int(pattern.dropFirst(3)) {
            let bg = fill ?? [255, 255, 255]
            let fg = color ?? [0, 0, 0]
            let t = Double(min(max(n, 0), 100)) / 100
            return hex((0..<3).map { Int((Double(bg[$0]) + Double(fg[$0] - bg[$0]) * t).rounded(.toNearestOrEven)) })
        }
        return fill.map(hex)
    }
    static func highlightColor(_ n: String?) -> String? {
        guard let n else { return nil }
        if n == "white" { return "#FFFFFF" }
        return DocxWriter.highlights.first { $0.value == n }?.key
    }
}
