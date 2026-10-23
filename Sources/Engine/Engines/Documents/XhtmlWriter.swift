// Port of XhtmlWriter.cs: chapters, links, lists, tables, pictures and notes.
import Foundation

struct XhtmlOptions {
    var splitChapters = false
    var chapterFile: (Int) -> String = { String(format: "ch%03d.xhtml", $0 + 1) }
    var imageSource: (String) -> String?
    var epub = false
    init(
        splitChapters: Bool = false,
        chapterFile: @escaping (Int) -> String = { String(format: "ch%03d.xhtml", $0 + 1) },
        imageSource: @escaping (String) -> String?, epub: Bool = false
    ) {
        self.splitChapters = splitChapters
        self.chapterFile = chapterFile
        self.imageSource = imageSource
        self.epub = epub
    }
}
struct XhtmlHeading { let level: Int, text: String, target: String }
struct XhtmlChapter {
    let fileName: String
    let title: String?
    let body: String, plainStart: String
    let headings: [XhtmlHeading]
}
final class XhtmlWriter {
    static let css =
        "body{font-family:serif;line-height:1.6;margin:0 3%;}\nh1,h2,h3,h4,h5,h6{line-height:1.3;margin:1.2em 0 .6em;page-break-after:avoid;}\np{margin:0 0 .6em;}\nli p{margin:.2em 0;}\ntable{border-collapse:collapse;margin:.8em 0;}\ntd,th{border:1px solid #999;padding:.2em .5em;vertical-align:top;}\ntable.plain td,table.plain th{border:none;}\ncaption{font-style:italic;margin-bottom:.3em;}\nimg{max-width:100%;}\npre{white-space:pre-wrap;background:#f4f3f8;padding:.5em .8em;}\ncode,pre{font-family:monospace;}\ncode{background:#f1f0f5;}\nmark{background:#fff3a3;}\nhr{border:none;border-top:1px solid #999;width:30%;margin:1.2em auto;}\n.page-break{page-break-before:always;break-before:page;}\n.box{border:1px solid #999;padding:.3em .6em;display:inline-block;}\naside.footnote,.footnotes{font-size:.9em;}\n"
    let options: XhtmlOptions, bodySize: Int
    var bookmarkChapter: [String: Int] = [:], ids: [String: String] = [:], usedIds = Set<String>(), chapter = 0,
        headingCount = 0, noteCount = 0, headings: [XhtmlHeading] = [], notes = ""
    private init(_ options: XhtmlOptions, _ size: Int) {
        self.options = options
        bodySize = size
    }
    static func write(_ doc: HDocument, _ options: XhtmlOptions) -> [XhtmlChapter] {
        let chapters = split(doc, options.splitChapters)
        let writer = XhtmlWriter(options, bodySize(doc))
        for (i, blocks) in chapters.enumerated() {
            for b in HDocumentWalker.inlines(blocks).compactMap({ $0 as? HBookmark })
            where writer.bookmarkChapter[b.name] == nil { writer.bookmarkChapter[b.name] = i }
        }
        var result: [XhtmlChapter] = []
        for (i, blocks) in chapters.enumerated() {
            writer.chapter = i
            writer.headings = []
            writer.notes = ""
            var body = writer.blocks(blocks)
            if !writer.notes.isEmpty {
                body +=
                    (options.epub
                        ? "<section class=\"footnotes\" epub:type=\"footnotes\">"
                        : "<section class=\"footnotes\"><hr/>") + writer.notes + "</section>\n"
            }
            let plain = HDocumentWalker.text(Array(HDocumentWalker.inlines(blocks).prefix(200)))
            result.append(
                XhtmlChapter(
                    fileName: options.chapterFile(i), title: writer.headings.first?.text, body: body,
                    plainStart: String(decoding: plain.utf16.prefix(60), as: UTF16.self), headings: writer.headings))
        }
        return result
    }
    static func page(
        _ title: String, _ body: String, _ language: String, _ styleSheet: String?, _ epub: Bool, _ head: String = ""
    ) -> String {
        (epub ? "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" : "")
            + "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\""
            + (epub ? " xmlns:epub=\"http://www.idpf.org/2007/ops\"" : "")
            + " lang=\"\(escape(language))\" xml:lang=\"\(escape(language))\">\n<head>\n<meta charset=\"utf-8\"/>\n<title>\(escape(title))</title>\n"
            + head
            + (styleSheet.map { "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escape($0))\"/>\n" }
                ?? "<style>\n\(css)</style>\n") + "</head>\n<body>\n" + body + "</body>\n</html>\n"
    }
    static func escape(_ s: String) -> String { HwpxWriter.escape(s) }
    static func split(_ doc: HDocument, _ split: Bool) -> [[HBlock]] {
        var chapters: [[HBlock]] = [[]]
        var length = 0
        for section in doc.sections {
            var start = true
            for b in section.blocks {
                if split && hasContent(chapters.last!) {
                    let p = b as? HParagraph
                    if start || p?.pageBreakBefore == true || p?.headingLevel == 1
                        || (length > 150000 && p != nil && p?.list == nil && p?.headingLevel == 0)
                    {
                        chapters.append([])
                        length = 0
                    }
                }
                start = false
                chapters[chapters.count - 1].append(b)
                length += HDocumentWalker.inlines([b]).compactMap { ($0 as? HText)?.text.utf16.count }.reduce(0, +)
            }
        }
        return chapters
    }
    static func hasContent(_ blocks: [HBlock]) -> Bool {
        blocks.contains {
            $0 is HTable
                || HDocumentWalker.inlines([$0]).contains {
                    $0 is HImage || ($0 as? HText).map { !DocumentXML.trim($0.text).isEmpty } == true
                }
        }
    }
    static func bodySize(_ doc: HDocument) -> Int {
        var counts: [Int: Int] = [:]
        var order: [Int] = []
        for t in doc.sections.flatMap({ HDocumentWalker.inlines($0.blocks) }).compactMap({ $0 as? HText }) {
            if let size = t.format.size {
                if counts[size] == nil { order.append(size) }
                counts[size, default: 0] += t.text.utf16.count
            }
        }
        let size = order.sorted { counts[$0]! > counts[$1]! }.first ?? 1000
        return size > 0 ? size : 1000
    }
    func blocks(_ list: [HBlock]) -> String {
        var i = 0
        var s = ""
        while i < list.count {
            if (list[i] as? HParagraph)?.list != nil {
                let result = writeList(list, i)
                i = result.0
                s += result.1
            } else if Self.isCodeLine(list[i]) {
                var lines: [String] = []
                while i < list.count && Self.isCodeLine(list[i]) {
                    lines.append((list[i] as! HParagraph).inlines.compactMap { ($0 as? HText)?.text }.joined())
                    i += 1
                }
                s += "<pre><code>\(Self.escape(lines.joined(separator:"\n")))</code></pre>\n"
            } else {
                if let p = list[i] as? HParagraph {
                    s += paragraph(p)
                } else if let t = list[i] as? HTable {
                    s += table(t)
                }
                i += 1
            }
        }
        return s
    }
    func paragraph(_ p: HParagraph) -> String {
        let br = p.pageBreakBefore && !options.splitChapters ? " class=\"page-break\"" : ""
        if p.inlines.contains(where: { ($0 as? HShape)?.kind == .line }) && !Self.hasVisible(p.inlines) {
            return anchors(p.inlines) + "<hr/>\n"
        }
        let content = inlines(p.inlines, p.headingLevel > 0)
        if !Self.hasVisible(p.inlines) { return content.isEmpty ? "" : "<div\(br)>\(content)</div>\n" }
        let style = Self.paragraphStyle(p.format)
        if p.headingLevel > 0 {
            let level = min(max(p.headingLevel, 1), 6)
            headingCount += 1
            let id = "_h\(headingCount)"
            usedIds.insert(id)
            headings.append(
                XhtmlHeading(
                    level: p.headingLevel, text: HDocumentWalker.text(p.inlines),
                    target: "\(options.chapterFile(chapter))#\(id)"))
            return "<h\(level) id=\"\(id)\"\(br)\(style)>\(content)</h\(level)>\n"
        }
        return "<p\(br)\(style)>\(content)</p>\n"
    }
    static func decimal(_ n: Double) -> String {
        var s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), n)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
    static func em(_ n: Int) -> String { decimal(Double(n) / 1000) + "em" }
    static func paragraphStyle(_ f: HParaFormat) -> String {
        var s: [String] = []
        if f.align == .center {
            s.append("text-align:center")
        } else if f.align == .right {
            s.append("text-align:right")
        } else if f.align == .justify || f.align == .distribute {
            s.append("text-align:justify")
        }
        if let left = f.left, left > 0 { s.append("margin-left:" + em(left)) }
        if let first = f.firstLine, first != 0 { s.append("text-indent:" + em(first)) }
        return s.isEmpty ? "" : " style=\"\(s.joined(separator:";"))\""
    }
    static func isCodeLine(_ b: HBlock) -> Bool {
        guard let p = b as? HParagraph else { return false }
        return p.list == nil && p.headingLevel == 0 && !p.inlines.isEmpty
            && p.inlines.allSatisfy { ($0 as? HText)?.format.shade == HtmlReader.codeShade }
    }
    struct OpenList { let numbering: HNumbering, level: Int, ordered: Bool }
    func writeList(_ list: [HBlock], _ start: Int) -> (Int, String) {
        var stack: [OpenList] = []
        var i = start
        var s = ""
        func close() {
            let last = stack.removeLast()
            s += "</li>\n" + (last.ordered ? "</ol>\n" : "</ul>\n")
        }
        while i < list.count, let p = list[i] as? HParagraph, let item = p.list {
            while !stack.isEmpty && stack.last!.level > item.level { close() }
            i += 1
            if !item.numbered {
                if stack.isEmpty {
                    s += paragraph(p)
                } else {
                    var f = p.format
                    f.left = nil
                    s += "<p\(Self.paragraphStyle(f))>\(inlines(p.inlines,false))</p>"
                }
                continue
            }
            if let last = stack.last, last.level == item.level && last.numbering !== item.numbering { close() }
            if stack.last?.level == item.level {
                s += "</li>\n"
            } else {
                let level =
                    item.numbering.levels.isEmpty
                    ? nil : item.numbering.levels[min(item.level, item.numbering.levels.count - 1)]
                let ordered = level?.bullet == false
                stack.append(OpenList(numbering: item.numbering, level: item.level, ordered: ordered))
                if !ordered {
                    s += "<ul>\n"
                } else {
                    let type = ["LATIN_SMALL": "a", "LATIN_CAPITAL": "A", "ROMAN_SMALL": "i", "ROMAN_CAPITAL": "I"][
                        level!.format]
                    s +=
                        "<ol" + (type.map { " type=\"\($0)\"" } ?? "")
                        + (level!.start != 1 ? " start=\"\(level!.start)\"" : "") + ">\n"
                }
            }
            var f = p.format
            f.left = nil
            f.firstLine = nil
            s += "<li\(Self.paragraphStyle(f))>\(inlines(p.inlines,false))"
        }
        while !stack.isEmpty { close() }
        return (i, s)
    }
    func table(_ t: HTable) -> String {
        var s = t.borders == .empty ? "<table class=\"plain\"" : "<table"
        if t.indent > 0 { s += " style=\"margin-left:\(Self.em(t.indent))\"" }
        s += ">\n"
        if !t.caption.isEmpty {
            s +=
                "<caption>"
                + t.caption.compactMap { $0 as? HParagraph }.map { inlines($0.inlines, false) }.joined(separator: " ")
                + "</caption>\n"
        }
        let h = t.rows.prefix(while: { $0.header }).count
        if h > 0 && h < t.rows.count { s += "<thead>\n" }
        for (r, row) in t.rows.enumerated() {
            if r == h && h > 0 && h < t.rows.count { s += "</thead>\n<tbody>\n" }
            s += "<tr>"
            for c in row.cells {
                let tag = row.header ? "th" : "td"
                s += "<\(tag)"
                if c.rowSpan > 1 { s += " rowspan=\"\(c.rowSpan)\"" }
                if c.colSpan > 1 { s += " colspan=\"\(c.colSpan)\"" }
                var styles: [String] = []
                if let fill = c.fill { styles.append("background-color:" + fill) }
                if c.verticalAlign != .top {
                    styles.append(c.verticalAlign == .center ? "vertical-align:middle" : "vertical-align:bottom")
                }
                if !styles.isEmpty { s += " style=\"\(styles.joined(separator:";"))\"" }
                s += ">"
                if c.blocks.count == 1, let p = c.blocks[0] as? HParagraph, p.list == nil, p.headingLevel == 0 {
                    s += inlines(p.inlines, false)
                } else {
                    s += blocks(c.blocks)
                }
                s += "</\(tag)>"
            }
            s += "</tr>\n"
        }
        if h > 0 && h < t.rows.count { s += "</tbody>\n" }
        return s + "</table>\n"
    }
    static func hasVisible(_ list: [HInline]) -> Bool {
        HDocumentWalker.inlinesOf(list).contains { i in
            if let t = i as? HText { return !DocumentXML.trim(t.text).isEmpty || t.text.contains("\u{A0}") }
            return i is HImage || i is HNote || i is HTextBox || i is HTab
        }
    }
    func anchors(_ list: [HInline]) -> String {
        list.compactMap { $0 as? HBookmark }.compactMap { id($0.name) }.map { "<a id=\"\($0)\"></a>" }.joined()
    }
    func inlines(_ list: [HInline], _ heading: Bool) -> String {
        var s = ""
        for i in list {
            switch i {
            case let t as HText: s += run(t.text, t.format, heading)
            case is HLineBreak: s += "<br/>"
            case is HTab: s += "\u{2003}"
            case let b as HBookmark: if let id = id(b.name) { s += "<a id=\"\(id)\"></a>" }
            case let l as HLink:
                let content = inlines(l.content, heading)
                s += href(l.target).map { "<a href=\"\(Self.escape($0))\">\(content)</a>" } ?? content
            case let image as HImage:
                if let source = options.imageSource(image.path) {
                    s += "<img src=\"\(Self.escape(source))\" alt=\"\""
                    if let w = image.width, w > 0 {
                        s += " style=\"width:\(max(1,Int((Double(w)/75).rounded(.toNearestOrEven))))px\""
                    }
                    s += "/>"
                }
            case let n as HNote: s += note(n)
            case let b as HTextBox:
                let parts = b.blocks.compactMap { $0 as? HParagraph }.map { inlines($0.inlines, false) }.filter {
                    !$0.isEmpty
                }
                if !parts.isEmpty { s += "<span class=\"box\">" + parts.joined(separator: "<br/>") + "</span>" }
            default: break
            }
        }
        return s
    }
    func run(_ text: String, _ f: HCharFormat, _ heading: Bool) -> String {
        if text.isEmpty { return "" }
        var s = ""
        var close: [String] = []
        var styles: [String] = []
        func open(_ tag: String, _ attrs: String = "") {
            s += "<\(tag)\(attrs)>"
            close.append("</\(tag)>")
        }
        if let c = f.color, c != "#000000" { styles.append("color:" + c) }
        if let shade = f.shade, shade != HtmlReader.codeShade && shade != HtmlReader.markShade {
            styles.append("background-color:" + shade)
        }
        if let size = f.size, abs(size - bodySize) > bodySize / 20, f.superscript != true, f.subscript != true {
            styles.append("font-size:\(Self.decimal(Double(size)/Double(bodySize)))em")
        }
        if heading && f.bold == false { styles.append("font-weight:normal") }
        if !styles.isEmpty { open("span", " style=\"\(styles.joined(separator:";"))\"") }
        if f.shade == HtmlReader.codeShade { open("code") }
        if f.shade == HtmlReader.markShade { open("mark") }
        if f.bold == true && !heading { open("b") }
        if f.italic == true { open("i") }
        if f.underline == true { open("u") }
        if f.strike == true { open("s") }
        if f.superscript == true { open("sup") } else if f.subscript == true { open("sub") }
        return s + Self.escape(text) + close.reversed().joined()
    }
    func href(_ target: String) -> String? {
        if target.hasPrefix("#") {
            let name = String(target.dropFirst())
            guard let c = bookmarkChapter[name], let id = id(name) else { return nil }
            return !options.splitChapters || c == chapter ? "#" + id : options.chapterFile(c) + "#" + id
        }
        guard let colon = target.firstIndex(of: ":"), target.distance(from: target.startIndex, to: colon) > 1,
            target[..<colon].allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        return target
    }
    func id(_ name: String) -> String? {
        if DocumentXML.trim(name).isEmpty { return nil }
        if let id = ids[name] { return id }
        var base = name.utf16.map { c -> String in
            if (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45 || c == 95 || c == 46
            {
                return String(UnicodeScalar(c)!)
            }
            return "_"
        }.joined()
        if base.first?.isASCII != true || base.first?.isLetter != true && base.first != "_" { base = "id-" + base }
        var result = base
        var n = 2
        while !usedIds.insert(result).inserted {
            result = "\(base)-\(n)"
            n += 1
        }
        ids[name] = result
        return result
    }
    func note(_ n: HNote) -> String {
        noteCount += 1
        let number = noteCount
        let epub = options.epub ? " epub:type=\"noteref\"" : ""
        let result =
            "<a class=\"noteref\" href=\"#_fn\(number)\" id=\"_fnref\(number)\"\(epub)><sup>\(number)</sup></a>"
        let content = blocks(n.blocks)
        let type = options.epub ? " epub:type=\"footnote\"" : ""
        notes +=
            "<aside class=\"footnote\" id=\"_fn\(number)\"\(type)><p><a href=\"#_fnref\(number)\">\(number).</a></p>\n"
            + content + "</aside>\n"
        return result
    }
}
