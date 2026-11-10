import XCTest
@testable import FileToXEngineKit

final class RoutePlannerTests: XCTestCase {
    func testDirectEdgeAndTwoStepRoute() {
        let a = CoreFakeConverter("rhwp", ConversionEdge("hwpx", "pdf")), b = CoreFakeConverter("pdfium", ConversionEdge("pdf", "png"))
        let route = RoutePlanner([a, b]).plan("HWPX", "PNG")!
        XCTAssertEqual(route.steps.map { $0.from + "→" + $0.to }, ["hwpx→pdf", "pdf→png"])
        XCTAssertTrue(route.steps[0].converter === a)
        XCTAssertEqual(RoutePlanner([a]).plan("hwpx", "pdf")?.steps.count, 1)
    }
    func testCheaperRouteAndPriorityBreakTies() {
        let a = CoreFakeConverter("slow", ConversionEdge("docx", "pdf", 30)), b = CoreFakeConverter("fast", ConversionEdge("docx", "pdf", 10))
        XCTAssertEqual(RoutePlanner([a,b]).plan("docx", "pdf")?.steps.first?.converter.id, "fast")
        let c = CoreFakeConverter("word", ConversionEdge("docx", "pdf"))
        XCTAssertEqual(RoutePlanner([c,b], priorityPenalty: { $0.id == "word" ? 5 : 0 }).plan("docx", "pdf")?.steps.first?.converter.id, "fast")
    }
    func testSelfEdgeImpossibleAndMaxSteps() {
        let c = CoreFakeConverter("chain", ConversionEdge("a", "b"), ConversionEdge("b", "c"), ConversionEdge("c", "d"), ConversionEdge("d", "e"), ConversionEdge("b", "a"))
        XCTAssertNil(RoutePlanner([c]).plan("a", "a")); XCTAssertNil(RoutePlanner([c]).plan("z", "x"))
        XCTAssertNotNil(RoutePlanner([c]).plan("a", "d")); XCTAssertNil(RoutePlanner([c]).plan("a", "e"))
        XCTAssertNotNil(RoutePlanner([CoreFakeConverter("self", ConversionEdge("jpg", "jpg"))]).plan("jpg", "jpg"))
    }
    func testGeneratedPdfDoesNotUseTextExtractionToReachRichDocuments() {
        let engines = [
            CoreFakeConverter("vector", ConversionEdge("svg", "pdf")),
            CoreFakeConverter("pdf-text", ConversionEdge("pdf", "txt", 10, isTextExtraction: true)),
            CoreFakeConverter("documents", ConversionEdge("pdf", "docx", 14), ConversionEdge("docx", "odt"),
                ConversionEdge("txt", "odt"), ConversionEdge("txt", "txtz"), ConversionEdge("docx", "txtz")),
        ]
        // Include a penalty so rebuilding edges cannot accidentally lose the extraction flag.
        let planner = RoutePlanner(engines, priorityPenalty: { _ in 3 })
        XCTAssertEqual(planner.plan("svg", "odt")?.steps.map(\.to), ["pdf", "docx", "odt"])
        XCTAssertEqual(planner.plan("svg", "txt")?.steps.map(\.to), ["pdf", "txt"])
        XCTAssertEqual(planner.plan("svg", "txtz")?.steps.map(\.to), ["pdf", "docx", "txtz"])
    }
    func testRealImageDocumentRoutesPreservePagesAndTextRequestsStayExplicit() {
        let engines = EngineRegistry.createAll(EngineEnvironment(dataDirectory: FileManager.default.temporaryDirectory.path))
        let priority = AppSettings().enginePriority
        // Test default costs assuming all engines are available, without probing external programs.
        let planner = RoutePlanner(engines, priorityPenalty: { min(priority.firstIndex(of: $0.id) ?? priority.count, 9) })
        XCTAssertEqual(planner.plan("svg", "odt")?.steps.map { $0.converter.id }, ["vector", "docx-writer", "libreoffice"])
        XCTAssertEqual(planner.plan("webp", "epub")?.steps.map { $0.converter.id }, ["pdfsharp", "docx-writer", "ebook"])
        XCTAssertEqual(planner.plan("png", "txtz")?.steps.map { $0.converter.id }, ["pdfsharp", "docx-writer", "ebook"])
        XCTAssertEqual(planner.plan("png", "txt")?.steps.map { $0.converter.id }, ["pdfsharp", "pdf-text"])
        XCTAssertEqual(planner.plan("pdf", "txt")?.steps.map { $0.converter.id }, ["pdf-text"])
        // An original PDF keeps its text route; the queue's no-text re-plan reaches the target through the page pictures.
        XCTAssertEqual(planner.plan("pdf", "epub")?.steps.map { $0.converter.id }, ["pdf-text", "ebook"])
        XCTAssertEqual(planner.plan("pdf", "epub", textExtraction: false)?.steps.map { $0.converter.id }, ["docx-writer", "ebook"])
    }
    func testRoutesNeverPromiseSoundOrTextTheSourceCannotHave() {
        let engines = EngineRegistry.createAll(EngineEnvironment(dataDirectory: FileManager.default.temporaryDirectory.path))
        let planner = RoutePlanner(engines)
        // Pictures, PDFs and drawings reached audio through a still video, which has no sound to extract.
        for (from, to) in [("png", "mp3"), ("gif", "m4a"), ("heic", "wav"), ("pdf", "opus"), ("svg", "ogg"), ("dxf", "flac")] {
            XCTAssertNil(planner.plan(from, to), "\(from) → \(to)")
        }
        // A video's or recording's TXT is its speech, never OCR of one still frame; other formats don't go through it.
        // Pictures and comics reach TXT through PDF pages and OCR.
        for from in ["mp4", "MXF", "webm", "mp3", "wav"] {
            if #available(macOS 26.0, *) { XCTAssertEqual(planner.plan(from, "txt")?.steps.map { $0.converter.id }, ["ffmpeg"], from) }
            else { XCTAssertNil(planner.plan(from, "txt"), from) }
        }
        for to in ["md", "docx", "hwpx", "epub"] { XCTAssertNotEqual(planner.plan("mp4", to)?.steps.first?.to, "txt", to) }
        XCTAssertNil(planner.plan("mp3", "docx"))
        XCTAssertEqual(planner.plan("gif", "txt")?.steps.last?.converter.id, "pdf-text")
        for from in ["png", "JPG", "psd", "jxl", "cbz", "cbr"] { XCTAssertEqual(planner.plan(from, "txt")?.steps.last?.converter.id, "pdf-text", from) }
        for (from, to) in [("mp4", "mp3"), ("mkv", "wav"), ("wav", "mp3"), ("flac", "flac"), ("svg", "txt"), ("dxf", "txt"),
                           ("pdf", "txt"), ("docx", "txt"), ("epub", "txt"), ("png", "md"), ("png", "epub"), ("cbz", "epub"),
                           ("mp4", "pdf"), ("png", "mp4")] {
            XCTAssertNotNil(planner.plan(from, to), "\(from) → \(to)")
        }
        // Formats the registry does not know keep the plain graph search.
        XCTAssertFalse(RoutePlanner.sourceLacksContent("a", "mp3"))
    }
    func testCatalogAvailabilityPriorityCacheAndAssumptions() {
        let c = CoreFakeConverter("office", ConversionEdge("xlsx", "pdf")); c.available = false
        let catalog = ConverterCatalog([c, CoreFakeConverter("image", ConversionEdge("pdf", "png"))])
        XCTAssertFalse(catalog.createPlanner().canConvert("xlsx", "png")); XCTAssertTrue(catalog.createPlanner(["office"]).canConvert("xlsx", "png"))
        c.available = true; XCTAssertFalse(catalog.statusOf(c).isAvailable); catalog.refresh(); XCTAssertTrue(catalog.statusOf(c).isAvailable)
        catalog.priority = ["IMAGE"]; XCTAssertEqual(catalog.ordered.first?.id, "image")
    }
    func testDotNetQuaternaryHeapEqualPriorityRemoval() {
        var heap = DotNetPriorityQueue<Int>()
        for i in 0..<10 { heap.enqueue(i, 1) }
        XCTAssertEqual((0..<10).compactMap { _ in heap.dequeue()?.0 }, [0,9,8,7,6,5,4,3,2,1])
        // Equal costs at intermediate nodes choose the last enqueued node after the first pop, as .NET does.
        let edges = [ConversionEdge("s", "a", 1), ConversionEdge("s", "b", 1), ConversionEdge("s", "c", 1), ConversionEdge("a", "x", 1), ConversionEdge("b", "t", 1), ConversionEdge("c", "t", 1)]
        XCTAssertEqual(RoutePlanner([CoreFakeConverter(edges: edges, script: { _ in [] })]).plan("s", "t")?.steps.map(\.to), ["c", "t"])
    }
}
