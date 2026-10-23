// Port of Filee.Engines/Hwp/Hwpx/HtmlReader.cs: HTML / XHTML → HDocument, so HTML → HWPX / PDF needs no Pandoc and
// e-books (EPUB, MOBI, HTMLZ) reuse the same reader for their chapters. Filee parsed with AngleSharp; this port parses
// with libxml2 (HtmlDom), which repairs the tree where it differs from HTML5.
//
// Headings, paragraphs, inline formatting (b / strong / i / em / u / s / del / sub / sup / code / mark / small /
// font and the basic inline CSS: colour, background, font-weight, font-style, font-size, text-decoration,
// vertical-align, text-align), simple class and tag rules from <style> and linked style sheets, line breaks, nested
// lists with their start numbers and marker types, tables with spans / header rows / borders, images (local files
// and data: URIs; remote images are skipped), links and anchors, block quotes, pre, hr, figures and CSS page breaks.
// Scripts, styles, forms, media and <nav> are skipped. The encoding comes from the BOM, the XML declaration or
// <meta charset>, else UTF-8 when valid, else the ANSI code page of the user's language (what browsers fall back to).

import Foundation

/// How an HTML document's resources, links and anchors are resolved.
struct HtmlReadOptions {
    /// Folder that relative image and style sheet paths are resolved against (the HTML file's folder).
    var baseFolder: String
    /// Folder that receives images embedded as data: URIs (created on demand).
    var mediaFolder: String
    /// Maps an href to the link target to write, or nil to keep only the link text. Default: unchanged.
    var mapLink: ((String) -> String?)?
    /// Maps an element id to a bookmark name, or nil for no bookmark. Default: the id itself.
    var mapId: ((String) -> String?)?

    init(baseFolder: String, mediaFolder: String, mapLink: ((String) -> String?)? = nil, mapId: ((String) -> String?)? = nil) {
        self.baseFolder = baseFolder
        self.mediaFolder = mediaFolder
        self.mapLink = mapLink
        self.mapId = mapId
    }
}

/// What HtmlReader read from one HTML document: its blocks, the text of <title> and the lang attribute of <html>.
struct HtmlContent {
    var blocks: [HBlock]
    var title: String?
    var language: String?
}

/// Reads HTML into the HWPX document model.
final class HtmlReader {
    /// Indent per block quote level (same as the Markdown and Pandoc readers).
    private static let quoteIndent = 2000

    /// Deeper elements are read as plain text.
    private static let maxDepth = 200

    /// Size 1em stands for when no size is set: 10 pt, the body text of the HWPX template.
    private static let baseSize = 1000

    /// Shading of code, as the Markdown reader writes it.
    static let codeShade = "#F1F0F5"

    /// Shading of <mark>, as the Markdown reader writes ==marked== text.
    static let markShade = "#FFF3A3"

    /// Elements whose content is never document text.
    private static let skipped: Set<String> = [
        "head", "title", "meta", "link", "script", "style", "noscript", "template", "nav", "button", "select",
        "option", "textarea", "input", "iframe", "object", "embed", "video", "audio", "canvas", "map", "param",
        "source", "track", "dialog", "rp", "base",
    ]

