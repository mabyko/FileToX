// Port of DocxReader.cs. Each part keeps its own relationships; fields span paragraphs.
import Foundation

final class DocxReader {
    static let w = XNamespace("http://schemas.openxmlformats.org/wordprocessingml/2006/main"),
        r = XNamespace("http://schemas.openxmlformats.org/officeDocument/2006/relationships"),
        a = XNamespace("http://schemas.openxmlformats.org/drawingml/2006/main"),
        wp = XNamespace("http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"),
        pic = XNamespace("http://schemas.openxmlformats.org/drawingml/2006/picture"),
        wps = XNamespace("http://schemas.microsoft.com/office/word/2010/wordprocessingShape"),
        wpg = XNamespace("http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"),
        wpc = XNamespace("http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"),
        mc = XNamespace("http://schemas.openxmlformats.org/markup-compatibility/2006"),
        v = XNamespace("urn:schemas-microsoft-com:vml"), w10 = XNamespace("urn:schemas-microsoft-com:office:word"),
        m = XNamespace("http://schemas.openxmlformats.org/officeDocument/2006/math")
    struct Part {
        let path: String
        let xml: XDocument
        let relationships: [String: OpcRelationship]
    }
    let zip: ZipReader, mediaFolder: String
    var parts: [String: Part?] = [:], relationshipOrder: [String: [String]] = [:]
    var part: Part!, media: [String: String] = [:], footnotes: [String: XElement] = [:],
        endnotes: [String: XElement] = [:], fields: [FieldState] = [], footnotesPart: Part?, endnotesPart: Part?,
        evenAndOddHeaders = false, linePitches: [Int] = [], sectionIndex = 0, textBoxDepth = 0
    var styles: [String: Style] = [:], resolvedStyles: [String: (ParaProps, RunProps)] = [:],
        numberingLevels: [String: [NumberingLevel]] = [:], numberings: [String: HNumbering] = [:],
        defaultPara = ParaProps(), defaultRun = RunProps(), defaultParagraphStyle: String?, defaultTableStyle: String?,
        minorFont: (String?, String?) = (nil, nil), majorFont: (String?, String?) = (nil, nil),
        themeColors: [String: String] = [:]
    private init(_ path: String, _ folder: String) throws {
        zip = try ZipReader(path: path)
        mediaFolder = folder
        let rels = try relationshipsOf("")
        let mainPath =
            (relationshipOrder[""] ?? []).compactMap { rels[$0] }.first { $0.type.hasSuffix("/officeDocument") }?.target
            ?? "word/document.xml"
        guard let main = try loadPart(mainPath) else {
            throw ConversionError("The file is not a Word document (no word/document.xml).")
        }
        part = main
    }
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        try DocxReader(path, mediaFolder).readDocument()
    }
    func loadPart(_ path: String) throws -> Part? {
        if let cached = parts[path] { return cached }
        var part: Part?
        if let e = zip.entry(named: path) {
            part = try Part(
                path: path, xml: XDocument.load(data: zip.data(for: e), preserveWhitespace: true),
                relationships: relationshipsOf(path))
        }
        parts[path] = .some(part)
        return part
    }
    func relationshipsOf(_ path: String) throws -> [String: OpcRelationship] {
        let folder = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        let relPath =
            path.isEmpty
            ? "_rels/.rels" : String("\(folder)/_rels/\(FilePath.fileName(path)).rels".drop(while: { $0 == "/" }))
        var result: [String: OpcRelationship] = [:]
        var order: [String] = []
        if let entry = zip.entry(named: relPath) {
            let root = try XDocument.load(data: zip.data(for: entry)).root
            for rel in root.elements(
                XNamespace("http://schemas.openxmlformats.org/package/2006/relationships") + "Relationship")
            {
                let id = rel.attributeValue("Id") ?? ""
                let target = rel.attributeValue("Target") ?? ""
                let external = rel.attributeValue("TargetMode") == "External"
                if result[id] == nil { order.append(id) }
                result[id] = OpcRelationship(
                    type: rel.attributeValue("Type") ?? "",
                    target: external ? target : Self.resolvePath(folder, target), external: external)
            }
        }
        relationshipOrder[path] = order
        return result
    }
    static func resolvePath(_ folder: String, _ target: String) -> String {
        if target.hasPrefix("/") { return String(target.drop(while: { $0 == "/" })) }
        var parts = folder.isEmpty ? [] : folder.components(separatedBy: "/")
        for segment in (target.removingPercentEncoding ?? target).components(separatedBy: "/") {
            if segment == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else if segment != "." && !segment.isEmpty {
                parts.append(segment)
            }
        }
        return parts.joined(separator: "/")
    }
    func relatedPart(_ p: Part, _ suffix: String) throws -> Part? {
        let rel = (relationshipOrder[p.path] ?? []).compactMap { p.relationships[$0] }.first {
            !$0.external && $0.type.hasSuffix(suffix)
        }
        guard let rel, !rel.target.isEmpty else { return nil }
        return try loadPart(rel.target)
    }
    func withPart<T>(_ p: Part, _ read: () throws -> T) rethrows -> T {
        let old = part
        part = p
        defer { part = old }
        return try read()
    }
    func readDocument() throws -> HDocument {
        let main = part!
        let w = Self.w
        loadStyles(try relatedPart(main, "/styles"))
        let theme = try relatedPart(main, "/theme")
        loadTheme(theme)
        loadThemeColors(theme)
        loadNumbering(try relatedPart(main, "/numbering"))
        if let e = try relatedPart(main, "/settings")?.xml.root.element(w + "evenAndOddHeaders") {
            evenAndOddHeaders = !["0", "false"].contains(Self.val(e) ?? "")
        }
        footnotesPart = try relatedPart(main, "/footnotes")
        endnotesPart = try relatedPart(main, "/endnotes")
        for e in footnotesPart?.xml.root.elements(w + "footnote") ?? [] { footnotes[Self.attr(e, "id") ?? ""] = e }
        for e in endnotesPart?.xml.root.elements(w + "endnote") ?? [] { endnotes[Self.attr(e, "id") ?? ""] = e }
        let doc = HDocument()
        if let core = zip.entry(named: "docProps/core.xml") {
            let xml = try XDocument.load(data: zip.data(for: core))
            doc.title = Self.nullIfEmpty(
                xml.root.descendants(XNamespace("http://purl.org/dc/elements/1.1/") + "title").first?.value)
        }
        guard let body = main.xml.root.element(w + "body") else {
            throw ConversionError("word/document.xml has no body.")
        }
        for e in Self.flatten(body.elements()) {
            if e.name == w + "p", let s = e.element(w + "pPr")?.element(w + "sectPr") {
                linePitches.append(Self.linePitch(s))
            }
        }
        linePitches.append(Self.linePitch(body.element(w + "sectPr")))
        var blocks: [HBlock] = []
        var headers: [String: [HBlock]] = [:]
        var footers: [String: [HBlock]] = [:]
        for e in Self.flatten(body.elements()) {
            try Task.checkCancellation()
            if e.name == w + "sectPr" { continue }
            blocks += try readBlock(e)
            if e.name == w + "p", let s = e.element(w + "pPr")?.element(w + "sectPr") {
                try addSection(doc, blocks, s, &headers, &footers)
                blocks = []
                sectionIndex += 1
            }
        }
        try addSection(doc, blocks, body.element(w + "sectPr"), &headers, &footers)
        return doc
    }
    func addSection(
        _ d: HDocument, _ input: [HBlock], _ props: XElement?, _ headers: inout [String: [HBlock]],
        _ footers: inout [String: [HBlock]]
    ) throws {
        let page = Self.page(props)
        let columns = Self.columns(props)
        let w = Self.w
        var blocks = input
        if let previous = d.sections.last, Self.val(props?.element(w + "type")) == "continuous", previous.page == page {
            if !(blocks.first is HParagraph) { blocks.insert(HParagraph(), at: 0) }
            (blocks[0] as! HParagraph).columnsChange = columns
            previous.blocks += blocks
            return
        }
        let s = HSection()
        s.page = page
        s.columns = columns
        s.blocks = blocks
        for e in props?.elements(w + "headerReference") ?? [] {
            headers[Self.attr(e, "type") ?? "default"] = try headerFooterBlocks(e)
        }
        for e in props?.elements(w + "footerReference") ?? [] {
            footers[Self.attr(e, "type") ?? "default"] = try headerFooterBlocks(e)
        }
        func add(_ source: [String: [HBlock]], _ header: Bool) {
            for (key, pages) in evenAndOddHeaders
                ? [("default", HPageType.odd), ("even", HPageType.even)] : [("default", HPageType.both)]
            {
                if let b = source[key] {
                    let item = HHeaderFooter(pages)
                    item.blocks = b
                    if header { s.headers.append(item) } else { s.footers.append(item) }
                }
            }
        }
        add(headers, true)
        add(footers, false)
        if let title = props?.element(w + "titlePg"), !["0", "false"].contains(Self.val(title) ?? "") {
            s.hideFirstHeader = Self.isBlank(headers["first"])
            s.hideFirstFooter = Self.isBlank(footers["first"])
        }
        s.startPageNumber = DocumentXML.int(Self.attr(props?.element(w + "pgNumType"), "start"))
        d.sections.append(s)
    }
    func headerFooterBlocks(_ e: XElement) throws -> [HBlock] {
        guard let id = Self.attr(e, "id", Self.r), let rel = part.relationships[id], let p = try loadPart(rel.target)
        else { return [] }
        return try withPart(p) { try readBlocks(p.xml.root.elements()) }
    }
    static func isBlank(_ blocks: [HBlock]?) -> Bool {
        blocks?.allSatisfy { b in
            guard let p = b as? HParagraph else { return false }
            return p.inlines.allSatisfy {
                $0 is HBookmark || ($0 as? HText).map { DocumentXML.trim($0.text).isEmpty } == true
            }
        } ?? true
    }
    static func page(_ props: XElement?) -> HPage {
        let size = props?.element(w + "pgSz")
        let margin = props?.element(w + "pgMar")
        func get(_ e: XElement?, _ n: String, _ f: Int) -> Int { abs(twips(e, n) ?? f) }
        var width = get(size, "w", 11906)
        var height = get(size, "h", 16838)
        if attr(size, "orient") == "landscape" && width < height { swap(&width, &height) }
        let top = get(margin, "top", 1440)
        let bottom = get(margin, "bottom", 1440)
        let hd = min(get(margin, "header", 720), top)
        let fd = min(get(margin, "footer", 720), bottom)
        func u(_ n: Int) -> Int { HwpxUnits.fromTwips(Double(n)) }
        return HPage(
            width: u(width), height: u(height), left: u(get(margin, "left", 1440)),
            right: u(get(margin, "right", 1440)), top: u(hd), bottom: u(fd), header: u(top - hd),
            footer: u(bottom - fd), gutter: u(get(margin, "gutter", 0)))
    }
    static func linePitch(_ props: XElement?) -> Int {
        let g = props?.element(w + "docGrid")
        return ["lines", "linesAndChars", "snapToChars"].contains(attr(g, "type") ?? "")
            ? twips(g, "linePitch") ?? 0 : 0
    }
    func snapToGrid(_ p: HParagraph, _ props: ParaProps) {
        let pitch = textBoxDepth > 0 || sectionIndex >= linePitches.count ? 0 : linePitches[sectionIndex]
        if pitch <= 0 || props.snapToGrid == false || ["exact", "atLeast"].contains(props.lineRule ?? "") { return }
        let size = Self.maxFontSize(p.inlines) ?? p.markFormat.size ?? 1000
        let cell = HwpxUnits.fromTwips(Double(pitch))
        let lines = max(1, ceil(Double(size) * 1.3 / Double(cell)))
        let multiple = Double(props.line ?? 240) / 240
        p.format.lineSpacing = HLineSpacing(.atLeast, Int((lines * Double(cell) * multiple).rounded(.toNearestOrEven)))
    }
    static func maxFontSize(_ list: [HInline]) -> Int? {
        list.compactMap { i in
            (i as? HText)?.format.size ?? (i as? HField)?.format.size
                ?? (i as? HLink).flatMap { maxFontSize($0.content) }
        }.filter { $0 > 0 }.max()
    }
    static func columns(_ p: XElement?) -> HColumns {
        let c = p?.element(w + "cols")
        let count = DocumentXML.int(attr(c, "num")) ?? c?.elements(w + "col").count ?? 1
        return count <= 1
            ? .single
            : HColumns(
                count: min(count, 255), gap: HwpxUnits.fromTwips(Double(twips(c, "space") ?? 720)),
                separator: bool(c, "sep") == true)
    }
    static func flatten(_ list: [XElement]) -> [XElement] {
        list.flatMap { e -> [XElement] in
            if e.name == w + "sdt" { return flatten(e.element(w + "sdtContent")?.elements() ?? []) }
            if [w + "customXml", w + "ins", w + "moveTo"].contains(e.name) { return flatten(e.elements()) }
            return [w + "p", w + "tbl", w + "sectPr"].contains(e.name) ? [e] : []
        }
    }
    func readBlocks(_ list: [XElement]) throws -> [HBlock] { try Self.flatten(list).flatMap { try readBlock($0) } }
    func readBlock(_ e: XElement) throws -> [HBlock] {
        if e.name == Self.w + "p" { return try readParagraph(e) }
        if e.name == Self.w + "tbl" { return [try readTable(e)] }
        return []
    }
    final class ParagraphBuilder {
        unowned let owner: DocxReader
        let props: ParaProps, format: HParaFormat, mark: HCharFormat, heading: Int, list: HListRef?
        var output: [HBlock] = [], current: HParagraph, sinks: [HLink] = []
        init(_ owner: DocxReader, _ props: ParaProps, _ mark: RunProps, _ pPr: XElement?) {
            self.owner = owner
            self.props = props
            format = owner.paraFormat(props)
            self.mark = owner.charFormat(mark)
            heading = owner.headingLevel(props, pPr)
            list = owner.numbering(props.numId).map { HListRef($0, min(max(props.ilvl ?? 0, 0), 8), true) }
            current = HParagraph()
            newParagraph(list)
            current.pageBreakBefore = props.pageBreakBefore == true
            if let target = owner.fields.last(where: { $0.result && $0.target != nil })?.target { openLink(target) }
        }
        func add(_ i: HInline) { if let s = sinks.last { s.content.append(i) } else { current.inlines.append(i) } }
        func openLink(_ target: String) {
            let l = HLink(target)
            add(l)
            sinks.append(l)
        }
        func closeLink() { _ = sinks.popLast() }
        func pageBreak(_ page: Bool) {
            if !current.inlines.isEmpty {
                emit()
                newParagraph(list.map { HListRef($0.numbering, $0.level, false) })
                sinks = []
            }
            if page { current.pageBreakBefore = true } else { current.columnBreakBefore = true }
        }
        func newParagraph(_ list: HListRef?) {
            current = HParagraph()
            current.format = format
            current.markFormat = mark
            current.headingLevel = heading
            current.list = list
        }
        func emit() {
            owner.snapToGrid(current, props)
            output.append(current)
        }
    }
    func readParagraph(_ p: XElement) throws -> [HBlock] {
        let pPr = p.element(Self.w + "pPr")
        let (props, mark) = paragraphProperties(pPr)
        let b = ParagraphBuilder(self, props, mark, pPr)
        let styleRun = resolveStyle(Self.val(pPr?.element(Self.w + "pStyle")) ?? defaultParagraphStyle).1
        try paragraphContent(p.elements(), b, styleRun)
        b.emit()
        return b.output
    }
    func paragraphContent(_ list: [XElement], _ b: ParagraphBuilder, _ styleRun: RunProps) throws {
        for e in list {
            let n = e.name.localName
            if e.name.namespace == Self.m {
                if n == "oMath" || n == "oMathPara" {
                    var f = charFormat(styleRun)
                    f.italic = true
                    b.add(HText(e.descendants(Self.m + "t").map(\.value).joined(), f))
                }
                continue
            }
            if e.name.namespace != Self.w {
                if e.name == Self.mc + "AlternateContent" {
                    try paragraphContent(Self.chooseAlternative(e), b, styleRun)
                }
                continue
            }
            switch n {
            case "r": try run(e, b, styleRun)
            case "hyperlink":
                let target =
                    Self.attr(e, "id", Self.r).flatMap { part.relationships[$0]?.target }
                    ?? Self.attr(e, "anchor").map { "#" + $0 }
                if let target { b.openLink(target) }
                try paragraphContent(e.elements(), b, styleRun)
                if target != nil { b.closeLink() }
            case "fldSimple":
                let f = FieldState()
                f.instruction = Self.attr(e, "instr") ?? ""
                fields.append(f)
                startFieldResult(f, b, charFormat(styleRun))
                try paragraphContent(e.elements(), b, styleRun)
                endField(b)
            case "bookmarkStart":
                if let name = Self.attr(e, "name"), !name.isEmpty, name != "_GoBack" { b.add(HBookmark(name)) }
            case "ins", "moveTo", "smartTag", "customXml", "dir", "bdo": try paragraphContent(e.elements(), b, styleRun)
            case "sdt": try paragraphContent(e.element(Self.w + "sdtContent")?.elements() ?? [], b, styleRun)
            default: break
            }
        }
    }
    func run(_ e: XElement, _ b: ParagraphBuilder, _ styleRun: RunProps) throws {
        let props = runProperties(e.element(Self.w + "rPr"), styleRun)
        if props.hidden == true { return }
        let f = charFormat(props)
        for c in e.elements() {
            if c.name == Self.mc + "AlternateContent" {
                for chosen in Self.chooseAlternative(c) { try runChild(chosen, b, f) }
            } else {
                try runChild(c, b, f)
            }
        }
    }
    func runChild(_ e: XElement, _ b: ParagraphBuilder, _ f: HCharFormat) throws {
        if e.name.namespace != Self.w { return }
        switch e.name.localName {
        case "t": if showsText { b.add(HText(e.value, f)) }
        case "tab", "ptab": if showsText { b.add(HTab(f)) }
        case "br":
            if showsText {
                switch Self.attr(e, "type") {
                case "page": b.pageBreak(true)
                case "column": b.pageBreak(false)
                default: b.add(HLineBreak(f))
                }
            }
        case "cr": if showsText { b.add(HLineBreak(f)) }
        case "noBreakHyphen": if showsText { b.add(HText("-", f)) }
        case "sym":
            if showsText, let code = Self.attr(e, "char").flatMap({ UInt16($0, radix: 16) }) {
                b.add(HText(Self.bulletText(String(decoding: [code], as: UTF16.self)), f))
            }
        case "fldChar": fieldChar(e, b, f)
        case "instrText": if let field = fields.last, !field.result { field.instruction += e.value }
        case "drawing": if showsText { for i in try drawing(e) { b.add(i) } }
        case "pict", "object": if showsText { for i in try vml(e) { b.add(i) } }
        case "footnoteReference": if let n = try note(e, footnotes, footnotesPart, false) { b.add(n) }
        case "endnoteReference": if let n = try note(e, endnotes, endnotesPart, true) { b.add(n) }
        default: break
        }
    }
    func note(_ e: XElement, _ notes: [String: XElement], _ p: Part?, _ endnote: Bool) throws -> HNote? {
        guard let p, let element = notes[Self.attr(e, "id") ?? ""] else { return nil }
        let n = HNote(endnote)
        n.blocks = try withPart(p) { try readBlocks(element.elements()) }
        if let first = n.blocks.first as? HParagraph, let text = first.inlines.first as? HText {
            first.inlines[0] = HText(String(text.text.drop(while: { $0.isWhitespace })), text.format)
        }
        return n
    }
    static func chooseAlternative(_ e: XElement) -> [XElement] {
        let choices = e.elements(mc + "Choice")
        let choice = choices.first {
            ["wps", "wpg", "wp14", "w14", "a14", "wpc"].contains($0.attributeValue("Requires") ?? "")
        }
        return (choice ?? e.element(mc + "Fallback") ?? choices.first)?.elements() ?? []
    }
    final class FieldState { var instruction = "", result = false, suppress = false, target: String? }
    var showsText: Bool { fields.allSatisfy { $0.result && !$0.suppress } }
    func fieldChar(_ e: XElement, _ b: ParagraphBuilder, _ f: HCharFormat) {
        switch Self.attr(e, "fldCharType") {
        case "begin": fields.append(FieldState())
        case "separate": if let field = fields.last, !field.result { startFieldResult(field, b, f) }
        case "end":
            if let field = fields.last, !field.result { startFieldResult(field, b, f) }
            endField(b)
        default: break
        }
    }
    func startFieldResult(_ f: FieldState, _ b: ParagraphBuilder, _ format: HCharFormat) {
        f.result = true
        let words = Self.splitInstruction(f.instruction)
        switch words.first?.uppercased() {
        case "HYPERLINK":
            var url: String?
            var anchor: String?
            var i = 1
            while i < words.count {
                if words[i] == "\\l" && i + 1 < words.count {
                    i += 1
                    anchor = words[i]
                } else if !words[i].hasPrefix("\\") && url == nil {
                    url = words[i]
                } else if words[i].hasPrefix("\\") && i + 1 < words.count && !words[i + 1].hasPrefix("\\") {
                    i += 1
                }
                i += 1
            }
            f.target = anchor.map { (url ?? "") + "#" + $0 } ?? url
            if let target = f.target { b.openLink(target) }
        case "PAGE":
            b.add(HField(.pageNumber, format))
            f.suppress = true
        case "NUMPAGES", "SECTIONPAGES":
            b.add(HField(.totalPages, format))
            f.suppress = true
        default: break
        }
    }
    func endField(_ b: ParagraphBuilder) { if let f = fields.popLast(), f.target != nil { b.closeLink() } }
    static func splitInstruction(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for c in text {
            if c == "\"" {
                quoted.toggle()
                continue
            }
            if c.isWhitespace && !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
    static func attr(_ e: XElement?, _ n: String) -> String? { e?.attributeValue(w + n) ?? e?.attributeValue(XName(n)) }
    static func attr(_ e: XElement?, _ n: String, _ ns: XNamespace) -> String? { e?.attributeValue(ns + n) }
    static func val(_ e: XElement?) -> String? { attr(e, "val") }
    static func twips(_ e: XElement?, _ n: String) -> Int? {
        DocumentXML.double(attr(e, n)).flatMap {
            $0.isFinite && $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : nil
        }
    }
    static func long(_ e: XElement?, _ n: String) -> Int? { DocumentXML.int(attr(e, n)) }
    static func bool(_ e: XElement?, _ n: String) -> Bool? { attr(e, n).map { !["0", "false", "off"].contains($0) } }
    static func toggle(_ p: XElement?, _ n: String) -> Bool? {
        p?.element(w + n).map { !["0", "false", "off", "none"].contains(val($0) ?? "") }
    }
    static func nullIfEmpty(_ s: String?) -> String? { s.flatMap { DocumentXML.trim($0).isEmpty ? nil : $0 } }
}
