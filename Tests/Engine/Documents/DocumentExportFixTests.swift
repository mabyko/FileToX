import Darwin
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FileToXEngineKit

final class DocumentExportFixTests: DocumentTestCase {
    private func directoryNames(_ path: String) throws -> [[UInt8]] {
        let directory = try XCTUnwrap(opendir(path))
        defer { closedir(directory) }
        var result: [[UInt8]] = []
        while let entry = readdir(directory) {
            let bytes = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.d_namlen)) {
                    Array(UnsafeBufferPointer(start: $0, count: Int(entry.pointee.d_namlen)))
                }
            }
            result.append(bytes)
        }
        return result
    }
    private func document(_ blocks: [HBlock]) -> HDocument {
        let d = HDocument(), s = HSection()
        s.blocks = blocks; d.sections = [s]
        return d
    }
    private func package(_ body: String, header: String = "<head/>", media: [(String, Data)] = []) throws -> String {
        let file = path(UUID().uuidString + ".hwpx")
        let zip = try ZipWriter(path: file)
        try zip.add("mimetype", text: "application/hwp+zip", level: .noCompression)
        try zip.add("Contents/header.xml", text: header)
        try zip.add("Contents/section0.xml", text: "<sec>\(body)</sec>")
        for (name, data) in media { try zip.add("BinData/\(name)", data: data) }
        try zip.close()
        return file
    }
    private func p(_ text: String) -> String { "<p><run><t>\(text)</t></run></p>" }
    private func table(_ blocks: [HBlock]) -> HTable {
        let t = HTable(), row = HRow(), cell = HCell()
        t.columnCount = 1; cell.blocks = blocks; row.cells = [cell]; t.rows = [row]
        return t
    }
    private func exports(_ doc: HDocument) -> [String] {
        [PlainTextWriter.write(doc), MarkdownWriter.write(doc) { _ in nil },
         XhtmlWriter.write(doc, XhtmlOptions(imageSource: { _ in nil }))[0].body]
    }
    func testUnreadableWmfIsDroppedWithoutFailing() async throws {
        let input = try package("<p><run><pic><img binaryItemIDRef=\"BIN0001\"/></pic><t>본문 유지</t></run></p>",
                                media: [("BIN0001.wmf", Data([0xD7, 0xCD, 0xC6, 0x9A]))])
        for format in ["md", "html", "txt"] {
            let output = try await convert(UnhwpConverter(), input, "hwpx", format, "wmf.\(format)")
            let content = try String(contentsOfFile: output, encoding: .utf8)
            XCTAssertTrue(content.contains("본문 유지"))
            XCTAssertFalse(content.contains("<img"))
            XCTAssertFalse(content.contains("![]"))
        }
    }
    func testBmpBecomesPngAndSidecarSurvivesCommit() async throws {
        let png = path("original.png")
        _ = try DocumentFixtures.png(png, 5, 3)
        let bmp = path("original.bmp")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: bmp) as CFURL, UTType.bmp.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try ImageSupport.cgImage(png), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: bmp))
        let input = try package("<p><run><pic><img binaryItemIDRef=\"BIN0001\"/></pic><pic><img binaryItemIDRef=\"BIN0001\"/></pic></run></p>", media: [("BIN0001.bmp", bytes)])
        let final = path("한글 (그림)#1.md")
        let staging = StagedOutputs()
        let staged = try staging.stage(final)
        _ = try await convert(UnhwpConverter(), input, "hwpx", "md", staged)
        var outputs: [String] = []
        try staging.commit([staged], &outputs, OutputRule(), [input], { _ in })
        XCTAssertEqual(outputs, [final])
        let markdown = try String(contentsOfFile: final, encoding: .utf8)
        XCTAssertFalse(markdown.contains("data:"))
        let target = "%ED%95%9C%EA%B8%80%20%28%EA%B7%B8%EB%A6%BC%29%231_files/img0001.png"
        XCTAssertEqual(markdown.components(separatedBy: target).count - 1, 2)
        let image = path("한글 (그림)#1_files/img0001.png")
        XCTAssertTrue((try Data(contentsOf: URL(fileURLWithPath: image))).starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(ImageSupport.info(image)?.width, 5)
        XCTAssertTrue(try directoryNames(folder).contains(Array("한글 (그림)#1_files".utf8)))
        XCTAssertTrue(try directoryNames(path("한글 (그림)#1_files")).contains(Array("img0001.png".utf8)))
        let html = try await convert(UnhwpConverter(), input, "hwpx", "html", "bmp.html")
        XCTAssertTrue(try String(contentsOfFile: html, encoding: .utf8).contains("data:image/png;base64,"))
    }
    func testCommonImagesKeepOriginalBytesAndOpaqueTiffBecomesJpeg() throws {
        let png = path("keep.png"), bytes = try DocumentFixtures.png(path("keep.png"), 2, 2)
        XCTAssertEqual(EbookFiles.commonImage(png, path("converted"), true)?.file, png)
        XCTAssertEqual(try EbookFiles.dataUri(png, folder),
                       "data:image/png;base64," + bytes.base64EncodedString())
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let tiff = path("opaque.tiff")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: tiff) as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let common = try XCTUnwrap(EbookFiles.commonImage(tiff, path("converted"), true))
        XCTAssertEqual(common.mediaType, "image/jpeg")
    }
    func testListsStartAtZeroIndentAndKeepNestedLevels() throws {
        let n = HNumbering(); n.levels = (0..<6).map { _ in HNumberingLevel("DIGIT", "^1.", 1, true) }
        let ps = [DocumentFixtures.p("첫 항목"), DocumentFixtures.p("하위 항목"), DocumentFixtures.p("둘째 항목")]
        for (p, level) in zip(ps, [2, 4, 2]) { p.list = HListRef(n, level, true) }
        let md = MarkdownWriter.write(document(ps)) { _ in nil }
        XCTAssertEqual(md, "- 첫 항목\n    - 하위 항목\n- 둘째 항목\n")
        let source = try write(md, "lists.md")
        let pandoc = FileManager.default.currentDirectoryPath + "/build/optional-engines/osx-arm64/pandoc/bin/pandoc"
        guard FileManager.default.isExecutableFile(atPath: pandoc) else { throw XCTSkip("Development Pandoc is missing") }
        let rendered = try ProcessRunner.runBlocking(pandoc, ["-f", "commonmark_x", "-t", "html", source], timeout: 30)
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertEqual(rendered.standardOutput.components(separatedBy: "<li>").count - 1, 3)
        XCTAssertFalse(rendered.standardOutput.contains("<pre>"))
    }
    func testNestedTablesAndTextBoxesPreserveText() {
        let inner = table([DocumentFixtures.p("안쪽 첫 행")])
        let second = HRow(), c = HCell(); c.blocks = [DocumentFixtures.p("안쪽 둘째 행")]; second.cells = [c]; inner.rows.append(second)
        let outer = table([DocumentFixtures.p("바깥"), inner, DocumentFixtures.p("끝")])
        let box = HTextBox(); box.blocks = [table([DocumentFixtures.p("글상자 표")])]
        let p = HParagraph(); p.inlines = [box]
        let doc = document([outer, p])
        for content in exports(doc) {
            for text in ["바깥", "안쪽 첫 행", "안쪽 둘째 행", "끝", "글상자 표"] { XCTAssertTrue(content.contains(text), content) }
        }
        XCTAssertTrue(MarkdownWriter.write(doc) { _ in nil }.contains("바깥<br>안쪽 첫 행<br>안쪽 둘째 행<br>끝"))
    }
    func testTableCellBreaksStayInsideOneMarkdownRow() {
        let p = HParagraph(); p.inlines = [HText("첫 줄"), HLineBreak(), HText("둘째 줄")]
        let doc = document([table([p, DocumentFixtures.p("다음 문단")])])
        let md = MarkdownWriter.write(doc) { _ in nil }
        XCTAssertTrue(md.contains("| 첫 줄<br>둘째 줄<br>다음 문단 |"))
        XCTAssertTrue(PlainTextWriter.write(doc).contains("첫 줄 둘째 줄 다음 문단"))
    }
    func testFigureAndTableCaptionsAreReadAndWritten() throws {
        let input = try package("<p><run><pic><caption><subList>\(p("Fig. 1 그림"))</subList></caption></pic></run></p><p><run><tbl colCnt=\"1\"><caption><subList>\(p("Table 1 표"))</subList></caption><tr><tc><subList>\(p("셀"))</subList></tc></tr></tbl></run></p>")
        let doc = try HwpxReader.read(input, path("media"))
        for content in exports(doc) {
            XCTAssertTrue(content.contains("Fig. 1 그림")); XCTAssertTrue(content.contains("Table 1 표"))
        }
    }
    func testOutlineStylesAndNumberedHeadingsProduceHeadingTags() throws {
        let header = "<head><styles><style id=\"1\" name=\"개요 1\" engName=\"Outline 1\"/><style id=\"2\" name=\"제목 2\"/><style id=\"3\" engName=\"Heading 3\"/></styles><paraPr id=\"1\"><heading type=\"OUTLINE\" idRef=\"1\" level=\"3\"/></paraPr><numberings><numbering id=\"1\"><paraHead level=\"1\" numFormat=\"DIGIT\">^1.</paraHead><paraHead level=\"4\" numFormat=\"DIGIT\">^4.</paraHead></numbering></numberings></head>"
        let body = (1...3).map { "<p styleIDRef=\"\($0)\"><run><t>제목\($0)</t></run></p>" }.joined()
            + "<p paraPrIDRef=\"1\"><run><t>제목4</t></run></p>"
        let doc = try HwpxReader.read(package(body, header: header), path("media"))
        let md = MarkdownWriter.write(doc) { _ in nil }
        let html = XhtmlWriter.write(doc, XhtmlOptions(imageSource: { _ in nil }))[0].body
        for i in 1...4 { XCTAssertTrue(md.contains(String(repeating: "#", count: i) + " 제목\(i)")); XCTAssertTrue(html.contains("<h\(i) ")) }
    }
    func testMidSectionHeadersPreserveEveryDefinitionInOrder() throws {
        let first = "<header applyPageType=\"BOTH\"><subList>\(p("머리말 처음"))</subList></header>"
        let next = "<header applyPageType=\"BOTH\"><subList>\(p("머리말 변경"))</subList></header>"
        let nested = "<header applyPageType=\"BOTH\"><subList>\(p("표 안 머리말"))</subList></header>"
        let input = try package("<p><run><ctrl>\(first)</ctrl><t>본문1</t></run></p><p><run><ctrl>\(next)</ctrl><t>본문2</t></run></p><p><run><tbl><tr><tc><subList><p><run><ctrl>\(nested)</ctrl><t>표 본문</t></run></p></subList></tc></tr></tbl></run></p>")
        let doc = try HwpxReader.read(input, path("media"))
        XCTAssertEqual(doc.sections[0].headers.map(\.startBlockIndex), [0, 1, 2])
        for content in exports(doc) {
            let ranges = ["머리말 처음", "본문1", "머리말 변경", "본문2", "표 안 머리말", "표 본문"].map { content.range(of: $0) }
            XCTAssertTrue(ranges.allSatisfy { $0 != nil })
            if ranges.allSatisfy({ $0 != nil }) { XCTAssertEqual(ranges.map { $0!.lowerBound }, ranges.map { $0!.lowerBound }.sorted()) }
        }
    }
    func testEquationModelKeepsScriptAndDisplayMode() throws {
        let input = try package("<p><run><equation lineMode=\"CHAR\"><script>x over y</script></equation><equation lineMode=\"LINE\"><script>SQRT{5}</script></equation><equation/><t>끝</t></run></p>")
        let doc = try HwpxReader.read(input, path("media"))
        let eqs = HDocumentWalker.inlines(doc.sections[0].blocks).compactMap { $0 as? HEquation }
        XCTAssertEqual(eqs.count, 3); XCTAssertEqual(eqs[0].text, "x over y"); XCTAssertTrue(eqs[1].display)
        XCTAssertTrue(MarkdownWriter.write(doc) { _ in nil }.contains("$\\frac{x}{y}$ $$\\sqrt{5}$$ [unhwp:equation-unsupported]"))
    }
    func testMarkdownPreservesLeadingWhitespaceInOrdinaryParagraphs() {
        for prefix in ["  ", "\t", "\u{3000}\u{3000}"] {
            let paragraph = HParagraph()
            paragraph.inlines = [HText(prefix + "FileToX sample")]
            XCTAssertEqual(MarkdownWriter.write(document([paragraph])) { _ in nil }, prefix + "FileToX sample\n")
        }
    }
    func testUnknownKeywordsAndEmptyEquations() {
        XCTAssertEqual(HwpEquationConverter.toLatex("eqalign{x}"), "eqalign{x}")
        XCTAssertEqual(HwpEquationConverter.toLatex("RM IT"), "")
        let doc = HDocument(), section = HSection(), p = HParagraph()
        p.inlines = [HEquation(""), HText(" "), HEquation("RM IT"), HText(" "), HEquation("x over y"), HEquation("SQRT{5}", display: true)]
        section.blocks = [p]; doc.sections = [section]
        let md = MarkdownWriter.write(doc) { _ in nil }
        XCTAssertTrue(md.contains("[unhwp:equation-unsupported]"))
        XCTAssertTrue(md.contains("`RM IT`"))
        XCTAssertTrue(md.contains("$\\frac{x}{y}$"))
        XCTAssertTrue(md.contains("$$\\sqrt{5}$$"))
        XCTAssertTrue(PlainTextWriter.write(doc).contains("\\frac{x}{y}"))
        let html = XhtmlWriter.write(doc, XhtmlOptions(imageSource: { _ in nil }))[0].body
        XCTAssertTrue(html.contains("<span class=\"math inline\">\\(\\frac{x}{y}\\)</span>"))
    }
}
