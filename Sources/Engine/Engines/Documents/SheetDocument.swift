// Port of SheetDocument.cs: visible sheets become paged tables.
import Foundation

enum SheetDocument {
    static let maxRows = 5000, maxColumns = 60, a4Short = 59528, a4Long = 84188, margin = 2268
    static let gridLine = HBorder(.solid, 0.1, "#D9D9D9")
    static func build(_ book: Workbook) -> HDocument {
        let doc = HDocument()
        let sheets = book.sheets.filter { $0.usedRange() != nil }
        for sheet in sheets { doc.sections.append(section(sheet, sheets.count > 1)) }
        if doc.sections.isEmpty {
            let s = HSection()
            s.blocks.append(HParagraph())
            doc.sections.append(s)
        }
        return doc
    }
    static func section(_ sheet: Worksheet, _ withTitle: Bool) -> HSection {
        let range = sheet.usedRange()!
        let allRows = (range.top...range.bottom).filter { !sheet.hiddenRows.contains($0) }
        let allColumns = (range.left...range.right).filter { !sheet.hiddenColumns.contains($0) }
        let cutRows = allRows.count > maxRows
        let cutColumns = allColumns.count > maxColumns
        let rows = Array(allRows.prefix(maxRows))
        let columns = Array(allColumns.prefix(maxColumns))
        let widths = columns.map { Int(((sheet.columnWidth($0) * 8 + 10) * 75).rounded(.toNearestOrEven)) }
        let total = max(1, widths.reduce(0, +))
        let landscape = total > a4Short - 2 * margin
        let page = HPage(
            width: landscape ? a4Long : a4Short, height: landscape ? a4Short : a4Long, left: margin, right: margin,
            top: margin / 2, bottom: margin / 2, header: margin / 2, footer: margin / 2, gutter: 0)
        let scale = min(1, Double(page.textWidth) / Double(total))
        let fontScale = max(0.5, scale)
        let section = HSection()
        section.page = page
        if withTitle {
            let p = HParagraph()
            p.format.after = 400
            p.markFormat.size = 1300
            p.inlines.append(HText(sheet.name, HCharFormat(bold: true, size: 1300)))
            section.blocks.append(p)
        }
        let table = HTable()
        table.columnCount = columns.count
        table.columnWidths = widths.map { max(300, Int(Double($0) * scale)) }
        table.cellMargin = HInsets(141, 141, 57, 57)
        table.borders = HBorders(gridLine, gridLine, gridLine, gridLine)
        var anchors: [String: (Int, Int)] = [:]
        var covered = Set<String>()
        for merge in sheet.merges {
            let mr = rows.filter { $0 >= merge.top && $0 <= merge.bottom }
            let mc = columns.filter { $0 >= merge.left && $0 <= merge.right }
            if mr.isEmpty || mc.isEmpty { continue }
            anchors["\(mr[0]),\(mc[0])"] = (mr.count, mc.count)
            for r in mr { for c in mc where r != mr[0] || c != mc[0] { covered.insert("\(r),\(c)") } }
        }
        let headerRows = (1...5).contains(sheet.frozenRows) ? sheet.frozenRows : 0
        for r in rows {
            let row = HRow()
            row.header = r < headerRows
            row.height = sheet.rowHeights[r].map { Int($0 * 100 * fontScale) }
            for (i, c) in columns.enumerated() {
                if covered.contains("\(r),\(c)") { continue }
                let span = anchors["\(r),\(c)"] ?? (1, 1)
                row.cells.append(cell(sheet, r, c, span.0, span.1, i, fontScale))
            }
            table.rows.append(row)
        }
        section.blocks.append(table)
        if cutRows || cutColumns {
            let p = HParagraph()
            let label =
                (cutRows ? "first \(maxRows) rows" : "") + (cutRows && cutColumns ? ", " : "")
                + (cutColumns ? "first \(maxColumns) columns" : "")
            p.inlines.append(
                HText("… \(sheet.name): \(label) shown", HCharFormat(italic: true, size: 900, color: "#808080")))
            section.blocks.append(p)
        }
        return section
    }
    static func cell(_ sheet: Worksheet, _ r: Int, _ c: Int, _ rs: Int, _ cs: Int, _ column: Int, _ scale: Double)
        -> HCell
    {
        let value = sheet.get(r, c)
        let style = value?.style ?? .default
        let size = Int(((style.fontSize ?? 11) * 100 * scale).rounded(.toNearestOrEven))
        let f = HCharFormat(
            bold: style.bold ? true : nil, italic: style.italic ? true : nil, underline: style.underline ? true : nil,
            strike: style.strike ? true : nil, size: size,
            color: style.color == nil || style.color == "#000000" ? nil : style.color)
        let align: HAlign =
            style.align == .center
            ? .center
            : style.align == .right ? .right : style.align == .left ? .left : value?.isNumber == true ? .right : .left
        let p = HParagraph()
        p.format.align = align
        p.markFormat.size = size
        for (i, line) in (value?.text ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .enumerated()
        {
            if i > 0 { p.inlines.append(HLineBreak(f)) }
            if !line.isEmpty { p.inlines.append(HText(line, f)) }
        }
        let cell = HCell()
        cell.column = column
        cell.rowSpan = rs
        cell.colSpan = cs
        cell.fill = style.fill
        cell.verticalAlign = style.verticalAlign == .top ? .top : style.verticalAlign == .center ? .center : .bottom
        cell.borders = HBorders(
            border(style.left, sheet.get(r, c - 1)?.style.right), border(style.right, sheet.get(r, c + cs)?.style.left),
            border(style.top, sheet.get(r - 1, c)?.style.bottom), border(style.bottom, sheet.get(r + rs, c)?.style.top))
        cell.blocks.append(p)
        return cell
    }
    static func border(_ own: CellBorder, _ neighbour: CellBorder?) -> HBorder {
        let side = own.isVisible ? own : neighbour?.isVisible == true ? neighbour! : .none
        if !side.isVisible { return gridLine }
        let color = side.color ?? "#000000"
        switch side.style {
        case "hair": return HBorder(.solid, 0.1, color)
        case "medium": return HBorder(.solid, 0.4, color)
        case "thick": return HBorder(.solid, 0.7, color)
        case "double": return HBorder(.double, 0.5, color)
        case "dotted": return HBorder(.dot, 0.12, color)
        case "dashed", "mediumDashed": return HBorder(.dash, side.style == "dashed" ? 0.12 : 0.4, color)
        case "dashDot", "dashDotDot", "mediumDashDot", "mediumDashDotDot", "slantDashDot":
            return HBorder(.dashDot, 0.12, color)
        default: return HBorder(.solid, 0.12, color)
        }
    }
}
