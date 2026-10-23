// Behavioral port of Filee.Engines.Tests/EbookTests.cs. The low-level cases live in EbookFoundationTests.
import Foundation
import XCTest
import PDFKit
@testable import FileToXEngineKit

final class EbookTests: EbookTestCase {
    private func epubText(_ path: String) throws -> String { try PlainTextWriter.write(EpubReader.readBook(path, folder).document) }
    private func validEpub(_ path: String) throws -> (title: String, language: String, authors: [String], chapters: Int, images: Int, toc: String, allText: String, hasCover: Bool) {
        let zip = try ZipReader(path: path)
        XCTAssertEqual(zip.entries.first?.name, "mimetype"); XCTAssertEqual(zip.entries.first?.method, 0)
        XCTAssertEqual(try zip.string(named: "mimetype"), "application/epub+zip")
        let container = try XDocument.parse(XCTUnwrap(zip.string(named: "META-INF/container.xml")))
        let rootFile = try XCTUnwrap(container.root.descendants().first { $0.name.localName == "rootfile" }?.attributeValue("full-path"))
        let opf = try XDocument.parse(XCTUnwrap(zip.string(named: rootFile))), root = opf.root, folder = FilePath.directoryName(rootFile) ?? ""
        let manifest = try XCTUnwrap(root.elements().first { $0.name.localName == "manifest" }), items = manifest.elements()
        var files: [String: String] = [:]
        for item in items {
            let href = try XCTUnwrap(item.attributeValue("href")), id = try XCTUnwrap(item.attributeValue("id"))
            let path = FilePath.combine(folder, href.removingPercentEncoding ?? href)
            XCTAssertNotNil(zip.entry(named: path), path); files[id] = path
        }
        let spine = try XCTUnwrap(root.elements().first { $0.name.localName == "spine" })
        for ref in spine.elements() { XCTAssertNotNil(files[ref.attributeValue("idref") ?? ""]) }
        let metadata = try XCTUnwrap(root.elements().first { $0.name.localName == "metadata" })
        let title = try XCTUnwrap(metadata.descendants().first { $0.name.localName == "title" }?.value)
        let language = try XCTUnwrap(metadata.descendants().first { $0.name.localName == "language" }?.value)
        let authors = metadata.descendants().filter { $0.name.localName == "creator" }.map(\.value)
        let nav = try XCTUnwrap(items.first { ($0.attributeValue("properties") ?? "").components(separatedBy: " ").contains("nav") })
        let toc = try XCTUnwrap(zip.string(named: FilePath.combine(folder, nav.attributeValue("href")!)))
        _ = try XDocument.parse(toc)
        let ncx = try XCTUnwrap(items.first { $0.attributeValue("media-type") == "application/x-dtbncx+xml" })
        _ = try XDocument.parse(XCTUnwrap(zip.string(named: FilePath.combine(folder, ncx.attributeValue("href")!))))
        let allText = try zip.entries.filter { $0.name.hasSuffix(".xhtml") }.map { String(decoding: try zip.data(for: $0), as: UTF8.self) }.joined()
        return (title, language, authors, spine.elements().count, items.filter { ($0.attributeValue("media-type") ?? "").hasPrefix("image/") }.count, toc, allText, items.contains { ($0.attributeValue("properties") ?? "").contains("cover-image") })
    }
    func testEpubReaderKeepsChaptersLinksPicturesAndMetadata() throws {
        let book = try EpubReader.readBook(EbookBuilders.epub(folder), folder)
        XCTAssertEqual(book.metadata.title, "별빛 이야기"); XCTAssertEqual(book.metadata.authors, ["김작가"]); XCTAssertEqual(book.metadata.language, "ko")
        XCTAssertTrue(book.metadata.coverImage?.hasSuffix("cover.png") == true)
        let blocks = book.document.sections[0].blocks, headings = blocks.compactMap { $0 as? HParagraph }.filter { $0.headingLevel == 1 }
        XCTAssertEqual(headings.map { HDocumentWalker.text($0.inlines) }, ["첫 번째 장", "두 번째 장", "세 번째 장"])
        XCTAssertEqual(headings.map(\.pageBreakBefore), [false, true, true])
        let all = inlines(book.document), links = all.compactMap { $0 as? HLink }
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(all.compactMap { $0 as? HBookmark }.contains { "#" + $0.name == links.first?.target })
        XCTAssertEqual(all.filter { $0 is HImage }.count, 1); XCTAssertEqual(blocks.filter { $0 is HTable }.count, 1)
        XCTAssertTrue(all.contains { ($0 as? HText).map { $0.text == "크게" && $0.format.bold == true } == true })
        XCTAssertTrue(all.contains { ($0 as? HText)?.text == "빈 div 다음 문단" })
    }
    func testEpubToTxtHtmlAndMarkdown() async throws {
        let epub = try EbookBuilders.epub(folder)
        let txt = try await convert(epub, "epub", "txt"), bytes = try Data(contentsOf: URL(fileURLWithPath: txt))
        XCTAssertTrue(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = TextEncodings.decodeText(bytes)
        for expected in ["첫 번째 장", "밤하늘에 별이 반짝였다.", "주석 내용입니다.", "● 목록 하나", "이름\t값"] { XCTAssertTrue(text.contains(expected), expected) }
        XCTAssertFalse(text.contains("<"))
        let html = try String(contentsOfFile: await convert(epub, "epub", "html"), encoding: .utf8)
        for expected in ["<h1 id=\"_h1\">첫 번째 장</h1>", "src=\"data:image/png;base64,", "<b>별</b>", "<title>별빛 이야기</title>"] { XCTAssertTrue(html.contains(expected), expected) }
        let md = try await convert(epub, "epub", "md"), markdown = try String(contentsOfFile: md, encoding: .utf8)
        for expected in ["# 첫 번째 장", "**별**", "| 이름 | 값 |"] { XCTAssertTrue(markdown.contains(expected), expected) }
        let match = try XCTUnwrap(EbookRegex.matches(#"!\[\]\(<([^>]+)>\)"#, markdown).first)
        let image = EbookRegex.group(match, markdown, 1)
        XCTAssertTrue(FileManager.default.fileExists(FilePath.combine(FilePath.directoryName(md)!, image.removingPercentEncoding ?? image)))
    }
    func testMarkdownToEpubIsValidAndReadsBack() async throws {
        _ = try save("그림.png", EbookBuilders.picture(120, 80))
        let markdown = """
        ---
        title: 마크다운 책
        ---

        # 1장 시작

        첫 문단에 **굵게**와 [링크](https://example.com)가 있습니다.[^1]

        ![그림](그림.png)

        ## 1.1 절

        - 하나
        - 둘

        # 2장 끝

        | A | B |
        |---|---|
        | 1 | 2 |

        [^1]: 각주입니다.
        """
        let source = try save("책.md", Data(markdown.utf8)), epub = try await convert(source, "md", "epub"), package = try validEpub(epub)
        XCTAssertEqual(package.title, "마크다운 책"); XCTAssertEqual(package.language, "ko"); XCTAssertEqual(package.chapters, 2); XCTAssertEqual(package.images, 1)
        XCTAssertTrue(package.toc.contains("1장 시작")); XCTAssertTrue(package.toc.contains("1.1 절"))
        let text = try epubText(epub)
        for expected in ["1장 시작", "굵게", "하나", "2장 끝", "각주입니다."] { XCTAssertTrue(text.contains(expected), expected) }
    }
    func testTextHtmlAndDocxBecomeEpub() async throws {
        let txt = try save("메모.txt", Data("첫 문단의 첫 줄\n같은 문단\n\n둘째 문단".utf8))
        let html = try save("page.html", Data("<html><head><title>웹 페이지</title></head><body><h1>제목</h1><p>본문</p></body></html>".utf8))
        let docx = path("워드.docx"), zip = try ZipWriter(path: docx)
        try zip.add("[Content_Types].xml", text: "<Types xmlns='http://schemas.openxmlformats.org/package/2006/content-types'><Override PartName='/word/document.xml' ContentType='application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml'/></Types>")
        try zip.add("_rels/.rels", text: "<Relationships xmlns='http://schemas.openxmlformats.org/package/2006/relationships'><Relationship Id='r1' Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' Target='word/document.xml'/></Relationships>")
        try zip.add("word/document.xml", text: "<w:document xmlns:w='http://schemas.openxmlformats.org/wordprocessingml/2006/main'><w:body><w:p><w:r><w:t>워드 문서 본문</w:t></w:r></w:p></w:body></w:document>")
        try zip.close()
        let fromText = try await convert(txt, "txt", "epub"); _ = try validEpub(fromText)
        XCTAssertTrue(try epubText(fromText).contains("둘째 문단"))
        let fromHtml = try await convert(html, "html", "epub")
        XCTAssertEqual(try validEpub(fromHtml).title, "웹 페이지")
        let fromDocx = try await convert(docx, "docx", "epub")
        XCTAssertTrue(try epubText(fromDocx).contains("워드 문서 본문"))
    }
    func testMobiToEpubAllCompressionSchemes() async throws {
        let original = """
        <html><head><guide><reference type="toc" title="Contents" filepos=0000000000 /></guide></head><body>
        <h1>Chapter One</h1>
        <p>It was a <b>dark</b> and stormy night; the rain fell in torrents — except at occasional intervals.</p>
        <p>See <a filepos=FILEPOS>the note</a> below. Ünïcödé text and 한글 too.</p>
        <p><img recindex="00001" /></p>
        <mbp:pagebreak/>
        <h1>Chapter Two</h1>
        <p>The note is here.</p>
        </body></html>
        """
        let placeholder = original.replacingOccurrences(of: "FILEPOS", with: "0000000000"), target = placeholder[..<placeholder.range(of: "<p>The note")!.lowerBound].utf8.count
        let source = original.replacingOccurrences(of: "FILEPOS", with: String(format: "%010d", target))
        for compression in [1, 2, 17480] {
            let data = EbookBuilders.mobi(Data(source.utf8), [try EbookBuilders.picture(64, 32), try EbookBuilders.picture(100, 150)], EbookBuilders.MobiOptions(compression: compression, cover: 1, title: "Stormy Night", author: "E. Bulwer-Lytton"))
            let mobi = try save("book\(compression).mobi", data), epub = try await convert(mobi, "mobi", "epub"), package = try validEpub(epub)
            XCTAssertEqual(package.title, "Stormy Night"); XCTAssertEqual(package.authors, ["E. Bulwer-Lytton"]); XCTAssertEqual(package.images, 2); XCTAssertTrue(package.hasCover)
            let book = try EpubReader.readBook(epub, folder), text = try PlainTextWriter.write(book.document)
            for expected in ["Chapter One", "dark and stormy night", "Ünïcödé text and 한글 too", "Chapter Two", "The note is here."] { XCTAssertTrue(text.contains(expected), "\(compression): \(expected)") }
            let all = inlines(book.document), link = try XCTUnwrap(all.compactMap { $0 as? HLink }.first)
            XCTAssertTrue(all.compactMap { $0 as? HBookmark }.contains { "#" + $0.name == link.target })
            XCTAssertTrue(all.contains { ($0 as? HText).map { $0.text == "dark" && $0.format.bold == true } == true })
        }
    }
    func testPalmDocTextBooksReadAsText() async throws {
        let bytes = Data("Plain PalmDOC text.\n\nSecond paragraph of the book.".utf8)
        var header = Data(repeating: 0, count: 16); header[1] = 2; header[9] = 1
        BinaryPrimitives.writeUInt32BigEndian(&header, 4, UInt32(bytes.count))
        let source = try save("old.prc", EbookBuilders.palmDb("Old Book", "TEXtREAd", [header, EbookBuilders.palmDocCompress(bytes)]))
        let txt = try await convert(source, "prc", "txt"), text = TextEncodings.decodeText(try Data(contentsOf: URL(fileURLWithPath: txt)))
        XCTAssertTrue(text.contains("Plain PalmDOC text.")); XCTAssertTrue(text.contains("Second paragraph of the book."))
    }
    func testFb2ToEpubKeepsNotesCoverAndLegacyEncoding() async throws {
        let epub = try await convert(EbookBuilders.fb2(folder), "fb2", "epub"), package = try validEpub(epub)
        XCTAssertEqual(package.title, "Война и мир"); XCTAssertEqual(package.authors, ["Лев Толстой"]); XCTAssertEqual(package.language, "ru"); XCTAssertTrue(package.hasCover)
        XCTAssertTrue(package.toc.contains("Глава первая")); XCTAssertTrue(package.allText.contains("epub:type=\"footnote\""))
        let text = try epubText(epub)
        for expected in ["Первый абзац и курсив.", "Строка стиха один", "Текст подглавы.", "Цитата из книги.", "Текст примечания."] { XCTAssertTrue(text.contains(expected), expected) }
    }
    func testEpubToFb2RoundTrips() async throws {
        let source = try EbookBuilders.epub(folder), fb2 = try await convert(source, "epub", "fb2"), xml = try XDocument.load(fb2), ns = XNamespace("http://www.gribuser.ru/xml/fictionbook/2.0")
        XCTAssertEqual(xml.root.descendants(ns + "book-title").first?.value, "별빛 이야기")
        XCTAssertEqual(xml.root.element(ns + "body")?.elements(ns + "section").count, 3)
        XCTAssertEqual(xml.root.descendants(ns + "binary").count, 2)
        let book = try Fb2Reader.readBook(fb2, folder), text = try PlainTextWriter.write(book.document)
        for expected in ["첫 번째 장", "밤하늘에 별이 반짝였다.", "주석 내용입니다.", "목록 하나"] { XCTAssertTrue(text.contains(expected), expected) }
        XCTAssertTrue(inlines(book.document).contains { ($0 as? HText).map { $0.text == "별" && $0.format.bold == true } == true })
    }
    func testHtmlzAndTxtzWrittenAndRead() async throws {
        let source = try EbookBuilders.epub(folder), htmlz = try await convert(source, "epub", "htmlz"), zip = try ZipReader(path: htmlz)
        XCTAssertNotNil(zip.entry(named: "index.html")); XCTAssertNotNil(zip.entry(named: "metadata.opf")); XCTAssertTrue(zip.entries.contains { $0.name.hasPrefix("images/") })
        let txt = try await convert(htmlz, "htmlz", "txt"), text = TextEncodings.decodeText(try Data(contentsOf: URL(fileURLWithPath: txt)))
        XCTAssertTrue(text.contains("주석 내용입니다."))
        let txtz = try await convert(source, "epub", "txtz"), book = try ZippedText.readTxtzBook(txtz, folder)
        XCTAssertEqual(book.metadata.title, "별빛 이야기"); XCTAssertEqual(HDocumentWalker.images(book.document).count, 1)
        XCTAssertTrue(try PlainTextWriter.write(book.document).contains("밤하늘에"))
    }
    func testEpubToHwpxPreservesChapterPageBreaks() async throws {
        let output = try await convert(EbookBuilders.epub(folder), "epub", "hwpx"), zip = try ZipReader(path: output)
        let section = try XCTUnwrap(zip.string(named: "Contents/section0.xml"))
        XCTAssertTrue(section.contains("첫 번째 장")); XCTAssertTrue(section.contains("두 번째 장")); XCTAssertTrue(section.contains("세 번째 장"))
    }
}
