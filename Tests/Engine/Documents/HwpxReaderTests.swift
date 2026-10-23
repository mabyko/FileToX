import Foundation
import XCTest

@testable import FileToXEngineKit

final class HwpxReaderTests: DocumentTestCase {
    func roundTrip(_ doc: HDocument, _ name: String) throws -> HDocument {
        let first = path(name + ".hwpx")
        try HwpxWriter.write(doc, first)
        var skipped: [String: Int] = [:]
        let read = try HwpxReader.read(first, path("media-1"), &skipped)
        XCTAssertTrue(skipped.isEmpty, "\(skipped)")
        HDocumentAssert.similar(doc, read)
        let second = path(name + "-again.hwpx")
        try HwpxWriter.write(read, second)
        let again = try HwpxReader.read(second, path("media-2"))
        XCTAssertEqual(HDocumentAssert.dump(read), HDocumentAssert.dump(again))
        return read
    }
    func testDocxDocumentsSurviveHwpx() throws {
        let source = try DocxReader.read(DocumentFixtures.richDocx(folder), path("docx-media"))
        let read = try roundTrip(source, "docx")
        XCTAssertEqual(read.sections.count, 2)
        XCTAssertEqual(read.sections[0].headers.count, 2)
        XCTAssertTrue(read.sections[1].page!.landscape)
    }
    func testMarkdownDocumentsSurviveHwpx() throws {
        _ = try roundTrip(markdown("# 첫 제목\n\n일반 **굵게**[^1]\n\n3. 항목\n\n[^1]: 각주"), "markdown")
    }
    func testSheetsSurviveHwpx() throws {
        let source = SheetDocument.build(DocumentFixtures.workbook())
        let read = try roundTrip(source, "sheets")
        let table = read.sections[0].blocks.compactMap { $0 as? HTable }[0]
        XCTAssertEqual(table.rows[0].cells[0].colSpan, 2)
        XCTAssertEqual(table.rows[0].cells[0].fill, "#1F4E79")
        XCTAssertEqual(table.rows.map(\.header), [true, true, false])
    }
    func testPresentationsSurviveHwpx() throws {
        let source = try PptxReader.read(DocumentFixtures.slides(path("slides.pptx")), path("slide-media"))
        let read = try roundTrip(source, "slides")
        XCTAssertTrue(read.sections[0].page!.landscape)
        XCTAssertEqual(HDocumentWalker.inlines(read.sections[0].blocks).compactMap { $0 as? HTextBox }.count, 2)
    }
    func testTemplateSavedByHangul() throws {
        let path = self.path("blank.hwpx")
        try HwpxWriter.openBuiltInTemplate().write(to: URL(fileURLWithPath: path))
        let doc = try HwpxReader.read(path, self.path("media"))
        let s = doc.sections[0]
        let p = try XCTUnwrap(s.blocks[0] as? HParagraph)
        XCTAssertEqual(
            s.page,
            HPage(
                width: 59530, height: 84190, left: 7200, right: 7200, top: 4255, bottom: 4960, header: 4250,
                footer: 2240, gutter: 0))
        XCTAssertEqual(s.columns, .single)
        XCTAssertTrue(p.inlines.isEmpty)
        XCTAssertEqual(p.format.lineSpacing, HLineSpacing(.percent, 180))
        XCTAssertEqual(p.format.after, 1000)
        XCTAssertEqual(p.markFormat.size, 1000)
    }
    func customPackage(_ header: String, _ section: String, _ extra: [(String, String)] = []) throws -> String {
        let p = path(UUID().uuidString + ".hwpx")
        let z = try ZipWriter(path: p)
        try z.add("mimetype", text: "application/hwp+zip", level: .noCompression)
        try z.add("Contents/header.xml", text: header)
        try z.add("Contents/section0.xml", text: section)
        for (n, s) in extra { try z.add(n, text: s) }
        try z.close()
        return p
    }
    func testHangulProducerVariants() throws {
        let header = #"""
            <hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hh:refList>
            <hh:fontfaces><hh:fontface lang="HANGUL"><hh:font id="0" face="맑은 고딕"/></hh:fontface><hh:fontface lang="LATIN"><hh:font id="0" face="Times New Roman"/></hh:fontface></hh:fontfaces>
            <hh:charProperties><hh:charPr id="0" height="1400" textColor="#0000ff"><hh:fontRef hangul="0" latin="0"/><hh:bold/><hh:italic/><hh:underline type="BOTTOM"/><hh:strikeout shape="3D"/></hh:charPr></hh:charProperties>
            <hh:paraProperties><hh:paraPr id="0"><hh:align horizontal="LEFT"/><hh:heading type="OUTLINE" idRef="1" level="0"/><hp:switch><hp:case hp:required-namespace="http://www.hancom.co.kr/hwpml/2016/HwpUnitChar"><hh:margin><hc:intent value="-2000"/><hc:left value="1000"/><hc:right value="500"/></hh:margin><hh:lineSpacing type="FIXED" value="1800"/></hp:case><hp:default><hh:margin left="9000"/></hp:default></hp:switch></hh:paraPr></hh:paraProperties>
            <hh:numberings><hh:numbering id="1"><hh:paraHead level="1" numFormat="DIGIT">^1.</hh:paraHead></hh:numbering></hh:numberings></hh:refList></hh:head>
            """#
        let section = #"""
            <sec xmlns="http://www.hancom.co.kr/hwpml/2011/section" xmlns:p="http://www.hancom.co.kr/hwpml/2011/paragraph"><p:p paraPrIDRef="0"><p:run charPrIDRef="0"><p:secPr><p:startNum page="0"/><p:pagePr landscape="NARROWLY" width="59528" height="84188"/></p:secPr><p:ctrl><p:newNum numType="PAGE" num="3"/><p:colPr colCount="2" sameSz="0"><p:colSz gap="850"/></p:colPr><p:pageNum pos="BOTTOM_CENTER" sideChar="-"/></p:ctrl><p:t>굵게<p:markpenBegin color="#00FF00"/>형광<p:markpenEnd/><p:deleteBegin/>삭제<p:deleteEnd/><p:insertBegin/>넣은 글<p:nbSpace/>빈칸<p:fwSpace/>고정<p:hyphen/>끝<p:tab/><p:lineBreak/></p:t><p:equation><p:script>x over y</p:script></p:equation><p:compose composeText="12"/><p:dutmal><p:mainText>본말</p:mainText></p:dutmal><p:ole/><p:pic/></p:run></p:p></sec>
            """#
        var skipped: [String: Int] = [:]
        let doc = try HwpxReader.read(customPackage(header, section), path("media"), &skipped)
        let s = doc.sections[0]
        let p = s.blocks[0] as! HParagraph
        XCTAssertEqual(p.headingLevel, 1)
        XCTAssertNotNil(p.list)
        XCTAssertEqual(p.format.left, 3000)
        XCTAssertEqual(p.format.firstLine, -2000)
        XCTAssertEqual(p.format.lineSpacing, HLineSpacing(.fixed, 1800))
        XCTAssertEqual(s.startPageNumber, 3)
        XCTAssertEqual(s.columns.gap, 850)
        XCTAssertTrue(s.page!.landscape)
        XCTAssertEqual(s.footers.count, 1)
        let texts = p.inlines.compactMap { $0 as? HText }
        XCTAssertEqual(texts[0].format.font, "Times New Roman")
        XCTAssertEqual(texts[0].format.strike, false)
        XCTAssertEqual(texts[1].format.shade, "#00FF00")
        XCTAssertFalse(texts.map(\.text).joined().contains("삭제"))
        XCTAssertTrue(texts.map(\.text).joined().contains("x over y12본말"))
        XCTAssertEqual(skipped, ["ole": 1, "pic": 1])
    }
    func testProtectedAndForeignFilesGiveClearErrors() throws {
        let media = path("media")
        let encrypted = try customPackage(
            "<head/>", "broken", [("META-INF/manifest.xml", "<manifest><encryption-data/></manifest>")])
        XCTAssertThrowsError(try HwpxReader.read(encrypted, media)) {
            XCTAssertTrue($0.localizedDescription.contains("password"))
        }
        let drm = try write("<DRMONE>protected</DRMONE>", "drm.hwpx")
        XCTAssertThrowsError(try HwpxReader.read(drm, media)) { XCTAssertTrue($0.localizedDescription.contains("DRM")) }
        let binary = path("binary.hwpx")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]).write(to: URL(fileURLWithPath: binary))
        XCTAssertThrowsError(try HwpxReader.read(binary, media)) {
            XCTAssertTrue($0.localizedDescription.contains("HWP 5.0"))
        }
        let broken = try customPackage("<head/>", "PK\u{3}\u{4} encrypted")
        XCTAssertThrowsError(try HwpxReader.read(broken, media)) {
            XCTAssertTrue($0.localizedDescription.contains("encrypted"))
        }
    }
    func testHyperlinkCommandEscaping() throws {
        for target in ["https://example.com/a?b=1#c", "#처음", "mailto:user@example.com"] {
            let field = try XElement.parse("<r xmlns:hp=\"\(HwpxWriter.hp)\">\(HwpxWriter.fieldBegin(1,target))</r>")
            XCTAssertEqual(HwpxReader.hyperlinkTarget(field), target)
        }
    }
    func testHundredPagesReadUnderOneSecond() throws {
        let doc = HDocument()
        let s = HSection()
        doc.sections.append(s)
        for i in 0..<1300 {
            let p = DocumentFixtures.p("\(i+1). ", HCharFormat(bold: true, size: 1100))
            p.format = HParaFormat(align: .justify, after: 400)
            p.inlines += [
                HText(String(repeating: "한글 문서를 읽는 속도를 확인하는 문장입니다. ", count: 4)),
                HText("강조", HCharFormat(italic: true, color: "#C00000")),
            ]
            s.blocks.append(p)
            if i % 50 == 49 {
                let t = HTable()
                t.columnCount = 5
                for r in 0..<10 {
                    let row = HRow()
                    for c in 0..<5 {
                        let cell = HCell()
                        cell.blocks = [DocumentFixtures.p("셀 \(r),\(c)")]
                        row.cells.append(cell)
                    }
                    t.rows.append(row)
                }
                s.blocks.append(t)
            }
        }
        let out = path("long.hwpx")
        try HwpxWriter.write(doc, out)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = Date()
            let read = try HwpxReader.read(out, path("media"))
            best = min(best, Date().timeIntervalSince(start))
            XCTAssertEqual(read.sections[0].blocks.count, 1326)
        }
        XCTAssertLessThan(best, 1)
    }
    func testRhwpFilesReadLikeOriginal() async throws {
        try requireRhwp()
        let doc = DocumentReaders.textDocument(Data("한글 본문\n둘째 줄".utf8))
        let first = path("original.hwpx")
        try HwpxWriter.write(doc, first)
        let hwp = try await convert(RhwpConverter(), first, "hwpx", "hwp", "converted.hwp")
        let next = try await convert(RhwpConverter(), hwp, "hwp", "hwpx", "converted.hwpx")
        let a = try HwpxReader.read(first, path("m1"))
        let b = try HwpxReader.read(next, path("m2"))
        HDocumentAssert.similar(a, b)
    }
}

extension HwpxReaderTests {
    func testGroupsShapesAndDrawingText() throws {
        let reference = try ZipReader(data: HwpxWriter.openBuiltInTemplate())
        let header = String(decoding: try XCTUnwrap(reference.data(named: "Contents/header.xml")), as: UTF8.self)
        let section = #"""
            <hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"><hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:container><hp:sz width="20000" height="10000"/><hp:pos treatAsChar="0" horzRelTo="COLUMN" vertRelTo="PARA" horzOffset="1000" vertOffset="2000"/><hp:rect ratio="20"><hp:offset x="1000" y="500"/><hp:curSz width="12000" height="2000"/><hp:lineShape style="DASH" width="34" color="#000000"/><hc:fillBrush><hc:gradation angle="90"><hc:color value="#FF0000"/><hc:color value="#0000FF"/></hc:gradation></hc:fillBrush><hp:drawText><hp:subList vertAlign="CENTER"><hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>묶음 글상자</hp:t></hp:run></hp:p></hp:subList><hp:textMargin left="100" right="100" top="50" bottom="50"/></hp:drawText></hp:rect><hp:ellipse><hp:offset x="5000" y="8000"/><hp:orgSz width="3000" height="3000"/><hp:renderingInfo><hc:scaMatrix e1="2" e5="2"/></hp:renderingInfo><hp:lineShape style="SOLID" width="0" color="#000000"/></hp:ellipse></hp:container></hp:run></hp:p></hs:sec>
            """#
        let doc = try HwpxReader.read(customPackage(header, section), path("media"))
        let list = HDocumentWalker.inlines(doc.sections[0].blocks)
        let box = try XCTUnwrap(list.compactMap { $0 as? HTextBox }.first)
        let ellipse = try XCTUnwrap(list.compactMap { $0 as? HShape }.first)
        XCTAssertEqual(box.width, 12000)
        XCTAssertEqual(box.height, 2000)
        XCTAssertEqual(box.anchor?.horizontalOffset, 2000)
        XCTAssertEqual(box.anchor?.verticalOffset, 2500)
        XCTAssertEqual(box.gradient, HGradient(["#FF0000", "#0000FF"], 90))
        XCTAssertEqual(box.padding, HInsets(100, 100, 50, 50))
        XCTAssertEqual(box.verticalAlign, .center)
        XCTAssertEqual(HDocumentAssert.text(box.blocks), "묶음 글상자")
        XCTAssertEqual(ellipse.width, 6000)
        XCTAssertEqual(ellipse.anchor?.horizontalOffset, 6000)
        XCTAssertEqual(ellipse.line.widthMm, 0.1)
    }
}
