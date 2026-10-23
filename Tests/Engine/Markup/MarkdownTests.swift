// Port of Filee's MarkdownTests: Markdown without optional engines (the built-in parser), the progress estimate of
// silent engines, and routes. The LibreOffice warm-up fact belongs to the LibreOffice engine's tests.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class MarkdownTests: XCTestCase {
    private static let sample = """
        ---
        title: 회의록
        ---

        # 주간 회의

        오늘 결정한 것: **배포**, *문서 정리*, `v1.0.1`.

        | 항목 | 담당 |
        |------|------|
        | 설치 | 민지 |

        ![그림](chart.png)

        - [x] 끝낸 일
        - [ ] 남은 일
        """

    /// Only engines that ship with the app (or run in-process): no Pandoc or LibreOffice.
    private static let optionalEngines = ["pandoc", "libreoffice"]

    private func builtInPlanner(_ assumeInstalled: [String] = []) -> RoutePlanner {
        ConverterCatalog(MarkupTestSupport.converters(excluding: Self.optionalEngines)).createPlanner(assumeInstalled)
    }

    private func writeSample(_ folder: String) throws -> String {
        try MarkupTestSupport.png(160, 90).write(to: URL(fileURLWithPath: FilePath.combine(folder, "chart.png")))
        let md = FilePath.combine(folder, "회의록.md")
        try Data(Self.sample.utf8).write(to: URL(fileURLWithPath: md))
        return md
    }

    func testMarkdownRoutesNeedNoOptionalEngine() throws {
        let planner = builtInPlanner()
        XCTAssertEqual(planner.plan("md", "html")?.steps.map(\.converter.id), ["markdown"])
        XCTAssertEqual(planner.plan("md", "txt")?.steps.map(\.converter.id), ["markdown"])
        XCTAssertEqual(planner.plan("md", "hwpx")?.steps.map(\.converter.id), ["hwpx-writer"])
        // PDF: the built-in HWPX writer, then rhwp (bundled with the installer).
        XCTAssertEqual(builtInPlanner(["rhwp"]).plan("md", "pdf")?.steps.map(\.converter.id), ["hwpx-writer", "rhwp"])
    }

    func testBuiltInMarkdownWinsOverPandocForHtmlAndText() {
        let planner = ConverterCatalog(MarkupTestSupport.converters()).createPlanner(["pandoc"])
        XCTAssertEqual(planner.plan("md", "html")?.steps.map(\.converter.id), ["markdown"])
        XCTAssertEqual(planner.plan("md", "txt")?.steps.map(\.converter.id), ["markdown"])
    }

    func testMarkdownToHtmlAndText() async throws {
        let folder = try MarkupTestSupport.newFolder()
        let md = try writeSample(folder)

        let html = try String(contentsOfFile: try await MarkupTestSupport.convert(md, "html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<strong>배포</strong>"))
        XCTAssertTrue(html.contains("src=\"chart.png\"")) // next to the Markdown file the relative path still works
        XCTAssertFalse(html.contains("title: 회의록"))

        let text = try String(contentsOfFile: try await MarkupTestSupport.convert(md, "txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("주간 회의"))
        XCTAssertTrue(text.contains("배포"))
        XCTAssertFalse(text.contains("**"))
    }

    func testHtmlWrittenElsewherePointsImagesAtTheOriginalFiles() throws {
        let folder = try MarkupTestSupport.newFolder()
        let md = try writeSample(folder)

        let html = try MarkdownConverter.toHtml(Self.sample, md, FilePath.combine(try MarkupTestSupport.newFolder(), "step.html"))

        XCTAssertTrue(html.contains("src=\"\(MarkupConvert.fileUri(FilePath.combine(folder, "chart.png")))\""))
    }

    func testImageUrisAreEscapedLikeDotNet() {
        // Expected values: `new Uri(path).AbsoluteUri` on .NET 10.
        let cases = [
            ("/tmp/로고 1.png", "file:///tmp/%EB%A1%9C%EA%B3%A0%201.png"),
            ("/tmp/\u{1105}\u{1169}.png", "file:///tmp/%E1%84%85%E1%85%A9.png"), // no normalization either way
            ("/tmp/x~y #1?.png", "file:///tmp/x~y%20%231%3F.png"),
            ("/tmp/[a]{b}|c^d`e\"f<g>h\\i.png", "file:///tmp/[a]%7Bb%7D%7Cc%5Ed%60e%22f%3Cg%3Eh%5Ci.png"),
            ("/tmp/!$&'()*+,;=:@.png", "file:///tmp/!$&'()*+,;=:@.png"),
            ("/tmp/é😀\u{A0}\ttab.png", "file:///tmp/%C3%A9%F0%9F%98%80%C2%A0%09tab.png"),
            ("/tmp/a b/c%20d.png", "file:///tmp/a%20b/c%2520d.png"),
            ("/tmp/100%.png", "file:///tmp/100%25.png"),
        ]
        for (path, uri) in cases { XCTAssertEqual(MarkupConvert.fileUri(path), uri) }
    }

    func testMarkdownToHwpxKeepsStructure() async throws {
        let folder = try MarkupTestSupport.newFolder()
        let hwpx = try await MarkupTestSupport.convert(try writeSample(folder), "hwpx")

        try HwpxAssert.validPackage(hwpx, 1)
        let document = try HwpxReader.read(hwpx, FilePath.combine(folder, "readback"))
        let text = document.sections.map { HDocumentWalker.inlines($0.blocks).compactMap { ($0 as? HText)?.text }.joined(separator: " ") }.joined()
        for expected in ["주간 회의", "배포", "v1.0.1", "설치", "민지", "☑", "끝낸 일", "☐", "남은 일"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains("title:"))
        XCTAssertEqual(try HwpxAssert.xml(hwpx).descendants(HwpxAssert.hp + "tbl").count, 1)
    }

    func testMarkdownToHwpxEscapesMarkupCharactersBeforeCombiningMarks() async throws {
        let md = FilePath.combine(try MarkupTestSupport.newFolder(), "marks.md")
        let text = "less <\u{338} than, R&\u{301}D, \"\u{1F3FB}, '\u{301} and >\u{20D2}"
        try Data(text.utf8).write(to: URL(fileURLWithPath: md))

        let hwpx = try await MarkupTestSupport.convert(md, "hwpx")

        try HwpxAssert.validPackage(hwpx) // every XML part parses
        let document = try HwpxReader.read(hwpx, FilePath.combine(FilePath.directoryName(md)!, "readback"))
        let read = document.sections.map { HDocumentWalker.inlines($0.blocks).compactMap { ($0 as? HText)?.text }.joined() }.joined()
        XCTAssertEqual(Array(read.unicodeScalars), Array(text.unicodeScalars))
    }

    func testFootnotesReferringToThemselvesAndLongChainsAreRead() async throws {
        // Filee's reader recursed forever on a footnote that refers to itself and overflowed the stack; the reference
        // inside the note is left out.
        let cycle = try MarkdownReader.read("Text[^a]\n\n[^a]: Note [^b]\n\n[^b]: Back to [^a] here.\n", NSTemporaryDirectory())
        let paragraph = try XCTUnwrap(cycle.sections.first?.blocks.first as? HParagraph)
        let a = try XCTUnwrap(paragraph.inlines.last as? HNote)
        let b = try XCTUnwrap((a.blocks.first as? HParagraph)?.inlines.last as? HNote)
        XCTAssertEqual(HDocumentWalker.inlines(b.blocks).compactMap { $0 as? HNote }.count, 0)
        XCTAssertEqual(HDocumentWalker.inlines(b.blocks).compactMap { ($0 as? HText)?.text }.joined(), "Back to  here.")

        // A chain of notes nests one level per note; read from a pool thread, as conversions are. (Releasing such a
        // document recurses per level too, so that happens on a large stack here.)
        let count = 3000
        let chain = "A[^1]\n\n" + (1..<count).map { "[^\($0)]: x[^\($0 + 1)]\n" }.joined(separator: "\n") + "\n[^\(count)]: end\n"
        let depth = try await Task.detached { () throws -> Int in
            var document: HDocument? = try MarkdownReader.read(chain, NSTemporaryDirectory())
            var depth = 0
            try MarkupConvert.onLargeStack {
                var inlines = (document?.sections.first?.blocks.first as? HParagraph)?.inlines ?? []
                while let note = inlines.last as? HNote {
                    depth += 1
                    inlines = (note.blocks.first as? HParagraph)?.inlines ?? []
                }
                inlines = []
                document = nil
            }
            return depth
        }.value
        XCTAssertEqual(depth, count)
    }

    func testDeepNestingFailsLikeMarkdigOrIsReadInsteadOfOverflowingTheStack() async throws {
        // Parsing up to Markdig's depth limits, reading and releasing the tree recurse per level, deeper than the stack
        // of the pool threads conversions run on.
        let folder = try MarkupTestSupport.newFolder()
        let lists = FilePath.combine(folder, "lists.md")
        try Data((String(repeating: "- ", count: 1000) + "x").utf8).write(to: URL(fileURLWithPath: lists))
        for target in ["html", "txt", "hwpx"] {
            let job = await MarkupTestSupport.run([lists], MarkupTestSupport.preset(target))
            XCTAssertEqual(job.files.first?.state, .failed, target)
            XCTAssertEqual(job.files.first?.errorDetail, Markdown.DepthLimitError().localizedDescription, target)
        }
        // 1 500 nested emphases: past the HTML renderer's limit, but read into HWPX (Filee's reader overflowed the stack).
        let emphasis = FilePath.combine(folder, "emphasis.md")
        try Data((String(repeating: "*", count: 3000) + "x" + String(repeating: "*", count: 3000)).utf8).write(to: URL(fileURLWithPath: emphasis))
        let html = await MarkupTestSupport.run([emphasis], MarkupTestSupport.preset("html"))
        XCTAssertEqual(html.files.first?.errorDetail, Markdown.DepthLimitError().localizedDescription)
        try HwpxAssert.validPackage(try await MarkupTestSupport.convert(emphasis, "hwpx"))
    }

    func testMarkdownToPdfWithBuiltInEngines() async throws {
        guard RhwpConverter.locate() != nil else { throw XCTSkip("rhwp not found (bundled engine)") }
        let pdf = try await MarkupTestSupport.convert(try writeSample(try MarkupTestSupport.newFolder()), "pdf")
        let data = try Data(contentsOf: URL(fileURLWithPath: pdf))
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
    }

    func testProgressEstimateRisesTowardsTheBoundAndNeverReachesIt() {
        let values = [0, 0.5, 1, 2, 4, 8, 30].map { ProgressEstimate.value(elapsed: $0, typical: 2, from: 0.1, to: 0.9) }
        XCTAssertEqual(values[0], 0.1, accuracy: 1e-6)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $1 > $0 })
        XCTAssertLessThan(values.last!, 0.9)
        let atTypical = ProgressEstimate.value(elapsed: 2, typical: 2, from: 0.1, to: 0.9)
        XCTAssertTrue((0.6...0.62).contains(atTypical)) // 1 - 1/e of the way
    }

    func testProgressEstimateReportsWhileRunningAndStopsWhenStopped() async throws {
        final class Reports: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func add(_ value: Double) { lock.withLock { values.append(value) } }
            var all: [Double] { lock.withLock { values } }
        }
        let reports = Reports()
        let estimate = ProgressEstimate.start({ reports.add($0) }, typical: 1)
        // Timer callbacks run late on a busy machine: wait for two reports, up to 10 s.
        let deadline = Date().addingTimeInterval(10)
        while reports.all.count < 2 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        estimate.stop()
        // A callback that was already running when the estimate stopped may still report once.
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = reports.all.count
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertEqual(reports.all.count, count)
        XCTAssertTrue(reports.all.allSatisfy { (0.1...0.9).contains($0) })
    }
}
