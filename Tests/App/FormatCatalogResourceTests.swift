import Foundation
import XCTest
@testable import FileToX

final class FormatCatalogResourceTests: XCTestCase {
    func testAppBundlesTheCompleteCatalog() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "FileeFormats", withExtension: "json"))
        let catalog = try FormatCatalog.decode(Data(contentsOf: url))
        XCTAssertEqual(catalog.formats.filter { !$0.isVirtual }.count, 171)
        XCTAssertEqual(catalog.upstream.license, "MIT")
        XCTAssertNotNil(Bundle.main.url(forResource: "Filee", withExtension: "LICENSE"))
    }
}
