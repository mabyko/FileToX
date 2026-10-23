// Port of Filee.Engines.Tests/HtmlReaderTests.cs: the built-in HTML reader (libxml2 here, AngleSharp in Filee) and
// the XHTML writer: structure, formatting, lists, tables, pictures, links, encodings and XHTML quirks. The planner and
// HWPX facts (Html_to_pdf_needs_no_optional_engine, Html_becomes_hwpx_and_pdf_with_built_in_engines) need the core
// catalog and the HWPX writer and belong with those ports.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class HtmlReaderTests: XCTestCase {
    private var folders: [String] = []

    override func tearDown() {
        for folder in folders { FileManager.default.removeIfPresent(folder) }
        super.tearDown()
    }

    private func newFolder() throws -> String {
        let folder = try MarkupTestSupport.newFolder()
        folders.append(folder)
        return folder
    }

    private func parse(_ html: String, _ folder: String? = nil) throws -> HtmlContent {
        let base = try folder ?? newFolder()
        return try HtmlReader.parse(html, HtmlReadOptions(baseFolder: base, mediaFolder: FilePath.combine(base, "media")))
    }

    private func paragraphs(_ content: HtmlContent) -> [HParagraph] { content.blocks.compactMap { $0 as? HParagraph } }

    private func text(_ paragraph: HParagraph) -> String { HDocumentWalker.text(paragraph.inlines) }

    private func run(_ content: HtmlContent, _ text: String) throws -> HText {
        try XCTUnwrap(content.blocks.flatMap { HDocumentWalker.inlines([$0]) }.compactMap { $0 as? HText }.first { $0.text.contains(text) }, text)
    }

    func testHeadingsParagraphsAndInlineFormatting() throws {
        let content = try parse("""
            <html><head><title>제목 </title><style>.x{font-weight:bold} p.c{text-align:center} body{color:red}</style>
            <script>document.write('no')</script></head>
            <body>
            <h1>큰   제목</h1>
            <h3>작은 제목</h3>
            <p>일반 <b>굵게</b> <i>기울임</i> <u>밑줄</u> <del>취소</del> H<sub>2</sub>O x<sup>2</sup> <code>code</code> <mark>표시</mark></p>
            <p><span style="color:#ff0000; font-size:20pt; font-style:italic">빨강</span> <span class="x">클래스</span></p>
            <p class="c">가운데</p>
            <p style="text-align:right">오른쪽</p>
            <nav>메뉴</nav><div style="display:none">숨김</div>
            </body></html>
            """)

        XCTAssertEqual(content.title, "제목")
        let paragraphs = paragraphs(content)
        XCTAssertEqual(paragraphs[0].headingLevel, 1)
        XCTAssertEqual(text(paragraphs[0]), "큰 제목")
        XCTAssertEqual(paragraphs[1].headingLevel, 3)
        XCTAssertEqual(try run(content, "굵게").format.bold, true)
        XCTAssertEqual(try run(content, "기울임").format.italic, true)
        XCTAssertEqual(try run(content, "밑줄").format.underline, true)
        XCTAssertEqual(try run(content, "취소").format.strike, true)
        XCTAssertEqual(try run(content, "2").format.subscript, true)
        XCTAssertEqual(try run(content, "code").format.shade, HtmlReader.codeShade)
        XCTAssertEqual(try run(content, "표시").format.shade, HtmlReader.markShade)
        let red = try run(content, "빨강").format
        XCTAssertEqual(red.color, "#FF0000")
        XCTAssertEqual(red.size, 2000)
        XCTAssertEqual(red.italic, true)
        XCTAssertEqual(try run(content, "클래스").format.bold, true) // style sheet class rule
        XCTAssertNil(try run(content, "일반").format.color) // body colour from the style sheet is not copied onto runs
        XCTAssertEqual(paragraphs.first { text($0) == "가운데" }?.format.align, .center)
        XCTAssertEqual(paragraphs.first { text($0) == "오른쪽" }?.format.align, .right)
        let all = paragraphs.map(text).joined(separator: "\n")
        XCTAssertFalse(all.contains("메뉴"))
        XCTAssertFalse(all.contains("숨김"))
        XCTAssertFalse(all.contains("document.write"))
    }

    func testWhitespaceCollapsesAndLineBreaksStay() throws {
        let paragraphs = paragraphs(try parse("<p>  하나   \n  둘<br>셋<br></p><p><br></p><p></p><div>\n</div><pre>  들여쓴\n\n코드</pre>"))

        XCTAssertEqual(paragraphs[0].inlines.compactMap { ($0 as? HText)?.text }, ["하나 둘", "셋"])
        XCTAssertEqual(paragraphs[0].inlines.filter { $0 is HLineBreak }.count, 1) // the trailing <br> is not shown
        XCTAssertTrue(paragraphs[1].inlines.isEmpty) // <p><br></p>: an intended empty line
        let code = Array(paragraphs.dropFirst(2))
        XCTAssertEqual(code.map { $0.inlines.compactMap { ($0 as? HText)?.text }.joined() }, ["  들여쓴", "", "코드"])
        for run in code.flatMap({ $0.inlines.compactMap { $0 as? HText } }) { XCTAssertEqual(run.format.shade, HtmlReader.codeShade) }
    }

    func testPreDropsTheNewlineAfterItsStartTag() throws {
        // HTML5 ignores a newline right after <pre>; libxml2 keeps it and would add an empty first line.
        let paragraphs = paragraphs(try parse("<pre>\nfirst\n  second</pre>"))
        XCTAssertEqual(paragraphs.map(text), ["first", "second"])
    }

    func testNestedListsKeepLevelsStartNumbersAndTypes() throws {
        let paragraphs = paragraphs(try parse("""
            <ol start="3" type="a">
              <li>셋째<ul><li>안쪽</li><li>안쪽 둘</li></ul>이어지는 글</li>
              <li><p>넷째</p><p>둘째 문단</p></li>
            </ol>
            <ul style="list-style:none"><li>표시 없음</li></ul>
            """))

        let third = try XCTUnwrap(paragraphs.first { text($0) == "셋째" })
        let thirdList = try XCTUnwrap(third.list)
        XCTAssertEqual(thirdList.level, 0)
        XCTAssertTrue(thirdList.numbered)
        XCTAssertEqual(thirdList.numbering.levels[0].format, "LATIN_SMALL")
        XCTAssertEqual(thirdList.numbering.levels[0].start, 3)
        XCTAssertFalse(thirdList.numbering.levels[0].bullet)
        let inner = try XCTUnwrap(paragraphs.first { text($0) == "안쪽" }?.list)
        XCTAssertEqual(inner.level, 1)
        XCTAssertTrue(inner.numbering.levels[1].bullet)
        XCTAssertTrue(inner.numbering === paragraphs.first { text($0) == "안쪽 둘" }?.list?.numbering)
        let continued = try XCTUnwrap(paragraphs.first { text($0) == "이어지는 글" }?.list)
        XCTAssertEqual(continued.level, 0)
        XCTAssertFalse(continued.numbered)
        XCTAssertTrue(thirdList.numbering === continued.numbering)
        XCTAssertEqual(paragraphs.first { text($0) == "넷째" }?.list?.numbered, true)
        XCTAssertEqual(paragraphs.first { text($0) == "둘째 문단" }?.list?.numbered, false)
        let unmarked = try XCTUnwrap(paragraphs.first { text($0) == "표시 없음" })
        XCTAssertNil(unmarked.list)
        XCTAssertGreaterThan(unmarked.format.left ?? 0, 0)
    }

    func testTablesKeepSpansHeaderRowsAndBorders() throws {
        let content = try parse("""
            <table border="0">
              <caption>표 제목</caption>
              <thead><tr><th>이름</th><th colspan="2">값</th></tr></thead>
              <tbody>
                <tr><td rowspan="2" bgcolor="#eeeeee">병합</td><td>1</td><td>2</td></tr>
                <tr><td>3</td><td>4</td></tr>
              </tbody>
            </table>
            <table><tr><td style="width:25%">a</td><td style="width:75%">b</td></tr></table>
            """)

        let tables = content.blocks.compactMap { $0 as? HTable }
        let table = tables[0]
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.rows.map(\.header), [true, false, false])
        XCTAssertEqual(((table.rows[0].cells[0].blocks[0] as? HParagraph)?.inlines[0] as? HText)?.format.bold, true)
        XCTAssertEqual(table.rows[0].cells[1].colSpan, 2)
        XCTAssertEqual(table.rows[1].cells[0].rowSpan, 2)
        XCTAssertEqual(table.rows[1].cells[0].fill, "#EEEEEE")
        XCTAssertEqual(table.borders, HBorders.empty)
        XCTAssertEqual((table.caption[0] as? HParagraph).map(text), "표 제목")
        XCTAssertNil(tables[1].borders) // default: thin grid
        XCTAssertEqual(tables[1].relativeWidths, [0.25, 0.75])
    }

    func testMisnestedTablesKeepTheirTextLikeHtml5() throws {
        // Cells without a row get one, and stray content moves in front of the table (HTML5 foster parenting).
        let content = try parse("<table>앞<td>a</td><td>b</td><tr><td>c</td>뒤</tr></table>")
        XCTAssertEqual(content.blocks.compactMap { ($0 as? HParagraph).map(text) }, ["앞뒤"])
        let table = try XCTUnwrap(content.blocks.last as? HTable)
        XCTAssertEqual(table.rows.map(\.cells.count), [2, 1])
    }

    func testContentAfterTheBodyIsRead() throws {
        let content = try parse("<html><body><p>안</p></body></html><p>밖</p>")
        XCTAssertEqual(paragraphs(content).map(text), ["안", "밖"])
    }

    func testTreeRepairsMatchHtml5() throws {
        // Where libxml2's HTML 4 tree differs from HTML5 (AngleSharp in Filee), HtmlDom repairs it.
        let content = try parse("""
            <html><head><title>제목 <b>그대로</b></title><style>p { text-indent: 3em }</style></head>
            글<dl><dd>하나<dd>둘</dl><picture><source srcset="x.png"><b>소스 뒤</b></picture>
            <xmp>a <b>b</b> &amp;</xmp><p>줄</br>바꿈 &#150; <o:p>워드</o:p></p><pre>쪽\u{0C}나눔</pre>
            """)

        XCTAssertEqual(content.title, "제목 <b>그대로</b>") // <title> is text in HTML5
        let paragraphs = paragraphs(content)
        XCTAssertNil(paragraphs[0].format.firstLine) // no implied <p> picking up p rules
        XCTAssertEqual(paragraphs.map { $0.format.left ?? 0 }.prefix(3), [0, 2000, 2000]) // dd closes dd
        XCTAssertEqual(paragraphs.map(text).dropFirst(3).prefix(2), ["소스 뒤", "a <b>b</b> &amp;"])
        XCTAssertEqual(paragraphs[5].inlines.filter { $0 is HLineBreak }.count, 1) // </br>
        XCTAssertEqual(text(paragraphs[5]), "줄 바꿈 – 워드") // C1 reference as Windows-1252, o:p kept
        XCTAssertEqual(text(paragraphs[6]), "쪽\u{0C}나눔") // libxml2 would drop the form feed
    }

    func testReadOptionsMapLinksAndIds() throws {
        let folder = try newFolder()
        let options = HtmlReadOptions(baseFolder: folder, mediaFolder: folder,
                                      mapLink: { $0.hasPrefix("#") ? "ch2.xhtml" + $0 : nil },
                                      mapId: { $0 == "skip" ? nil : "c1-" + $0 })
        let content = try HtmlReader.parse(##"<p id="a">A <a href="#b">내부</a> <a href="http://x">외부</a></p><p id="skip">B</p>"##, options)
        let inlines = HDocumentWalker.inlines(content.blocks)
        XCTAssertEqual(inlines.compactMap { ($0 as? HBookmark)?.name }, ["c1-a"])
        XCTAssertEqual(inlines.compactMap { ($0 as? HLink)?.target }, ["ch2.xhtml#b"])
        XCTAssertEqual(paragraphs(content).map(text), ["A 내부 외부", "B"])
    }

    func testPicturesFromFilesAndDataUrisLinksAndAnchors() throws {
        let folder = try newFolder()
        try FileManager.default.createDirectoryIfNeeded(FilePath.combine(folder, "img"))
        try MarkupTestSupport.png(40, 20).write(to: URL(fileURLWithPath: FilePath.combine(folder, "img", "로고 1.png")))
        let data = MarkupTestSupport.png(10, 10, red: 255, green: 0, blue: 0).base64EncodedString()
        let content = try parse("""
            <p><a href="#part2">둘째로</a> <a href="https://example.com/x?a=1">웹</a> <a name="unused">아무도</a></p>
            <p><img src="img/%EB%A1%9C%EA%B3%A0%201.png" width="200"> <img src="data:image/png;base64,\(data)"> <img src="https://example.com/remote.png"></p>
            <h2 id="part2">둘째 부분</h2>
            """, folder)
        let document = HDocument()
        let section = HSection()
        section.blocks = content.blocks
        document.sections.append(section)
        HtmlReader.pruneBookmarks(document)

        let inlines = document.sections[0].blocks.flatMap { HDocumentWalker.inlines([$0]) }
        XCTAssertEqual(inlines.compactMap { ($0 as? HLink)?.target }, ["#part2", "https://example.com/x?a=1"])
        XCTAssertEqual(inlines.compactMap { ($0 as? HBookmark)?.name }, ["part2"]) // "unused" is pruned
        let images = inlines.compactMap { $0 as? HImage }
        XCTAssertEqual(images.count, 2) // the remote picture is skipped
        XCTAssertEqual(images[0].path, FilePath.combine(folder, "img", "로고 1.png"))
        XCTAssertEqual(images[0].width, Int(200 * HwpxUnits.perPixel))
        XCTAssertTrue(FileManager.default.fileExists(images[1].path))
        XCTAssertTrue(images[1].path.hasPrefix(FilePath.combine(folder, "media")))
    }

    func testSvgPicturesBecomePng() throws {
        let folder = try newFolder()
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="red"/></svg>"#
            .write(toFile: FilePath.combine(folder, "shape.svg"), atomically: true, encoding: .utf8)
        let image = try XCTUnwrap(HDocumentWalker.inlines(try parse(#"<p><img src="shape.svg"></p>"#, folder).blocks).first as? HImage)
        XCTAssertTrue(FilePath.fileName(image.path).hasPrefix("shape-"))
        XCTAssertEqual(FilePath.extension(image.path), ".png")
        XCTAssertEqual(ImageSupport.info(image.path)?.width, 30) // 144 dpi
    }

    func testCssPageBreaksStartNewPages() throws {
        let paragraphs = paragraphs(try parse("""
            <p style="page-break-before:always">첫</p>
            <p>둘</p>
            <div style="break-after: page"><p>셋</p></div>
            <p>넷</p>
            <mbp:pagebreak/>
            <p>다섯</p>
            """))

        XCTAssertEqual(paragraphs.map(\.pageBreakBefore), [false, false, false, true, true]) // none before the first paragraph
    }

    func testEncodingsComeFromTheBomTheXmlDeclarationOrMetaCharset() throws {
        let korean = "한글 문서"
        let russian = "Русский текст"
        let cp949 = try XCTUnwrap(TextEncodings.encoding(codePage: 949))
        let cp1251 = try XCTUnwrap(TextEncodings.encoding(codePage: 1251))

        XCTAssertTrue(HtmlReader.decode(TextEncodings.encode("<html><head><meta charset=\"euc-kr\"></head><body>\(korean)</body></html>", encoding: cp949)).contains(korean))
        XCTAssertTrue(HtmlReader.decode(TextEncodings.encode("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=ks_c_5601-1987\"><p>\(korean)</p>", encoding: cp949)).contains(korean))
        XCTAssertTrue(HtmlReader.decode(TextEncodings.encode("<?xml version=\"1.0\" encoding=\"windows-1251\"?><html><body>\(russian)</body></html>", encoding: cp1251)).contains(russian))
        XCTAssertTrue(HtmlReader.decode(Data([0xFF, 0xFE]) + TextEncodings.encode("<p>\(korean)</p>", encoding: .utf16LittleEndian)).contains(korean))
        XCTAssertTrue(HtmlReader.decode(Data("<p>\(korean)</p>".utf8)).contains(korean)) // undeclared UTF-8
    }

    func testXhtmlSelfClosedElementsDoNotSwallowThePage() throws {
        let content = try HtmlReader.parse("""
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title/></head>
            <body><div id="a"/><p>첫 문단</p><a id="b"/><p>둘째 문단</p><br/><hr/></body></html>
            """, HtmlReadOptions(baseFolder: try newFolder(), mediaFolder: try newFolder()), true)

        let paragraphs = paragraphs(content)
        XCTAssertEqual(text(paragraphs[0]), "첫 문단")
        XCTAssertEqual(text(paragraphs[1]), "둘째 문단")
        XCTAssertFalse(paragraphs[1].inlines.contains { $0 is HLink })
        XCTAssertEqual(paragraphs.last?.inlines.count, 1)
        XCTAssertTrue(paragraphs.last?.inlines.first is HShape) // <hr/> is a short line
    }

    func testAbsurdlyDeepHtmlIsReadAsTextWithoutExhaustingTheStack() throws {
        let html = String(repeating: "<div><span>", count: 5000) + "깊은 글" + String(repeating: "</span></div>", count: 5000)

        XCTAssertTrue(paragraphs(try parse(html)).contains { text($0) == "깊은 글" })
    }

    func testXhtmlWriterOutputIsWellFormedAndLinksAcrossChapters() throws {
        let content = try parse("""
            <h1>하나</h1><p>본문 <a href="#target">링크</a> <b>굵게</b> &amp; &lt;기호&gt;</p>
            <ol start="2"><li>둘<ul><li>안</li></ul></li><li>셋</li></ol>
            <table><tr><th>A</th><th>B</th></tr><tr><td colspan="2">합침</td></tr></table>
            <h1>둘</h1><p id="target">목표</p><pre>code  line</pre>
            """)
        let document = HDocument()
        let section = HSection()
        section.blocks = content.blocks
        document.sections.append(section)
        let note = HNote(false)
        let noteParagraph = HParagraph()
        noteParagraph.inlines.append(HText("각주"))
        note.blocks.append(noteParagraph)
        (document.sections[0].blocks[1] as? HParagraph)?.inlines.append(note)

        let chapters = XhtmlWriter.write(document, XhtmlOptions(splitChapters: true, imageSource: { _ in nil }, epub: true))

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters.map(\.title), ["하나", "둘"])
        for chapter in chapters {
            _ = try XDocument.parse(XhtmlWriter.page(chapter.title!, chapter.body, "ko", "style.css", true)) // throws if malformed
        }
        XCTAssertTrue(chapters[0].body.contains("href=\"ch002.xhtml#target\""))
        XCTAssertTrue(chapters[1].body.contains("id=\"target\""))
        XCTAssertTrue(chapters[0].body.contains("<ol start=\"2\">"))
        XCTAssertNotNil(chapters[0].body.range(of: #"<li>둘<ul>\s*<li>안</li>\s*</ul>\s*</li>"#, options: .regularExpression))
        XCTAssertTrue(chapters[0].body.contains("colspan=\"2\""))
        XCTAssertTrue(chapters[0].body.contains("epub:type=\"footnote\""))
        XCTAssertTrue(chapters[1].body.contains("<pre><code>code  line</code></pre>"))
    }
}

final class HtmlCssTests: XCTestCase {
    func testColoursLengthsAndFontSizes() {
        XCTAssertEqual(CssValues.color(" #abc "), "#AABBCC")
        XCTAssertEqual(CssValues.color("#11223344"), "#112233")
        XCTAssertEqual(CssValues.color("rgb(255, 0, 50%)"), "#FF007F") // 50 * 2.55 = 127.4999…, as in .NET
        XCTAssertEqual(CssValues.color("rgba(10 20 30 / 0.5)"), "#0A141E")
        XCTAssertEqual(CssValues.color("Navy"), "#000080")
        XCTAssertNil(CssValues.color("transparent"))
        XCTAssertNil(CssValues.color("#12"))
        XCTAssertEqual(CssValues.firstColor("url(x.png) #eee no-repeat"), "#EEEEEE")
        XCTAssertEqual(CssValues.length("2em", 1000), 2000)
        XCTAssertEqual(CssValues.length("12pt", 1000), 1200)
        XCTAssertEqual(CssValues.length("96px", 1000), 7200)
        XCTAssertEqual(CssValues.length("1in", 1000), 7200)
        XCTAssertNil(CssValues.length("auto", 1000))
        XCTAssertEqual(CssValues.fontSize("larger", 1000), 1200)
        XCTAssertEqual(CssValues.fontSize("1pt", 1000), 100)
        XCTAssertEqual(CssValues.fontSize("500pt", 1000), 20000)
        XCTAssertNil(CssValues.fontSize("0", 1000))
        XCTAssertEqual(CssValues.tryParseDouble(" 1.5e2 "), 150)
        XCTAssertEqual(CssValues.tryParseDouble("1."), 1)
        XCTAssertNil(CssValues.tryParseDouble("0x10"))
        XCTAssertNil(CssValues.tryParseDouble("inf"))
    }

    func testStyleSheetRulesCascadeBySpecificityThenOrder() {
        let sheet = CssStyleSheet()
        sheet.add("/* c */ p.a { font-weight: bold } .a { font-weight: normal; color: red } p { text-align: center } @media print { p { display: none } } div p { display: none }")
        let style = sheet.match("p", ["a", "b"])
        XCTAssertEqual(style.get("font-weight"), "bold") // tag.class beats .class
        XCTAssertNil(style.get("color")) // colours are not taken from style sheets
        XCTAssertEqual(style.get("TEXT-ALIGN"), "center")
        XCTAssertNil(style.get("display"))
        XCTAssertEqual(CssDeclarations.parse("color: red !important; COLOR: blue; :x; y:").get("color"), "blue")
    }

    func testUnescapeDataStringKeepsInvalidEscapes() {
        XCTAssertEqual(HtmlReader.unescapeDataString("%EB%A1%9C%EA%B3%A0%201.png"), "로고 1.png")
        XCTAssertEqual(HtmlReader.unescapeDataString("100%.png"), "100%.png")
        XCTAssertEqual(HtmlReader.unescapeDataString("a%E2%82b"), "a%E2%82b")
    }
}
