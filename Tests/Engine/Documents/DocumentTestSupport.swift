import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import FileToXEngineKit

class DocumentTestCase: XCTestCase {
    var folder = ""
    override func setUpWithError() throws {
        if let root = ProcessInfo.processInfo.environment["FILETOX_DOCUMENT_FIXTURE_OUTPUT"] {
            folder = FilePath.combine(
                root, String(describing: type(of: self)), name.replacingOccurrences(of: "/", with: "_"))
        } else {
            folder = FilePath.combine(
                FileManager.default.temporaryDirectory.path, "filetox-documents-" + UUID().uuidString)
        }
        try FileManager.default.createDirectoryIfNeeded(folder)
    }
    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["FILETOX_DOCUMENT_FIXTURE_OUTPUT"] == nil {
            try FileManager.default.removeItem(atPath: folder)
        }
    }
    func path(_ name: String) -> String { FilePath.combine(folder, name) }
    func write(_ text: String, _ name: String) throws -> String {
        let p = path(name)
        try Data(text.utf8).write(to: URL(fileURLWithPath: p))
        return p
    }
    func convert(_ converter: Converter, _ input: String, _ from: String, _ to: String, _ name: String) async throws
        -> String
    {
        let out = path(name)
        let step = ConversionStep(
            inputPath: input, from: from, to: to, preset: Preset(), output: DocumentFixedPath(out), workDirectory: folder)
        let outputs = try await converter.convert(step, progress: nil)
        XCTAssertEqual(outputs, [out])
        return out
    }
    func requireRhwp() throws { if RhwpConverter.locate() == nil { throw XCTSkip("Bundled rhwp is missing") } }
    func markdown(_ text: String) throws -> HDocument {
        do { return try MarkdownReader.read(text, folder) } catch let e as ConversionError
            where e.message == "not ported yet"
        { throw XCTSkip("MarkdownReader is pending cross-group integration") }
    }
}
final class DocumentFixedPath: OutputAllocator {
    let path: String?
    init(_ path: String?) { self.path = path }
    func allocate(_ extension: String, suffix: String?) throws -> String? { path }
}
enum DocumentFixtures {
    static func p(_ text: String, _ format: HCharFormat = HCharFormat()) -> HParagraph {
        let p = HParagraph()
        p.inlines.append(HText(text, format))
        return p
    }
    static func png(_ path: String, _ width: Int = 120, _ height: Int = 60) throws -> Data {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: color,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.58, green: 0.44, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (data as Data).write(to: URL(fileURLWithPath: path))
        return data as Data
    }
    static func workbook() -> Workbook {
        let book = Workbook()
        let sheet = Worksheet("매출")
        var header = CellStyle()
        header.bold = true
        header.fill = "#1F4E79"
        header.color = "#FFFFFF"
        sheet.set(0, 0, SheetCell("지점별 매출", header))
        sheet.set(1, 0, SheetCell("지점", header))
        sheet.set(1, 1, SheetCell("매출", header))
        sheet.set(2, 0, SheetCell("서울", .default))
        sheet.set(2, 1, SheetCell("1,350,000원", .default, isNumber: true, value: 1_350_000, numberFormat: "#,##0원"))
        sheet.merges = [CellRange(0, 0, 0, 1)]
        sheet.frozenRows = 2
        book.sheets.append(sheet)
        return book
    }
}

