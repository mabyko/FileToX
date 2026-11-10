// Opt-in comparisons with Filee on corpora produced by the Filee harness outside the repository:
// MARKDIG_CORPUS=<folder with inputs.json and out-<pipeline>.json> swift test --filter MarkdownCorpusComparisonTests
// compares the Markdig port's HTML and plain text, and MarkdownReader's documents when out-mdread.json is there;
// PANDOC_AST_CORPUS=<folder with inputs.json of `pandoc -t json` texts and out-pandocast.json> compares PandocAstReader.
// Documents are compared in the harness' dump format. Skipped in normal runs; the embedded conformance tests cover
// the Markdig cases offline.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class MarkdownCorpusComparisonTests: XCTestCase {
    /// Compares `actual(input, folder)` with out-<name>.json. "!!CRASH" marks inputs on which Filee's reader overflowed
    /// the stack (the port reads them; nothing to compare), "!!SKIP:" inputs Filee could not hand to the reader.
    private func compare(_ name: String, from variable: String = "MARKDIG_CORPUS", _ actual: (String, URL) throws -> String) throws {
        guard let path = ProcessInfo.processInfo.environment[variable] else { throw XCTSkip("\(variable) not set") }
        let folder = URL(fileURLWithPath: path)
        let file = folder.appendingPathComponent("out-\(name).json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("no out-\(name).json") }
        let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("inputs.json"))) as! [String]
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String]
        var failures: [Int] = []
        var report = ""
        for (i, input) in inputs.enumerated() {
            let result: String
            do {
                result = try actual(input, folder)
            } catch let error as Markdown.DepthLimitError {
                result = "!!EXCEPTION ArgumentException: \(error.localizedDescription)"
            } catch {
                result = "!!EXCEPTION \(error)"
            }
            if expected[i] == "!!CRASH" || expected[i].hasPrefix("!!SKIP:") { continue }
            if result != expected[i] {
                failures.append(i)
                if failures.count <= 40 {
                    report += "#\(i) input: \(input.debugDescription)\n  expected: \(expected[i].debugDescription)\n  actual:   \(result.debugDescription)\n"
                }
            }
        }
        try? report.write(to: folder.appendingPathComponent("swift-\(name).report.txt"), atomically: true, encoding: .utf8)
        try? (failures.map(String.init).joined(separator: "\n")).write(to: folder.appendingPathComponent("swift-\(name).failures.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(failures.count, 0, "\(name): \(failures.count) of \(inputs.count) differ, first: \(failures.prefix(30))")
    }

    func testCommonMarkPipeline() throws { try compare("commonmark") { markdown, _ in try Markdown.toHtml(markdown, .commonMark) } }
    func testAdvancedPipeline() throws { try compare("advanced") { markdown, _ in try Markdown.toHtml(markdown, .advanced) } }
    func testFileePipeline() throws { try compare("filee") { markdown, _ in try Markdown.toHtml(markdown, .advancedWithYaml) } }
    func testFileePlainText() throws { try compare("filee-text") { markdown, _ in try Markdown.toPlainText(markdown, .advancedWithYaml) } }

    func testMarkdownReader() throws {
        try compare("mdread") { markdown, folder in MarkupTestSupport.dump(try MarkdownReader.read(markdown, folder.path)) }
    }

    func testPandocAstReader() throws {
        try compare("pandocast", from: "PANDOC_AST_CORPUS") { text, folder in
            let ast = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
            let document = try PandocAstReader.read(ast) { target in
                let path = target.hasPrefix("/") ? target : FilePath.combine(folder.path, MarkupConvert.unescapeDataString(target))
                return FileManager.default.fileExists(atPath: path) ? FilePath.fullPath(path) : nil
            }
            return MarkupTestSupport.dump(document)
        }
    }
}
