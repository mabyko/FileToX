// Port of HwpxReader.Body.cs: fields survive body paragraph boundaries, nested lists isolate state.
import Foundation

extension HwpxReader {
    func readSubList(_ sub: XElement?) throws -> [HBlock] {
        guard let sub else { return [] }
        let saved = (fields, markpen, deleted)
        fields = []
        markpen = nil
        deleted = false
        defer { (fields, markpen, deleted) = saved }
        var blocks: [HBlock] = []
        for e in Self.elements(sub) {
            if e.name.localName == "p" { blocks += try readParagraph(e, nil) } else { skip(e) }
        }
        return blocks
    }
    final class ParagraphBuilder {
        unowned let owner: HwpxReader
        let format: HParaFormat, heading: Int, list: HListRef?
        var output: [HBlock] = [], sinks: [HLink] = [], current: HParagraph, markFormat = HCharFormat(),
            afterTable = false
        init(_ owner: HwpxReader, _ format: HParaFormat, _ heading: Int, _ list: HListRef?) {
            self.owner = owner
            self.format = format
            self.heading = heading
            self.list = list
            current = HParagraph()
            newParagraph(list)
        }
        func add(_ inline: HInline) {
            if let sink = sinks.last { sink.content.append(inline) } else { current.inlines.append(inline) }
        }
        func addText(_ text: String, _ format: HCharFormat) {
            if text.isEmpty { return }
            if let sink = sinks.last {
                if let t = sink.content.last as? HText, t.format == format {
                    sink.content[sink.content.count - 1] = HText(t.text + text, format)
                } else {
                    sink.content.append(HText(text, format))
                }
            } else {
                if let t = current.inlines.last as? HText, t.format == format {
                    current.inlines[current.inlines.count - 1] = HText(t.text + text, format)
                } else {
                    current.inlines.append(HText(text, format))
                }
            }
        }
        func openLink(_ target: String) {
            let link = HLink(target)
            add(link)
            sinks.append(link)
        }
        func closeLink() { _ = sinks.popLast() }
        var hasContent: Bool { current.inlines.contains { ($0 as? HLink)?.content.isEmpty != true } }
        func table(_ t: HTable) {
            if hasContent || current.pageBreakBefore || current.columnBreakBefore || current.columnsChange != nil {
                emit()
            }
            output.append(t)
            newParagraph(list.map { HListRef($0.numbering, $0.level, false) })
            afterTable = true
        }
        func finish() { if !afterTable || hasContent { emit() } }
        func emit() {
            current.markFormat = markFormat
            output.append(current)
        }
        func newParagraph(_ list: HListRef?) {
            current = HParagraph()
            current.format = format
            current.headingLevel = heading
            current.list = list
            sinks = []
            for field in owner.fields { if let target = field.target { openLink(target) } }
        }
    }
    func readParagraph(_ p: XElement, _ section: SectionState?) throws -> [HBlock] {
        let shape = paraShapeOf(Self.attr(p, "paraPrIDRef"))
        let (heading, list) = headingAndList(shape, Self.attr(p, "styleIDRef"))
        let b = ParagraphBuilder(self, shape.format, heading, list)
        b.markFormat = charFormat(nil)
        b.current.pageBreakBefore = Self.flag(p, "pageBreak") || shape.pageBreak
        b.current.columnBreakBefore = Self.flag(p, "columnBreak")
        for e in Self.elements(p) {
            switch e.name.localName {
            case "run": try run(e, b, section)
            case "linesegarray": break
            default: skip(e)
            }
        }
        b.finish()
        return b.output
    }
    func headingAndList(_ s: ParaShape, _ style: String?) -> (Int, HListRef?) {
        var heading = 0
        var list: HListRef?
        switch s.headingType {
        case "OUTLINE":
            heading = min(s.level + 1, 9)
            let id = s.headingId.flatMap { !$0.isEmpty && $0 != "0" ? $0 : nil } ?? outlineNumberingId
            if let n = numbering(id), s.level < n.levels.count, Self.hasCounter(n.levels[s.level].text) {
                list = HListRef(n, s.level, true)
            }
        case "NUMBER", "NUMBERING", "BULLET":
            if let n = s.headingType == "BULLET" ? bullet(s.headingId) : numbering(s.headingId), !n.levels.isEmpty {
                list = HListRef(n, min(s.level, n.levels.count - 1), true)
            }
        default: break
        }
        return (heading > 0 ? heading : styleHeadingLevel(style), list)
    }
    func run(_ run: XElement, _ b: ParagraphBuilder, _ section: SectionState?) throws {
        let f = charFormat(Self.attr(run, "charPrIDRef"))
        b.markFormat = f
        for item in Self.elements(run) {
            switch item.name.localName {
            case "t": text(item, b, f)
            case "secPr": break
            case "ctrl": for c in Self.elements(item) { try control(c, b, f, section) }
            case "tbl": b.table(try table(item))
            case "colPr", "header", "footer", "footNote", "endNote", "fieldBegin", "fieldEnd", "bookmark", "autoNum",
                "newNum", "pageNum":
                try control(item, b, f, section)
            default: try drawingObject(item, b, f)
            }
        }
    }
    func highlighted(_ f: HCharFormat) -> HCharFormat {
        var f = f
        if let markpen { f.shade = markpen }
        return f
    }
    func text(_ e: XElement, _ b: ParagraphBuilder, _ f: HCharFormat) {
        for node in e.nodes {
            if let value0 = node.text {
                var value = value0
                if value.contains("\n") || value.contains("\r") {
                    if DocumentXML.trim(value).isEmpty { continue }
                    value = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                }
                if !deleted { b.addText(value, highlighted(f)) }
                continue
            }
            guard let e = node.element else { continue }
            switch e.name.localName {
            case "tab": if !deleted { b.add(HTab(highlighted(f))) }
            case "lineBreak", "columnBreak": if !deleted { b.add(HLineBreak(f)) }
            case "nbSpace": if !deleted { b.addText("\u{A0}", highlighted(f)) }
            case "fwSpace": if !deleted { b.addText("\u{2007}", highlighted(f)) }
            case "hyphen": if !deleted { b.addText("\u{AD}", highlighted(f)) }
            case "markpenBegin": markpen = Self.color(Self.attr(e, "color")) ?? "#FFFF00"
            case "markpenEnd": markpen = nil
            case "deleteBegin": deleted = true
            case "deleteEnd": deleted = false
            case "insertBegin", "insertEnd", "titleMark": break
            default: skip(e)
            }
        }
    }
    func control(_ c: XElement, _ b: ParagraphBuilder, _ f: HCharFormat, _ section: SectionState?) throws {
        switch c.name.localName {
        case "colPr" where section != nil:
            if section!.columnsSet {
                b.current.columnsChange = Self.columns(c)
            } else {
                section!.current.columns = Self.columns(c)
                section!.columnsSet = true
            }
        case "header", "footer": if let section { try headerFooter(c, section.current) } else { skip(c) }
        case "footNote", "endNote": b.add(try note(c, c.name.localName == "endNote"))
        case "fieldBegin": fieldBegin(c, b)
        case "fieldEnd": fieldEnd(c, b)
        case "bookmark": if let n = Self.attr(c, "name"), !n.isEmpty { b.add(HBookmark(n)) }
        case "autoNum":
            switch Self.attr(c, "numType") {
            case "PAGE": b.add(HField(.pageNumber, f))
            case "TOTAL_PAGE": b.add(HField(.totalPages, f))
            case "FOOTNOTE", "ENDNOTE": break
            default: b.addText(Self.attr(c, "num") ?? "", f)
            }
        case "newNum" where section != nil:
            if Self.attr(c, "numType") == "PAGE" && !section!.startNumberSet {
                section!.current.startPageNumber = max(1, Self.int(c, "num", 1))
                section!.startNumberSet = true
            }
        case "pageNum" where section != nil: section!.pageNumber = c
        default: skip(c)
        }
    }
    func headerFooter(_ c: XElement, _ s: HSection) throws {
        let pages: HPageType =
            Self.attr(c, "applyPageType") == "EVEN" ? .even : Self.attr(c, "applyPageType") == "ODD" ? .odd : .both
        let header = c.name.localName == "header"
        if (header ? s.headers : s.footers).contains(where: { $0.pages == pages }) {
            skip(c)
            return
        }
        let h = HHeaderFooter(pages)
        h.blocks = try readSubList(Self.child(c, "subList"))
        if header { s.headers.append(h) } else { s.footers.append(h) }
    }
    func note(_ c: XElement, _ endnote: Bool) throws -> HNote {
        let n = HNote(endnote)
        n.blocks = try readSubList(Self.child(c, "subList"))
        if let p = n.blocks.first as? HParagraph, let t = p.inlines.first as? HText, t.text.hasPrefix(" ") {
            if t.text.utf16.count == 1 {
                p.inlines.removeFirst()
            } else {
                p.inlines[0] = HText(String(t.text.dropFirst()), t.format)
            }
        }
        return n
    }
    func fieldBegin(_ c: XElement, _ b: ParagraphBuilder) {
        var target: String?
        if Self.attr(c, "type") == "HYPERLINK" {
            target = Self.hyperlinkTarget(c)
        } else if Self.attr(c, "type") == "BOOKMARK", let n = Self.attr(c, "name"), !n.isEmpty {
            b.add(HBookmark(n))
        }
        fields.append(OpenField(id: Self.attr(c, "id"), target: target))
        if let target { b.openLink(target) }
    }
    func fieldEnd(_ c: XElement, _ b: ParagraphBuilder) {
        let id = Self.attr(c, "beginIDRef")
        let index = fields.lastIndex { id == nil || $0.id == id } ?? fields.count - 1
        if index >= 0 {
            let f = fields.remove(at: index)
            if f.target != nil { b.closeLink() }
        }
    }
    static func hyperlinkTarget(_ e: XElement) -> String? {
        let p = descendants(e, "stringParam")
        func parameter(_ n: String) -> String? { p.first { attr($0, "name") == n }?.value }
        if let command = parameter("Command"), !command.isEmpty {
            let chars = Array(command)
            var target = ""
            var i = 0
            while i < chars.count {
                var c = chars[i]
                if c == "\\" && i + 1 < chars.count {
                    i += 1
                    target.append(chars[i])
                    i += 1
                    continue
                }
                if c == ";" { break }
                if c == "?" && !target.contains("://") { c = "#" }
                target.append(c)
                i += 1
            }
            if !target.isEmpty && target != "#" { return target }
        }
        return parameter("Path").flatMap { $0.isEmpty ? nil : $0 }
    }
    func table(_ tbl: XElement) throws -> HTable {
        let table = HTable()
        table.columnCount = max(0, Self.int(tbl, "colCnt"))
        let pos = Self.child(tbl, "pos")
        if pos != nil && !Self.flag(pos, "treatAsChar") {
            table.align =
                Self.attr(pos, "horzAlign") == "CENTER"
                ? .center : Self.attr(pos, "horzAlign") == "RIGHT" ? .right : .left
            if table.align == .left && [nil, "COLUMN", "PARA"].contains(Self.attr(pos, "horzRelTo")) {
                table.indent = max(0, Self.int(pos, "horzOffset"))
            }
        }
        if let m = Self.child(tbl, "inMargin") { table.cellMargin = Self.insets(m) }
        table.borders = borderFill(Self.attr(tbl, "borderFillIDRef"))?.borders
        var widths: [(Int, Int, Int)] = []
        var margins = Set<HInsets?>()
        var headerRows = true
        for tr in Self.children(tbl, "tr") {
            let row = HRow()
            var height: Int?
            var allHeader = true
            for tc in Self.children(tr, "tc") {
                func part(_ n: String) -> XElement? { Self.child(tc, n) ?? Self.child(Self.child(tc, "tcPr"), n) }
                let a = part("cellAddr")
                let span = part("cellSpan")
                let sz = part("cellSz")
                let sub = Self.child(tc, "subList")
                let cell = HCell()
                cell.column = a == nil ? -1 : max(0, Self.int(a, "colAddr"))
                cell.colSpan = max(1, Self.int(span, "colSpan", 1))
                cell.rowSpan = max(1, Self.int(span, "rowSpan", 1))
                cell.verticalAlign = Self.verticalAlign(Self.attr(sub, "vertAlign"))
                if let fill = borderFill(Self.attr(tc, "borderFillIDRef")) {
                    cell.borders = fill.borders
                    cell.fill = fill.fill
                }
                cell.blocks = try readSubList(sub)
                row.cells.append(cell)
                let h = Self.int(sz, "height")
                if cell.rowSpan == 1 && h > 0 { height = min(height ?? Int.max, h) }
                if cell.column >= 0 { widths.append((cell.column, cell.colSpan, Self.int(sz, "width"))) }
                allHeader = allHeader && Self.flag(tc, "header")
                margins.insert(Self.flag(tc, "hasMargin") ? part("cellMargin").map(Self.insets) : nil)
            }
            if row.cells.isEmpty { continue }
            row.height = height
            headerRows = headerRows && allHeader
            row.header = headerRows
            table.rows.append(row)
        }
        if margins.count == 1, let m = margins.first, let m { table.cellMargin = m }
        table.columnCount = max(table.columnCount, widths.map { $0.0 + $0.1 }.max() ?? 1)
        table.columnWidths = Self.columnWidths(widths, table.columnCount)
        if let c = Self.child(Self.child(tbl, "caption"), "subList") { table.caption = try readSubList(c) }
        return table
    }
    static func insets(_ e: XElement) -> HInsets {
        HInsets(int(e, "left"), int(e, "right"), int(e, "top"), int(e, "bottom"))
    }
    static func verticalAlign(_ v: String?) -> HVerticalAlign {
        v == "CENTER" ? .center : v == "BOTTOM" ? .bottom : .top
    }
    static func columnWidths(_ cells: [(Int, Int, Int)], _ columns: Int) -> [Int]? {
        if columns <= 0 { return nil }
        var widths = [Int?](repeating: nil, count: columns)
        for (c, s, w) in cells where s == 1 && c < columns && w > 0 { if widths[c] == nil { widths[c] = w } }
        for (c, s, w) in cells where s > 1 && w > 0 && c < columns {
            let range = Array(c..<min(c + s, columns))
            let unknown = range.filter { widths[$0] == nil }
            if unknown.isEmpty { continue }
            let rest = w - range.reduce(0) { $0 + (widths[$1] ?? 0) }
            for i in unknown { widths[i] = max(1, rest / unknown.count) }
        }
        let known = widths.compactMap { $0 }
        if known.isEmpty { return nil }
        let fallback = known.reduce(0, +) / known.count
        return widths.map { $0 ?? fallback }
    }
}
