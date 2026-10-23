// Port of DocxWriter.cs: OPC parts, relationships, styles, settings, numbering and notes.
import Foundation

final class DocxWriter {
    static let relationshipBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let contentTypeBase = "application/vnd.openxmlformats-officedocument.wordprocessingml."
    static let namespaces =
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\""
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    static let pictureTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp",
        "emf": "image/x-emf", "wmf": "image/x-wmf",
    ]
    final class Part {
        let path: String, contentType: String
        var xml = ""
        var relationships: [(id: String, type: String, target: String, external: Bool)] = []
        init(_ path: String, _ type: String, _ xml: String = "") {
            self.path = path
            contentType = type
            self.xml = xml
        }
        @discardableResult func relate(_ type: String, _ target: String, _ external: Bool = false) -> String {
            if let r = relationships.first(where: { $0.type == type && $0.target == target && $0.external == external })
            {
                return r.id
            }
            let id = "rId\(relationships.count+1)"
            relationships.append((id, type, target, external))
            return id
        }
    }
    let document = Part("word/document.xml", contentTypeBase + "document.main+xml")
    var part: Part!
    var parts: [Part] = [], media: [(source: String, path: String, ext: String)] = [], footnotes: [String] = [],
        endnotes: [String] = [], numberings: [(HNumbering, Int)] = []
    var bookmarks: [String: String] = [:], bookmarkNames = Set<String>(), nextDrawingId = 1, nextBookmarkId = 0,
        evenAndOddHeaders = false, relativeHeight = 251_659_264, textBoxDepth = 0
    var footnotesPart: Part?, endnotesPart: Part?, width = defaultPage.textWidth, headerTypes: [String] = [],
        footerTypes: [String] = []
    private init() { part = document }
    static func write(_ document: HDocument, _ path: String) throws {
        let w = DocxWriter()
        let body = try w.body(document)
        try w.writePackage(document, body, path)
    }
    func withPart<T>(_ p: Part, _ write: () throws -> T) rethrows -> T {
        let old = part
        part = p
        defer { part = old }
        return try write()
    }
    func headerFooterPart(_ kind: String, _ content: () throws -> String) rethrows -> String {
        let i = parts.filter { $0.path.hasPrefix("word/" + kind) }.count + 1
        let p = Part(
            "word/\(kind)\(parts.filter { $0.path.hasPrefix("word/"+kind) }.count+1).xml",
            Self.contentTypeBase + kind + "+xml")
        let root = kind == "header" ? "w:hdr" : "w:ftr"
        p.xml = "<\(root) \(Self.namespaces)>" + (try withPart(p, content)) + "</\(root)>"
        parts.append(p)
        return document.relate(Self.relationshipBase + kind, "\(kind)\(i).xml")
    }
    func writePackage(_ model: HDocument, _ body: String, _ path: String) throws {
        let rb = Self.relationshipBase
        let cb = Self.contentTypeBase
        document.xml = "<w:document \(Self.namespaces)><w:body>\(body)</w:body></w:document>"
        document.relate(rb + "styles", "styles.xml")
        document.relate(rb + "settings", "settings.xml")
        if !numberings.isEmpty { document.relate(rb + "numbering", "numbering.xml") }
        if !footnotes.isEmpty { document.relate(rb + "footnotes", "footnotes.xml") }
        if !endnotes.isEmpty { document.relate(rb + "endnotes", "endnotes.xml") }
        var all =
            [document] + parts + [
                Part("word/styles.xml", cb + "styles+xml", Self.stylesXml),
                Part("word/settings.xml", cb + "settings+xml", settings()),
            ]
        if !numberings.isEmpty { all.append(Part("word/numbering.xml", cb + "numbering+xml", numbering())) }
        if let p = footnotesPart {
            p.xml = Self.notes("footnote", footnotes)
            all.append(p)
        }
        if let p = endnotesPart {
            p.xml = Self.notes("endnote", endnotes)
            all.append(p)
        }
        all += [
            Part(
                "docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml",
                Self.coreProperties(model.title)),
            Part(
                "docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml",
                "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>Filee</Application></Properties>"
            ),
        ]
        let temp = path + ".tmp"
        let zip = try ZipWriter(path: temp)
        func write(_ n: String, _ s: String) throws { try zip.add(n, text: Self.declaration + s) }
        try write("[Content_Types].xml", contentTypes(all))
        try write(
            "_rels/.rels",
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rb)officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"\(rb)extended-properties\" Target=\"docProps/app.xml\"/></Relationships>"
        )
        for p in all {
            try Task.checkCancellation()
            try write(p.path, p.xml)
            if !p.relationships.isEmpty {
                let folder = String(p.path[..<p.path.lastIndex(of: "/")!])
                let name = FilePath.fileName(p.path)
                let rels = p.relationships.map {
                    "<Relationship Id=\"\($0.id)\" Type=\"\($0.type)\" Target=\"\(Self.escape($0.target))\"\($0.external ? " TargetMode=\"External\"" : "")/>"
                }.joined()
                try write(
                    "\(folder)/_rels/\(name).rels",
                    "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>"
                )
            }
        }
        for m in media {
            let ext = FilePath.extension(m.source).lowercased().dropFirst()
            try zip.add(
                m.path,
                data: ext == m.ext || (m.ext == "jpg" && ext == "jpeg")
                    ? Data(contentsOf: URL(fileURLWithPath: m.source)) : ImageSupport.pngData(m.source))
        }
        try zip.close()
        try DocumentXML.moveReplacing(temp, path)
    }
    func contentTypes(_ parts: [Part]) -> String {
        var s =
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        var seen = Set<String>()
        for m in media where seen.insert(m.ext.lowercased()).inserted {
            s += "<Default Extension=\"\(m.ext)\" ContentType=\"\(Self.pictureTypes[m.ext]!)\"/>"
        }
        for p in parts { s += "<Override PartName=\"/\(p.path)\" ContentType=\"\(p.contentType)\"/>" }
        return s + "</Types>"
    }
    static func coreProperties(_ title: String?) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let now = f.string(from: Date())
        let t = title.flatMap { DocumentXML.trim($0).isEmpty ? nil : "<dc:title>\(escape($0))</dc:title>" } ?? ""
        return
            "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\(t)<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified></cp:coreProperties>"
    }
    func settings() -> String {
        var s = "<w:settings \(Self.namespaces)><w:zoom w:percent=\"100\"/><w:defaultTabStop w:val=\"800\"/>"
        if evenAndOddHeaders { s += "<w:evenAndOddHeaders/>" }
        s += "<w:characterSpacingControl w:val=\"doNotCompress\"/>"
        if !footnotes.isEmpty { s += "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>" }
        if !endnotes.isEmpty { s += "<w:endnotePr><w:endnote w:id=\"-1\"/><w:endnote w:id=\"0\"/></w:endnotePr>" }
        return s
            + "<w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"
    }
    func numberingId(_ n: HNumbering) -> Int {
        if let pair = numberings.first(where: { $0.0 === n }) { return pair.1 }
        let id = numberings.count + 1
        numberings.append((n, id))
        return id
    }
    static func listIndent(_ level: Int) -> Int { (level + 1) * 400 }
    func numbering() -> String {
        var s = "<w:numbering \(Self.namespaces)>"
        for (n, id) in numberings {
            s += "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for l in 0..<9 {
                let d = l < n.levels.count ? n.levels[l] : HNumberingLevel("DIGIT", "^\(l+1).", 1, false)
                let f = d.bullet ? "bullet" : Self.numberFormat(d.format)
                let t = d.bullet ? (d.text.isEmpty ? "●" : d.text) : Self.numberText(d.text)
                s +=
                    "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"\(max(0,d.start))\"/><w:numFmt w:val=\"\(f)\"/><w:lvlText w:val=\"\(Self.escape(t))\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(Self.listIndent(l))\" w:hanging=\"400\"/></w:pPr></w:lvl>"
            }
            s += "</w:abstractNum>"
        }
        for (_, id) in numberings { s += "<w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"\(id)\"/></w:num>" }
        return s + "</w:numbering>"
    }
    static func numberFormat(_ s: String) -> String {
        [
            "ROMAN_CAPITAL": "upperRoman", "ROMAN_SMALL": "lowerRoman", "LATIN_CAPITAL": "upperLetter",
            "LATIN_SMALL": "lowerLetter", "HANGUL_SYLLABLE": "ganada", "HANGUL_JAMO": "chosung",
            "CIRCLED_DIGIT": "decimalEnclosedCircle", "HANGUL_PHONETIC": "koreanDigital",
            "IDEOGRAPH": "ideographDigital",
        ][s] ?? "decimal"
    }
    static func numberText(_ s: String) -> String {
        var a = Array(s.utf16)
        for i in a.indices.dropLast() where a[i] == 94 && DocumentXML.isDigit(a[i + 1]) { a[i] = 37 }
        return String(decoding: a, as: UTF16.self)
    }
    static func notes(_ kind: String, _ notes: [String]) -> String {
        var s = "<w:\(kind)s \(namespaces)>"
        for (id, type, tag) in [(-1, "separator", "separator"), (0, "continuationSeparator", "continuationSeparator")] {
            s +=
                "<w:\(kind) w:type=\"\(type)\" w:id=\"\(id)\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:\(tag)/></w:r></w:p></w:\(kind)>"
        }
        for (i, n) in notes.enumerated() { s += "<w:\(kind) w:id=\"\(i+1)\">\(n)</w:\(kind)>" }
        return s + "</w:\(kind)s>"
    }
    static func twips(_ n: Int) -> Int { Int((Double(n) / 5).rounded(.toNearestOrEven)) }
    static func emu(_ n: Int) -> Int { n * 127 }
    static func hex(_ s: String?) -> String? {
        guard let s, s.utf16.count == 7, s.hasPrefix("#"), Int(s.dropFirst(), radix: 16) != nil else { return nil }
        return s.dropFirst().uppercased()
    }
    static func escape(_ s: String) -> String { HwpxWriter.escape(s) }
}
