// Opt-in comparison with Markdig (Filee's library) on a corpus produced by the Filee harness outside the repository:
// MARKDIG_CORPUS=<folder with specs.json, inputs.json and out-<pipeline>.json> swift test --filter MarkdownCorpusComparisonTests
// Skipped in normal runs; the embedded conformance tests cover the same cases offline.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class MarkdownCorpusComparisonTests: XCTestCase {
    private func corpus() throws -> (folder: URL, inputs: [String]) {
        guard let folder = ProcessInfo.processInfo.environment["MARKDIG_CORPUS"] else { throw XCTSkip("MARKDIG_CORPUS not set") }
        let url = URL(fileURLWithPath: folder)
        let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("inputs.json"))) as! [String]
        return (url, inputs)
    }

    private func compare(_ name: String, _ pipeline: Markdown.Pipeline, plainText: Bool = false) throws {
        let (folder, inputs) = try corpus()
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("out-\(name).json"))) as! [String]
        var failures: [Int] = []
        var report = ""
        for (i, input) in inputs.enumerated() {
            let actual: String
            do {
                actual = plainText ? try Markdown.toPlainText(input, pipeline) : try Markdown.toHtml(input, pipeline)
            } catch {
                actual = "!!EXCEPTION \(error)"
            }
            if actual != expected[i] {
                failures.append(i)
                if failures.count <= 40 {
                    report += "#\(i) input: \(input.debugDescription)\n  expected: \(expected[i].debugDescription)\n  actual:   \(actual.debugDescription)\n"
                }
            }
        }
        try? report.write(to: folder.appendingPathComponent("swift-\(name).report.txt"), atomically: true, encoding: .utf8)
        try? (failures.map(String.init).joined(separator: "\n")).write(to: folder.appendingPathComponent("swift-\(name).failures.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(failures.count, 0, "\(name): \(failures.count) of \(inputs.count) differ, first: \(failures.prefix(30))")
    }

    func testCommonMarkPipeline() throws { try compare("commonmark", .commonMark) }
    func testAdvancedPipeline() throws { try compare("advanced", .advanced) }
    func testFileePipeline() throws { try compare("filee", .advancedWithYaml) }
    func testFileePlainText() throws { try compare("filee-text", .advancedWithYaml, plainText: true) }
}
