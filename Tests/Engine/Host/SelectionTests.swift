import XCTest
@testable import FileToXEngineKit

final class SelectionTests: XCTestCase {
    func testUnavailablePackageGuidanceAndPartialRunnableCount() throws {
        let d = CoreTempDir(), doc = try d.file("a.docx"), pdf = try d.file("b.pdf")
        let optional = CoreFakeConverter("pandoc",ConversionEdge("docx","pdf")); optional.available = false
        let catalog = ConverterCatalog([optional])
        let selection = Selection(catalog,BuiltInData.createProfiles(),BuiltInData.createPresets(),Localizer("en"))
        let missing = selection.resolve([doc]), option = try XCTUnwrap(hostObjects(missing["presetOptions"]).first { $0["presetId"] as? String == "to-pdf" })
        XCTAssertEqual(option["available"] as? Bool,false); XCTAssertEqual(option["needsPackage"] as? String,"pandoc")
        XCTAssertEqual(option["reasonKey"] as? String,"engine.reason.needs_package")
        let package = try XCTUnwrap(EngineDownloads.packages.first { $0.id == "pandoc" })
        XCTAssertEqual(option["canDownload"] as? Bool,EngineDownloads.canDownload(package))
        optional.available = true; catalog.refresh()
        let partial = selection.resolve([doc,pdf]), pdfTarget = try XCTUnwrap(hostObjects(partial["targets"]).first { $0["formatId"] as? String == "pdf" })
        XCTAssertEqual(pdfTarget["available"] as? Bool,true); XCTAssertEqual(pdfTarget["runnableCount"] as? Int,1)
        let merge = try XCTUnwrap(hostObjects(partial["presetOptions"]).first { $0["presetId"] as? String == "merge-pdf" })
        XCTAssertEqual(merge["runnableCount"] as? Int,2)
    }
}
