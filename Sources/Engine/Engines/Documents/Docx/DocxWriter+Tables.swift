// Table portion of DocxWriter.Body.cs.
import Foundation

extension DocxWriter {
    func table(_ table: HTable) throws -> String {
        if table.rows.isEmpty { return "" }
        let (placed, count) = HwpxWriter.placeCells(table)
        let widths = HwpxWriter.columnWidths(table, count, max(4000, width - (table.align == .left ? table.indent : 0)))
        let borders = table.borders ?? .grid
        let margin = table.cellMargin
        var continuations: [String: HCell] = [:]
        for (r, row) in placed.enumerated() {
            for (cell, c) in row {
                if cell.rowSpan > 1 { for below in 1..<cell.rowSpan { continuations["\(r+below),\(c)"] = cell } }
            }
        }
        var s = "<w:tbl><w:tblPr><w:tblW w:w=\"\(Self.twips(widths.reduce(0,+)))\" w:type=\"dxa\"/>"
        if table.align == .center || table.align == .right {
            s += "<w:jc w:val=\"\(table.align == .center ? "center" : "right")\"/>"
        } else if table.indent != 0 {
            s += "<w:tblInd w:w=\"\(Self.twips(table.indent))\" w:type=\"dxa\"/>"
        }
        s +=
            "<w:tblBorders>" + Self.border("top", borders.top) + Self.border("left", borders.left)
            + Self.border("bottom", borders.bottom) + Self.border("right", borders.right)
            + Self.border("insideH", borders.top) + Self.border("insideV", borders.left)
            + "</w:tblBorders><w:tblLayout w:type=\"fixed\"/>"
        if let m = margin {
            s += "<w:tblCellMar>"
            for (key, n) in [("top", m.top), ("left", m.left), ("bottom", m.bottom), ("right", m.right)] {
                s += "<w:\(key) w:w=\"\(Self.twips(n))\" w:type=\"dxa\"/>"
            }
            s += "</w:tblCellMar>"
        }
        s +=
            "<w:tblLook w:val=\"04A0\"/></w:tblPr><w:tblGrid>"
            + widths.map { "<w:gridCol w:w=\"\(Self.twips($0))\"/>" }.joined() + "</w:tblGrid>"
        let padding = margin.map { $0.left + $0.right } ?? 1080
        let outer = width
        let headerRows = table.rows.prefix(while: { $0.header }).count
        defer { width = outer }
        for (r, row) in table.rows.enumerated() {
            s += "<w:tr>"
            if (row.height ?? 0) > 0 || r < headerRows {
                s += "<w:trPr>"
                if let h = row.height, h > 0 { s += "<w:trHeight w:val=\"\(Self.twips(h))\" w:hRule=\"atLeast\"/>" }
                if r < headerRows { s += "<w:tblHeader/>" }
                s += "</w:trPr>"
            }
            var column = 0
            while column < count {
                if let cell = placed[r].first(where: { $0.column == column })?.cell {
                    let span = min(max(cell.colSpan, 1), count - column)
                    let w = widths.dropFirst(column).prefix(span).reduce(0, +)
                    width = max(1000, w - padding)
                    s += Self.cell(
                        cell, w, span, cell.rowSpan > 1 ? "<w:vMerge w:val=\"restart\"/>" : "",
                        try blocks(cell.blocks, nil, true))
                    column += span
                } else if let cell = continuations["\(r),\(column)"] {
                    let span = min(max(cell.colSpan, 1), count - column)
                    s += Self.cell(
                        cell, widths.dropFirst(column).prefix(span).reduce(0, +), span, "<w:vMerge/>", "<w:p/>")
                    column += span
                } else {
                    s +=
                        "<w:tc><w:tcPr><w:tcW w:w=\"\(Self.twips(widths[column]))\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    column += 1
                }
            }
            s += "</w:tr>"
        }
        width = outer
        s += "</w:tbl>"
        if !table.caption.isEmpty { s += try blocks(table.caption) }
        return s
    }
    static func cell(_ c: HCell, _ width: Int, _ span: Int, _ merge: String, _ content: String) -> String {
        var s = "<w:tc><w:tcPr><w:tcW w:w=\"\(twips(width))\" w:type=\"dxa\"/>"
        if span > 1 { s += "<w:gridSpan w:val=\"\(span)\"/>" }
        s += merge
        if let b = c.borders {
            s +=
                "<w:tcBorders>" + border("top", b.top) + border("left", b.left) + border("bottom", b.bottom)
                + border("right", b.right) + "</w:tcBorders>"
        }
        if let fill = hex(c.fill) { s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
        if c.verticalAlign != .top { s += "<w:vAlign w:val=\"\(c.verticalAlign == .center ? "center" : "bottom")\"/>" }
        return s + "</w:tcPr>" + content + "</w:tc>"
    }
    static func border(_ edge: String, _ b: HBorder) -> String {
        if b.style == .none { return "<w:\(edge) w:val=\"nil\"/>" }
        let style =
            b.style == .dash
            ? "dashed"
            : b.style == .dot ? "dotted" : b.style == .dashDot ? "dotDash" : b.style == .double ? "double" : "single"
        let n = min(max(Int((b.widthMm / 25.4 * 72 * 8).rounded(.toNearestOrEven)), 2), 96)
        return "<w:\(edge) w:val=\"\(style)\" w:sz=\"\(n)\" w:space=\"0\" w:color=\"\(hex(b.color) ?? "auto")\"/>"
    }
}
