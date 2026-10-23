import Foundation
import XCTest
import PDFKit
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
        results[case["id"]] = host.convert([case["input"]], targetFormat=case["target"])
    result_path.write_text(json.dumps(results, ensure_ascii=False, indent=2))
"""#
    private func baseline(_ cases: [[String: String]]) async throws -> [String: [String: Any]] {
        let host = "/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine"
        guard FileManager.default.fileExists(host) else { throw XCTSkip("installed C# baseline not found") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized.path
        let tools = ProcessInfo.processInfo.environment["FILETOX_ENGINE_COMPARE_TOOLS"] ?? FilePath.combine(repo, "Tools/engine-compare")
        guard FileManager.default.fileExists(FilePath.combine(tools, "hostwire.py")) else { throw XCTSkip("comparison harness not merged; set FILETOX_ENGINE_COMPARE_TOOLS to its Tools/engine-compare folder") }
        let manifest = path("baseline-manifest.json"), results = path("baseline-results.json")
        let data: [String: Any] = ["host": host, "cases": cases, "copies": ["calibre": "build/optional-engines/osx-arm64/calibre/calibre.app"]]
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
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
