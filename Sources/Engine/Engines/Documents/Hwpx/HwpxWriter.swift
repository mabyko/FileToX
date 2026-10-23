// Port of Filee's HwpxWriter.cs. Package layout and XML follow its blank.hwpx template.
import Foundation

final class HwpxWriter {
    static let hh = XNamespace("http://www.hancom.co.kr/hwpml/2011/head")
    static let hc = XNamespace("http://www.hancom.co.kr/hwpml/2011/core")
    static let hp = XNamespace("http://www.hancom.co.kr/hwpml/2011/paragraph")
    static let hs = XNamespace("http://www.hancom.co.kr/hwpml/2011/section")
    static let hwpUnitCharNamespace = "http://www.hancom.co.kr/hwpml/2016/HwpUnitChar"
    static let imageTypes = ["png", "jpg", "gif", "bmp"]
    let head: XElement
    let templateSection: XElement
    var images: [(id: String, path: String, ext: String)] = []
    var plainText = ""
    var nextObjectId = 1_000_000
    var width = 42520, pageLeft = 7200, pageTop = 8505
    typealias StyleIds = (style: String, para: String, char: String)
    var base: StyleIds = ("0", "0", "0")
    var normal: StyleIds = ("0", "0", "0")
    var footnoteStyle: StyleIds?
    var headings: [Int: StyleIds] = [:]
    var maxCharPr = 0, maxParaPr = 0
    struct CharKey: Hashable {
        let base: String
        let format: HCharFormat
        let link: Bool
    }
    struct ParaKey: Hashable {
        let base: String
        let format: HParaFormat
        let numbering: String?
        let level: Int
        let numbered: Bool
    }
    struct BorderKey: Hashable {
        let borders: HBorders
        let fill: String?
    }
    var charPrCache: [CharKey: String] = [:], paraPrCache: [ParaKey: String] = [:]
    var numberingIds: [ObjectIdentifier: String] = [:], borderFills: [BorderKey: String] = [:],
        tabPrIds: [String: String] = [:], fontIds: [String: Int] = [:]
    var footnotes = 0, endnotes = 0, zOrder = 0
    private init(_ header: XDocument, _ section: XDocument) throws {
        head = header.root
        templateSection = section.root
        try initializeHeader()
    }
    static func openBuiltInTemplate() throws -> Data {
        guard let data = ResourceBundle.data("blank", "hwpx") else {
            throw ConversionError("Embedded blank.hwpx is missing.")
        }
        return data
    }
    static func write(_ document: HDocument, _ outputPath: String, _ template: Data? = nil) throws {
        let reference = try ZipReader(data: template ?? openBuiltInTemplate())
        let writer = try HwpxWriter(
            XDocument.parse(readEntry(reference, "Contents/header.xml")),
            XDocument.parse(readEntry(reference, "Contents/section0.xml")))
        let sections = document.sections.isEmpty ? [HSection()] : document.sections
        let xml = try sections.map { try writer.section($0) }
        try writer.writePackage(reference, outputPath, xml, document.title)
    }
    private func writePackage(_ reference: ZipReader, _ path: String, _ sections: [String], _ title: String?) throws {
        let header = try serializeHeader(sections.count)
        let temp = path + ".tmp"
        let zip = try ZipWriter(path: temp)
        try zip.add("mimetype", text: Self.readEntry(reference, "mimetype"), level: .noCompression)
        for entry in reference.entries {
            try Task.checkCancellation()
            if entry.name == "mimetype" || entry.name.hasSuffix("/") { continue }
            switch entry.name {
            case "Contents/section0.xml":
                for (i, s) in sections.enumerated() { try zip.add("Contents/section\(i).xml", text: s) }
            case "Contents/header.xml": try zip.add(entry.name, text: header)
            case "Contents/content.hpf":
                try zip.add(
                    entry.name, text: buildManifest(Self.readEntry(reference, entry.name), sections.count, title))
            case "META-INF/container.rdf":
                try zip.add(entry.name, text: Self.buildRdf(Self.readEntry(reference, entry.name), sections.count))
            case "Preview/PrvText.txt":
                try zip.add(
                    entry.name, text: String(decoding: DocumentXML.trim(plainText).utf16.prefix(1000), as: UTF16.self))
            default: try zip.add(entry.name, data: reference.data(for: entry))
            }
        }
        for image in images {
            let ext = Self.imageTypes.contains(image.ext) ? image.ext : "png"
            try zip.add(
                "BinData/\(image.id).\(ext)",
                data: ext == image.ext
                    ? Data(contentsOf: URL(fileURLWithPath: image.path)) : ImageSupport.pngData(image.path))
        }
        try zip.close()
        try DocumentXML.moveReplacing(temp, path)
    }
    func sectionOpenTag() -> String {
        var ns = head.attributes.filter(\.isNamespaceDeclaration)
        if !ns.contains(where: { $0.value == Self.hs.namespaceName }) {
            ns.append(XAttribute(XNamespace.xmlns + "hs", Self.hs.namespaceName))
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?><hs:sec "
            + ns.map { "\($0.name.localName == "xmlns" ? "xmlns" : "xmlns:" + $0.name.localName)=\"\($0.value)\"" }
            .joined(separator: " ") + ">"
    }
    private func buildManifest(_ source: String, _ count: Int, _ title: String?) -> String {
        var text = source
        if let title, !DocumentXML.trim(title).isEmpty {
            if let start = text.range(of: "<opf:title>"), let end = text.range(of: "</opf:title>"),
                end.lowerBound > start.lowerBound
            {
                text.replaceSubrange(start.upperBound..<end.lowerBound, with: Self.escape(title))
            } else {
                text = text.replacingOccurrences(
                    of: "<opf:title/>", with: "<opf:title>\(Self.escape(title))</opf:title>")
            }
        }
        var items = ""
        var spine = ""
        for i in 1..<count {
            items += "<opf:item id=\"section\(i)\" href=\"Contents/section\(i).xml\" media-type=\"application/xml\"/>"
            spine += "<opf:itemref idref=\"section\(i)\" linear=\"yes\"/>"
        }
        for image in images {
            let ext = Self.imageTypes.contains(image.ext) ? image.ext : "png"
            let mime = ["jpg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp"][ext] ?? "image/png"
            items +=
                "<opf:item id=\"\(image.id)\" href=\"BinData/\(image.id).\(ext)\" media-type=\"\(mime)\" isEmbeded=\"1\"/>"
        }
        text =
            Self.insertAfter(text, "href=\"Contents/section0.xml\" media-type=\"application/xml\"/>", items)
            ?? Self.insertBefore(text, "</opf:manifest>", items)
        return Self.insertAfter(text, "<opf:itemref idref=\"section0\" linear=\"yes\"/>", spine)
            ?? Self.insertBefore(text, "</opf:spine>", spine)
    }
    private static func buildRdf(_ rdf: String, _ count: Int) -> String {
        var parts = ""
        for i in 1..<count {
            parts +=
                "<rdf:Description rdf:about=\"\"><ns0:hasPart xmlns:ns0=\"http://www.hancom.co.kr/hwpml/2016/meta/pkg#\" rdf:resource=\"Contents/section\(i).xml\"/></rdf:Description><rdf:Description rdf:about=\"Contents/section\(i).xml\"><rdf:type rdf:resource=\"http://www.hancom.co.kr/hwpml/2016/meta/pkg#SectionFile\"/></rdf:Description>"
        }
        return insertBefore(rdf, "</rdf:RDF>", parts)
    }
    private static func insertAfter(_ text: String, _ marker: String, _ insert: String) -> String? {
        guard let r = text.range(of: marker) else { return nil }
        var s = text
        s.insert(contentsOf: insert, at: r.upperBound)
        return s
    }
    private static func insertBefore(_ text: String, _ marker: String, _ insert: String) -> String {
        guard let r = text.range(of: marker, options: .backwards) else { return text }
        var s = text
        s.insert(contentsOf: insert, at: r.lowerBound)
        return s
    }
    func nextId() -> Int {
        defer { nextObjectId += 1 }
        return nextObjectId
    }
    func nextZ() -> Int {
        defer { zOrder += 1 }
        return zOrder
    }
    static func maxId(_ list: [XElement]) -> Int {
        list.map { DocumentXML.int($0.attributeValue("id")) ?? 0 }.max() ?? 0
    }
    static func escape(_ text: String) -> String {
        // One pass over the scalars: drops the characters XML forbids and escapes the five markup characters. Working
        // per scalar matches .literal replacement (which never skips a "<" or "&" that a combining mark follows).
        var needsWork = false
        for scalar in text.unicodeScalars where !escapeKeeps(scalar) {
            needsWork = true
            break
        }
        if !needsWork { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result.append(contentsOf: "&amp;".unicodeScalars)
            case "<": result.append(contentsOf: "&lt;".unicodeScalars)
            case ">": result.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": result.append(contentsOf: "&quot;".unicodeScalars)
            case "'": result.append(contentsOf: "&apos;".unicodeScalars)
            case "\t", "\n", "\r": result.append(scalar)
            default: if scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF { result.append(scalar) }
            }
        }
        return String(result)
    }
    /// True when `escape` leaves the scalar as it is.
    private static func escapeKeeps(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "&", "<", ">", "\"", "'": return false
        case "\t", "\n", "\r": return true
        default: return scalar.value >= 0x20 && scalar.value != 0xFFFE && scalar.value != 0xFFFF
        }
    }
    private static func readEntry(_ zip: ZipReader, _ name: String) throws -> String {
        guard let e = zip.entry(named: name) else { throw ConversionError("Reference HWPX has no \(name).") }
        return String(decoding: try zip.data(for: e), as: UTF8.self)
    }
    static func inner(_ element: XElement) throws -> String {
        let copy = XElement(copying: element)
        let namespaces = [("hp", hp), ("hc", hc), ("hh", hh), ("hs", hs)]
        for (p, n) in namespaces { copy.setAttributeValue(XNamespace.xmlns + p, n.namespaceName) }
        var xml = try copy.toString(indent: false)
        for (p, n) in namespaces { xml = xml.replacingOccurrences(of: " xmlns:\(p)=\"\(n.namespaceName)\"", with: "") }
        return xml
    }
}
