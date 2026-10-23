import Foundation

@testable import FileToXEngineKit

extension DocumentFixtures {
    static func richDocx(_ folder: String) throws -> String {
        let d = DocxBuilder()
        func p(_ s: String, _ props: String = "") -> String { DocxBuilder.p(s, props) }
        func r(_ s: String, _ props: String = "") -> String { DocxBuilder.r(s, props) }
        d.numbering = #"""
            <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="400" w:hanging="400"/></w:pPr></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="ganada"/><w:lvlText w:val="%2)"/><w:pPr><w:ind w:left="800" w:hanging="400"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
            """#
        d.settings = "<w:evenAndOddHeaders/>"
        let data = try png(FilePath.combine(folder, "picture.png"))
        let image = d.image(data)
        let url = d.hyperlink("https://example.com/a?b=1")
        let header = d.header(p(r("홀수 쪽 머리말"), "<w:jc w:val=\"right\"/>"))
        let even = d.header(p(r("짝수 쪽 머리말")))
        let footer = d.footer(
            p(
                DocxBuilder.field("PAGE", "1") + r(" / ") + DocxBuilder.field("NUMPAGES", "3"),
                "<w:jc w:val=\"center\"/>"))
        d.footnotes("<w:footnote w:id=\"1\"><w:p><w:r><w:footnoteRef/></w:r>" + r(" 각주 설명") + "</w:p></w:footnote>")
        d.endnotes("<w:endnote w:id=\"1\"><w:p><w:r><w:endnoteRef/></w:r>" + r(" 미주 설명") + "</w:p></w:endnote>")
        d.paragraph(
            p(
                "<w:bookmarkStart w:id=\"0\" w:name=\"intro\"/>" + r("가운데 제목") + "<w:bookmarkEnd w:id=\"0\"/>",
                "<w:pStyle w:val=\"Heading1\"/><w:jc w:val=\"center\"/>"))
        d.paragraph(
            p(
                r(
                    "굵은 빨강",
                    "<w:b/><w:color w:val=\"FF0000\"/><w:sz w:val=\"28\"/><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:eastAsia=\"굴림\"/>"
                ) + r(" 형광펜", "<w:highlight w:val=\"yellow\"/>")
                    + r(" 무늬", "<w:shd w:val=\"pct25\" w:color=\"auto\" w:fill=\"auto\"/>") + "<w:r><w:tab/></w:r>"
                    + r("탭 뒤"),
                "<w:ind w:left=\"720\" w:hanging=\"360\"/><w:spacing w:before=\"240\" w:after=\"120\"/><w:tabs><w:tab w:val=\"right\" w:leader=\"dot\" w:pos=\"8000\"/></w:tabs><w:keepNext/><w:keepLines/>"
            ))
        d.paragraph(p(r("고정 줄 간격"), "<w:spacing w:line=\"360\" w:lineRule=\"exact\"/><w:jc w:val=\"both\"/>"))
        d.paragraph(p(r("최소 줄 간격"), "<w:spacing w:line=\"300\" w:lineRule=\"atLeast\"/><w:jc w:val=\"distribute\"/>"))
        for (level, text) in [(0, "첫 항목"), (1, "하위 항목")] {
            d.paragraph(p(r(text), "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"1\"/></w:numPr>"))
        }
        d.paragraph(
            p(
                r("본문") + "<w:r><w:footnoteReference w:id=\"1\"/></w:r>" + r("미주")
                    + "<w:r><w:endnoteReference w:id=\"1\"/></w:r><w:hyperlink r:id=\"\(url)\">"
                    + r("웹 링크", "<w:rStyle w:val=\"Hyperlink\"/>") + "</w:hyperlink><w:hyperlink w:anchor=\"intro\">"
                    + r("소개로 이동") + "</w:hyperlink>"))
        func cell(_ content: String, _ props: String = "") -> String {
            "<w:tc><w:tcPr>\(props)</w:tcPr>\(content)</w:tc>"
        }
        let nested =
            "<w:tbl><w:tblGrid><w:gridCol w:w=\"1000\"/><w:gridCol w:w=\"1000\"/></w:tblGrid><w:tr>" + cell(p(r("안1")))
            + cell(p(r("안2"))) + "</w:tr></w:tbl>" + p("")
        d.paragraph(
            "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:jc w:val=\"center\"/></w:tblPr><w:tblGrid><w:gridCol w:w=\"2000\"/><w:gridCol w:w=\"3000\"/><w:gridCol w:w=\"2000\"/></w:tblGrid><w:tr><w:trPr><w:tblHeader/></w:trPr>"
                + cell(
                    p(r("가로 병합")), "<w:gridSpan w:val=\"2\"/><w:shd w:val=\"pct10\" w:fill=\"auto\" w:color=\"auto\"/>")
                + cell(p(r("세로 병합")), "<w:vMerge w:val=\"restart\"/><w:vAlign w:val=\"center\"/>") + "</w:tr><w:tr>"
                + cell(nested) + cell(p(r("B"))) + cell(p(""), "<w:vMerge/>") + "</w:tr><w:tr>"
                + cell(
                    p(r("C")), "<w:tcBorders><w:bottom w:val=\"double\" w:sz=\"12\" w:color=\"FF0000\"/></w:tcBorders>")
                + cell(p(r("D")), "<w:shd w:fill=\"FFF2CC\" w:val=\"clear\"/>") + cell(p(r("E"))) + "</w:tr></w:tbl>")
        let column = "<wp:positionH relativeFrom=\"column\"><wp:posOffset>0</wp:posOffset></wp:positionH>"
        let paragraph = "<wp:positionV relativeFrom=\"paragraph\"><wp:posOffset>0</wp:posOffset></wp:positionV>"
        d.paragraph(
            p(
                DocxBuilder.inlinePicture(image, 457200, 457200)
                    + DocxBuilder.anchor(
                        "http://schemas.openxmlformats.org/drawingml/2006/picture",
                        DocxBuilder.picture(image, 914400, 457200), 914400, 457200,
                        "<wp:positionH relativeFrom=\"page\"><wp:posOffset>914400</wp:posOffset></wp:positionH>",
                        paragraph)))
        let shape =
            "<wps:wsp><wps:spPr><a:prstGeom prst=\"roundRect\"/><a:solidFill><a:srgbClr val=\"FFF2CC\"/></a:solidFill><a:ln w=\"12700\"><a:solidFill><a:srgbClr val=\"C00000\"/></a:solidFill></a:ln></wps:spPr><wps:txbx><w:txbxContent>"
            + p(r("글상자 안의 글")) + "</w:txbxContent></wps:txbx><wps:bodyPr anchor=\"ctr\"/></wps:wsp>"
        d.paragraph(
            p(
                DocxBuilder.anchor(
                    "http://schemas.microsoft.com/office/word/2010/wordprocessingShape", shape, 1_828_800, 914400,
                    column, paragraph)))
        let gradientShape =
            "<wps:wsp><wps:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1000000\" cy=\"500000\"/></a:xfrm><a:prstGeom prst=\"ellipse\"/><a:gradFill><a:gsLst><a:gs pos=\"0\"><a:srgbClr val=\"99CCFF\"/></a:gs><a:gs pos=\"100000\"><a:srgbClr val=\"FFFFFF\"/></a:gs></a:gsLst><a:lin ang=\"5400000\"/></a:gradFill><a:ln><a:noFill/></a:ln></wps:spPr><wps:bodyPr/></wps:wsp>"
        d.paragraph(
            p(
                DocxBuilder.anchor(
                    "http://schemas.microsoft.com/office/word/2010/wordprocessingShape", gradientShape, 1_000_000,
                    500000, column, paragraph)))
        let lineShape =
            "<wps:wsp><wps:spPr><a:prstGeom prst=\"line\"/><a:ln w=\"25400\"><a:solidFill><a:srgbClr val=\"4F81BD\"/></a:solidFill><a:prstDash val=\"dash\"/></a:ln></wps:spPr><wps:bodyPr/></wps:wsp>"
        d.paragraph(
            p(
                DocxBuilder.anchor(
                    "http://schemas.microsoft.com/office/word/2010/wordprocessingShape", lineShape, 3_000_000, 0,
                    column, paragraph)))
        d.paragraph(
            p(
                DocxBuilder.anchor(
                    "http://schemas.openxmlformats.org/drawingml/2006/picture",
                    DocxBuilder.picture(image, 457200, 457200), 457200, 457200,
                    "<wp:positionH relativeFrom=\"margin\"><wp:posOffset>-635000</wp:posOffset></wp:positionH>",
                    "<wp:positionV relativeFrom=\"paragraph\"><wp:posOffset>-127000</wp:posOffset></wp:positionV>")))
        d.paragraph(
            p(
                "<w:r><w:pict><v:roundrect style=\"position:absolute;width:144pt;height:72pt;margin-left:20pt;margin-top:30pt\" fillcolor=\"#AABBCC\" strokecolor=\"#123\"><v:textbox><w:txbxContent>"
                    + p(r("옛 글상자")) + "</w:txbxContent></v:textbox></v:roundrect></w:pict></w:r>"))
        d.paragraph(p(r("앞 쪽") + "<w:r><w:br w:type=\"page\"/></w:r>" + r("다음 쪽")))
        d.paragraph(
            p(
                r("첫 구역 끝"),
                "<w:sectPr><w:headerReference w:type=\"default\" r:id=\"\(header)\"/><w:headerReference w:type=\"even\" r:id=\"\(even)\"/><w:footerReference w:type=\"default\" r:id=\"\(footer)\"/>\(DocxBuilder.defaultPage)<w:titlePg/><w:pgNumType w:start=\"3\"/></w:sectPr>"
            ))
        d.paragraph(p(r("가로 두 단")))
        d.sectionProperties =
            "<w:pgSz w:w=\"16838\" w:h=\"11906\" w:orient=\"landscape\"/><w:pgMar w:top=\"1985\" w:right=\"1134\" w:bottom=\"1418\" w:left=\"1134\" w:header=\"851\" w:footer=\"851\" w:gutter=\"0\"/><w:cols w:num=\"2\" w:space=\"720\" w:sep=\"1\"/>"
        return try d.save(FilePath.combine(folder, "rich.docx"))
    }
    static func slides(_ path: String) throws -> String {
        let zip = try ZipWriter(path: path)
        let p = PptxReader.p.namespaceName
        let a = PptxReader.a.namespaceName
        let r = PptxReader.r.namespaceName
        func rels(_ targets: [(String, String, String)]) -> String {
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + targets.map {
                    "<Relationship Id=\"\($0.0)\" Type=\"\(DocxWriter.relationshipBase)\($0.1)\" Target=\"\($0.2)\"/>"
                }.joined() + "</Relationships>"
        }
        try zip.add("_rels/.rels", text: rels([("rId1", "officeDocument", "ppt/presentation.xml")]))
        try zip.add(
            "ppt/presentation.xml",
            text:
                "<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"s1\"/><p:sldId id=\"257\" r:id=\"s2\"/></p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/></p:presentation>"
        )
        try zip.add(
            "ppt/_rels/presentation.xml.rels",
            text: rels([("s1", "slide", "slides/slide1.xml"), ("s2", "slide", "slides/slide2.xml")]))
        for i in 1...2 {
            let fill =
                i == 2 ? "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"1F1E2D\"/></a:solidFill></p:bgPr></p:bg>" : ""
            let text = i == 1 ? "2026년 사업 보고" : "다음 분기 계획"
            let shape =
                "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"title\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"838200\" y=\"440000\"/><a:ext cx=\"8000000\" cy=\"1500000\"/></a:xfrm><a:prstGeom prst=\"roundRect\"/><a:solidFill><a:srgbClr val=\"7F77DD\"/></a:solidFill></p:spPr><p:txBody><a:bodyPr anchor=\"ctr\"/><a:lstStyle/><a:p><a:pPr algn=\"ctr\"/><a:r><a:rPr sz=\"3200\" b=\"1\"/><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>"
            try zip.add(
                "ppt/slides/slide\(i).xml",
                text:
                    "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld>\(fill)<p:spTree>\(shape)</p:spTree></p:cSld></p:sld>"
            )
        }
        try zip.close()
        return path
    }
}
