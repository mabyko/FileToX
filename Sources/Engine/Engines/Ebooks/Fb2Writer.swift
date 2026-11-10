// Port of Filee.Engines/Ebooks/Fb2Writer.cs.
import Foundation

final class Fb2Writer {
    private static let fb2 = XNamespace("http://www.gribuser.ru/xml/fictionbook/2.0")
    private static let xlink = XNamespace("http://www.w3.org/1999/xlink")
    private let imageFolder: String
    private var binaries: [(path: String, id: String, file: String, mediaType: String)] = []
    private var notes: [[HBlock]] = []
    private let numbers = ListNumbers()
    private init(_ imageFolder: String) { self.imageFolder = imageFolder }
    private final class Section {
        let title: HParagraph?
        let level: Int
        var blocks: [HBlock] = []
        var children: [Section] = []
        init(_ title: HParagraph?, _ level: Int) { self.title = title; self.level = level }
    }
    private static func e(_ name: String, _ content: XContent?...) -> XElement {
        let element = XElement(fb2 + name)
        for item in content { if let item { element.add(item) } }
        return element
    }

    static func write(_ book: Book, _ outputPath: String, _ sourcePath: String, _ workFolder: String) throws {
        let writer = Fb2Writer(try EbookFiles.newFolder(workFolder, "fb2-images"))
        let root = writer.tree(book.document)
        let xml = e("FictionBook", XAttribute(XNamespace.xmlns + "l", xlink.namespaceName), writer.description(book, sourcePath))
        let body = e("body"); xml.add(body)
        for section in root.children { body.add(writer.writeSection(section)) }
        if root.children.isEmpty { body.add(e("section", e("empty-line"))) }
        if !writer.notes.isEmpty {
            let notes = e("body", XAttribute("name", "notes"))
            // Writing a note can append more notes, just like Filee's indexed loop.
            var i = 0
            while i < writer.notes.count {
                let section = e("section", XAttribute("id", "n\(i + 1)"), e("title", e("p", "\(i + 1)")))
                writer.blocks(section, writer.notes[i]); notes.add(section); i += 1
            }
            xml.add(notes)
        }
        for binary in writer.binaries {
            let raw = try Data(contentsOf: URL(fileURLWithPath: binary.file)).base64EncodedString()
            let chars = Array(raw.utf8)
            let base64 = stride(from: 0, to: chars.count, by: 76).map { String(decoding: chars[$0..<min($0 + 76, chars.count)], as: UTF8.self) }.joined(separator: "\r\n")
            xml.add(e("binary", XAttribute("id", binary.id), XAttribute("content-type", binary.mediaType), base64))
        }
        let document = XDocument(XDeclaration(), root: xml)
        var text = String(decoding: try document.data(), as: UTF8.self)
        // XmlWriterSettings.IndentChars = " "; the shared LINQ writer uses two spaces.
        let before = text
        text = EbookRegex.replace(#"(?m)^( +)(?=<)"#, before) { String(repeating: " ", count: EbookRegex.group($0, before, 1).utf16.count / 2) }
        let temp = outputPath + ".tmp"
        try Data(text.utf8).write(to: URL(fileURLWithPath: temp))
        try EbookFiles.replace(temp, outputPath)
    }

    private func tree(_ document: HDocument) -> Section {
        let root = Section(nil, 0)
        var stack = [root]
        for block in document.sections.flatMap(\.blocks) {
            if let heading = block as? HParagraph, heading.headingLevel > 0 {
                while stack.last!.level >= heading.headingLevel { stack.removeLast() }
                let section = Section(heading, heading.headingLevel)
                stack.last!.children.append(section); stack.append(section); continue
            }
            if stack.count == 1 { let untitled = Section(nil, 1); root.children.append(untitled); stack.append(untitled) }
            stack.last!.blocks.append(block)
        }
        return root
    }
    private func description(_ book: Book, _ sourcePath: String) -> XElement {
        let titleInfo = Self.e("title-info", Self.e("genre", "antique"))
        for author in book.metadata.authors.isEmpty ? [""] : book.metadata.authors {
            let parts = author.split(separator: " "), element = Self.e("author")
            if parts.count >= 2 { element.add(Self.e("first-name", parts.dropLast().joined(separator: " ")), Self.e("last-name", String(parts.last!))) }
            else { element.add(Self.e("nickname", parts.first.map(String.init) ?? "Unknown")) }
            titleInfo.add(element)
        }
        titleInfo.add(Self.e("book-title", book.displayTitle(sourcePath)))
        if let description = book.metadata.description { titleInfo.add(Self.e("annotation", Self.e("p", Self.clean(description)))) }
        titleInfo.add(Self.e("lang", book.displayLanguage().components(separatedBy: "-")[0]))
        if let cover = book.metadata.coverImage, let id = binary(cover) { titleInfo.add(Self.e("coverpage", imageElement(id))) }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd"
        let today = date.string(from: Date())
        let info = Self.e("document-info", Self.e("author", Self.e("nickname", "Filee")), Self.e("program-used", "Filee"),
            Self.e("date", XAttribute("value", today), today), Self.e("id", UUID().uuidString.lowercased()), Self.e("version", "1.0"))
        return Self.e("description", titleInfo, info)
    }
    private func writeSection(_ section: Section) -> XElement {
        let element = Self.e("section")
        if let title = section.title, let id = Self.bookmark(title.inlines) { element.add(XAttribute("id", id)) }
        if let title = section.title {
            let heading = Self.e("title"); paragraphs(heading, title.inlines.filter { !($0 is HBookmark) }, "p"); element.add(heading)
        }
        if !section.children.isEmpty && !section.blocks.isEmpty { let content = Self.e("section"); blocks(content, section.blocks); element.add(content) }
        else if !section.blocks.isEmpty { blocks(element, section.blocks) }
        for child in section.children { element.add(writeSection(child)) }
        if section.blocks.isEmpty && section.children.isEmpty { element.add(Self.e("empty-line")) }
        return element
    }
    private func blocks(_ xml: XElement, _ blocks: [HBlock]) {
        for block in blocks {
            if let paragraph = block as? HParagraph { self.paragraph(xml, paragraph) }
            else if let table = block as? HTable { self.table(xml, table) }
        }
    }
    private func paragraph(_ xml: XElement, _ paragraph: HParagraph) {
        let visible = HDocumentWalker.inlines([paragraph]).contains {
            $0 is HImage || $0 is HNote || ($0 as? HText).map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        }
        if !visible {
            if paragraph.inlines.contains(where: { ($0 as? HShape)?.kind == .line }) { xml.add(Self.e("subtitle", "* * *")) }
            else { xml.add(Self.e("empty-line")) }
            return
        }
        let withoutBookmarks = paragraph.inlines.filter { !($0 is HBookmark) }
        if withoutBookmarks.count == 1, let image = withoutBookmarks[0] as? HImage, let id = binary(image.path) { xml.add(imageElement(id)); return }
        var inlines = paragraph.inlines
        if let list = paragraph.list {
            let marker = list.numbered ? numbers.next(list) + " " : ""
            inlines.insert(HText(String(repeating: "\u{00A0}", count: max(0, list.level * 4)) + marker), at: 0)
        }
        let element = paragraph.format.align == .center && paragraph.inlines.compactMap { $0 as? HText }.allSatisfy { $0.format.bold == true } ? "subtitle" : "p"
        paragraphs(xml, inlines, element)
    }
    private func paragraphs(_ xml: XElement, _ inlines: [HInline], _ element: String) {
        var lines: [[HInline]] = [[]]
        for inline in inlines { if inline is HLineBreak { lines.append([]) } else { lines[lines.count - 1].append(inline) } }
        for line in lines {
            let output = Self.e(element)
            if let id = Self.bookmark(line) { output.add(XAttribute("id", id)) }
            self.inlines(output, line); xml.add(output)
        }
    }
    private static func bookmark(_ inlines: [HInline]) -> String? { inlines.compactMap { $0 as? HBookmark }.first.map { id($0.name) } }
    private static func id(_ name: String) -> String {
        let units = name.utf16.map { c -> UInt16 in ((65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || [45, 95, 46].contains(c)) ? c : 95 }
        let id = String(decoding: units, as: UTF16.self)
        return units.first.map { (65...90).contains($0) || (97...122).contains($0) } == true ? id : "id-" + id
    }
    private func inlines(_ xml: XElement, _ inlines: [HInline]) {
        for inline in inlines {
            switch inline {
            case let text as HText: run(xml, text.text, text.format)
            case is HTab: xml.add("    ")
            case let link as HLink:
                let target = link.target.hasPrefix("#") ? "#" + Self.id(String(link.target.dropFirst())) : link.target
                let a = Self.e("a", XAttribute(Self.xlink + "href", target)); self.inlines(a, link.content.filter { !($0 is HLineBreak) }); xml.add(a)
            case let image as HImage: if let id = binary(image.path) { xml.add(imageElement(id)) }
            case let note as HNote:
                notes.append(note.blocks); xml.add(Self.e("a", XAttribute(Self.xlink + "href", "#n\(notes.count)"), XAttribute("type", "note"), "[\(notes.count)]"))
            case let box as HTextBox: self.inlines(xml, box.blocks.compactMap { $0 as? HParagraph }.flatMap { [HText(" ")] + $0.inlines }.filter { !($0 is HLineBreak) })
            default: break
            }
        }
    }
    private func run(_ xml: XElement, _ text: String, _ format: HCharFormat) {
        var parent = xml
        func open(_ name: String) { let child = Self.e(name); parent.add(child); parent = child }
        if format.shade == HtmlReader.codeShade { open("code") }
        if format.bold == true { open("strong") }
        if format.italic == true { open("emphasis") }
        if format.strike == true { open("strikethrough") }
        if format.superscript == true { open("sup") } else if format.subscript == true { open("sub") }
        parent.add(Self.clean(text))
    }
    private func table(_ xml: XElement, _ table: HTable) {
        let output = Self.e("table")
        for row in table.rows {
            let tr = Self.e("tr")
            for cell in row.cells {
                let td = Self.e(row.header ? "th" : "td")
                if cell.colSpan > 1 { td.add(XAttribute("colspan", cell.colSpan)) }
                if cell.rowSpan > 1 { td.add(XAttribute("rowspan", cell.rowSpan)) }
                for (i, p) in cell.blocks.compactMap({ $0 as? HParagraph }).enumerated() {
                    if i > 0 { td.add(" ") }
                    inlines(td, p.inlines.filter { !($0 is HLineBreak) && !($0 is HImage) })
                }
                tr.add(td)
            }
            output.add(tr)
        }
        xml.add(output)
    }
    private func imageElement(_ id: String) -> XElement { Self.e("image", XAttribute(Self.xlink + "href", "#" + id)) }
    private func binary(_ path: String) -> String? {
        if let known = binaries.first(where: { $0.path.lowercased() == path.lowercased() }) { return known.id }
        guard let (file, mediaType) = EbookFiles.commonImage(path, imageFolder, false) else { return nil }
        let id = "img\(binaries.count + 1).\(mediaType == "image/png" ? "png" : "jpg")"
        binaries.append((path, id, file, mediaType)); return id
    }
    private static func clean(_ text: String) -> String {
        if !text.unicodeScalars.contains(where: { !allowed($0) }) { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter(allowed)))
    }
    private static func allowed(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || (scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF)
    }
}
