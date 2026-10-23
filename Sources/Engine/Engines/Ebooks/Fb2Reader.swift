// Port of Filee.Engines/Ebooks/Fb2Reader.cs.
import Foundation

final class Fb2Reader {
    private var binaries: [String: String] = [:]
    private var notes: [String: XElement] = [:]
    private init() {}
    static func read(_ path: String, _ workFolder: String) throws -> HDocument { try readBook(path, workFolder).document }
    static func readBook(_ path: String, _ workFolder: String) throws -> Book {
        let root = try XDocument.load(path, preserveWhitespace: true).root
        guard root.name.localName == "FictionBook" else { throw ConversionError("This is not a FictionBook (FB2) file.") }
        let reader = Fb2Reader(), folder = try EbookFiles.newFolder(workFolder, "fb2")
        try reader.saveBinaries(root, folder)
        let bodies = children(root, "body")
        for body in bodies where ["notes", "comments"].contains(body.attributeValue("name") ?? "") {
            for section in body.descendants().filter({ $0.name.localName == "section" }) {
                if let id = section.attributeValue("id"), reader.notes[id] == nil { reader.notes[id] = section }
            }
        }
        let metadata = reader.metadata(root), section = HSection()
        for body in bodies where !["notes", "comments"].contains(body.attributeValue("name") ?? "") { reader.body(body, &section.blocks) }
        let document = HDocument(); document.title = metadata.title; document.sections.append(section)
        HtmlReader.pruneBookmarks(document)
        return Book(document, metadata)
    }
    private static func children(_ parent: XElement?, _ name: String) -> [XElement] { parent?.elements().filter { $0.name.localName == name } ?? [] }
    private static func child(_ parent: XElement?, _ name: String) -> XElement? { children(parent, name).first }
    private static func href(_ element: XElement) -> String? { element.attributes.first { $0.name.localName == "href" }?.value }
    private func metadata(_ root: XElement) -> BookMetadata {
        let info = Self.child(Self.child(root, "description"), "title-info"), metadata = BookMetadata()
        metadata.title = Self.child(info, "book-title")?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = Self.child(info, "lang")?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.language = lang?.isEmpty == false ? lang : nil
        let annotation = Self.child(info, "annotation")?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.description = annotation?.isEmpty == false ? annotation : nil
        metadata.publisher = Self.child(Self.child(Self.child(root, "description"), "publish-info"), "publisher")?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        for author in Self.children(info, "author") {
            var name = ["first-name", "middle-name", "last-name"].compactMap { Self.child(author, $0)?.value.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = Self.child(author, "nickname")?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            if !name.isEmpty { metadata.authors.append(name) }
        }
        if let cover = Self.child(Self.child(info, "coverpage"), "image"), let href = Self.href(cover), let file = binaries[String(href.drop(while: { $0 == "#" }))] { metadata.coverImage = file }
        return metadata
    }
    private func saveBinaries(_ root: XElement, _ folder: String) throws {
        for binary in Self.children(root, "binary") {
            guard let id = binary.attributeValue("id"), !id.isEmpty else { continue }
            // Convert.FromBase64String allows XML whitespace, but rejects other non-base64 characters.
            let text = binary.value.filter { ![" ", "\t", "\r", "\n"].contains($0) }
            guard let data = Data(base64Encoded: text) else { continue }
            let ext: String
            switch binary.attributeValue("content-type")?.lowercased() {
            case "image/png": ext = "png"
            case "image/gif": ext = "gif"
            case "image/jpeg", "image/jpg": ext = "jpg"
            default: ext = data.starts(with: [0x89, 80]) ? "png" : data.starts(with: [71, 73, 70]) ? "gif" : "jpg"
            }
            let file = FilePath.combine(folder, String(format: "binary%04d.%@", binaries.count + 1, ext))
            try data.write(to: URL(fileURLWithPath: file)); binaries[id] = file
        }
    }
    private func body(_ body: XElement, _ output: inout [HBlock]) {
        for element in body.elements() {
            switch element.name.localName {
            case "title": title(element, &output, 1, true)
            case "epigraph": epigraph(element, &output)
            case "image": image(element, &output, 0)
            case "section": section(element, &output, 1)
            default: break
            }
        }
    }
    private func section(_ section: XElement, _ output: inout [HBlock], _ depth: Int) {
        let start = output.count
        for element in section.elements() { block(element, &output, depth, 0) }
        if output.count == start { return }
        let first: HParagraph
        if let paragraph = output[start] as? HParagraph { first = paragraph } else { first = HParagraph(); output.insert(first, at: start) }
        first.pageBreakBefore = depth == 1 && start > 0
        if let id = section.attributeValue("id"), !id.isEmpty { first.inlines.insert(HBookmark(id), at: 0) }
    }
    private func block(_ element: XElement, _ output: inout [HBlock], _ depth: Int, _ indent: Int) {
        switch element.name.localName {
        case "title": title(element, &output, depth, false)
        case "section": section(element, &output, depth + 1)
        case "p": output.append(paragraph(element, HParaFormat(left: indent > 0 ? indent : nil), HCharFormat()))
        case "subtitle": output.append(paragraph(element, HParaFormat(align: .center), HCharFormat(bold: true)))
        case "empty-line": output.append(HParagraph())
        case "epigraph": epigraph(element, &output)
        case "annotation", "cite": for child in element.elements() { block(child, &output, depth, indent + 2000) }
        case "text-author": output.append(paragraph(element, HParaFormat(align: .right, left: indent > 0 ? indent : nil), HCharFormat(italic: true)))
        case "poem": poem(element, &output, depth, indent + 2000)
        case "image": image(element, &output, indent)
        case "table": output.append(table(element))
        default: break
        }
    }
    private func title(_ title: XElement, _ output: inout [HBlock], _ depth: Int, _ center: Bool) {
        let heading = HParagraph(); heading.headingLevel = min(6, max(1, depth)); heading.format = center ? HParaFormat(align: .center) : HParaFormat()
        for p in Self.children(title, "p") { if !heading.inlines.isEmpty { heading.inlines.append(HLineBreak()) }; heading.inlines += line(p, HCharFormat()) }
        if !heading.inlines.isEmpty { output.append(heading) }
    }
    private func epigraph(_ epigraph: XElement, _ output: inout [HBlock]) {
        for child in epigraph.elements() {
            if child.name.localName == "p" { output.append(paragraph(child, HParaFormat(align: .right), HCharFormat(italic: true))) }
            else { block(child, &output, 0, 2000) }
        }
    }
    private func poem(_ poem: XElement, _ output: inout [HBlock], _ depth: Int, _ indent: Int) {
        for child in poem.elements() {
            switch child.name.localName {
            case "stanza":
                let stanza = HParagraph(); stanza.format = HParaFormat(left: indent)
                for line in child.elements() {
                    if ["title", "subtitle"].contains(line.name.localName) {
                        output.append(paragraph(line.name.localName == "title" ? Self.child(line, "p") ?? line : line, HParaFormat(left: indent), HCharFormat(bold: true))); continue
                    }
                    if !stanza.inlines.isEmpty { stanza.inlines.append(HLineBreak()) }
                    stanza.inlines += self.line(line, HCharFormat())
                }
                if !stanza.inlines.isEmpty { output.append(stanza) }
            case "title": title(child, &output, depth + 1, false)
            default: block(child, &output, depth, indent)
            }
        }
    }
    private func image(_ image: XElement, _ output: inout [HBlock], _ indent: Int) {
        guard let href = Self.href(image), let file = binaries[String(href.drop(while: { $0 == "#" }))] else { return }
        let paragraph = HParagraph(); paragraph.format = HParaFormat(align: .center, left: indent > 0 ? indent : nil); paragraph.inlines.append(HImage(file)); output.append(paragraph)
    }
    private func table(_ table: XElement) -> HTable {
        let result = HTable()
        for row in Self.children(table, "tr") {
            let cells = row.elements().filter { ["td", "th"].contains($0.name.localName) }, hRow = HRow()
            hRow.header = !cells.isEmpty && cells.allSatisfy { $0.name.localName == "th" }
            for cell in cells {
                let hCell = HCell()
                hCell.colSpan = max(1, Int(cell.attributeValue("colspan")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1)
                hCell.rowSpan = max(1, Int(cell.attributeValue("rowspan")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1)
                let align: HAlign? = cell.attributeValue("align")?.lowercased() == "center" ? .center : cell.attributeValue("align")?.lowercased() == "right" ? .right : nil
                hCell.blocks.append(paragraph(cell, HParaFormat(align: align), cell.name.localName == "th" ? HCharFormat(bold: true) : HCharFormat())); hRow.cells.append(hCell)
            }
            if !hRow.cells.isEmpty { result.rows.append(hRow) }
        }
        result.columnCount = max(1, result.rows.map { $0.cells.reduce(0) { $0 + $1.colSpan } }.max() ?? 1)
        return result
    }
    private func paragraph(_ element: XElement, _ format: HParaFormat, _ charFormat: HCharFormat) -> HParagraph {
        let p = HParagraph(); p.format = format
        if let id = element.attributeValue("id"), !id.isEmpty { p.inlines.append(HBookmark(id)) }
        inlines(element, &p.inlines, charFormat); HtmlReader.mergeRuns(&p.inlines); Self.trimEdges(&p.inlines)
        return p
    }
    private func line(_ element: XElement, _ format: HCharFormat) -> [HInline] {
        var result: [HInline] = []; inlines(element, &result, format); HtmlReader.mergeRuns(&result); Self.trimEdges(&result); return result
    }
    private static func collapseWhitespace(_ text: String) -> String {
        var output = ""
        for ch in text.unicodeScalars {
            if ![32, 10, 13, 9].contains(ch.value) { output.unicodeScalars.append(ch) }
            else if output.isEmpty || output.last != " " { output += " " }
        }
        return output
    }
    private static func trimEdges(_ inlines: inout [HInline]) {
        if let first = inlines.firstIndex(where: { $0 is HText }), let head = inlines[first] as? HText { inlines[first] = HText(String(head.text.drop(while: \.isWhitespace)), head.format) }
        if let tail = inlines.last as? HText { inlines[inlines.count - 1] = HText(String(tail.text.reversed().drop(while: \.isWhitespace).reversed()), tail.format) }
        inlines.removeAll { ($0 as? HText)?.text.isEmpty == true }
    }
    private func inlines(_ element: XElement, _ output: inout [HInline], _ format: HCharFormat) {
        for node in element.nodes {
            if let text = node.text { let value = Self.collapseWhitespace(text); if !value.isEmpty { output.append(HText(value, format)) }; continue }
            guard let child = node.element else { continue }
            var styled = format
            switch child.name.localName {
            case "strong": styled.bold = true
            case "emphasis": styled.italic = true
            case "strikethrough": styled.strike = true
            case "sub": styled.subscript = true
            case "sup": styled.superscript = true
            case "code": styled.shade = HtmlReader.codeShade
            case "image": if let href = Self.href(child), let file = binaries[String(href.drop(while: { $0 == "#" }))] { output.append(HImage(file)) }; continue
            case "a": link(child, &output, format); continue
            default: break
            }
            inlines(child, &output, styled)
        }
    }
    private func link(_ link: XElement, _ output: inout [HInline], _ format: HCharFormat) {
        let href = Self.href(link) ?? ""
        if href.hasPrefix("#"), let section = notes[String(href.dropFirst())] {
            let note = HNote(false)
            for child in section.elements().filter({ $0.name.localName != "title" }) { block(child, &note.blocks, 0, 0) }
            if !note.blocks.isEmpty { output.append(note); return }
        }
        if href.isEmpty { inlines(link, &output, format); return }
        let hLink = HLink(href); inlines(link, &hLink.content, format); output.append(hLink)
    }
}
