import Foundation
import XCTest
@testable import FileToXCore

final class FormatCatalogTests: XCTestCase {
    func testImportedCatalogPreservesAllFormatsAndProvenance() throws {
        let catalog = try FormatCatalog.decode(resource())
        XCTAssertEqual(catalog.upstream.commit, "21fdd05ef7181b032ed83ec895cc9bbc4b198985")
        XCTAssertEqual(catalog.upstream.license, "MIT")
        XCTAssertEqual(catalog.formats.count, 172)
        XCTAssertEqual(catalog.formats.filter { !$0.isVirtual }.count, 171)
        XCTAssertEqual(Set(catalog.formats.map(\.category)).count, 14)
        XCTAssertEqual(Set(catalog.formats.map(\.id)).count, 172)
        let extensions = catalog.formats.flatMap(\.extensions).filter { !$0.isEmpty }
        XCTAssertEqual(extensions.count, 257)
        XCTAssertEqual(Set(extensions).count, extensions.count)
        XCTAssertEqual(catalog.formats.first?.id, "png")
        XCTAssertEqual(catalog.formats.last?.id, "eot")
    }

    func testReadOnlyAliasesAndExtractionPseudoFormatArePreserved() throws {
        let formats = try FormatCatalog.decode(resource()).formats
        XCTAssertEqual(formats.filter { !$0.writable }.count, 58)
        XCTAssertEqual(formats.first { $0.id == "jpg" }?.extensions, ["jpg", "jpeg", "jpe", "jfif"])
        XCTAssertEqual(formats.first { $0.id == "tgz" }?.extensions, ["tar.gz", "tgz", "taz"])
        XCTAssertEqual(formats.first { $0.id == "heic" }?.writable, false)
        XCTAssertEqual(formats.first { $0.id == "dwg" }?.category, "Cad")
        let folder = try XCTUnwrap(formats.first { $0.isVirtual })
        XCTAssertEqual(folder.id, "folder")
        XCTAssertEqual(folder.extensions, [""])
        XCTAssertTrue(folder.writable)
    }

    func testUnsupportedSchemaAndIncompleteDefinitionsAreRejected() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: resource()) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try FormatCatalog.decode(JSONSerialization.data(withJSONObject: object))) { error in
            guard case FormatCatalog.CatalogError.unsupportedSchema(2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        object["schemaVersion"] = 1
        object["formats"] = [["id": "png"]]
        XCTAssertThrowsError(try FormatCatalog.decode(JSONSerialization.data(withJSONObject: object)))
    }

    private func resource() throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Resources/FileeFormats.json"))
    }
}
