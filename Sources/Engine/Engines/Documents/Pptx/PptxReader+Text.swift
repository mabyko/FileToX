// Port of PptxReader.Text.cs: text inheritance, bullets and slide tables.
import Foundation

extension PptxReader {
    static func bodyProperties(_ shape: XElement, _ l: XElement?, _ m: XElement?) -> (HInsets, HVerticalAlign) {
        let chain = [shape, l, m].compactMap { $0?.element(p + "txBody")?.element(a + "bodyPr") }
        func attr(_ n: String) -> String? { chain.compactMap { $0.attributeValue(XName(n)) }.first }
        func inset(_ n: String, _ fallback: Int) -> Int { hwp(DocumentXML.int(attr(n)) ?? fallback) }
        let va = attr("anchor")
        return (
            HInsets(inset("lIns", 91440), inset("rIns", 91440), inset("tIns", 45720), inset("bIns", 45720)),
            va == "ctr" ? .center : va == "b" ? .bottom : .top
        )
    }
    func textBody(
        _ c: SlideContext, _ path: String, _ body: XElement?, _ ph: XElement?, _ lp: XElement?, _ mp: XElement?,
        _ defaultColor: String?
    ) -> [HBlock] {
        guard let body, body.descendants(Self.a + "t").contains(where: { !DocumentXML.trim($0.value).isEmpty }) else {
            return []
        }
        let a = Self.a
        let scale =
            DocumentXML.double(body.element(a + "bodyPr")?.element(a + "normAutofit")?.attributeValue("fontScale")).map
        { $0 / 100000 } ?? 1
        var counters = [Int](repeating: 0, count: 10)
        var lastNumbered = [Bool](repeating: false, count: 10)
        var blocks: [HBlock] = []
        for p in body.elements(a + "p") {
            let pp = p.element(a + "pPr")
            let level = min(max(DocumentXML.int(p.element(a + "pPr")?.attributeValue("lvl")) ?? 0, 0), 8)
            let chain = styleChain(c, body, ph, lp, mp, level + 1)
            let pc = [pp].compactMap { $0 } + chain.0 + chain.1
            func attr(_ n: String) -> String? { pc.compactMap { $0.attributeValue(XName(n)) }.first }
            let para = HParagraph()
            let align = attr("algn")
            para.format = HParaFormat(
                align: align == "ctr"
                    ? .center
                    : align == "r" ? .right : align == "just" ? .justify : align == "dist" ? .distribute : .left,
                left: DocumentXML.int(attr("marL")).map(Self.hwp) ?? 0,
                firstLine: DocumentXML.int(attr("indent")).map(Self.hwp) ?? 0, before: Self.spacing(pc, "spcBef"),
                after: Self.spacing(pc, "spcAft"), lineSpacing: Self.lineSpacing(pc))
            let runs = p.elements().filter { ["r", "br", "fld"].contains($0.name.localName) }
            let first = runs.first { $0.name.localName != "br" }
            let mark = runFormat(
                c, p.element(a + "endParaRPr") ?? first?.element(a + "rPr"), pp, chain, defaultColor, scale)
            para.markFormat = mark
            para.markFormat.color = nil
            let bullet = runs.contains { ($0.element(a + "t")?.value.utf16.count ?? 0) > 0 } ? Self.bullet(pc) : nil
            for i in (level + 1)..<10 {
                counters[i] = 0
                lastNumbered[i] = false
            }
            if let scheme = bullet?.autoNumber {
                counters[level] = lastNumbered[level] ? counters[level] + 1 : bullet!.start
                lastNumbered[level] = true
                para.inlines.append(HText(Self.number(scheme, counters[level]) + " ", mark))
            } else {
                lastNumbered[level] = false
                if let ch = bullet?.char {
                    var f = mark
                    f.bold = nil
                    f.italic = nil
                    f.underline = nil
                    para.inlines.append(HText(ch + " ", f))
                }
            }
            for run in runs {
                let f = runFormat(c, run.element(a + "rPr"), pp, chain, defaultColor, scale)
                if run.name.localName == "br" {
                    para.inlines.append(HLineBreak(f))
                    continue
                }
                let text = run.element(a + "t")?.value ?? ""
                if text.isEmpty { continue }
                let rel = run.element(a + "rPr")?.element(a + "hlinkClick")?.attributeValue(Self.r + "id").flatMap {
                    package.relationships(path)[$0]
                }
                if let rel, rel.external {
                    let l = HLink(rel.target)
                    l.content.append(HText(text, f))
                    para.inlines.append(l)
                } else {
                    para.inlines.append(HText(text, f))
                }
            }
            blocks.append(para)
        }
        return blocks
    }
    func styleChain(_ c: SlideContext, _ body: XElement, _ ph: XElement?, _ l: XElement?, _ m: XElement?, _ level: Int)
        -> ([XElement], [XElement])
    {
        let name = Self.a + "lvl\(level)pPr"
        let specific = [body, l?.element(Self.p + "txBody"), m?.element(Self.p + "txBody")].compactMap {
            $0?.element(Self.a + "lstStyle")?.element(name)
        }
        var general: [XElement] = []
        if let ph {
            let type = Self.normalize(ph.attributeValue("type"))
            let key = type == "title" ? "titleStyle" : type == "body" ? "bodyStyle" : "otherStyle"
            if let from = c.master?.element(Self.p + "txStyles")?.element(Self.p + key)?.element(name) {
                general.append(from)
            }
        }
        if let from = defaultTextStyle?.element(name) { general.append(from) }
        return (specific, general)
    }
    func runFormat(
        _ c: SlideContext, _ rp: XElement?, _ pp: XElement?, _ chain: ([XElement], [XElement]), _ defaultColor: String?,
        _ scale: Double
    ) -> HCharFormat {
        let a = Self.a
        var props = [rp, pp?.element(a + "defRPr")].compactMap { $0 } + chain.0.compactMap { $0.element(a + "defRPr") }
        let specific = props.count
        props += chain.1.compactMap { $0.element(a + "defRPr") }
        func attr(_ n: String) -> String? { props.compactMap { $0.attributeValue(XName(n)) }.first }
        var color: String?
        for (i, p) in props.enumerated() {
            if color != nil { break }
            if i == specific && defaultColor != nil {
                color = defaultColor
            } else if let f = p.element(a + "solidFill") {
                color = c.colors.drawing(f)
            }
        }
        color = color ?? defaultColor ?? c.colors.theme("tx1")
        let size = DocumentXML.int(attr("sz")) ?? 1800
        let latin = Self.typeface(c, props.compactMap { $0.element(a + "latin")?.attributeValue("typeface") }.first)
        let east = Self.typeface(c, props.compactMap { $0.element(a + "ea")?.attributeValue("typeface") }.first)
        let baseline = DocumentXML.int(attr("baseline")) ?? 0
        return HCharFormat(
            bold: ["1", "true"].contains(attr("b") ?? "") ? true : nil,
            italic: ["1", "true"].contains(attr("i") ?? "") ? true : nil,
            underline: attr("u").map { $0 != "none" ? true : nil } ?? nil,
            strike: attr("strike").map { $0 != "noStrike" ? true : nil } ?? nil, superscript: baseline > 0 ? true : nil,
            subscript: baseline < 0 ? true : nil, size: max(100, Int((Double(size) * scale).rounded(.toNearestOrEven))),
            font: latin, eastAsianFont: east, color: color)
    }
    static func typeface(_ c: SlideContext, _ t: String?) -> String? {
        switch t {
        case nil, "": return nil
        case "+mj-lt": return c.fonts.majorLatin
        case "+mn-lt": return c.fonts.minorLatin
        case "+mj-ea": return c.fonts.majorEastAsian
        case "+mn-ea": return c.fonts.minorEastAsian
        default: return t!.hasPrefix("+") ? nil : t
        }
    }
    struct BulletInfo {
        let char: String?, autoNumber: String?
        let start: Int
    }
    static func bullet(_ chain: [XElement]) -> BulletInfo? {
        for e in chain {
            if e.element(a + "buNone") != nil { return nil }
            if let b = e.element(a + "buChar") {
                return BulletInfo(char: b.attributeValue("char") ?? "•", autoNumber: nil, start: 1)
            }
            if let b = e.element(a + "buAutoNum") {
                return BulletInfo(
                    char: nil, autoNumber: b.attributeValue("type") ?? "arabicPeriod",
                    start: DocumentXML.int(b.attributeValue("startAt")) ?? 1)
            }
            if e.element(a + "buBlip") != nil { return BulletInfo(char: "•", autoNumber: nil, start: 1) }
        }
        return nil
    }
    static func number(_ scheme: String, _ n: Int) -> String {
        let value: String
        if scheme.hasPrefix("alphaLc") || scheme.hasPrefix("alphaUc") {
            var x = n
            var s = ""
            while x > 0 {
                s = String(UnicodeScalar(65 + (x - 1) % 26)!) + s
                x = (x - 1) / 26
            }
            value = scheme.hasPrefix("alphaLc") ? s.lowercased() : s
        } else if scheme.hasPrefix("romanLc") || scheme.hasPrefix("romanUc") {
            var x = n
            var s = ""
            for (v, t) in [
                (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
            ] {
                while x >= v {
                    s += t
                    x -= v
                }
            }
            value = scheme.hasPrefix("romanLc") ? s.lowercased() : s
        } else if scheme.hasPrefix("circleNum") && (1...20).contains(n) {
            value = String(UnicodeScalar(0x2460 + n - 1)!)
        } else {
            value = String(n)
        }
        return scheme.hasSuffix("ParenBoth")
            ? "(\(value))" : scheme.hasSuffix("ParenR") ? value + ")" : scheme.hasSuffix("Plain") ? value : value + "."
    }
    static func spacing(_ chain: [XElement], _ name: String) -> Int {
        for e in chain {
            if let s = e.element(a + name) {
                if let pt = DocumentXML.int(s.element(a + "spcPts")?.attributeValue("val")) { return pt }
                if let pct = DocumentXML.int(s.element(a + "spcPct")?.attributeValue("val")) {
                    return Int(Double(pct) / 100000 * 1800 * 1.2)
                }
            }
        }
        return 0
    }
    static func lineSpacing(_ chain: [XElement]) -> HLineSpacing {
        for e in chain {
            if let s = e.element(a + "lnSpc") {
                if let pct = DocumentXML.int(s.element(a + "spcPct")?.attributeValue("val")) {
                    return HLineSpacing(.percent, max(60, Int((Double(pct) / 1000 * 1.2).rounded(.toNearestOrEven))))
                }
                if let pt = DocumentXML.int(s.element(a + "spcPts")?.attributeValue("val")) {
                    return HLineSpacing(.fixed, pt)
                }
            }
        }
        return HLineSpacing(.percent, 120)
    }
    func table(_ c: SlideContext, _ path: String, _ frame: XElement, _ t: Transform) -> HTextBox? {
        let a = Self.a
        guard let tbl = frame.element(a + "graphic")?.element(a + "graphicData")?.element(a + "tbl") else { return nil }
        let b = Self.bounds(frame.element(Self.p + "xfrm"), t)
        let rows = tbl.elements(a + "tr")
        var grid = tbl.element(a + "tblGrid")?.elements(a + "gridCol").map {
            max(1, HwpxUnits.fromEmu(Double(Self.emu($0, "w")) * t.scaleX))
        } ?? []
        if grid.isEmpty, let columns = rows.map({ $0.elements(a + "tc").count }).max(), columns > 0 {
            let width = b.flatMap { $0.w > 0 ? $0.w : nil } ?? c.frame.w
            grid = Array(repeating: max(1, Self.hwp(width) / columns), count: columns)
        }
        if grid.isEmpty { return nil }
        let props = tbl.element(a + "tblPr")
        let styled = props?.element(a + "tableStyleId") != nil
        let first = ["1", "true"].contains(props?.attributeValue("firstRow") ?? "")
        let banded = ["1", "true"].contains(props?.attributeValue("bandRow") ?? "")
        let accent = c.colors.theme("accent1")
        let line = styled ? HBorder(.solid, 0.35, "#FFFFFF") : .thin
        let table = HTable()
        table.columnCount = grid.count
        table.columnWidths = grid
        table.cellMargin = HInsets(720, 720, 360, 360)
        table.borders = HBorders(line, line, line, line)
        for (r, tr) in rows.enumerated() {
            let header = first && r == 0
            let row = HRow()
            row.header = header
            row.height = max(1, HwpxUnits.fromEmu(Double(Self.emu(tr, "h")) * t.scaleY))
            // DrawingML keeps a cell at every grid position, including merged continuations.
            for (column, tc) in tr.elements(a + "tc").enumerated() {
                let span = max(1, DocumentXML.int(tc.attributeValue("gridSpan")) ?? 1)
                if ["1", "true"].contains(tc.attributeValue("hMerge") ?? "")
                    || ["1", "true"].contains(tc.attributeValue("vMerge") ?? "")
                {
                    continue
                }
                let cp = tc.element(a + "tcPr")
                var fill = cp?.element(a + "solidFill").flatMap { c.colors.drawing($0) }
                if fill == nil && styled && cp?.element(a + "noFill") == nil {
                    fill =
                        header
                        ? accent
                        : banded && (r - (first ? 1 : 0)) % 2 == 0
                            ? OoxmlColors.tint(accent, 0.6) : OoxmlColors.tint(accent, 0.8)
                }
                let cell = HCell()
                cell.column = column
                cell.colSpan = span
                cell.rowSpan = max(1, DocumentXML.int(tc.attributeValue("rowSpan")) ?? 1)
                cell.fill = fill
                let va = cp?.attributeValue("anchor")
                cell.verticalAlign = va == "ctr" ? .center : va == "b" ? .bottom : .top
                cell.borders = HBorders(
                    Self.cellLine(cp?.element(a + "lnL"), c.colors, line),
                    Self.cellLine(cp?.element(a + "lnR"), c.colors, line),
                    Self.cellLine(cp?.element(a + "lnT"), c.colors, line),
                    Self.cellLine(cp?.element(a + "lnB"), c.colors, line))
                var text = textBody(
                    c, path, tc.element(a + "txBody"), nil, nil, nil, styled && header ? c.colors.theme("lt1") : nil)
                if styled && header {
                    for p in text.compactMap({ $0 as? HParagraph }) {
                        for (i, item) in p.inlines.enumerated() {
                            if let t = item as? HText, t.format.bold == nil {
                                var f = t.format
                                f.bold = true
                                p.inlines[i] = HText(t.text, f)
                            }
                        }
                    }
                }
                if text.isEmpty { text = [HParagraph()] }
                cell.blocks = text
                row.cells.append(cell)
            }
            table.rows.append(row)
        }
        let box = HTextBox()
        box.width = grid.reduce(0, +)
        box.height = max(1, table.rows.reduce(0) { $0 + ($1.height ?? 0) })
        if let b, b.w > 0 {
            box.width = max(1, Self.hwp(b.w))
            box.anchor = Self.anchor(Self.hwp(b.x), Self.hwp(b.y))
        }
        box.line = .none
        box.padding = HInsets(0, 0, 0, 0)
        box.blocks.append(table)
        return box
    }
    static func cellLine(_ line: XElement?, _ colors: OoxmlColors, _ fallback: HBorder) -> HBorder {
        guard let line else { return fallback }
        if line.element(a + "noFill") != nil { return .none }
        guard let color = line.element(a + "solidFill").flatMap({ colors.drawing($0) }) else { return fallback }
        return HBorder(.solid, max(0.1, Double(emu(line, "w")) / 36000), color)
    }
}
