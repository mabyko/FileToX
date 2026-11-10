import Foundation
import XCTest
import PDFKit
import AppKit
@testable import FileToXEngineKit

final class EbookBaselineTests: EbookTestCase {
    private static let driver = #"""
#!/usr/bin/env python3
"""Drive the installed C# baseline with the shared comparison harness and isolated host state."""
import json
import pathlib
import sys

# Explicit path keeps this usable before the comparison-harness branch is integrated.
tools, manifest_path, result_path = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(tools.resolve()))
from hostwire import Host

manifest = json.loads(manifest_path.read_text())
with Host(manifest["host"], copies=manifest.get("copies"), scratch=manifest_path.parent) as host:
    host.configure(first="ebook")
    results = {}
    for case in manifest["cases"]:
        if case.get("pdf") or case.get("image"):
            preset = host.call("library.get")["presets"][0]
            preset["targetFormat"] = case["target"]
            preset["pdf"].update(case.get("pdf", {}))
            preset["image"].update(case.get("image", {}))
            results[case["id"]] = host.convert([case["input"]], preset=preset)
        else:
            results[case["id"]] = host.convert([case["input"]], targetFormat=case["target"])
    result_path.write_text(json.dumps(results, ensure_ascii=False, indent=2))
"""#
    private func baseline(_ cases: [[String: Any]]) async throws -> [String: [String: Any]] {
        let host = "/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine"
        guard FileManager.default.fileExists(host) else { throw XCTSkip("installed C# baseline not found") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..").standardized.path
        let tools = ProcessInfo.processInfo.environment["FILETOX_ENGINE_COMPARE_TOOLS"] ?? FilePath.combine(repo, "Tools/engine-compare")
        guard FileManager.default.fileExists(FilePath.combine(tools, "hostwire.py")) else { throw XCTSkip("comparison harness not merged; set FILETOX_ENGINE_COMPARE_TOOLS to its Tools/engine-compare folder") }
        let manifest = path("baseline-manifest.json"), results = path("baseline-results.json")
        let data: [String: Any] = ["host": host, "cases": cases, "copies": ["calibre": FileManager.default.currentDirectoryPath + "/build/optional-engines/osx-arm64/calibre/calibre.app"]]
        try JSONSerialization.data(withJSONObject: data).write(to: URL(fileURLWithPath: manifest))
        let result = try await ProcessRunner.run("/usr/bin/python3", ["-I", "-c", Self.driver, tools, manifest, results], timeout: 600)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: results))) as? [String: [String: Any]])
    }
    private func output(_ result: [String: Any]) throws -> String {
        XCTAssertEqual(result["state"] as? String, "completed", String(describing: result))
        let files = try XCTUnwrap(result["files"] as? [[String: Any]])
        let outputs = files.flatMap { $0["outputs"] as? [[String: Any]] ?? [] }
        return try XCTUnwrap(outputs.first?["path"] as? String)
    }
    private func canonical(_ text: String) -> String {
        var value = text
        for (pattern, replacement) in [
            (#"urn:uuid:[0-9a-fA-F-]+"#, "urn:uuid:UUID"),
            (#"<id>[0-9a-fA-F-]{36}</id>"#, "<id>UUID</id>"),
            (#"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#, "DATE"),
            (#"\s+(/?>)"#, "$1"), (#">\s+<"#, "><")
        ] {
            let regex = try! NSRegularExpression(pattern: pattern)
            value = regex.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length), withTemplate: replacement)
        }
        // XmlWriter chooses p4 here while the libxml2-backed writer chooses p1; namespace URIs are identical.
        let declarations = EbookRegex.matches(#"xmlns:(p\d+)="([^"]+)""#, value).map { EbookRegex.group($0, value, 1) }
        for prefix in declarations {
            value = value.replacingOccurrences(of: "xmlns:" + prefix + "=", with: "xmlns:auto=")
            value = value.replacingOccurrences(of: prefix + ":", with: "auto:")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func testComicExifOrientationAgainstInstalledCSharp() async throws {
        let comic = path("rotated.cbz"), zip = try ZipWriter(path: comic)
        try zip.add("page.jpg", data: EbookBuilders.picture(80, 120, true, orientation: 6)); try zip.close()
        let results = try await baseline([["id": "rotated", "input": comic, "target": "pdf"]])
        let native = try await convert(comic, "cbz", "pdf"), cs = try output(XCTUnwrap(results["rotated"]))
        let a = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: native))?.page(at: 0)?.bounds(for: .mediaBox))
        let b = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: cs))?.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(a.width, b.width, accuracy: 0.1); XCTAssertEqual(a.height, b.height, accuracy: 0.1)
    }
    func testPdfRenderPageRangeRotationAndAnnotationsAgainstInstalledCSharp() async throws {
        let source = path("annotated.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 120, height: 180)
        let consumer = CGDataConsumer(url: URL(fileURLWithPath: source) as CFURL)!, context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(bounds)
            context.setFillColor(CGColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFDocument(url: URL(fileURLWithPath: source))!, page = document.page(at: 1)!
        page.rotation = 90
        let annotation = PDFAnnotation(bounds: CGRect(x: 50, y: 60, width: 40, height: 50), forType: .square, withProperties: nil)
        annotation.color = .red; annotation.interiorColor = .yellow; annotation.shouldPrint = true; page.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: URL(fileURLWithPath: source)))
        let results = try await baseline([["id": "render", "input": source, "target": "cbz", "pdf": ["pageRange": "2", "renderDpi": 96], "image": ["quality": 75]]])
        var preset = Preset(); preset.pdf.pageRange = "2"; preset.pdf.renderDpi = 96; preset.image.quality = 75
        let native = try await convert(source, "pdf", "cbz", preset), cs = try output(XCTUnwrap(results["render"]))
        let a = try ZipReader(path: native), b = try ZipReader(path: cs)
        XCTAssertEqual(a.entries.map(\.name), ["001.jpg"]); XCTAssertEqual(a.entries.map(\.name), b.entries.map(\.name))
        let nativeImage = try save("native.jpg", XCTUnwrap(a.data(named: "001.jpg"))), csImage = try save("baseline.jpg", XCTUnwrap(b.data(named: "001.jpg")))
        let left = try EbookFiles.cgImage(nativeImage), right = try EbookFiles.cgImage(csImage)
        XCTAssertEqual(left.width, right.width); XCTAssertEqual(left.height, right.height)
        func pixels(_ image: CGImage) -> [UInt8] {
            let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let lhs = pixels(left), rhs = pixels(right)
        if lhs.count == rhs.count {
            let error = zip(lhs, rhs).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + Double(abs(Int($1.element.0) - Int($1.element.1))) } / Double(left.width * left.height * 3)
            XCTAssertLessThan(error, 6, "PDFKit / PDFium mean color difference")
        }
    }
    func testPlainTextBookPackagesAgainstInstalledCSharp() async throws {
        let txt = try save("plain.txt", Data("First paragraph has <xml> & Unicode 한글.\nSame paragraph.\n\nSecond paragraph.\n".utf8))
        let formats = ["epub", "htmlz", "txtz"]
        let results = try await baseline(formats.map { ["id": $0, "input": txt, "target": $0] })
        for format in formats {
            let native = try await convert(txt, "txt", format), cs = try output(XCTUnwrap(results[format]))
            let a = try ZipReader(path: native), b = try ZipReader(path: cs)
            XCTAssertEqual(a.entries.map(\.name), b.entries.map(\.name), format)
            for entry in a.entries {
                let lhs = try a.data(for: entry), rhs = try XCTUnwrap(b.data(named: entry.name))
                if entry.name.hasSuffix(".txt") || entry.name.hasSuffix(".css") { XCTAssertEqual(lhs, rhs, "\(format): \(entry.name)") }
                else { XCTAssertEqual(canonical(String(decoding: lhs, as: UTF8.self)), canonical(String(decoding: rhs, as: UTF8.self)), "\(format): \(entry.name)") }
            }
        }
    }
    func testRichEbookExportsAgainstInstalledCSharp() async throws {
        let epub = try EbookBuilders.epub(folder), fb2 = try EbookBuilders.fb2(folder)
        let mobi = try save("source.mobi", EbookBuilders.mobi(Data("<html><body><h1>Title</h1><p>Ünïcödé 한글 <b>bold</b>.</p></body></html>".utf8), [], EbookBuilders.MobiOptions(title: "Mobi comparison")))
        var cases: [[String: Any]] = [
            ["id": "fb2-epub", "input": fb2, "target": "epub"],
            ["id": "mobi-epub", "input": mobi, "target": "epub"]
        ]
        for target in ["fb2", "htmlz", "txtz", "html", "txt", "md"] { cases.append(["id": "epub-" + target, "input": epub, "target": target]) }
        let results = try await baseline(cases)
        for item in cases {
            let id = item["id"] as! String, input = item["input"] as! String, target = item["target"] as! String
            let from = FormatRegistry.detect(input)!.id
            let native = try await convert(input, from, target), cs = try output(XCTUnwrap(results[id]))
            if ["epub", "htmlz", "txtz"].contains(target) {
                let a = try ZipReader(path: native), b = try ZipReader(path: cs)
                XCTAssertEqual(a.entries.map(\.name), b.entries.map(\.name), id)
                for entry in a.entries {
                    let left = try a.data(for: entry), right = try XCTUnwrap(b.data(named: entry.name))
                    if entry.name.hasSuffix(".png") || entry.name.hasSuffix(".jpg") { XCTAssertEqual(left, right, "\(id): \(entry.name)") }
                    else { XCTAssertEqual(canonical(String(decoding: left, as: UTF8.self)), canonical(String(decoding: right, as: UTF8.self)), "\(id): \(entry.name)") }
                }
            } else {
                var left = try String(contentsOfFile: native, encoding: .utf8), right = try String(contentsOfFile: cs, encoding: .utf8)
                if target == "md" {
                    left = left.replacingOccurrences(of: EbookFiles.uriEscape(FilePath.fileNameWithoutExtension(native) + "_files"), with: "IMAGES")
                    right = right.replacingOccurrences(of: EbookFiles.uriEscape(FilePath.fileNameWithoutExtension(cs) + "_files"), with: "IMAGES")
                }
                XCTAssertEqual(canonical(left), canonical(right), id)
            }
        }
    }
    func testStandaloneOutputsAgainstInstalledCSharp() async throws {
        let txt = try save("book.txt", Data("Hello from Filee.\n\nSecond paragraph with 한글 & XML <characters>.".utf8))
        let cbz = try EbookBuilders.cbz(folder)
        let replica = try save("replica.azw4", EbookBuilders.printReplica(Data("%PDF-1.7 exact data".utf8)))
        let locked = try save("locked.azw", EbookBuilders.mobi(Data("locked".utf8), [], EbookBuilders.MobiOptions(encryption: 2)))
        let cases = [
            ["id": "txt-fb2", "input": txt, "target": "fb2"],
            ["id": "cbz-epub", "input": cbz, "target": "epub"],
            ["id": "cbz-pdf", "input": cbz, "target": "pdf"],
            ["id": "azw4-pdf", "input": replica, "target": "pdf"],
            ["id": "drm", "input": locked, "target": "epub"]
        ]
        let results = try await baseline(cases)
        let nativeFb2 = try await convert(txt, "txt", "fb2"), csFb2 = try output(XCTUnwrap(results["txt-fb2"]))
        let a = try String(contentsOfFile: nativeFb2, encoding: .utf8), b = try String(contentsOfFile: csFb2, encoding: .utf8)
        XCTAssertEqual(canonical(a), canonical(b))
        let nativeEpub = try await convert(cbz, "cbz", "epub"), csEpub = try output(XCTUnwrap(results["cbz-epub"]))
        let nativeZip = try ZipReader(path: nativeEpub), csZip = try ZipReader(path: csEpub)
        XCTAssertEqual(nativeZip.entries.map(\.name), csZip.entries.map(\.name))
        for entry in nativeZip.entries {
            let native = try nativeZip.data(for: entry), baseline = try XCTUnwrap(csZip.data(named: entry.name))
            if entry.name.hasSuffix(".png") || entry.name.hasSuffix(".jpg") { XCTAssertEqual(native, baseline, entry.name) }
            else { XCTAssertEqual(canonical(String(decoding: native, as: UTF8.self)), canonical(String(decoding: baseline, as: UTF8.self)), entry.name) }
        }
        let nativePdf = try await convert(cbz, "cbz", "pdf"), csPdf = try output(XCTUnwrap(results["cbz-pdf"]))
        let nativeDocument = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: nativePdf))), csDocument = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: csPdf)))
        XCTAssertEqual(nativeDocument.pageCount, csDocument.pageCount)
        for i in 0..<nativeDocument.pageCount {
            let a = nativeDocument.page(at: i)!.bounds(for: .mediaBox), b = csDocument.page(at: i)!.bounds(for: .mediaBox)
            XCTAssertEqual(a.width, b.width, accuracy: 0.1); XCTAssertEqual(a.height, b.height, accuracy: 0.1)
        }
        let nativeReplica = try await convert(replica, "azw4", "pdf"), csReplica = try output(XCTUnwrap(results["azw4-pdf"]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: nativeReplica)), try Data(contentsOf: URL(fileURLWithPath: csReplica)))
        let drm = try XCTUnwrap(results["drm"]), files = try XCTUnwrap(drm["files"] as? [[String: Any]])
        XCTAssertEqual(drm["state"] as? String, "failed"); XCTAssertEqual(files.first?["errorDetail"] as? String, EbookFiles.drmMessage)
    }
}