    /// Elements that start a new paragraph (HTML's block-level elements).
    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "main", "header", "footer", "aside", "address", "center", "details",
        "summary", "fieldset", "legend", "form", "hgroup", "body", "html", "dl", "dt", "dd", "menu", "caption",
        "figure", "figcaption", "blockquote", "pre", "li", "listing", "plaintext", "xmp",
    ]

    private let options: HtmlReadOptions
    private let sheet = CssStyleSheet()
    private var embedded = 0

    private init(_ options: HtmlReadOptions) { self.options = options }

    // MARK: Entry points

    /// Reads an HTML file as a document of its own. `mediaFolder` is a scratch folder for images embedded as data: URIs.
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        let content = try readFile(path, HtmlReadOptions(baseFolder: FilePath.directoryName(FilePath.fullPath(path)) ?? "/",
                                                         mediaFolder: mediaFolder))
        let section = HSection()
        section.blocks += content.blocks
        let document = HDocument()
        document.title = content.title
        document.sections.append(section)
        pruneBookmarks(document)
        return document
    }

    /// Reads an HTML file (e.g. an e-book chapter) with the given resolution rules.
    static func readFile(_ path: String, _ options: HtmlReadOptions) throws -> HtmlContent {
        try parse(decode(Data(contentsOf: URL(fileURLWithPath: path))), options, isXhtml(path))
    }

    /// Reads HTML text. `xhtml`: the text is XHTML (XML syntax), so self-closed elements such as <div/> are closed.
    static func parse(_ html: String, _ options: HtmlReadOptions, _ xhtml: Bool = false) throws -> HtmlContent {
        let document = HtmlDom.parse(xhtml || html.hasPrefix("<?xml") ? expandSelfClosing(html) : html)
        defer { document.dispose() }
        let reader = HtmlReader(options)
        reader.loadStyleSheets(document)

        let sink = Sink()
        if let body = document.body {
            try onLargeStack {
                try reader.children(body, sink, Context(format: HCharFormat(), align: nil, indent: 0, listLevel: 0, item: nil,
                                                        heading: 0, pre: false, firstLine: nil))
            }
        }
        reader.flush(sink)
        if !sink.pendingBookmarks.isEmpty, let last = sink.blocks.last(where: { $0 is HParagraph }) as? HParagraph {
            last.inlines += sink.pendingBookmarks
        }
        if let first = sink.blocks.first as? HParagraph {
            first.pageBreakBefore = false // a break before the very first paragraph would only add an empty page
        }

        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = document.documentElement?.getAttribute("lang") ?? document.documentElement?.getAttribute("xml:lang")
        return HtmlContent(blocks: sink.blocks, title: title.isEmpty ? nil : title,
                           language: language.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 })
    }

    /// Runs the tree walk on a thread with a 16 MB stack: the walk recurses per element level, and deeply nested
    /// pages (up to `maxDepth` levels) would exhaust the stack of a pool thread.
    private static func onLargeStack(_ work: @escaping () throws -> Void) throws {
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            do { try work() } catch { outcome.error = error }
            done.signal()
        }
        thread.stackSize = 16 * 1024 * 1024
        thread.start()
        done.wait()
        if let error = outcome.error { throw error }
    }

    /// Removes bookmarks that no link points to (every element id becomes one while reading).
    static func pruneBookmarks(_ document: HDocument) {
        var targets = Set<String>()
        for section in document.sections {
            for case let link as HLink in HDocumentWalker.inlines(section.blocks) where link.target.unicodeScalars.first == "#" {
                targets.insert(link.target.droppingFirstScalar())
            }
        }
        func prune(_ inlines: inout [HInline]) {
            inlines.removeAll { ($0 as? HBookmark).map { !targets.contains($0.name) } ?? false }
            for inline in inlines {
                if let link = inline as? HLink { prune(&link.content) }
                else if let note = inline as? HNote { prune(note.blocks) }
                else if let box = inline as? HTextBox { prune(box.blocks) }
            }
        }
        func prune(_ blocks: [HBlock]) {
            for block in blocks {
                if let paragraph = block as? HParagraph {
                    prune(&paragraph.inlines)
                } else if let table = block as? HTable {
                    prune(table.caption)
                    for row in table.rows { for cell in row.cells { prune(cell.blocks) } }
                }
            }
        }
        for section in document.sections { prune(section.blocks) }
    }

    // MARK: Encoding

    /// Decodes an HTML file: BOM, then the XML declaration or <meta charset>, then UTF-8 when the bytes are valid
    /// UTF-8, else the ANSI code page of the user's language (CP949 for Korean), like browsers do.
    static func decode(_ bytes: Data) -> String {
        let start = [UInt8](bytes.prefix(4))
        if start.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        if start.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return TextEncodings.decode(bytes.dropFirst(4), encoding: .utf32LittleEndian) }
        if start.starts(with: [0xFF, 0xFE]) { return TextEncodings.decode(bytes.dropFirst(2), encoding: .utf16LittleEndian) }
        if start.starts(with: [0xFE, 0xFF]) { return TextEncodings.decode(bytes.dropFirst(2), encoding: .utf16BigEndian) }

        let head = String(String.UnicodeScalarView(bytes.prefix(4096).map { Unicode.Scalar($0) }))
        let declared = firstGroup(xmlEncoding, head) ?? firstGroup(metaCharset, head)
        if let declared, !declared.lowercased().hasPrefix("utf-16"), let encoding = TextEncodings.encoding(name: declared) {
            return TextEncodings.decode(bytes, encoding: encoding)
        }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return TextEncodings.decode(bytes, codePage: ansiCodePage)
    }

    /// The Windows ANSI code page of the user's language, as .NET's `CultureInfo.CurrentCulture.TextInfo.ANSICodePage`.
    static var ansiCodePage: Int {
        let language = Locale.current.language
        let script = language.script?.identifier
        switch language.languageCode?.identifier ?? "en" {
        case "ko": return 949
        case "ja": return 932
        case "zh": return script == "Hant" || ["TW", "HK", "MO"].contains(Locale.current.region?.identifier ?? "") ? 950 : 936
        case "th": return 874
        case "vi": return 1258
        case "el": return 1253
        case "he": return 1255
        case "ar", "fa", "ur": return 1256
        case "et", "lv", "lt": return 1257
        case "tr": return 1254
        case "az", "uz": return script == "Cyrl" ? 1251 : 1254
        case "sr": return script == "Latn" ? 1250 : 1251
        case "ru", "uk", "be", "bg", "mk", "kk", "ky", "tt", "mn", "ba", "sah", "tg": return 1251
        case "cs", "hu", "pl", "ro", "sk", "sl", "hr", "bs", "sq", "hsb", "dsb": return 1250
        default: return 1252
        }
    }

    private static func isXhtml(_ path: String) -> Bool {
        [".xhtml", ".xht", ".xml", ".opf"].contains(FilePath.extension(path).lowercased())
    }

    /// XHTML allows <div/> and <a id="x"/>; an HTML parser would treat them as start tags and nest the rest of the
    /// chapter inside. Void elements (br, img, ...) stay as they are.
    static func expandSelfClosing(_ html: String) -> String {
        selfClosing.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<$1$2></$1>")
    }

    private static let xmlEncoding = try! NSRegularExpression(pattern: #"<\?xml[^>]*encoding\s*=\s*["']([\w.:-]+)"#, options: .caseInsensitive)
    private static let metaCharset = try! NSRegularExpression(pattern: #"<meta[^>]+charset\s*=\s*["']?\s*([\w.:-]+)"#, options: .caseInsensitive)
    private static let selfClosing = try! NSRegularExpression(
        pattern: #"<(?!(?:area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)[\s/>])([A-Za-z][\w:.-]*)(\s[^<>]*?)?\s*/>"#)

    private static func firstGroup(_ regex: NSRegularExpression, _ text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Style sheets

    private func loadStyleSheets(_ document: HtmlDom.Document) {
        for element in document.elements(["style", "link"]) {
            if element.localName == "style" {
                sheet.add(element.textContent)
                continue
            }
            // A missing or locked style sheet only costs formatting.
            guard (element.getAttribute("rel") ?? "").range(of: "stylesheet", options: .caseInsensitive) != nil,
                  let css = localFile(element.getAttribute("href")),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: css)) else { continue }
            sheet.add(Self.decode(data))
        }
    }

    /// Declarations for an element: matching style sheet rules, then its style attribute.
    private func styleOf(_ element: HtmlDom.Element) -> CssDeclarations {
        var style = sheet.isEmpty ? CssDeclarations() : sheet.match(element.localName, element.classList)
        if let inline = element.getAttribute("style"), !inline.isEmpty { style.merge(CssDeclarations.parse(inline)) }
        return style
    }

    // MARK: Walking

    /// Formatting and nesting of the content being read. `item`: list item receiving the next paragraphs (the first
    /// one gets the bullet or number); `heading`: level of the paragraphs being read, 0 for body text; `pre`: white
    /// space is kept; `firstLine`: CSS text-indent; `depth`: element nesting, limited so that absurdly deep HTML
    /// cannot exhaust the stack.
    private struct Context {
        var format: HCharFormat
        var align: HAlign?
        var indent: Int
        var listLevel: Int
        var item: ListItem?
        var heading: Int
        var pre: Bool
        var firstLine: Int?
        var depth = 0
    }

    /// A list item: its paragraphs share the list, only the first one is numbered.
    private final class ListItem {
        let numbering: HNumbering
        let level: Int
        var used = false
        init(_ numbering: HNumbering, _ level: Int) { self.numbering = numbering; self.level = level }
    }

    /// Where blocks go, and the paragraph currently receiving inline content.
    private final class Sink {
        var blocks: [HBlock] = []
        var paragraph: HParagraph?
        var paragraphItem: ListItem?
        /// The current paragraph is a line of preformatted text.
        var preformatted = false
        /// The link element being read, and its part in the current paragraph.
        var linkTarget: String?
        var link: HLink?
        /// True at the start of a line: leading spaces are dropped (HTML white space collapsing).
        var lineStart = true
        var endsWithSpace = false
        var breakPending = false
        var pendingBookmarks: [HInline] = []
    }

    private func children(_ parent: HtmlDom.Element, _ sink: Sink, _ context: Context) throws {
        for child in parent.childNodes { try node(child, sink, context) }
    }

    private func node(_ node: HtmlDom.Node, _ sink: Sink, _ context: Context) throws {
        if let text = node as? HtmlDom.Text { self.text(text.data, sink, context) }
        else if let element = node as? HtmlDom.Element { try self.element(element, sink, context) }
    }

    private func element(_ element: HtmlDom.Element, _ sink: Sink, _ context: Context) throws {
        let name = element.localName.lowercased()
        if Self.skipped.contains(name) || element.hasAttribute("hidden") { return }
        if context.depth > Self.maxDepth {
            text(element.textContent, sink, context)
            return
        }
        let style = styleOf(element)
        if style.get("display") == "none" { return }

        if Self.isPageBreak(style.get("page-break-before") ?? style.get("break-before")) {
            flush(sink)
            sink.breakPending = true
        }

        var c = context
        c.format = Self.charFormat(name, element, style, context.format)
        c.depth = context.depth + 1
        if let align = Self.align(element.getAttribute("align") ?? style.get("text-align")) { c.align = align }
        if let whiteSpace = style.get("white-space") { c.pre = whiteSpace.lowercased().hasPrefix("pre") }
        if let indent = CssValues.length(style.get("text-indent"), Double(Self.baseSize)) { c.firstLine = indent }

        switch name {
        case "br":
            addInline(HLineBreak(c.format), sink, c)
            sink.lineStart = true
            sink.endsWithSpace = false
        case "img":
            try image(element, element.getAttribute("src"), style, sink, c)
        case "image": // <image xlink:href> inside <svg>, e.g. EPUB cover pages
            try image(element, element.getAttribute("xlink:href") ?? element.getAttribute("href"), style, sink, c)
        case "svg":
            for image in element.descendants() where image.localName.lowercased() == "image" {
                try self.element(image, sink, c)
            }
        case "a":
            try anchor(element, sink, c)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            var heading = c
            heading.heading = Int(name.dropFirst()) ?? 0
            try block(element, sink, heading)
        case "ul", "ol", "menu", "dir":
            try list(element, name == "ol", style, sink, c)
        case "table":
            try table(element, style, sink, c)
        case "blockquote", "dd":
            var quoted = c
            quoted.indent = c.indent + Self.quoteIndent
            try block(element, sink, quoted)
        case "pre", "listing", "xmp", "plaintext":
            var code = c
            code.pre = true
            code.format.shade = Self.codeShade
            try block(element, sink, code)
        case "figure", "center":
            var centred = c
            centred.align = c.align ?? .center
            try block(element, sink, centred)
        case "figcaption":
            var caption = c
            caption.align = c.align ?? .center
            caption.format.italic = c.format.italic ?? true
            try block(element, sink, caption)
        case "hr":
            flush(sink)
            horizontalRule(sink, c)
        case "mbp:pagebreak": // Mobipocket page break
            flush(sink)
            sink.breakPending = true
            try children(element, sink, c) // an HTML parser nests what follows <mbp:pagebreak/> inside it
        case "q":
            addText("“", sink, c)
            try inline(element, sink, c)
            addText("”", sink, c)
        case "rt": // ruby annotation after its base text: 漢字(かんじ)
            addText("(", sink, c)
            try inline(element, sink, c)
            addText(")", sink, c)
        default:
            if Self.isBlock(name, style) { try block(element, sink, c) } else { try inline(element, sink, c) }
        }

        if Self.isPageBreak(style.get("page-break-after") ?? style.get("break-after")) {
            flush(sink)
            sink.breakPending = true
        }
    }

    private static func isBlock(_ name: String, _ style: CssDeclarations) -> Bool {
        switch style.get("display")?.lowercased() {
        case "block", "flex", "grid", "list-item", "table", "flow-root": true
        case "inline", "inline-block", "inline-flex", "contents": false
        default: blockElements.contains(name)
        }
    }

    private static func isPageBreak(_ value: String?) -> Bool {
        ["always", "page", "left", "right", "recto", "verso"].contains(value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }

    /// A block element: its content forms paragraphs of their own.
    private func block(_ element: HtmlDom.Element, _ sink: Sink, _ context: Context) throws {
        flush(sink)
        bookmark(element, sink)
        try children(element, sink, context)
        flush(sink)
    }

    /// An inline element: content continues the current paragraph.
    private func inline(_ element: HtmlDom.Element, _ sink: Sink, _ context: Context) throws {
        bookmark(element, sink)
        try children(element, sink, context)
    }

    /// An element id becomes a bookmark, so links to it keep working (unused ones are pruned later).
    private func bookmark(_ element: HtmlDom.Element, _ sink: Sink) {
        for id in [element.id, element.localName == "a" ? element.getAttribute("name") : nil] {
            guard let id, !id.allSatisfy(\.isWhitespace) else { continue }
            let mapped: String?
            if let mapId = options.mapId { mapped = mapId(id) } else { mapped = id }
            guard let name = mapped else { continue }
            if let paragraph = sink.paragraph { paragraph.inlines.append(HBookmark(name)) }
            else { sink.pendingBookmarks.append(HBookmark(name)) }
        }
    }

    private func anchor(_ element: HtmlDom.Element, _ sink: Sink, _ context: Context) throws {
        bookmark(element, sink)
        let href = element.getAttribute("href")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var target: String?
        if let href, !href.isEmpty {
            if let mapLink = options.mapLink { target = mapLink(href) } else { target = href }
        }
        guard let target, sink.linkTarget == nil else {
            try children(element, sink, context) // no link, or a link inside a link (invalid HTML): text only
            return
        }
        sink.linkTarget = target
        sink.link = nil
        try children(element, sink, context)
        sink.linkTarget = nil
        sink.link = nil
    }

    private func horizontalRule(_ sink: Sink, _ context: Context) {
        // A short centred line: a separator in documents and a scene break in books.
        var c = context
        c.align = .center
        c.heading = 0
        c.item = nil
        c.firstLine = nil
        let paragraph = newParagraph(sink, c)
        let line = HShape(.line)
        line.width = 14000
        line.height = 0
        line.line.color = "#808080"
        paragraph.inlines.append(line)
        sink.lineStart = false
        flush(sink)
    }

    // MARK: Paragraphs and text

    @discardableResult
    private func newParagraph(_ sink: Sink, _ context: Context) -> HParagraph {
        let paragraph = HParagraph()
        paragraph.format = HParaFormat(align: context.align, left: context.indent > 0 ? context.indent : nil,
                                       firstLine: context.firstLine.flatMap { $0 != 0 ? $0 : nil })
        paragraph.headingLevel = context.heading
        paragraph.pageBreakBefore = sink.breakPending
        sink.breakPending = false
        if let item = context.item {
            paragraph.list = HListRef(item.numbering, item.level, !item.used)
            item.used = true
        }
        paragraph.inlines += sink.pendingBookmarks
        sink.pendingBookmarks.removeAll()
        sink.paragraph = paragraph
        sink.paragraphItem = context.item
        sink.preformatted = context.pre
        sink.link = nil
        sink.lineStart = true
        sink.endsWithSpace = false
        sink.blocks.append(paragraph)
        return paragraph
    }

    private func addInline(_ inline: HInline, _ sink: Sink, _ context: Context) {
        let paragraph = sink.paragraph ?? newParagraph(sink, context)
        if let target = sink.linkTarget {
            let link: HLink
            if let current = sink.link {
                link = current
            } else {
                link = HLink(target)
                sink.link = link
                paragraph.inlines.append(link)
            }
            link.content.append(inline)
        } else {
            paragraph.inlines.append(inline)
        }
    }

    private func addText(_ text: String, _ sink: Sink, _ context: Context) {
        if text.isEmpty { return }
        addInline(HText(text, context.format), sink, context)
        sink.lineStart = false
        sink.endsWithSpace = text.unicodeScalars.last == " "
    }

    private func text(_ data: String, _ sink: Sink, _ context: Context) {
        if context.pre {
            let lines = data.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    if sink.paragraph == nil { newParagraph(sink, context) } // an empty line of preformatted text stays
                    flush(sink, keepEmpty: true)
                }
                addText(line.replacingOccurrences(of: "\t", with: "    "), sink, context)
            }
            return
        }

        var text = Self.collapseWhitespace(data)
        if text.unicodeScalars.first == " " && (sink.paragraph == nil || sink.lineStart || sink.endsWithSpace) {
            text = text.droppingFirstScalar()
        }
        addText(text, sink, context)
    }

    /// Closes the current paragraph; an empty one is dropped (its bookmarks and break move on).
    private func flush(_ sink: Sink, keepEmpty: Bool = false) {
        guard let paragraph = sink.paragraph else { return }
        sink.paragraph = nil
        sink.link = nil

        // Preformatted lines keep their spaces and stay even when empty.
        let hadBreak = !sink.preformatted && Self.trim(&paragraph.inlines)
        Self.mergeRuns(&paragraph.inlines)
        for case let link as HLink in paragraph.inlines { Self.mergeRuns(&link.content) }
        if keepEmpty || hadBreak || sink.preformatted || Self.hasContent(paragraph.inlines) { return }

        // Nothing visible: <div id="x"></div>, white space between blocks, an empty list item.
        if let index = sink.blocks.firstIndex(where: { $0 === paragraph }) { sink.blocks.remove(at: index) }
        sink.breakPending = sink.breakPending || paragraph.pageBreakBefore
        sink.pendingBookmarks += HDocumentWalker.inlinesOf(paragraph.inlines).filter { $0 is HBookmark }
        if paragraph.list?.numbered == true, let item = sink.paragraphItem { item.used = false }
    }

    /// Drops leading and trailing spaces and a trailing line break, as browsers do. Returns true when the paragraph
    /// was only a line break (<p><br/></p>, an intended empty line).
    private static func trim(_ inlines: inout [HInline]) -> Bool {
        var onlyBreak = false
        if let lineBreak = lastVisible(inlines) as? HLineBreak {
            if let index = inlines.firstIndex(where: { $0 === lineBreak }) { inlines.remove(at: index) }
            onlyBreak = !hasContent(inlines)
        }
        trimEnd(&inlines)
        var index = 0
        leading: while index < inlines.count {
            switch inlines[index] {
            case is HBookmark:
                index += 1
                continue
            case let text as HText:
                let trimmed = text.text.trimmingScalars(" ", leading: true)
                if trimmed.isEmpty {
                    inlines.remove(at: index)
                    continue
                }
                inlines[index] = HText(trimmed, text.format)
            default:
                break
            }
            break leading
        }
        // Spaces before a line break are not shown either.
        var position = 0
        while position + 1 < inlines.count {
            if let text = inlines[position] as? HText, inlines[position + 1] is HLineBreak, text.text.unicodeScalars.last == " " {
                inlines[position] = HText(text.text.trimmingScalars(" ", leading: false), text.format)
            }
            position += 1
        }
        return onlyBreak
    }

    private static func lastVisible(_ inlines: [HInline]) -> HInline? {
        let last = inlines.last { !($0 is HBookmark) }
        if let link = last as? HLink { return lastVisible(link.content) ?? link }
        return last
    }

    private static func trimEnd(_ inlines: inout [HInline]) {
        var index = inlines.count - 1
        while index >= 0 {
            switch inlines[index] {
            case is HBookmark:
                index -= 1
            case let link as HLink:
                trimEnd(&link.content)
                return
            case let text as HText:
                let trimmed = text.text.trimmingScalars(" ", leading: false)
                if trimmed.isEmpty {
                    inlines.remove(at: index)
                    index -= 1
                    continue
                }
                inlines[index] = HText(trimmed, text.format)
                return
            default:
                return
            }
        }
    }

    private static func hasContent(_ inlines: [HInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case let text as HText: !text.text.isEmpty
            case let link as HLink: hasContent(link.content)
            case is HBookmark: false
            default: true
            }
        }
    }

    /// Joins neighbouring runs with the same format, so the output has one run per format change.
    static func mergeRuns(_ inlines: inout [HInline]) {
        var index = inlines.count - 1
        while index > 0 {
            if let b = inlines[index] as? HText, let a = inlines[index - 1] as? HText, a.format == b.format {
                inlines[index - 1] = HText(a.text + b.text, a.format)
                inlines.remove(at: index)
            }
            index -= 1
        }
    }

    /// `[ \t\n\r\f]+` → " ".
    private static func collapseWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var inSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
                if !inSpace { result.append(" ") }
                inSpace = true
            } else {
                result.append(scalar)
                inSpace = false
            }
        }
        return String(result)
    }

    // MARK: Formatting

    private static func charFormat(_ name: String, _ element: HtmlDom.Element, _ style: CssDeclarations, _ inherited: HCharFormat) -> HCharFormat {
        let size = inherited.size ?? baseSize
        var format = inherited
        switch name {
        case "b", "strong": format.bold = true
        case "i", "em", "cite", "dfn", "var", "address": format.italic = true
        case "u", "ins": format.underline = true
        case "s", "strike", "del": format.strike = true
        case "sub": format.subscript = true; format.superscript = nil
        case "sup": format.superscript = true; format.subscript = nil
        case "code", "kbd", "samp", "tt": format.shade = codeShade
        case "mark": format.shade = markShade
        case "small": format.size = MarkupConvert.int32(Double(size) * 0.83)
        case "big": format.size = MarkupConvert.int32(Double(size) * 1.2)
        case "th": format.bold = format.bold ?? true
        case "dt": format.bold = true
        default: break
        }
        if name == "font" {
            if let fontColor = CssValues.color(element.getAttribute("color")) { format.color = fontColor }
            if let factor = fontTagSize(element.getAttribute("size")) { format.size = MarkupConvert.int32(Double(baseSize) * factor) }
        }

        if let weight = style.get("font-weight")?.lowercased() {
            format.bold = weight == "bold" || weight == "bolder" || (MarkupConvert.tryParseInt(weight).map { $0 >= 600 } ?? false)
        }
        if let fontStyle = style.get("font-style")?.lowercased() {
            format.italic = fontStyle.hasPrefix("italic") || fontStyle.hasPrefix("oblique")
        }
        if let decoration = (style.get("text-decoration-line") ?? style.get("text-decoration"))?.lowercased() {
            if decoration.contains("none") { format.underline = false; format.strike = false }
            if decoration.contains("underline") { format.underline = true }
            if decoration.contains("line-through") { format.strike = true }
        }
        switch style.get("vertical-align")?.lowercased() {
        case "super": format.superscript = true; format.subscript = nil
        case "sub": format.subscript = true; format.superscript = nil
        default: break
        }
        if let color = CssValues.color(style.get("color")) { format.color = color }
        if let shade = CssValues.firstColor(style.get("background-color") ?? style.get("background")), shade != "#FFFFFF" {
            format.shade = shade
        }
        if let fontSize = CssValues.fontSize(style.get("font-size"), size) { format.size = fontSize }
        return format
    }

    /// <font size="1..7"> (3 is normal), also relative "+1" / "-2".
    private static func fontTagSize(_ value: String?) -> Double? {
        guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // int.TryParse(text.TrimStart('+'), NumberStyles.AllowLeadingSign): a sign, then digits only.
        guard let number = Int32(String(text.drop { $0 == "+" })) else { return nil }
        let size = text.first == "+" || text.first == "-" ? 3 &+ number : number
        switch min(max(size, 1), 7) {
        case 1: return 0.63
        case 2: return 0.82
        case 3: return 1.0
        case 4: return 1.13
        case 5: return 1.5
        case 6: return 2.0
        default: return 3.0
        }
    }

    private static func align(_ value: String?) -> HAlign? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left", "start": .left
        case "right", "end": .right
        case "center", "middle", "-webkit-center": .center
        case "justify": .justify
        default: nil
        }
    }

    // MARK: Lists

    private func list(_ list: HtmlDom.Element, _ ordered: Bool, _ style: CssDeclarations, _ sink: Sink, _ context: Context) throws {
        flush(sink)
        bookmark(list, sink)
        let type = (style.get("list-style-type") ?? style.get("list-style") ?? list.getAttribute("type") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let unmarked = type.lowercased().hasPrefix("none")
        let start = MarkupConvert.tryParseInt(list.getAttribute("start")) ?? 1
        let level = min(context.listLevel, 6)
        let numbering = unmarked ? nil : Self.numbering(ordered, start, type, level)
        var inner = context
        inner.listLevel = context.listLevel + 1
        inner.heading = 0

        for child in list.childNodes {
            guard let item = child as? HtmlDom.Element, item.localName == "li" else {
                var stray = inner
                stray.item = context.item
                try node(child, sink, stray) // white space or stray elements in a list
                continue
            }
            let itemStyle = styleOf(item)
            if item.hasAttribute("hidden") || itemStyle.get("display") == "none" { continue }
            flush(sink)
            bookmark(item, sink)
            // Items of an unmarked list (e.g. a table of contents) are indented paragraphs.
            var itemContext = inner
            if let numbering {
                itemContext.item = ListItem(numbering, level)
            } else {
                itemContext.indent = context.indent + Self.quoteIndent
                itemContext.item = nil
            }
            if let align = Self.align(item.getAttribute("align") ?? itemStyle.get("text-align")) { itemContext.align = align }
            itemContext.format = Self.charFormat("li", item, itemStyle, context.format)
            try children(item, sink, itemContext)
            flush(sink)
        }
        flush(sink)
    }

    /// A list definition in which `level` follows the HTML list; other levels use defaults.
    static func numbering(_ ordered: Bool, _ start: Int, _ type: String, _ level: Int) -> HNumbering {
        let bullets = ["●", "○", "■"]
        let numbering = HNumbering()
        for l in 0..<7 {
            if !ordered {
                let bullet: String
                if l == level {
                    switch type.lowercased() {
                    case "disc": bullet = "●"
                    case "circle": bullet = "○"
                    case "square": bullet = "■"
                    default: bullet = bullets[l % 3]
                    }
                } else {
                    bullet = bullets[l % 3]
                }
                numbering.levels.append(HNumberingLevel("DIGIT", bullet, 1, true))
                continue
            }
            let format: String
            if l != level {
                format = "DIGIT"
            } else {
                switch type {
                case "a", "lower-alpha", "lower-latin": format = "LATIN_SMALL"
                case "A", "upper-alpha", "upper-latin": format = "LATIN_CAPITAL"
                case "i", "lower-roman": format = "ROMAN_SMALL"
                case "I", "upper-roman": format = "ROMAN_CAPITAL"
                case "hangul", "korean-hangul-formal": format = "HANGUL_SYLLABLE"
                default: format = "DIGIT"
                }
            }
            numbering.levels.append(HNumberingLevel(format, "^\(l + 1).", l == level ? max(0, start) : 1, false))
        }
        return numbering
    }

    // MARK: Tables

    private func table(_ table: HtmlDom.Element, _ style: CssDeclarations, _ sink: Sink, _ context: Context) throws {
        flush(sink)
        let hTable = HTable()
        hTable.indent = context.indent
        hTable.align = context.align ?? .left
        hTable.borders = Self.tableBorders(table, style)
        var rows: [(row: HtmlDom.Element, head: Bool)] = []
        for child in table.children {
            switch child.localName {
            case "caption":
                let captionSink = Sink()
                var captionContext = context
                captionContext.indent = 0
                captionContext.item = nil
                captionContext.listLevel = 0
                captionContext.align = .center
                try children(child, captionSink, captionContext)
                flush(captionSink)
                hTable.caption += captionSink.blocks
            case "thead", "tbody", "tfoot":
                rows += child.children.filter { $0.localName == "tr" }.map { ($0, child.localName == "thead") }
            case "tr":
                rows.append((child, false))
            default:
                break
            }
        }

        for (row, head) in rows {
            let cells = row.children.filter { $0.localName == "td" || $0.localName == "th" }
            let hRow = HRow()
            hRow.header = head || (!cells.isEmpty && cells.allSatisfy { $0.localName == "th" })
            for cell in cells { hRow.cells.append(try self.cell(cell, context, hRow.header)) }
            if !hRow.cells.isEmpty { hTable.rows.append(hRow) }
        }
        if hTable.rows.isEmpty {
            sink.blocks += hTable.caption
            return
        }
        // Header rows repeat on every page in 한글: only the leading ones are headers.
        var leading = true
        for row in hTable.rows {
            leading = leading && row.header
            row.header = leading
        }

        hTable.columnCount = Self.columnCount(hTable)
        hTable.relativeWidths = relativeWidths(table, rows.first?.row, hTable.columnCount)

        bookmark(table, sink)
        if sink.breakPending {
            // A table cannot start a new page itself: an empty paragraph in front of it does.
            var c = context
            c.item = nil
            c.heading = 0
            newParagraph(sink, c)
            sink.paragraph = nil
        } else if !sink.pendingBookmarks.isEmpty {
            // Links to the table land in its first cell.
            let cell = hTable.rows[0].cells[0]
            let first: HParagraph
            if let paragraph = cell.blocks.first as? HParagraph {
                first = paragraph
            } else {
                first = HParagraph()
                cell.blocks.insert(first, at: 0)
            }
            first.inlines.insert(contentsOf: sink.pendingBookmarks, at: 0)
            sink.pendingBookmarks.removeAll()
        }
        sink.blocks.append(hTable)
    }

    private func cell(_ cell: HtmlDom.Element, _ context: Context, _ header: Bool) throws -> HCell {
        let style = styleOf(cell)
        let hCell = HCell()
        hCell.rowSpan = min(max(MarkupConvert.tryParseInt(cell.getAttribute("rowspan")) ?? 1, 1), 1000)
        hCell.colSpan = min(max(MarkupConvert.tryParseInt(cell.getAttribute("colspan")) ?? 1, 1), 1000)
        hCell.fill = CssValues.color(cell.getAttribute("bgcolor")) ?? CssValues.firstColor(style.get("background-color") ?? style.get("background"))
        hCell.verticalAlign = switch (cell.getAttribute("valign") ?? style.get("vertical-align"))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "middle", "center": .center
        case "bottom": .bottom
        default: .top
        }
        let cellSink = Sink()
        var format = Self.charFormat(cell.localName, cell, style, context.format)
        if header { format.bold = format.bold ?? true }
        let cellContext = Context(format: format, align: Self.align(cell.getAttribute("align") ?? style.get("text-align")) ?? (cell.localName == "th" ? .center : nil),
                                  indent: 0, listLevel: 0, item: nil, heading: 0, pre: false, firstLine: nil, depth: context.depth + 1)
        bookmark(cell, cellSink)
        try children(cell, cellSink, cellContext)
        flush(cellSink)
        hCell.blocks = cellSink.blocks
        if !cellSink.pendingBookmarks.isEmpty {
            let paragraph = hCell.blocks.lazy.compactMap { $0 as? HParagraph }.first ?? HParagraph()
            if !hCell.blocks.contains(where: { $0 === paragraph }) { hCell.blocks.insert(paragraph, at: 0) }
            paragraph.inlines.insert(contentsOf: cellSink.pendingBookmarks, at: 0)
        }
        return hCell
    }

    /// Grid width, taking cells that reach down from rows above into account.
    private static func columnCount(_ table: HTable) -> Int {
        var busy: [Int] = [] // per column: rows still covered by a row span from above
        var width = 0
        for row in table.rows {
            var column = 0
            for cell in row.cells {
                while column < busy.count && busy[column] > 0 { column += 1 }
                for covered in column..<(column + cell.colSpan) {
                    while busy.count <= covered { busy.append(0) }
                    busy[covered] = cell.rowSpan
                }
                column += cell.colSpan
            }
            width = max(width, column)
            for index in busy.indices { busy[index] = max(0, busy[index] - 1) }
        }
        return max(1, width)
    }

    /// Column widths from <col> or the first row, as fractions of the table width.
    private func relativeWidths(_ table: HtmlDom.Element, _ firstRow: HtmlDom.Element?, _ columns: Int) -> [Double]? {
        var sources = (table.children.filter { $0.localName == "colgroup" }.flatMap(\.children) + table.children).filter { $0.localName == "col" }
        if sources.isEmpty, let firstRow { sources = firstRow.children.filter { $0.localName == "td" || $0.localName == "th" } }
        if sources.isEmpty || sources.contains(where: { (MarkupConvert.tryParseInt($0.getAttribute("colspan") ?? $0.getAttribute("span")) ?? 0) > 1 }) {
            return nil
        }

        var widths: [(value: Double, percent: Bool)] = sources.prefix(columns).map { source in
            let text = (styleOf(source).get("width") ?? source.getAttribute("width") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("%"), let percent = CssValues.tryParseDouble(String(text.dropLast())) { return (percent, true) }
            return (Double(CssValues.length(text, Double(Self.baseSize)) ?? 0), false)
        }
        while widths.count < columns { widths.append((0, false)) }
        if widths.allSatisfy({ $0.value <= 0 }) { return nil }
        if widths.allSatisfy({ $0.percent || $0.value <= 0 }) { return widths.map { max(0, $0.value) / 100 } }
        if widths.allSatisfy({ !$0.percent && $0.value > 0 }) {
            let total = widths.reduce(0) { $0 + $1.value }
            return widths.map { $0.value / total }
        }
        return nil
    }

    /// border="0" or CSS border: none turns the grid off; everything else keeps the default thin grid.
    private static func tableBorders(_ table: HtmlDom.Element, _ style: CssDeclarations) -> HBorders? {
        let border = (style.get("border") ?? style.get("border-style"))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if table.getAttribute("border") == "0" || border == "none" || border == "0" || border == "hidden" { return .empty }
        return nil
    }

    // MARK: Images

    private func image(_ element: HtmlDom.Element, _ source: String?, _ style: CssDeclarations, _ sink: Sink, _ context: Context) throws {
        guard let path = try resolveImage(source) else { return } // remote or missing image: skip rather than produce a broken reference
        let image = HImage(path)
        image.width = Self.imageLength(style.get("width") ?? element.getAttribute("width"))
        image.height = Self.imageLength(style.get("height") ?? element.getAttribute("height"))
        addInline(image, sink, context)
        sink.lineStart = false
        sink.endsWithSpace = false
    }

    /// Pixels (width="300"), CSS lengths or percentages of the text width; "auto" and em-based sizes are left to the image.
    private static func imageLength(_ value: String?) -> Int? {
        guard let value, value.range(of: "em", options: .caseInsensitive) == nil, let length = HwpxUnits.parseLength(value), length > 0 else { return nil }
        return length
    }

    /// A local image file for an img src: relative paths, file: URIs and data: URIs; nil for remote images.
    private func resolveImage(_ source: String?) throws -> String? {
        guard let source, !source.allSatisfy(\.isWhitespace) else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("data:") { return try saveDataUri(trimmed) }
        return localFile(trimmed).flatMap { Self.usableImage($0, options.mediaFolder) }
    }

    /// A local file referenced from the document, or nil for remote and missing files.
    private func localFile(_ reference: String?) -> String? {
        guard let reference, !reference.allSatisfy(\.isWhitespace), !reference.contains("\0") else { return nil }
        let lower = reference.lowercased()
        if lower.hasPrefix("file:") {
            guard let url = URL(string: reference), url.isFileURL else { return nil }
            return FileManager.default.fileExists(url.path) ? url.path : nil
        }
        if reference.contains("://") || reference.hasPrefix("//") || lower.hasPrefix("mailto:") { return nil }
        let scalars = reference.unicodeScalars
        let cut = scalars.firstIndex { $0 == "?" || $0 == "#" }
        let relative = Self.unescapeDataString(cut.map { String(scalars[..<$0]) } ?? reference)
        if relative.isEmpty { return nil }
        let candidate = FilePath.fullPath(FilePath.combine(options.baseFolder, relative))
        return FileManager.default.fileExists(candidate) ? candidate : nil
    }

    /// Writes the image of a data: URI to the media folder.
    private func saveDataUri(_ uri: String) throws -> String? {
        let scalars = Array(uri.unicodeScalars)
        guard let comma = scalars.firstIndex(of: ",") else { return nil }
        let header = String(String.UnicodeScalarView(scalars[5..<comma])).lowercased()
        let payload = Self.unescapeDataString(String(String.UnicodeScalarView(scalars[(comma + 1)...])))
        let ext: String? = switch header.components(separatedBy: ";")[0] {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/bmp": "bmp"
        case "image/svg+xml": "svg"
        case "image/avif": "avif"
        default: nil
        }
        guard let ext else { return nil }
        let data: Data
        if header.hasSuffix(";base64") {
            // Convert.FromBase64String: white space is ignored, anything else must be valid base64.
            let compact = payload.unicodeScalars.filter { !" \t\r\n".unicodeScalars.contains($0) }
            guard let decoded = Data(base64Encoded: String(String.UnicodeScalarView(compact))) else { return nil }
            data = decoded
        } else {
            data = Data(payload.utf8)
        }
        try FileManager.default.createDirectoryIfNeeded(options.mediaFolder)
        embedded += 1
        let path = FilePath.combine(options.mediaFolder, "embedded-\(Self.guid())-\(embedded).\(ext)")
        try data.write(to: URL(fileURLWithPath: path))
        return Self.usableImage(path, options.mediaFolder)
    }

    /// Raster images are used as they are; SVG is rasterised to PNG at 144 dpi (HWPX has no vector pictures and the
    /// writers expect a picture with a pixel size). Nil when the file is not a picture this Mac can read.
    static func usableImage(_ path: String, _ mediaFolder: String) -> String? {
        let ext = FilePath.extension(path).lowercased()
        if [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"].contains(ext) { return path }
        if ext == ".svg" || ext == ".svgz" {
            guard let png = try? ImageSupport.pngData(path, svgScale: 1.5) else { return nil }
            let target = FilePath.combine(mediaFolder, "\(FilePath.fileNameWithoutExtension(path))-\(guid()).png")
            do {
                try FileManager.default.createDirectoryIfNeeded(mediaFolder)
                try png.write(to: URL(fileURLWithPath: target))
            } catch {
                return nil
            }
            return target
        }
        return ImageSupport.info(path) != nil ? path : nil // TIFF, AVIF, ...: the HWPX writer converts them, other writers too
    }

    /// `Guid.NewGuid().ToString("N")`.
    private static func guid() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// `Uri.UnescapeDataString`: %XX escapes that form valid UTF-8 are decoded, everything else stays as written.
    static func unescapeDataString(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let bytes = Array(text.utf8)
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x37
            case 0x61...0x66: byte - 0x57
            default: nil
            }
        }
        func escaped(at index: Int) -> UInt8? {
            guard index + 2 < bytes.count, bytes[index] == 0x25, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else { return nil }
            return high << 4 | low
        }
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard let first = escaped(at: index) else {
                output.append(bytes[index])
                index += 1
                continue
            }
            // The UTF-8 sequence this escape starts, all of it escaped too.
            let length = first < 0x80 ? 1 : first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 0
            var sequence: [UInt8] = [first]
            var next = index + 3
            while length > 1, sequence.count < length, let byte = escaped(at: next), byte & 0xC0 == 0x80 {
                sequence.append(byte)
                next += 3
            }
            if length > 0, sequence.count == length, String(bytes: sequence, encoding: .utf8) != nil {
                output += sequence
                index = next
            } else {
                output += bytes[index..<(index + 3)]
                index += 3
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

private extension String {
    func droppingFirstScalar() -> String { String(String.UnicodeScalarView(unicodeScalars.dropFirst())) }

    /// `TrimStart(ch)` / `TrimEnd(ch)` on UTF-16 characters.
    func trimmingScalars(_ scalar: Unicode.Scalar, leading: Bool) -> String {
        var scalars = Substring(self).unicodeScalars
        if leading { while scalars.first == scalar { scalars.removeFirst() } } else { while scalars.last == scalar { scalars.removeLast() } }
        return String(scalars)
    }
}
