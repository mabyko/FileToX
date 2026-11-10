import Foundation
import XCTest
@testable import FileToXEngineKit

final class EbookRouteTests: XCTestCase {
    private func converters() -> [Converter] {
        [HwpxConverter(), RhwpConverter(), EbookConverter(), CalibreConverter(), CoreFakeConverter("pdfium", ConversionEdge("pdf", "png"))]
    }
    func testBuiltInEbookRoutesAndDocumentReaderRegistration() throws {
        let planner = ConverterCatalog(converters().filter { $0.id != "calibre" }).createPlanner(["rhwp"])
        XCTAssertEqual(planner.plan("epub", "pdf")?.steps.map { $0.converter.id }, ["hwpx-writer", "rhwp"])
        XCTAssertEqual(planner.plan("mobi", "png")?.steps.map { $0.converter.id }, ["hwpx-writer", "rhwp", "pdfium"])
        for (from, to) in [("mobi","epub"),("azw3","epub"),("fb2","epub"),("epub","fb2"),("md","epub"),("docx","epub"),("epub","txt"),("cbr","pdf"),("pdf","cbz"),("azw4","pdf"),("htmlz","txtz")] {
            XCTAssertEqual(planner.plan(from, to)?.steps.map { $0.converter.id }, ["ebook"], "\(from) → \(to)")
        }
        XCTAssertNil(planner.plan("epub", "mobi"))
    }
    func testCalibreAddsKindleAndRareFormatsWithoutWinningBuiltInRoutes() {
        let planner = ConverterCatalog(converters()).createPlanner(["calibre", "rhwp"])
        XCTAssertEqual(planner.plan("epub", "azw3")?.steps.map { $0.converter.id }, ["calibre"])
        XCTAssertEqual(planner.plan("fb2", "mobi")?.steps.map { $0.converter.id }, ["ebook", "calibre"])
        XCTAssertEqual(planner.plan("lit", "txt")?.steps.map { $0.converter.id }, ["calibre", "ebook"])
        XCTAssertEqual(planner.plan("mobi", "epub")?.steps.map { $0.converter.id }, ["ebook"])
        XCTAssertEqual(planner.plan("epub", "fb2")?.steps.map { $0.converter.id }, ["ebook"])
    }
    func testOwnedConvertersAreRegisteredInFileeOrder() {
        let all = EngineRegistry.createAll(EngineEnvironment(dataDirectory: FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(all.map(\.id).filter { ["ebook", "calibre"].contains($0) }, ["ebook", "calibre"])
    }
}
