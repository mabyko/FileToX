// Port of HwpxWriter.Body.cs.
import Foundation

extension HwpxWriter {
    func section(_ section: HSection) throws -> String {
        guard let template = templateSection.descendants(Self.hp + "secPr").first else {
            throw ConversionError("The template section has no secPr.")
        }
        let secPr = XElement(copying: template)
        let pagePr = secPr.element(Self.hp + "pagePr")
        let margin = pagePr?.element(Self.hp + "margin")
        if let page = section.page, let p = pagePr, let margin {
            p.setAttributeValue("landscape", page.landscape ? "NARROWLY" : "WIDELY")
            DocumentXML.set(p, "width", min(page.width, page.height))
            DocumentXML.set(p, "height", max(page.width, page.height))
            for (n, v) in [
                ("left", page.left), ("right", page.right), ("top", page.top), ("bottom", page.bottom),
                ("header", page.header), ("footer", page.footer), ("gutter", page.gutter),
            ] { DocumentXML.set(margin, XName(n), v) }
        }
        if let v = secPr.element(Self.hp + "visibility") {
            DocumentXML.set(v, "hideFirstHeader", section.hideFirstHeader ? 1 : 0)
            DocumentXML.set(v, "hideFirstFooter", section.hideFirstFooter ? 1 : 0)
        }
        DocumentXML.set(secPr.element(Self.hp + "startNum"), "page", section.startPageNumber ?? 0)
        func m(_ n: String, _ fallback: Int) -> Int { DocumentXML.int(margin?.attributeValue(XName(n))) ?? fallback }
        let pw = DocumentXML.int(pagePr?.attributeValue("width")) ?? 59530
        let ph = DocumentXML.int(pagePr?.attributeValue("height")) ?? 84190
        let textWidth = max(
            2000,
            (pagePr?.attributeValue("landscape") == "NARROWLY" ? ph : pw) - m("left", 7200) - m("right", 7200)
                - m("gutter", 0))
        pageLeft = m("left", 7200) + m("gutter", 0)
        pageTop = m("top", 4255) + m("header", 4250)
        var setup = try Self.inner(secPr) + "<hp:ctrl>" + Self.columnDefinition(section.columns) + "</hp:ctrl>"
        base = normal
        width = textWidth
        var controlId = 1
        for item in section.headers {
            setup += try headerFooter("header", item, controlId, textWidth, m("header", 4250), "TOP")
            controlId += 1
        }
        for item in section.footers {
            setup += try headerFooter("footer", item, controlId, textWidth, m("footer", 2240), "BOTTOM")
            controlId += 1
        }
        width = Self.columnWidth(textWidth, section.columns)
        var body = sectionOpenTag()
        var blocks = section.blocks
        if blocks.isEmpty || !(blocks[0] is HParagraph) { blocks.insert(HParagraph(), at: 0) }
        for (i, b) in blocks.enumerated() {
            try Task.checkCancellation()
            if let c = (b as? HParagraph)?.columnsChange { width = Self.columnWidth(textWidth, c) }
            body += try block(b, i == 0 ? "<hp:run charPrIDRef=\"\(normal.char)\">\(setup)</hp:run>" : nil)
        }
        return body + "</hs:sec>"
    }
    static func columnWidth(_ textWidth: Int, _ c: HColumns) -> Int {
        c.count <= 1 ? textWidth : max(2000, (textWidth - c.gap * (c.count - 1)) / c.count)
    }
    static func columnDefinition(_ columns: HColumns) -> String {
        let line = columns.separator ? "<hp:colLine type=\"SOLID\" width=\"0.12 mm\" color=\"#000000\"/>" : ""
        return
            "<hp:colPr id=\"\" type=\"NEWSPAPER\" layout=\"LEFT\" colCount=\"\(max(1,columns.count))\" sameSz=\"1\" sameGap=\"\(columns.count > 1 ? columns.gap : 0)\">\(line)</hp:colPr>"
    }
    func headerFooter(_ kind: String, _ item: HHeaderFooter, _ id: Int, _ w: Int, _ h: Int, _ v: String) throws
        -> String
    {
        let pages = item.pages == .even ? "EVEN" : item.pages == .odd ? "ODD" : "BOTH"
        return "<hp:ctrl><hp:\(kind) id=\"\(id)\" applyPageType=\"\(pages)\">" + (try subList(item.blocks, v, w, h))
            + "</hp:\(kind)></hp:ctrl>"
    }
    func subList(
        _ blocks: [HBlock], _ verticalAlign: String, _ textWidth: Int = 0, _ textHeight: Int = 0,
        _ leadingRun: String? = nil
    ) throws -> String {
        var sb =
            "<hp:subList id=\"\" textDirection=\"HORIZONTAL\" lineWrap=\"BREAK\" vertAlign=\"\(verticalAlign)\" linkListIDRef=\"0\" linkListNextIDRef=\"0\" textWidth=\"\(textWidth)\" textHeight=\"\(textHeight)\" hasTextRef=\"0\" hasNumRef=\"0\">"
        var list = blocks
        if list.isEmpty || (leadingRun != nil && !(list[0] is HParagraph)) { list.insert(HParagraph(), at: 0) }
        for (i, b) in list.enumerated() { sb += try block(b, i == 0 ? leadingRun : nil) }
        return sb + "</hp:subList>"
    }
    func block(_ b: HBlock, _ leadingRun: String? = nil) throws -> String {
        if let p = b as? HParagraph { return try paragraph(p, leadingRun) }
        if let t = b as? HTable { return try table(t, leadingRun) }
        return ""
    }
    func paragraph(_ p: HParagraph, _ leadingRun: String?) throws -> String {
        plainText += "\n"
        let style = headings[p.headingLevel] ?? base
        let paraPrId = try paraPr(style.para, p.format, p.list)
        let runs = RunBuilder()
        if let c = p.columnsChange { runs.control(normal.char, "<hp:ctrl>\(Self.columnDefinition(c))</hp:ctrl>") }
        let size = Self.largestSize(p.inlines) ?? p.markFormat.size ?? baseSize(style.char)
        var tabs = Self.tabElements(p, size)
        try inlines(p.inlines, runs, style.char, false, &tabs)
        return
            "<hp:p id=\"0\" paraPrIDRef=\"\(paraPrId)\" styleIDRef=\"\(style.style)\" pageBreak=\"\(p.pageBreakBefore ? 1 : 0)\" columnBreak=\"\(p.columnBreakBefore ? 1 : 0)\" merged=\"0\">"
            + (leadingRun ?? "") + (try runs.finish(charPr(style.char, p.markFormat), leadingRun != nil)) + "</hp:p>"
    }
    final class RunBuilder {
        var output = "", items = "", char: String?, textOpen = false, endsWithObject = false
        func text(_ c: String, _ xml: String) {
            change(c)
            if !textOpen {
                items += "<hp:t>"
                textOpen = true
            }
            items += xml
            endsWithObject = false
        }
        func control(_ c: String, _ xml: String, _ object: Bool = false) {
            change(c)
            closeText()
            items += xml
            endsWithObject = object
        }
        func finish(_ empty: String, _ leading: Bool) -> String {
            flush()
            return output.isEmpty && !leading ? "<hp:run charPrIDRef=\"\(empty)\"><hp:t/></hp:run>" : output
        }
        func change(_ c: String) {
            if char != c {
                flush()
                char = c
            }
        }
        func closeText() {
            if textOpen { items += "</hp:t>" }
            textOpen = false
        }
        func flush() {
            guard let char else { return }
            closeText()
            if endsWithObject { items += "<hp:t/>" }
            output += "<hp:run charPrIDRef=\"\(char)\">\(items)</hp:run>"
            items = ""
            self.char = nil
            endsWithObject = false
        }
    }
    func inlines(_ list: [HInline], _ runs: RunBuilder, _ baseId: String, _ link: Bool, _ tabs: inout [String]) throws {
        for i in list {
            switch i {
            case let t as HText:
                runs.text(try charPr(baseId, t.format, link), Self.escape(t.text))
                plainText += t.text
            case let b as HLineBreak:
                runs.text(try charPr(baseId, b.format, link), "<hp:lineBreak/>")
                plainText += "\n"
            case let t as HTab:
                runs.text(
                    try charPr(baseId, t.format, link),
                    tabs.isEmpty ? "<hp:tab width=\"4000\" leader=\"0\" type=\"1\"/>" : tabs.removeFirst())
                plainText += "\t"
            case let l as HLink:
                let id = nextId()
                let f = l.content.compactMap { ($0 as? HText)?.format }.first ?? HCharFormat()
                let c = try charPr(baseId, f, true)
                runs.control(c, Self.fieldBegin(id, l.target))
                try inlines(l.content, runs, baseId, true, &tabs)
                runs.control(
                    c, "<hp:ctrl><hp:fieldEnd beginIDRef=\"\(id)\" fieldid=\"\(Self.hyperlinkFieldId)\"/></hp:ctrl>")
            case let b as HBookmark:
                runs.control(baseId, "<hp:ctrl><hp:bookmark name=\"\(Self.escape(b.name))\"/></hp:ctrl>")
            case let f as HField:
                runs.control(
                    try charPr(baseId, f.format), Self.autoNumber(f.kind == .pageNumber ? "PAGE" : "TOTAL_PAGE", 1, ""))
            case let n as HNote: runs.control(baseId, try note(n))
            case let image as HImage: if let xml = picture(image) { runs.control(baseId, xml, true) }
            case let box as HTextBox: runs.control(baseId, try textBox(box), true)
            case let s as HShape: runs.control(baseId, shape(s), true)
            default: break
            }
        }
    }
    func table(_ table: HTable, _ leadingRun: String?) throws -> String {
        if table.rows.isEmpty { return leadingRun == nil ? "" : try paragraph(HParagraph(), leadingRun) }
        let (placed, columnCount) = Self.placeCells(table)
        let widths = Self.columnWidths(table, columnCount, max(4000, width - table.indent))
        let totalWidth = widths.reduce(0, +)
        let rowHeights = estimateRowHeights(table, placed, widths)
        let margin = table.cellMargin ?? HInsets(510, 510, 141, 141)
        let tableBorders = table.borders ?? .grid
        let headerRows = table.rows.prefix(while: { $0.header }).count
        var sb = ""
        let id = nextId()
        sb +=
            "<hp:tbl id=\"\(id)\" zOrder=\"0\" numberingType=\"TABLE\" textWrap=\"TOP_AND_BOTTOM\" textFlow=\"BOTH_SIDES\" lock=\"0\" dropcapstyle=\"None\" pageBreak=\"CELL\" repeatHeader=\"\((headerRows > 0 ? 1 : 0))\" rowCnt=\"\(table.rows.count)\" colCnt=\"\(columnCount)\" cellSpacing=\"0\" borderFillIDRef=\"\(try borderFillId(tableBorders, nil))\" noAdjust=\"0\">"
        sb +=
            "<hp:sz width=\"\(totalWidth)\" widthRelTo=\"ABSOLUTE\" height=\"\(rowHeights.reduce(0,+))\" heightRelTo=\"ABSOLUTE\" protect=\"0\"/>"
        let horizontalAlign = table.align == .center ? "CENTER" : table.align == .right ? "RIGHT" : "LEFT"
        sb +=
            "<hp:pos treatAsChar=\"0\" affectLSpacing=\"0\" flowWithText=\"1\" allowOverlap=\"0\" holdAnchorAndSO=\"0\" vertRelTo=\"PARA\" horzRelTo=\"COLUMN\" vertAlign=\"TOP\" horzAlign=\"\(horizontalAlign)\" vertOffset=\"0\" horzOffset=\"\((table.align == .left ? table.indent : 0))\"/>"
        sb += "<hp:outMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"1417\"/>"
        sb +=
            "<hp:inMargin left=\"\(margin.left)\" right=\"\(margin.right)\" top=\"\(margin.top)\" bottom=\"\(margin.bottom)\"/>"
        let outerWidth = width
        for (r, row) in placed.enumerated() {
            sb += "<hp:tr>"
            for (cell, column) in row {
                let w = widths.dropFirst(column).prefix(cell.colSpan).reduce(0, +)
                let height = rowHeights.dropFirst(r).prefix(cell.rowSpan).reduce(0, +)
                width = max(1000, w - margin.left - margin.right)
                let verticalAlign =
                    cell.verticalAlign == .center ? "CENTER" : cell.verticalAlign == .bottom ? "BOTTOM" : "TOP"
                sb +=
                    "<hp:tc name=\"\" header=\"\(r < headerRows ? 1 : 0)\" hasMargin=\"0\" protect=\"0\" editable=\"0\" dirty=\"0\" borderFillIDRef=\"\(try borderFillId(cell.borders ?? tableBorders,cell.fill))\">"
                sb += try subList(cell.blocks, verticalAlign)
                sb +=
                    "<hp:cellAddr colAddr=\"\(column)\" rowAddr=\"\(r)\"/><hp:cellSpan colSpan=\"\(cell.colSpan)\" rowSpan=\"\(cell.rowSpan)\"/><hp:cellSz width=\"\(w)\" height=\"\(height)\"/><hp:cellMargin left=\"\(margin.left)\" right=\"\(margin.right)\" top=\"\(margin.top)\" bottom=\"\(margin.bottom)\"/></hp:tc>"
            }
            sb += "</hp:tr>"
        }
        width = outerWidth
        sb += "</hp:tbl>"
        let runs = RunBuilder()
        runs.control(base.char, sb, true)
        var result =
            "<hp:p id=\"0\" paraPrIDRef=\"\(base.para)\" styleIDRef=\"\(base.style)\" pageBreak=\"0\" columnBreak=\"0\" merged=\"0\">\(leadingRun ?? "")\(runs.finish(base.char,leadingRun != nil))</hp:p>"
        for b in table.caption { result += try block(b) }
        return result
    }
    static func placeCells(_ table: HTable) -> (placed: [[(cell: HCell, column: Int)]], columns: Int) {
        var placed: [[(cell: HCell, column: Int)]] = []
        var occupied = Set<String>()
        var count = table.columnCount
        for (r, row) in table.rows.enumerated() {
            var cells: [(HCell, Int)] = []
            var column = 0
            for cell in row.cells {
                if cell.column >= 0 { column = cell.column }
                while occupied.contains("\(r),\(column)") { column += 1 }
                for dr in 0..<max(1, cell.rowSpan) {
                    for dc in 0..<max(1, cell.colSpan) { occupied.insert("\(r+dr),\(column+dc)") }
                }
                cells.append((cell, column))
                column += max(1, cell.colSpan)
                count = max(count, column)
            }
            placed.append(cells)
        }
        return (placed, max(1, count))
    }
    static func columnWidths(_ table: HTable, _ columns: Int, _ available: Int) -> [Int] {
        if let abs = table.columnWidths, !abs.isEmpty {
            let widths = (0..<columns).map { $0 < abs.count ? abs[$0] : abs.reduce(0, +) / abs.count }
            let total = widths.reduce(0, +)
            return total <= available ? widths : widths.map { $0 * available / total }
        }
        let fractions = (0..<columns).map { i in table.relativeWidths.flatMap { i < $0.count ? $0[i] : nil } ?? 0 }
        let known = fractions.filter { $0 > 0 }.reduce(0, +)
        let unknown = fractions.filter { $0 <= 0 }.count
        let scale = known > 1 ? 1 / known : 1
        let rest = unknown == 0 ? 0 : max(0, 1 - known * scale) / Double(unknown)
        if unknown > 0 && rest <= 0 { return [Int](repeating: available / columns, count: columns) }
        return fractions.map { Int(Double(available) * ($0 > 0 ? $0 * scale : rest)) }
    }
}
