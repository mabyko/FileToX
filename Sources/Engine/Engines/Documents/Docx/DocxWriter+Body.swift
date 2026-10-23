// Port of DocxWriter.Body.cs, with section properties and formatting in schema order.
import Foundation

extension DocxWriter {
    static let defaultPage = HPage(
        width: 59528, height: 84188, left: 7200, right: 7200, top: 4255, bottom: 4255, header: 2945, footer: 2945,
        gutter: 0)
    static let highlights = [
        "#FFFF00": "yellow", "#00FF00": "green", "#00FFFF": "cyan", "#FF00FF": "magenta", "#0000FF": "blue",
        "#FF0000": "red", "#000080": "darkBlue", "#008080": "darkCyan", "#008000": "darkGreen",
        "#800080": "darkMagenta", "#800000": "darkRed", "#808000": "darkYellow", "#808080": "darkGray",
        "#C0C0C0": "lightGray", "#000000": "black",
    ]
    struct RunContext { var styleBold = false, link = false }
    func body(_ doc: HDocument) throws -> String {
        let sections = doc.sections.isEmpty ? [HSection()] : doc.sections
        evenAndOddHeaders = sections.contains { ($0.headers + $0.footers).contains { $0.pages == .even } }
        var s = ""
        for (i, section) in sections.enumerated() {
            let page = section.page ?? Self.defaultPage
            let pieces = Self.splitAtColumnChanges(section)
            for (j, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                width = page.textWidth
                let props = try sectionProperties(section, page, piece.0, j > 0)
                width = HwpxWriter.columnWidth(page.textWidth, piece.0)
                if i == sections.count - 1 && j == pieces.count - 1 {
                    s += try blocks(piece.1, nil, true) + props
                } else {
                    s += try blocks(piece.1, props)
                }
            }
        }
        return s
    }
    static func splitAtColumnChanges(_ s: HSection) -> [(HColumns, [HBlock])] {
        var result: [(HColumns, [HBlock])] = []
        var columns = s.columns
        var current: [HBlock] = []
        for b in s.blocks {
            if let change = (b as? HParagraph)?.columnsChange {
                if !current.isEmpty {
                    result.append((columns, current))
                    current = []
                }
                columns = change
            }
            current.append(b)
        }
        result.append((columns, current))
        return result
    }
    func sectionProperties(_ section: HSection, _ page: HPage, _ columns: HColumns, _ continuous: Bool) throws -> String
    {
        var s = "<w:sectPr>"
        let titlePage = !continuous && (section.hideFirstHeader || section.hideFirstFooter)
        if !continuous {
            var h = headerTypes
            var f = footerTypes
            s += try headerFooterReferences("header", section.headers, section.hideFirstHeader, titlePage, &h)
            headerTypes = h
            s += try headerFooterReferences("footer", section.footers, section.hideFirstFooter, titlePage, &f)
            footerTypes = f
        } else {
            s += "<w:type w:val=\"continuous\"/>"
        }
        s +=
            "<w:pgSz w:w=\"\(Self.twips(page.width))\" w:h=\"\(Self.twips(page.height))\"\(page.landscape ? " w:orient=\"landscape\"" : "")/>"
        s +=
            "<w:pgMar w:top=\"\(Self.twips(page.top+page.header))\" w:right=\"\(Self.twips(page.right))\" w:bottom=\"\(Self.twips(page.bottom+page.footer))\" w:left=\"\(Self.twips(page.left))\" w:header=\"\(Self.twips(page.top))\" w:footer=\"\(Self.twips(page.bottom))\" w:gutter=\"\(Self.twips(page.gutter))\"/>"
        if !continuous, let start = section.startPageNumber { s += "<w:pgNumType w:start=\"\(start)\"/>" }
        s +=
            columns.count > 1
            ? "<w:cols w:num=\"\(min(columns.count,45))\" w:space=\"\(Self.twips(columns.gap))\"\(columns.separator ? " w:sep=\"1\"" : "")/>"
            : "<w:cols w:space=\"720\"/>"
        if titlePage { s += "<w:titlePg/>" }
        return s + "</w:sectPr>"
    }
    func headerFooterReferences(
        _ kind: String, _ items: [HHeaderFooter], _ hide: Bool, _ title: Bool, _ used: inout [String]
    ) throws -> String {
        var byType: [String: [HBlock]] = [:]
        var order: [String] = []
        func set(_ key: String, _ value: [HBlock]) {
            if byType[key] == nil { order.append(key) }
            byType[key] = value
        }
        for item in items { set(item.pages == .even ? "even" : "default", item.blocks) }
        if evenAndOddHeaders && byType["even"] == nil, let both = items.last(where: { $0.pages == .both }) {
            set("even", both.blocks)
        }
        if title { set("first", hide ? [] : byType["default"] ?? []) }
        for key in used where byType[key] == nil { set(key, []) }
        var s = ""
        for key in order {
            let b = byType[key]!
            let id = try headerFooterPart(kind) { try blocks(b, nil, true) }
            s += "<w:\(kind)Reference w:type=\"\(key)\" r:id=\"\(id)\"/>"
            if !used.contains(key) { used.append(key) }
        }
        return s
    }
    func blocks(
        _ input: [HBlock], _ sectionEnd: String? = nil, _ requireParagraph: Bool = false, _ style: String? = nil,
        _ leading: String? = nil
    ) throws -> String {
        var input = input
        var s = ""
        if leading != nil && (input.isEmpty || !(input[0] is HParagraph)) { input.insert(HParagraph(), at: 0) }
        for (i, b) in input.enumerated() {
            if let p = b as? HParagraph {
                s += try paragraph(p, i == input.count - 1 ? sectionEnd : nil, style, i == 0 ? leading : nil)
            } else if let t = b as? HTable {
                if i > 0 && input[i - 1] is HTable { s += "<w:p/>" }
                s += try table(t)
            }
        }
        if !(input.last is HParagraph) {
            if let end = sectionEnd {
                s += "<w:p><w:pPr>\(end)</w:pPr></w:p>"
            } else if requireParagraph {
                s += "<w:p/>"
            }
        }
        return s
    }
    func paragraph(_ p: HParagraph, _ sectPr: String? = nil, _ style: String? = nil, _ leading: String? = nil) throws
        -> String
    {
        let heading = (1...9).contains(p.headingLevel) ? p.headingLevel : 0
        let context = RunContext(styleBold: heading > 0, link: false)
        return "<w:p>" + paragraphProperties(p, heading > 0 ? "Heading\(heading)" : style, heading > 0, sectPr, context)
            + (p.columnBreakBefore ? "<w:r><w:br w:type=\"column\"/></w:r>" : "") + (leading ?? "")
            + (try inlines(p.inlines, context)) + "</w:p>"
    }
    func paragraphProperties(
        _ p: HParagraph, _ style: String?, _ heading: Bool, _ sectPr: String?, _ context: RunContext
    ) -> String {
        let f = p.format
        var s = ""
        if let style { s += "<w:pStyle w:val=\"\(style)\"/>" }
        for (key, value) in [("keepNext", f.keepWithNext), ("keepLines", f.keepLines)] {
            if value == true { s += "<w:\(key)/>" } else if value == false && heading { s += "<w:\(key) w:val=\"0\"/>" }
        }
        if p.pageBreakBefore { s += "<w:pageBreakBefore/>" }
        if f.widowOrphan == false { s += "<w:widowControl w:val=\"0\"/>" }
        if let list = p.list, list.numbered {
            s +=
                "<w:numPr><w:ilvl w:val=\"\(min(max(list.level,0),8))\"/><w:numId w:val=\"\(numberingId(list.numbering))\"/></w:numPr>"
        }
        if let tabs = f.tabs, !tabs.isEmpty {
            s += "<w:tabs>"
            for t in tabs.sorted(by: { $0.position < $1.position }) {
                let kind =
                    t.kind == .right ? "right" : t.kind == .center ? "center" : t.kind == .decimal ? "decimal" : "left"
                let leader =
                    ["DOT": " w:leader=\"dot\"", "DASH": " w:leader=\"hyphen\"", "SOLID": " w:leader=\"underscore\""][
                        t.leader] ?? ""
                s += "<w:tab w:val=\"\(kind)\"\(leader) w:pos=\"\(Self.twips(t.position))\"/>"
            }
            s += "</w:tabs>"
        }
        var spacing = ""
        if let b = f.before { spacing += " w:before=\"\(max(0,Self.twips(b)))\"" }
        if let a = f.after { spacing += " w:after=\"\(max(0,Self.twips(a)))\"" }
        if let line = f.lineSpacing {
            if line.kind == .fixed || line.kind == .atLeast {
                spacing +=
                    " w:line=\"\(max(20,Self.twips(line.value)))\" w:lineRule=\"\(line.kind == .fixed ? "exact" : "atLeast")\""
            } else {
                spacing +=
                    " w:line=\"\(min(max(Int((Double(line.value)*240/130).rounded(.toNearestOrEven)),24),2400))\" w:lineRule=\"auto\""
            }
        }
        if !spacing.isEmpty { s += "<w:spacing\(spacing)/>" }
        if let list = p.list, f.left == nil {
            if !list.numbered { s += "<w:ind w:left=\"\(Self.listIndent(list.level))\"/>" }
        } else if (f.left != nil || f.right != nil || f.firstLine != nil)
            && (p.list != nil || (f.left ?? 0) != 0 || (f.right ?? 0) != 0 || (f.firstLine ?? 0) != 0)
        {
            s += "<w:ind"
            if let n = f.left { s += " w:left=\"\(Self.twips(n))\"" }
            if let n = f.right { s += " w:right=\"\(Self.twips(n))\"" }
            if let n = f.firstLine {
                s += n < 0 ? " w:hanging=\"\(Self.twips(-n))\"" : " w:firstLine=\"\(Self.twips(n))\""
            }
            s += "/>"
        }
        if let a = f.align, a != .left {
            s +=
                "<w:jc w:val=\"\(a == .center ? "center" : a == .right ? "right" : a == .distribute ? "distribute" : "both")\"/>"
        }
        let mark = Self.runProperties(p.markFormat, context)
        if !mark.isEmpty { s += "<w:rPr>\(mark)</w:rPr>" }
        s += sectPr ?? ""
        return s.isEmpty ? "" : "<w:pPr>\(s)</w:pPr>"
    }
    func inlines(_ list: [HInline], _ c: RunContext) throws -> String {
        var s = ""
        for i in list {
            switch i {
            case let t as HText: s += Self.textRuns(t.text, t.format, c)
            case let b as HLineBreak: s += "<w:r>\(Self.runPr(b.format,c))<w:br/></w:r>"
            case let t as HTab: s += "<w:r>\(Self.runPr(t.format,c))<w:tab/></w:r>"
            case let l as HLink: s += try hyperlink(l, c)
            case let b as HBookmark:
                let id = nextBookmarkId
                nextBookmarkId += 1
                s +=
                    "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(Self.escape(bookmarkName(b.name)))\"/><w:bookmarkEnd w:id=\"\(id)\"/>"
            case let f as HField: s += Self.field(f.kind == .pageNumber ? "PAGE" : "NUMPAGES", Self.runPr(f.format, c))
            case let n as HNote: s += try noteReference(n)
            case let image as HImage: s += picture(image)
            case let box as HTextBox: s += try textBox(box, c)
            case let shape as HShape: s += shapeXml(shape)
            default: break
            }
        }
        return s
    }
    static func textRuns(_ text: String, _ f: HCharFormat, _ c: RunContext) -> String {
        if text.isEmpty { return "" }
        var s = "<w:r>" + runPr(f, c)
        var segment: [UInt16] = []
        let chars = Array(text.utf16)
        for (i, ch) in chars.enumerated() {
            if ch != 10 && ch != 9 && ch != 13 {
                segment.append(ch)
                continue
            }
            if !segment.isEmpty {
                s += "<w:t xml:space=\"preserve\">\(escape(String(decoding:segment,as:UTF16.self)))</w:t>"
                segment = []
            }
            if ch == 9 {
                s += "<w:tab/>"
            } else if ch == 10 || (ch == 13 && (i + 1 >= chars.count || chars[i + 1] != 10)) {
                s += "<w:br/>"
            }
        }
        if !segment.isEmpty {
            s += "<w:t xml:space=\"preserve\">\(escape(String(decoding:segment,as:UTF16.self)))</w:t>"
        }
        return s + "</w:r>"
    }
    static func runPr(_ f: HCharFormat, _ c: RunContext, _ style: String? = nil) -> String {
        let s = runProperties(f, c, style)
        return s.isEmpty ? "" : "<w:rPr>\(s)</w:rPr>"
    }
    static func runProperties(_ f: HCharFormat, _ c: RunContext, _ characterStyle: String? = nil) -> String {
        let style = characterStyle ?? (c.link ? "Hyperlink" : nil)
        var s = ""
        if let style { s += "<w:rStyle w:val=\"\(style)\"/>" }
        if f.font != nil || f.eastAsianFont != nil {
            s += "<w:rFonts"
            if let font = f.font { s += " w:ascii=\"\(escape(font))\" w:hAnsi=\"\(escape(font))\"" }
            if let east = f.eastAsianFont ?? f.font { s += " w:eastAsia=\"\(escape(east))\"" }
            if let font = f.font { s += " w:cs=\"\(escape(font))\"" }
            s += "/>"
        }
        if f.bold == true {
            s += "<w:b/><w:bCs/>"
        } else if f.bold == false && c.styleBold {
            s += "<w:b w:val=\"0\"/><w:bCs w:val=\"0\"/>"
        }
        if f.italic == true { s += "<w:i/><w:iCs/>" }
        if f.strike == true { s += "<w:strike/>" }
        if let color = hex(f.color) { s += "<w:color w:val=\"\(color)\"/>" }
        if let spacing = f.spacing, spacing != 0 {
            s += "<w:spacing w:val=\"\(Int((Double(spacing*(f.size ?? 1000))/500).rounded(.toNearestOrEven)))\"/>"
        }
        if let size = f.size {
            let n = min(max(Int((Double(size) / 50).rounded(.toNearestOrEven)), 2), 3276)
            s += "<w:sz w:val=\"\(n)\"/><w:szCs w:val=\"\(n)\"/>"
        }
        let highlight = f.shade.flatMap { highlights[$0.uppercased()] }
        if let highlight { s += "<w:highlight w:val=\"\(highlight)\"/>" }
        if f.underline == true {
            s += "<w:u w:val=\"single\"/>"
        } else if f.underline == false && style == "Hyperlink" {
            s += "<w:u w:val=\"none\"/>"
        }
        if highlight == nil, let fill = hex(f.shade) {
            s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>"
        }
        if f.superscript == true {
            s += "<w:vertAlign w:val=\"superscript\"/>"
        } else if f.subscript == true {
            s += "<w:vertAlign w:val=\"subscript\"/>"
        }
        return s
    }
    static func field(_ instruction: String, _ props: String) -> String {
        "<w:r>\(props)<w:fldChar w:fldCharType=\"begin\"/></w:r><w:r>\(props)<w:instrText xml:space=\"preserve\"> \(instruction) </w:instrText></w:r><w:r>\(props)<w:fldChar w:fldCharType=\"separate\"/></w:r><w:r>\(props)<w:t>1</w:t></w:r><w:r>\(props)<w:fldChar w:fldCharType=\"end\"/></w:r>"
    }
    func noteReference(_ n: HNote) throws -> String {
        let kind = n.endnote ? "endnote" : "footnote"
        let style = n.endnote ? "Endnote" : "Footnote"
        if part !== document || textBoxDepth > 0 {
            let text = n.blocks.compactMap { $0 as? HParagraph }.flatMap(\.inlines).compactMap { ($0 as? HText)?.text }
                .joined()
            return Self.textRuns(" (\(text))", HCharFormat(), RunContext())
        }
        let p: Part
        let id: Int
        if n.endnote {
            if endnotesPart == nil { endnotesPart = Part("word/endnotes.xml", Self.contentTypeBase + "endnotes+xml") }
            p = endnotesPart!
            id = endnotes.count + 1
            endnotes.append("")
        } else {
            if footnotesPart == nil {
                footnotesPart = Part("word/footnotes.xml", Self.contentTypeBase + "footnotes+xml")
            }
            p = footnotesPart!
            id = footnotes.count + 1
            footnotes.append("")
        }
        let number =
            "<w:r><w:rPr><w:rStyle w:val=\"\(style)Reference\"/></w:rPr><w:\(kind)Ref/></w:r><w:r><w:t xml:space=\"preserve\"> </w:t></w:r>"
        let content = try withPart(p) { try blocks(n.blocks, nil, true, style + "Text", number) }
        if n.endnote { endnotes[id - 1] = content } else { footnotes[id - 1] = content }
        return "<w:r><w:rPr><w:rStyle w:val=\"\(style)Reference\"/></w:rPr><w:\(kind)Reference w:id=\"\(id)\"/></w:r>"
    }
}
