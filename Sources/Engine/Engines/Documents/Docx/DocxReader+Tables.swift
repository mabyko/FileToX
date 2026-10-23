// Port of DocxReader.Tables.cs.
import Foundation

extension DocxReader {
    func readTable(_ tbl: XElement) throws -> HTable {
        let w = Self.w
        let props = tbl.element(Self.w + "tblPr")
        let chain = styleChain(
            styles[Self.val(tbl.element(Self.w + "tblPr")?.element(Self.w + "tblStyle")) ?? defaultTableStyle ?? ""])
        let grid =
            tbl.element(w + "tblGrid")?.elements(w + "gridCol").map {
                HwpxUnits.fromTwips(Double(Self.twips($0, "w") ?? 0))
            } ?? []
        let t = HTable()
        t.columnWidths = !grid.isEmpty && grid.allSatisfy { $0 > 0 } ? grid : nil
        t.columnCount = grid.count
        let jc = Self.val(props?.element(w + "jc"))
        t.align = jc == "center" ? .center : jc == "right" || jc == "end" ? .right : .left
        t.indent = HwpxUnits.fromTwips(Double(Self.twips(props?.element(w + "tblInd"), "w") ?? 0))
        var borders: [String: HBorder] = [:]
        var margins: HInsets?
        for p in chain.map(\.tblPr) + [props] {
            Self.applyBorders(p?.element(w + "tblBorders"), &borders)
            if let m = p?.element(w + "tblCellMar") { margins = Self.cellMargins(m, margins) }
        }
        t.cellMargin = margins
        t.borders = .empty
        let look = props?.element(w + "tblLook")
        let first = Self.attr(look, "firstRow")
        let firstLook =
            first.map { $0 == "1" || $0 == "true" } ?? ((Int(Self.val(look) ?? "", radix: 16) ?? 0) & 0x20 != 0)
        let firstStyle = firstLook ? chain.flatMap(\.tableConditions).last { Self.attr($0, "type") == "firstRow" } : nil
        let rows = tbl.elements().flatMap { $0.name == w + "tr" ? [$0] : Self.flattenTable($0, "tr") }
        var origins: [Int: HCell] = [:]
        for (r, tr) in rows.enumerated() {
            let p = tr.element(w + "trPr")
            let row = HRow()
            row.header = p?.element(w + "tblHeader").map { !["0", "false"].contains(Self.val($0) ?? "") } ?? false
            if let h = Self.twips(p?.element(w + "trHeight"), "val"), h > 0 {
                row.height = HwpxUnits.fromTwips(Double(h))
            }
            var column = Self.twips(p?.element(w + "gridBefore"), "val") ?? 0
            for tc in tr.elements().flatMap({ $0.name == w + "tc" ? [$0] : Self.flattenTable($0, "tc") }) {
                let cp = tc.element(w + "tcPr")
                let span = max(1, Self.twips(tc.element(w + "tcPr")?.element(w + "gridSpan"), "val") ?? 1)
                let merge = cp?.element(w + "vMerge")
                if merge != nil && Self.val(merge) != "restart", let origin = origins[column] {
                    origin.rowSpan += 1
                    column += span
                    continue
                }
                let c = HCell()
                c.column = column
                c.colSpan = span
                c.blocks = try readBlocks(tc.elements())
                let va = Self.val(cp?.element(w + "vAlign"))
                c.verticalAlign = va == "center" ? .center : va == "bottom" ? .bottom : .top
                var cb: [String: HBorder] = [
                    "left": borders[column == 0 ? "left" : "insideV"] ?? .none,
                    "right": borders[column + span >= grid.count ? "right" : "insideV"] ?? .none,
                    "top": borders[r == 0 ? "top" : "insideH"] ?? .none,
                    "bottom": borders[r == rows.count - 1 ? "bottom" : "insideH"] ?? .none,
                ]
                var fill: String?
                for pp in chain.map(\.tcPr) + [r == 0 ? firstStyle?.element(w + "tcPr") : nil, cp] {
                    Self.applyBorders(pp?.element(w + "tcBorders"), &cb)
                    if let shd = pp?.element(w + "shd") { fill = Self.shadingColor(shd) ?? fill }
                }
                c.borders = HBorders(cb["left"]!, cb["right"]!, cb["top"]!, cb["bottom"]!)
                c.fill = fill
                if r == 0 && firstStyle?.element(w + "rPr")?.element(w + "b") != nil { Self.embolden(c.blocks) }
                if merge != nil { origins[column] = c } else { origins.removeValue(forKey: column) }
                row.cells.append(c)
                column += span
            }
            t.rows.append(row)
            t.columnCount = max(t.columnCount, column)
        }
        return t
    }
    static func flattenTable(_ e: XElement, _ name: String) -> [XElement] {
        let children: [XElement]
        if e.name == w + "sdt" {
            children = e.element(w + "sdtContent")?.elements() ?? []
        } else if e.name == w + "customXml" {
            children = e.elements()
        } else {
            return []
        }
        return children.flatMap { $0.name == w + name ? [$0] : flattenTable($0, name) }
    }
    static func applyBorders(_ e: XElement?, _ target: inout [String: HBorder]) {
        for edge in e?.elements() ?? [] {
            let n = edge.name.localName
            target[n == "start" ? "left" : n == "end" ? "right" : n] = border(edge)
        }
    }
    static func border(_ e: XElement) -> HBorder {
        let style: HBorderStyle
        switch val(e) {
        case nil, "nil", "none": style = .none
        case "dotted": style = .dot
        case "dashed", "dashSmallGap": style = .dash
        case "dotDash", "dotDotDash": style = .dashDot
        case "double", "triple", "thinThickSmallGap", "thickThinSmallGap": style = .double
        default: style = .solid
        }
        let color = attr(e, "color").flatMap { $0.utf16.count == 6 ? "#" + $0.uppercased() : nil } ?? "#000000"
        return HBorder(style, Double(twips(e, "sz") ?? 4) / 8 * 25.4 / 72, color)
    }
    static func cellMargins(_ e: XElement, _ current: HInsets?) -> HInsets {
        let m = current ?? HInsets(540, 540, 0, 0)
        func get(_ name: String, _ alt: String, _ fallback: Int) -> Int {
            HwpxUnits.fromTwips(
                Double(twips(e.element(w + name), "w") ?? twips(e.element(w + alt), "w") ?? fallback / 5))
        }
        return HInsets(
            get("left", "start", m.left), get("right", "end", m.right), get("top", "top", m.top),
            get("bottom", "bottom", m.bottom))
    }
    static func embolden(_ blocks: [HBlock]) {
        for p in blocks.compactMap({ $0 as? HParagraph }) {
            for (i, item) in p.inlines.enumerated() {
                if let t = item as? HText {
                    var f = t.format
                    f.bold = true
                    p.inlines[i] = HText(t.text, f)
                }
            }
        }
    }
}
