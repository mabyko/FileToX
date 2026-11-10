import CryptoKit
import Foundation
import XCTest

@testable import FileToXEngineKit

enum HwpxAssert {
    static let hh = HwpxWriter.hh, hp = HwpxWriter.hp, hc = HwpxWriter.hc
    static func xml(_ path: String, _ name: String = "Contents/section0.xml") throws -> XElement {
        let zip = try ZipReader(path: path)
        return try XDocument.load(data: XCTUnwrap(zip.data(named: name)), preserveWhitespace: true).root
    }
    static func validPackage(
        _ path: String, _ expectImages: Int? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(raw[8..<10]), [0, 0], file: file, line: line)
        XCTAssertEqual(String(decoding: raw[30..<38], as: UTF8.self), "mimetype", file: file, line: line)
        let zip = try ZipReader(path: path)
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(zip.data(named: "mimetype")), as: UTF8.self), "application/hwp+zip",
            file: file, line: line)
        for e in zip.entries where [".xml", ".hpf", ".rdf"].contains(FilePath.extension(e.name)) {
            _ = try XDocument.load(data: zip.data(for: e))
        }
        let head = try xml(path, "Contents/header.xml")
        let sections = zip.entries.filter { $0.name.hasPrefix("Contents/section") }
        XCTAssertEqual(DocumentXML.int(head.attributeValue("secCnt")), sections.count, file: file, line: line)
        for (container, item) in [
            ("charProperties", "charPr"), ("paraProperties", "paraPr"), ("numberings", "numbering"),
            ("borderFills", "borderFill"), ("tabProperties", "tabPr"),
        ] {
            let c = try XCTUnwrap(head.descendants(hh + container).first)
            XCTAssertEqual(
                DocumentXML.int(c.attributeValue("itemCnt")), c.elements(hh + item).count, file: file, line: line)
        }
        for face in head.descendants(hh + "fontface") {
            let fonts = face.elements(hh + "font")
            XCTAssertEqual(DocumentXML.int(face.attributeValue("fontCnt")), fonts.count, file: file, line: line)
            let lang = try XCTUnwrap(face.attributeValue("lang")).lowercased()
            for r in head.descendants(hh + "fontRef") {
                let id = DocumentXML.int(r.attributeValue(XName(lang))) ?? -1
                XCTAssertTrue(id >= 0 && id < fonts.count, file: file, line: line)
            }
        }
        func ids(_ name: String) -> Set<String> {
            Set(head.descendants(hh + name).compactMap { $0.attributeValue("id") })
        }
        for entry in sections {
            let s = try xml(path, entry.name)
            for r in s.descendants(hp + "run") {
                XCTAssertTrue(ids("charPr").contains(r.attributeValue("charPrIDRef") ?? ""), file: file, line: line)
            }
            for p in s.descendants(hp + "p") {
                XCTAssertTrue(ids("paraPr").contains(p.attributeValue("paraPrIDRef") ?? ""), file: file, line: line)
            }
            for t in s.descendants().filter({ $0.name.localName == "tbl" || $0.name.localName == "tc" }) {
                XCTAssertTrue(
                    ids("borderFill").contains(t.attributeValue("borderFillIDRef") ?? ""), file: file, line: line)
            }
            XCTAssertNotNil(s.descendants(hp + "run").first?.element(hp + "secPr"), file: file, line: line)
        }
        let manifest = String(decoding: try XCTUnwrap(zip.data(named: "Contents/content.hpf")), as: UTF8.self)
        let images = zip.entries.filter { $0.name.hasPrefix("BinData/") }
        if let n = expectImages { XCTAssertEqual(images.count, n, file: file, line: line) }
        for e in sections + images { XCTAssertTrue(manifest.contains(e.name), file: file, line: line) }
    }
    static func headItem(_ path: String, _ kind: String, _ id: String) throws -> XElement {
        try XCTUnwrap(xml(path, "Contents/header.xml").descendants(hh + kind).first { $0.attributeValue("id") == id })
    }
    static func paragraphWith(_ root: XElement, _ text: String) throws -> XElement {
        try XCTUnwrap(
            root.descendants(hp + "p").last {
                $0.elements(hp + "run").flatMap { $0.elements(hp + "t") }.contains { $0.value.contains(text) }
            })
    }
}
enum DocxAssert {
    static func body(_ path: String, _ part: String = "word/document.xml") throws -> XElement {
        let zip = try ZipReader(path: path)
        return try XDocument.load(data: XCTUnwrap(zip.data(named: part)), preserveWhitespace: true).root
    }
    static func readBack(_ path: String) throws -> HDocument {
        try DocxReader.read(path, FilePath.combine(FilePath.directoryName(path)!, "readback-media"))
    }
    static func textOf(_ p: HParagraph) -> String {
        HDocumentWalker.inlinesOf(p.inlines).compactMap { ($0 as? HText)?.text }.joined()
    }
    static func paragraphs(_ blocks: [HBlock]) -> [HParagraph] {
        blocks.flatMap { b -> [HParagraph] in
            if let p = b as? HParagraph {
                return [p] + p.inlines.compactMap { $0 as? HTextBox }.flatMap { paragraphs($0.blocks) }
            }
            if let t = b as? HTable { return t.rows.flatMap(\.cells).flatMap { paragraphs($0.blocks) } }
            return []
        }
    }
    static func validPackage(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let zip = try ZipReader(path: path)
        let types = try XDocument.load(data: XCTUnwrap(zip.data(named: "[Content_Types].xml"))).root
        let ns = XNamespace("http://schemas.openxmlformats.org/package/2006/content-types")
        let overrides = Set(
            types.elements(ns + "Override").compactMap { $0.attributeValue("PartName").map { String($0.dropFirst()) } })
        let defaults = Set(types.elements(ns + "Default").compactMap { $0.attributeValue("Extension") })
        var drawingIds: [String] = []
        for e in zip.entries {
            if e.name != "[Content_Types].xml" {
                XCTAssertTrue(
                    overrides.contains(e.name) || defaults.contains(String(FilePath.extension(e.name).dropFirst())),
                    e.name, file: file, line: line)
            }
            if e.name.hasSuffix(".xml") || e.name.hasSuffix(".rels") {
                let xml = try XDocument.load(data: zip.data(for: e))
                drawingIds += xml.root.descendants(DocxReader.wp + "docPr").compactMap { $0.attributeValue("id") }
                if e.name.hasSuffix(".rels") {
                    let folder = e.name.range(of: "_rels/").map { String(e.name[..<$0.lowerBound]) } ?? ""
                    let owner = folder + String(FilePath.fileName(e.name).dropLast(5))
                    let rels = xml.root.elements(
                        XNamespace("http://schemas.openxmlformats.org/package/2006/relationships") + "Relationship")
                    for r in rels where r.attributeValue("TargetMode") != "External" {
                        XCTAssertNotNil(
                            zip.entry(named: folder + (r.attributeValue("Target") ?? "")), file: file, line: line)
                    }
                    if !owner.isEmpty, let part = zip.entry(named: owner) {
                        let p = try XDocument.load(data: zip.data(for: part))
                        let ids = Set(rels.compactMap { $0.attributeValue("Id") })
                        for a in p.root.descendantsAndSelf().flatMap(\.attributes)
                        where a.name.namespace == DocxReader.r {
                            XCTAssertTrue(ids.contains(a.value), file: file, line: line)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(drawingIds.count, Set(drawingIds).count, file: file, line: line)
    }
}
enum HDocumentAssert {
    static func text(_ blocks: [HBlock]) -> String {
        HDocumentWalker.inlines(blocks).compactMap { ($0 as? HText)?.text }.joined()
    }
    // Stable diagnostic tree. Image paths differ after extraction; compare their bytes instead.
    static func dump(_ doc: HDocument, _ layout: Bool = false) -> String {
        func value(_ item: Any, _ label: String = "") -> String {
            if item is HBlock || item is HInline || item is HDocument || item is HSection || item is HRow
                || item is HCell || item is HHeaderFooter || item is HNumbering
            {
                let m = Mirror(reflecting: item)
                return String(describing: type(of: item)) + "{"
                    + m.children.compactMap { child -> String? in
                        let n = child.label ?? ""
                        if !layout && (n == "height" || n == "width") && item is HRow { return nil }
                        if n == "path", let p = child.value as? String {
                            return "imageBytes:"
                                + ((try? Data(contentsOf: URL(fileURLWithPath: p))).map {
                                    SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                                } ?? "missing")
                        }
                        return n + ":" + value(child.value, n)
                    }.joined(separator: ",") + "}"
            }
            let m = Mirror(reflecting: item)
            if m.displayStyle == .collection {
                return "[" + m.children.map { value($0.value) }.joined(separator: ",") + "]"
            }
            if m.displayStyle == .optional { return m.children.first.map { value($0.value, label) } ?? "nil" }
            return String(describing: item)
        }
        return value(doc)
    }
    static func similar(_ a: HDocument, _ b: HDocument, file: StaticString = #filePath, line: UInt = #line) {
        let c = Comparer()
        c.document(a, b)
        XCTAssertTrue(c.differences.isEmpty, c.differences.prefix(40).joined(separator: "\n"), file: file, line: line)
    }
}
