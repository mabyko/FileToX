// CommonMark conformance and Markdig parity, offline: every example of Markdig 1.4.0's spec tests (the 652 CommonMark
// 0.31.2 examples and the extension specs) must render exactly as Markdig renders it, byte for byte, with the
// CommonMark pipeline, Filee's pipeline (HTML and plain text) and UseAdvancedExtensions().

import Foundation
import XCTest
@testable import FileToXEngineKit

final class MarkdownConformanceTests: XCTestCase {
    private struct Case {
        let source: String
        let markdown: String
        let commonMark: String?
        let filee: String
        let advanced: String?
        let text: String
    }

    private static let cases: [Case] = {
        let items = try! JSONSerialization.jsonObject(with: Data(MarkdownConformanceData.json.utf8)) as! [[String: String]]
        return items.map {
            Case(source: $0["s"]!, markdown: $0["md"]!, commonMark: $0["cm"], filee: $0["filee"]!, advanced: $0["adv"], text: $0["text"]!)
        }
    }()

    private func check(_ pipeline: Markdown.Pipeline, plainText: Bool = false, _ expected: (Case) -> String?) {
        var checked = 0
        var failures: [String] = []
        for item in Self.cases {
            guard let want = expected(item) else { continue }
            checked += 1
            let got = (try? plainText ? Markdown.toPlainText(item.markdown, pipeline) : Markdown.toHtml(item.markdown, pipeline)) ?? "<error>"
            if got != want { failures.append("\(item.source): \(item.markdown.debugDescription)\n  want \(want.debugDescription)\n  got  \(got.debugDescription)") }
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(checked) differ:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    func testCommonMarkSpecExamples() {
        XCTAssertEqual(Self.cases.filter { $0.commonMark != nil }.count, 652)
        check(.commonMark) { $0.commonMark }
    }

    func testFileePipelineMatchesMarkdig() { check(.advancedWithYaml) { $0.filee } }

    func testFileePlainTextMatchesMarkdig() { check(.advancedWithYaml, plainText: true) { $0.text } }

    func testAdvancedPipelineMatchesMarkdig() { check(.advanced) { $0.advanced ?? $0.filee } }

    func testNestingPastMarkdigsLimitFailsLikeMarkdig() {
        XCTAssertThrowsError(try Markdown.toHtml(String(repeating: ">", count: 200) + " x", .advancedWithYaml)) { error in
            XCTAssertTrue(error is Markdown.DepthLimitError)
        }
        XCTAssertNoThrow(try Markdown.toHtml(String(repeating: ">", count: 120) + " x", .advancedWithYaml))
    }
}