final class DocxBuilder {
    static let namespaces =
        DocxWriter.namespaces
        + " xmlns:wpg=\"http://schemas.microsoft.com/office/word/2010/wordprocessingGroup\" xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:w10=\"urn:schemas-microsoft-com:office:word\""
    static let defaultPage =
        "<w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
    var body = "", sectionProperties = defaultPage, styles = defaultStyles, numbering: String?, settings: String?
    var relationships: [(id: String, type: String, target: String, external: Bool)] = [],
        parts: [(String, String)] = [], media: [(String, Data)] = []
    @discardableResult func paragraph(_ xml: String) -> DocxBuilder {
        body += xml
        return self
    }
    func relationship(_ kind: String, _ target: String, _ external: Bool = false) -> String {
        let id = "rId\(relationships.count+10)"
        relationships.append((id, DocxWriter.relationshipBase + kind, target, external))
        return id
    }
    @discardableResult func part(_ kind: String, _ xml: String) -> String {
        let n =
            kind == "header" || kind == "footer"
            ? kind + String(parts.filter { $0.0.hasPrefix(kind) }.count + 1) + ".xml" : kind + ".xml"
        parts.append((n, xml))
        return relationship(kind, n)
    }
    func header(_ p: String) -> String { part("header", "<w:hdr \(Self.namespaces)>\(p)</w:hdr>") }
    func footer(_ p: String) -> String { part("footer", "<w:ftr \(Self.namespaces)>\(p)</w:ftr>") }
    func image(_ data: Data) -> String {
        let n = "media/image\(media.count+1).png"
        media.append(("word/" + n, data))
        return relationship("image", n)
    }
    func hyperlink(_ url: String) -> String { relationship("hyperlink", url, true) }
    func footnotes(_ n: String) {
        part(
            "footnotes",
            "<w:footnotes \(Self.namespaces)><w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>\(n)</w:footnotes>"
        )
    }
    func endnotes(_ n: String) {
        part(
            "endnotes",
            "<w:endnotes \(Self.namespaces)><w:endnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:endnote>\(n)</w:endnotes>"
        )
    }
    @discardableResult func save(_ path: String) throws -> String {
        if let n = numbering { part("numbering", "<w:numbering \(Self.namespaces)>\(n)</w:numbering>") }
        if let s = settings { part("settings", "<w:settings \(Self.namespaces)>\(s)</w:settings>") }
        part("styles", "<w:styles \(Self.namespaces)>\(styles)</w:styles>")
        let zip = try ZipWriter(path: path)
        let overrides = parts.map { n, _ in
            "<Override PartName=\"/word/\(n)\" ContentType=\"\(DocxWriter.contentTypeBase)\(n.hasPrefix("header") ? "header" : n.hasPrefix("footer") ? "footer" : FilePath.fileNameWithoutExtension(n))+xml\"/>"
        }.joined()
        try zip.add(
            "[Content_Types].xml",
            text:
                "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"\(DocxWriter.contentTypeBase)document.main+xml\"/>\(overrides)</Types>"
        )
        try zip.add(
            "_rels/.rels",
            text:
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(DocxWriter.relationshipBase)officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        )
        let rels = relationships.map {
            "<Relationship Id=\"\($0.id)\" Type=\"\($0.type)\" Target=\"\(HwpxWriter.escape($0.target))\"\($0.external ? " TargetMode=\"External\"" : "")/>"
        }.joined()
        try zip.add(
            "word/_rels/document.xml.rels",
            text:
                "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>"
        )
        try zip.add(
            "word/document.xml",
            text:
                "<w:document \(Self.namespaces)><w:body>\(body)<w:sectPr>\(sectionProperties)</w:sectPr></w:body></w:document>"
        )
        for (n, s) in parts { try zip.add("word/" + n, text: s) }
        for (n, data) in media { try zip.add(n, data: data) }
        try zip.close()
        return path
    }
    static func p(_ runs: String, _ props: String = "") -> String { "<w:p><w:pPr>\(props)</w:pPr>\(runs)</w:p>" }
    static func r(_ text: String, _ props: String = "") -> String {
        "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(HwpxWriter.escape(text))</w:t></w:r>"
    }
    static func field(_ instruction: String, _ result: String) -> String {
        "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> \(instruction) </w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>\(r(result))<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
    }
    static func picture(_ id: String, _ cx: Int, _ cy: Int) -> String {
        "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"1\" name=\"p\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(id)\"/></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"/></pic:spPr></pic:pic>"
    }
    static func inlinePicture(_ id: String, _ cx: Int, _ cy: Int) -> String {
        "<w:r><w:drawing><wp:inline><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"2\" name=\"i\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">\(picture(id,cx,cy))</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }
    static func anchor(
        _ uri: String, _ graphic: String, _ cx: Int, _ cy: Int, _ horizontal: String, _ vertical: String,
        _ wrap: String = "<wp:wrapSquare wrapText=\"bothSides\"/>"
    ) -> String {
        "<w:r><w:drawing><wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" simplePos=\"0\" relativeHeight=\"1\" behindDoc=\"0\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"1\"><wp:simplePos x=\"0\" y=\"0\"/>\(horizontal)\(vertical)<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>\(wrap)<wp:docPr id=\"1\" name=\"obj\"/><a:graphic><a:graphicData uri=\"\(uri)\">\(graphic)</a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>"
    }
}

extension DocxBuilder {
    static let defaultStyles = #"""
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="맑은 고딕" w:eastAsia="맑은 고딕" w:hAnsi="맑은 고딕"/><w:sz w:val="20"/></w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders>
          <w:top w:val="single" w:sz="4" w:color="000000"/><w:left w:val="single" w:sz="4" w:color="000000"/><w:bottom w:val="single" w:sz="4" w:color="000000"/>
          <w:right w:val="single" w:sz="4" w:color="000000"/><w:insideH w:val="single" w:sz="4" w:color="000000"/><w:insideV w:val="single" w:sz="4" w:color="000000"/>
        </w:tblBorders></w:tblPr></w:style>
        """#
}
