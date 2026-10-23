// Port of HwpxReader.cs. Local-name matching accepts Hancom, rhwp and Filee namespaces.
import Foundation

final class HwpxReader {
    let zip: ZipReader, mediaFolder: String
    var binaryItems: [String: String] = [:], media: [String: String?] = [:], skipped: [String: Int] = [:]
    var fonts: [String: String] = [:], charPrs: [String: XElement] = [:], paraPrs: [String: XElement] = [:],
        borderElements: [String: XElement] = [:], tabPrs: [String: XElement] = [:],
        numberingElements: [String: XElement] = [:], bulletElements: [String: XElement] = [:],
        styles: [String: XElement] = [:]
    var charFormats: [String: HCharFormat] = [:], paraShapes: [String: ParaShape] = [:],
        numberings: [String: HNumbering?] = [:], borderFills: [String: (borders: HBorders, fill: String?)?] = [:]
    struct ParaShape {
        let format: HParaFormat
        let headingType: String
        let headingId: String?
        let level: Int
        let pageBreak: Bool
    }
    struct OpenField {
        let id: String?
        let target: String?
    }
    var fields: [OpenField] = [], markpen: String?, deleted = false, outlineNumberingId: String?
    private init(_ zip: ZipReader, _ media: String) {
        self.zip = zip
        mediaFolder = media
    }
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        var skipped: [String: Int] = [:]
        return try read(path, mediaFolder, &skipped)
    }
    static func read(_ path: String, _ mediaFolder: String, _ skipped: inout [String: Int]) throws -> HDocument {
        let zip: ZipReader
        do { zip = try ZipReader(path: path) } catch is ZipError {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            throw ConversionError(
                data.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
                    ? "The file is an HWP 5.0 (binary) document, not HWPX. Rename it to .hwp and convert it again."
                    : "The file is not an HWPX package. It may be damaged or protected by document security (DRM) software."
            )
        }
        let reader = HwpxReader(zip, mediaFolder)
        let doc = try reader.readDocument()
        for (n, c) in reader.skipped { skipped[n] = c }
        return doc
    }
    func readDocument() throws -> HDocument {
        if !Self.descendants(try loadXml("META-INF/manifest.xml", false)?.root, "encryption-data").isEmpty {
            throw ConversionError(
                "The HWPX file is password-protected. Open it in 한글 (Hangul), remove the password, save it and convert it again."
            )
        }
        let roots = Self.descendants(try loadXml("META-INF/container.xml", false)?.root, "rootfile")
        let root =
            roots.first { Self.attr($0, "media-type") == "application/hwpml-package+xml" }
            ?? roots.first { (Self.attr($0, "full-path") ?? "").lowercased().hasSuffix(".hpf") }
        let packagePath = Self.attr(root, "full-path") ?? "Contents/content.hpf"
        let package = try loadXml(packagePath, false)
        let folder = packagePath.lastIndex(of: "/").map { String(packagePath[...$0]) } ?? ""
        var items: [String: String] = [:]
        var itemOrder: [String] = []
        for item in Self.descendants(package?.root, "item") {
            guard let id = Self.attr(item, "id"), !id.isEmpty, let href = Self.attr(item, "href"), !href.isEmpty else {
                continue
            }
            let path = entryPath(href, folder)
            if items[id] == nil { itemOrder.append(id) }
            items[id] = path
            if path.lowercased().hasPrefix("bindata/") && Self.attr(item, "isEmbeded") != "0" { binaryItems[id] = path }
        }
        let header = try loadXml(
            itemOrder.compactMap { items[$0] }.first { $0.lowercased().hasSuffix("header.xml") }
                ?? "Contents/header.xml", true)!
        loadHeader(header.root)
        let document = HDocument()
        let title = Self.descendants(package?.root, "title").first.map { DocumentXML.trim($0.value) }
        document.title = title?.isEmpty == false ? title : nil
        func isSection(_ p: String) -> Bool {
            let n = FilePath.fileName(p).lowercased()
            return n.hasPrefix("section") && n.hasSuffix(".xml")
        }
        var paths: [String] = []
        for ref in Self.descendants(package?.root, "itemref") {
            if let p = items[Self.attr(ref, "idref") ?? ""], isSection(p), !paths.contains(p) { paths.append(p) }
        }
        if paths.isEmpty {
            paths = zip.entries.filter { $0.name.lowercased().hasPrefix("contents/") && isSection($0.name) }.sorted {
                (Int(FilePath.fileNameWithoutExtension($0.name).dropFirst(7)) ?? Int.max)
                    < (Int(FilePath.fileNameWithoutExtension($1.name).dropFirst(7)) ?? Int.max)
            }.map(\.name)
        }
        for path in paths {
            try Task.checkCancellation()
            try readSection(loadXml(path, true)!.root, document)
        }
        if document.sections.isEmpty {
            throw ConversionError("The HWPX file has no sections (Contents/section0.xml is missing).")
        }
        return document
    }
    func entryPath(_ href: String, _ folder: String) -> String {
        let path = String(
            (href.removingPercentEncoding ?? href).replacingOccurrences(of: "\\", with: "/").drop(while: { $0 == "/" }))
        if zip.entry(named: path) != nil { return path }
        return !folder.isEmpty && zip.entry(named: folder + path) != nil ? folder + path : path
    }
    func loadXml(_ path: String, _ required: Bool) throws -> XDocument? {
        guard let e = zip.entry(named: path) else {
            if required { throw ConversionError("The HWPX file is incomplete: \(path) is missing.") }
            return nil
        }
        do { return try XDocument.load(data: zip.data(for: e), preserveWhitespace: true) } catch let error as XmlError {
            throw ConversionError(
                "The HWPX file cannot be read (\(path) is not valid XML). It may be encrypted or damaged. \(error.localizedDescription)"
            )
        }
    }
    func extractBinary(_ id: String?) throws -> String? {
        guard let id, !id.isEmpty else { return nil }
        if let p = media[id] { return p }
        let path =
            binaryItems[id]
            ?? zip.entries.first {
                $0.name.lowercased().hasPrefix("bindata/")
                    && FilePath.fileNameWithoutExtension($0.name).caseInsensitiveCompare(id) == .orderedSame
            }?.name
        var output: String?
        if let path, let e = zip.entry(named: path) {
            try FileManager.default.createDirectoryIfNeeded(mediaFolder)
            let p = FilePath.combine(
                mediaFolder, "hwpx-media-\(media.count+1)" + FilePath.extension(e.name).lowercased())
            try zip.extract(e, to: p)
            output = p
        }
        media[id] = .some(output)
        return output
    }
    final class SectionState {
        let document: HDocument
        var section: HSection?, columnsSet = false, startNumberSet = false, pageNumber: XElement?
        init(_ d: HDocument) { document = d }
        var current: HSection { section ?? begin(nil) }
        @discardableResult func begin(_ value: HSection?) -> HSection {
            finish()
            let s = value ?? HSection()
            section = s
            columnsSet = false
            startNumberSet = s.startPageNumber != nil
            pageNumber = nil
            document.sections.append(s)
            return s
        }
        func finish() {
            guard let section, let control = pageNumber else { return }
            pageNumber = nil
            let position = HwpxReader.attr(control, "pos") ?? "BOTTOM_CENTER"
            if position == "NONE" { return }
            let side = HwpxReader.attr(control, "sideChar").flatMap { $0.isEmpty || $0 == "\0" ? nil : $0 }
            let p = HParagraph()
            p.format.align =
                position.hasSuffix("LEFT") || position.hasPrefix("INSIDE")
                ? .left : position.hasSuffix("RIGHT") || position.hasPrefix("OUTSIDE") ? .right : .center
            if let side { p.inlines.append(HText(side + " ")) }
            p.inlines.append(HField(.pageNumber))
            if let side { p.inlines.append(HText(" " + side)) }
            if position.contains("TOP") {
                if section.headers.isEmpty { section.headers.append(HHeaderFooter(.both)) }
                for h in section.headers { h.blocks.append(p) }
            } else {
                if section.footers.isEmpty { section.footers.append(HHeaderFooter(.both)) }
                for f in section.footers { f.blocks.append(p) }
            }
        }
    }
    func readSection(_ root: XElement, _ document: HDocument) throws {
        let state = SectionState(document)
        for e in Self.elements(root) {
            if e.name.localName == "p" {
                if let sec = Self.elements(e).filter({ $0.name.localName == "run" }).flatMap({ Self.elements($0) })
                    .first(where: { $0.name.localName == "secPr" })
                {
                    state.begin(Self.section(sec))
                    outlineNumberingId = Self.attr(sec, "outlineShapeIDRef")
                }
                state.current.blocks += try readParagraph(e, state)
            } else {
                skip(e)
            }
        }
        if state.section == nil { state.begin(nil) }
        state.finish()
    }
    static func section(_ s: XElement) -> HSection {
        let p = child(s, "pagePr")
        let m = child(p, "margin")
        var w = int(p, "width", 59530)
        var h = int(p, "height", 84190)
        if attr(p, "landscape") == "NARROWLY" { (w, h) = (max(w, h), min(w, h)) }
        let result = HSection()
        result.page = HPage(
            width: w, height: h, left: int(m, "left", 7200), right: int(m, "right", 7200), top: int(m, "top", 4255),
            bottom: int(m, "bottom", 4960), header: int(m, "header", 4250), footer: int(m, "footer", 2240),
            gutter: int(m, "gutter"))
        let v = child(s, "visibility")
        let start = int(child(s, "startNum"), "page")
        result.hideFirstHeader = flag(v, "hideFirstHeader")
        result.hideFirstFooter = flag(v, "hideFirstFooter")
        result.startPageNumber = start > 0 ? start : nil
        return result
    }
    static func columns(_ e: XElement) -> HColumns {
        let count = max(1, int(e, "colCount", 1))
        if count == 1 { return .single }
        let gap = flag(e, "sameSz", true) ? int(e, "sameGap") : int(child(e, "colSz"), "gap", int(e, "sameGap"))
        let line = child(e, "colLine")
        return HColumns(
            count: count, gap: gap, separator: line != nil && attr(line, "type") != nil && attr(line, "type") != "NONE")
    }
    static func elements(_ p: XElement?) -> [XElement] {
        (p?.elements() ?? []).flatMap { $0.name.localName == "switch" ? elements(branch($0).0) : [$0] }
    }
    static func branch(_ e: XElement) -> (XElement?, Bool) {
        for c in e.elements() where c.name.localName == "case" {
            let r = c.attributes.first { $0.name.localName == "required-namespace" }?.value ?? ""
            if r.contains("HwpUnitChar") || r == "http://www.hancom.co.kr/hwpml/2016/paragraph" { return (c, true) }
        }
        return (e.elements().first { $0.name.localName == "default" }, false)
    }
    static func child(_ e: XElement?, _ name: String) -> XElement? {
        for c in e?.elements() ?? [] {
            if c.name.localName == name { return c }
            if c.name.localName == "switch", let inner = child(branch(c).0, name) { return inner }
        }
        return nil
    }
    static func children(_ e: XElement?, _ name: String) -> [XElement] {
        elements(e).filter { $0.name.localName == name }
    }
    static func descendants(_ e: XElement?, _ name: String) -> [XElement] {
        (e?.descendants() ?? []).filter { $0.name.localName == name }
    }
    static func attr(_ e: XElement?, _ name: String) -> String? { e?.attributeValue(XName(name)) }
    static func int(_ e: XElement?, _ name: String, _ fallback: Int = 0) -> Int {
        guard let s = attr(e, name)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return fallback }
        if var n = Int64(s) {
            if n > Int32.max && n <= UInt32.max { n -= 1 << 32 }
            return Int(min(max(n, Int64(Int32.min)), Int64(Int32.max)))
        }
        guard let n = Double(s), n.isFinite else { return fallback }
        return Int(min(max(n.rounded(.toNearestOrEven), Double(Int32.min)), Double(Int32.max)))
    }
    static func flag(_ e: XElement?, _ n: String, _ fallback: Bool = false) -> Bool {
        guard let v = attr(e, n) else { return fallback }
        return v == "1" || v == "true"
    }
    static func color(_ v: String?) -> String? {
        guard let v, v.hasPrefix("#") else { return nil }
        let hex = String(v.dropFirst(v.utf16.count == 9 ? 3 : 1))
        return hex.utf16.count == 6 && Int(hex, radix: 16) != nil ? "#" + hex.uppercased() : nil
    }
    func skip(_ e: XElement) { skip(e.name.localName) }
    func skip(_ name: String) { skipped[name, default: 0] += 1 }
}
