import Foundation
import XCTest

@testable import FileToXEngineKit

final class OoxmlVariantTests: OfficeTestCase {
    private let ct = XNamespace("http://schemas.openxmlformats.org/package/2006/content-types"),
        rel = XNamespace("http://schemas.openxmlformats.org/package/2006/relationships"),
        s = XNamespace("http://schemas.openxmlformats.org/spreadsheetml/2006/main"),
        r = XNamespace("http://schemas.openxmlformats.org/officeDocument/2006/relationships")
    private func package(_ format: String, _ macros: Bool = false) throws -> String {
        let family = try XCTUnwrap(OoxmlConverter.variants[format]?.family)
        let main =
            family == "word" ? "word/document.xml" : family == "excel" ? "xl/workbook.xml" : "ppt/presentation.xml"
        let dir = FilePath.directoryName(main)!
        var parts: [(String, Data)] = []
        let mainXml: String
        if family == "excel" {
            mainXml =
                "<workbook xmlns=\"\(s)\" xmlns:r=\"\(r)\"><bookViews><workbookView activeTab=\"2\" firstSheet=\"1\"/></bookViews><sheets><sheet name=\"Before\" sheetId=\"1\" r:id=\"rId1\"/>"
                + (macros ? "<sheet name=\"Macro1\" sheetId=\"99\" r:id=\"rIdMacro\"/>" : "")
                + "<sheet name=\"After\" sheetId=\"2\" r:id=\"rId2\"/></sheets><definedNames><definedName name=\"before\" localSheetId=\"0\">A1</definedName><definedName name=\"macro\" localSheetId=\"1\">A1</definedName><definedName name=\"after\" localSheetId=\"2\">A1</definedName><definedName name=\"global\">A1</definedName></definedNames></workbook>"
        } else {
            mainXml =
                family == "word"
                ? "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>매크로가 있던 문서</w:t></w:r></w:p></w:body></w:document>"
                : "<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:sldSz cx=\"12192000\" cy=\"6858000\"/></p:presentation>"
        }
        parts += [
            (main, Data(mainXml.utf8)),
            (
                "_rels/.rels",
                Data(
                    "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(r)/officeDocument\" Target=\"/\(main)\"/></Relationships>"
                        .utf8)
            ), (dir + "/media/picture.png", Data([1, 2, 3, 4])),
        ]
        var types =
            "<Types xmlns=\"\(ct)\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/\(main)\" ContentType=\"\(OoxmlConverter.variants[format]!.contentType)\"/>"
        var rels =
            "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rIdExternal\" Type=\"\(r)/hyperlink\" Target=\"https://example.com/vbaProject.bin\" TargetMode=\"External\"/>"
        if family == "excel" {
            rels +=
                "<Relationship Id=\"rId1\" Type=\"\(r)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"\(r)/worksheet\" Target=\"worksheets/sheet2.xml\"/>"
            parts += [
                (
                    "xl/worksheets/sheet1.xml",
                    Data(
                        "<worksheet xmlns=\"\(s)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>1st</t></is></c></row></sheetData></worksheet>"
                            .utf8)
                ),
                (
                    "xl/worksheets/sheet2.xml",
                    Data(
                        "<worksheet xmlns=\"\(s)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>2nd</t></is></c></row></sheetData></worksheet>"
                            .utf8)
                ),
            ]
        }
        if macros {
            types += "<Default Extension=\"bin\" ContentType=\"application/vnd.ms-office.vbaProject\"/>"
            for (i, type) in [
                "application/vnd.ms-word.vbaData+xml", "application/vnd.ms-word.keyMapCustomizations+xml",
                "application/vnd.ms-office.vbaProjectSignatureAgile", "application/vnd.ms-office.vbaProjectSignatureV3",
            ].enumerated() {
                let name = "\(dir)/macro\(i).xml"
                types += "<Override PartName=\"/\(name)\" ContentType=\"\(type)\"/>"
                parts.append((name, Data("<macro/>".utf8)))
                rels += "<Relationship Id=\"m\(i)\" Type=\"macro\" Target=\"macro\(i).xml\"/>"
            }
            parts.append((dir + "/vbaProject.bin", Data([0xd0, 0xcf, 0x11, 0xe0])))
            parts.append(
                (
                    dir + "/_rels/vbaProject.bin.rels",
                    Data(
                        "<Relationships xmlns=\"\(rel)\"><Relationship Id=\"v\" Type=\"macro\" Target=\"macro0.xml\"/></Relationships>"
                            .utf8)
                ))
            rels +=
                "<Relationship Id=\"rIdVba\" Type=\"http://schemas.microsoft.com/office/2006/relationships/vbaProject\" Target=\"./vbaProject.bin\"/>"
            if family == "excel" {
                types +=
                    "<Override PartName=\"/xl/macrosheets/sheet1.xml\" ContentType=\"application/vnd.ms-excel.macrosheet+xml\"/>"
                rels +=
                    "<Relationship Id=\"rIdMacro\" Type=\"\(r)/xlMacrosheet\" Target=\"worksheets/../macrosheets/sheet1.xml\"/>"
                parts.append(("xl/macrosheets/sheet1.xml", Data("<macro/>".utf8)))
            }
        }
        types += "</Types>"
        rels += "</Relationships>"
        parts += [
            ("[Content_Types].xml", Data(types.utf8)),
            (dir + "/_rels/" + FilePath.fileName(main) + ".rels", Data(rels.utf8)),
        ]
        let path = self.path("sample." + format)
        let zip = try ZipWriter(path: path)
        for (name, data) in parts { try zip.add(name, data: data) }
        try zip.close()
        return path
    }
    func testAllVariantsKeepPartsAndChangeMainContentType() throws {
        var checked = 0
        for from in OoxmlConverter.variantOrder {
            let input = try package(from)
            for to in OoxmlConverter.variantOrder
            where to != from && OoxmlConverter.variants[from]?.family == OoxmlConverter.variants[to]?.family {
                let output = path("\(from)-\(to).\(to)")
                try OoxmlConverter.rewrite(input, output, to)
                let source = try ZipReader(path: input)
                let result = try ZipReader(path: output)
                XCTAssertEqual(source.entries.map(\.name), result.entries.map(\.name))
                for entry in source.entries where entry.name != "[Content_Types].xml" {
                    XCTAssertEqual(try source.data(for: entry), try result.data(named: entry.name))
                }
                let types = try XDocument.load(data: XCTUnwrap(result.data(named: "[Content_Types].xml")))
                XCTAssertTrue(
                    types.root.elements(ct + "Override").contains {
                        $0.attributeValue("ContentType") == OoxmlConverter.variants[to]?.contentType
                    })
                checked += 1
            }
        }
        XCTAssertEqual(checked, 30)
        XCTAssertEqual(OoxmlConverter().edges.count, 30)
    }
    func testMacroFreeTargetsRemoveAllMacroPartsAndKeepExternalRelationships() throws {
        for (from, to) in [("docm", "docx"), ("dotm", "dotx"), ("xlsm", "xlsx"), ("pptm", "pptx")] {
            let input = try package(from, true)
            let out = path("clean." + to)
            try OoxmlConverter.rewrite(input, out, to)
            let zip = try ZipReader(path: out)
            XCTAssertFalse(
                zip.entries.contains {
                    $0.name.contains("vbaProject") || $0.name.contains("macrosheets") || $0.name.contains("macro0")
                })
            for entry in zip.entries where entry.name.hasSuffix(".rels") {
                let rels = try XDocument.load(data: zip.data(for: entry)).root.elements(rel + "Relationship")
                XCTAssertTrue(
                    rels.allSatisfy {
                        $0.attributeValue("Id") == "rIdExternal" || !($0.attributeValue("Type") ?? "").contains("Macro")
                    })
                if entry.name != "_rels/.rels" {
                    XCTAssertTrue(rels.contains { $0.attributeValue("TargetMode") == "External" })
                }
            }
            XCTAssertEqual(
                try zip.data(
                    named: OoxmlConverter.variants[from]?.family == "word"
                        ? "word/media/picture.png" : from == "xlsm" ? "xl/media/picture.png" : "ppt/media/picture.png"),
                Data([1, 2, 3, 4]))
        }
    }
    func testMacroEnabledTargetsKeepMacros() throws {
        let input = try package("docm", true)
        let out = path("macro.dotm")
        try OoxmlConverter.rewrite(input, out, "dotm")
        XCTAssertNotNil(try ZipReader(path: out).entry(named: "word/vbaProject.bin"))
    }
    func testXlsmRemovesSheetsAndRenumbersScopedNamesAndViews() throws {
        let input = try package("xlsm", true)
        let out = path("clean.xlsx")
        try OoxmlConverter.rewrite(input, out, "xlsx")
        let book = try XDocument.load(data: XCTUnwrap(ZipReader(path: out).data(named: "xl/workbook.xml")))
        XCTAssertEqual(
            book.root.element(s + "sheets")?.elements(s + "sheet").compactMap { $0.attributeValue("name") },
            ["Before", "After"])
        let names = book.root.element(s + "definedNames")!.elements(s + "definedName")
        XCTAssertEqual(names.compactMap { $0.attributeValue("name") }, ["before", "after", "global"])
        XCTAssertEqual(names[1].attributeValue("localSheetId"), "1")
        XCTAssertNil(book.root.descendants(s + "workbookView").first?.attributeValue("activeTab"))
        XCTAssertEqual(try XlsxReader.read(out).sheets.map(\.name), ["Before", "After"])
    }
    func testInvalidPackageMessages() throws {
        let zip = try ZipWriter(path: path("bad.zip"))
        try zip.add("x", text: "x")
        try zip.close()
        XCTAssertThrowsError(try OoxmlConverter.rewrite(path("bad.zip"), path("out.docx"), "docx")) {
            XCTAssertTrue($0.localizedDescription.contains("no [Content_Types].xml"))
        }
    }
    func testCSharpBaselinePackages() throws {
        struct Scenario: Codable {
            let from: String
            let to: String
            let entries: [String: String]
            let order: [String]
        }
        var actual: [String: Scenario] = [:]
        var cases: [(String, String, Bool)] = OoxmlConverter().edges.map { ($0.from, $0.to, false) }
        cases += [
            ("docm", "docx", true), ("dotm", "dotx", true), ("xlsm", "xlsx", true), ("pptm", "pptx", true),
            ("docm", "dotm", true),
        ]
        for (from, to, macros) in cases {
            let input = try package(from, macros)
            let key = from + "-" + to + (macros ? "-macros" : "")
            let output = path(key + "." + to)
            try OoxmlConverter.rewrite(input, output, to)
            let archive = try ZipReader(path: output)
            var entries: [String: String] = [:]
            for entry in archive.entries { entries[entry.name] = try archive.data(for: entry).base64EncodedString() }
            actual[key] = Scenario(from: from, to: to, entries: entries, order: archive.entries.map(\.name))
            if let export = ProcessInfo.processInfo.environment["FTX_P5_EXPORT_DIR"] {
                let folder = FilePath.combine(export, "ooxml-cases", key)
                try FileManager.default.createDirectoryIfNeeded(folder)
                let target = FilePath.combine(folder, "sample." + from)
                if FileManager.default.fileExists(target) { try FileManager.default.removeItem(atPath: target) }
                try FileManager.default.copyItem(atPath: input, toPath: target)
            }
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/ooxml-baseline.json")
        let expected = try JSONDecoder().decode([String: Scenario].self, from: Data(contentsOf: url))
        for (key, got) in actual {
            let want = try XCTUnwrap(expected[key], key)
            XCTAssertEqual(got.order, want.order, key)
            for (part, data) in got.entries { XCTAssertEqual(data, want.entries[part], key + "/" + part) }
        }
    }

}
