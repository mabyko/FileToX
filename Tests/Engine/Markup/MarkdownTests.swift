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

        XCTAssertTrue(html.contains("src=\"\(URL(fileURLWithPath: FilePath.combine(folder, "chart.png")).absoluteString)\""))
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
