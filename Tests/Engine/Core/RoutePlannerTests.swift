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
