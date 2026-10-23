// DWG reading (the ACadSharp 3.8.0 DwgReader port) on fixtures made by the C# baseline: Filee's CadBuilder sample
// written by ACadSharp's DwgWriter in every version it writes (AC1014–AC1032; the AC1014 one is unreadable for the baseline too), the same sample converted dxf → dwg by
// the installed helper (the AC1018 code page 949 drawing is CadTests'). AC1021 (R2007, which ACadSharp cannot write) is
// covered by ACadSharp's AutoCAD sample when that checkout is present.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class CadDwgReaderTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let versions = ["AC1015", "AC1018", "AC1024", "AC1027", "AC1032"]

    private func fixture(_ name: String) -> String { Self.fixtures.appendingPathComponent(name).path }

    private func expectedCensus() throws -> [String: Int] {
        let folder = CadTestFolder()
        return CadBuilder.census(try CadFile.read(try CadBuilder.sample().save(folder.path, "sample.dxf"), "dxf"))
    }

    func testEveryWrittenVersionReadsTheWholeSample() throws {
        let expected = try expectedCensus()
        for version in Self.versions {
            var warnings: [String] = []
            let document = try CadFile.read(fixture("sample_\(version).dwg"), "dwg") { warnings.append($0) }
            XCTAssertEqual(document.header.version.name, version)
            XCTAssertEqual(CadBuilder.census(document), expected, version)
            XCTAssertFalse(warnings.contains { $0.hasPrefix("Could not read") }, "\(version): \(warnings)")
            try assertSampleContent(document, version)
        }
    }

    func testAc1014FileTheBaselineCannotReadFailsTheSameWay() throws {
        // ACadSharp writes this R14 file with a block entity chain its own reader cannot follow; the C# helper fails
        // with exactly this message.
        XCTAssertThrowsError(try CadFile.read(fixture("sample_AC1014.dwg"), "dwg")) { error in
            XCTAssertEqual(CadFile.message(error), "The file is not a valid DWG drawing or is damaged: Unable to cast object of type "
                + "'ACadSharp.IO.Templates.CadBlockRecordTemplate' to type 'ACadSharp.IO.Templates.CadEntityTemplate'.")
        }
    }

    func testBaselineDxfToDwgOutputIsRead() throws {
        let document = try CadFile.read(fixture("baseline_sample_AC1032.dwg"), "dwg")
        XCTAssertEqual(document.header.version, .ac1032)
        XCTAssertEqual(CadBuilder.census(document), try expectedCensus())
        try assertSampleContent(document, "baseline")
    }

    func testAutoCadSamplesOfEveryVersionAreRead() throws {
        let samples = "/tmp/ftx-ref/acadsharp/samples"
        guard FileManager.default.fileExists(atPath: samples) else { throw XCTSkip("ACadSharp samples are not checked out") }
        for version in ["AC1014", "AC1015", "AC1018", "AC1021", "AC1024", "AC1027", "AC1032"] {
            var warnings: [String] = []
            let document = try CadFile.read("\(samples)/sample_\(version).dwg", "dwg") { warnings.append($0) }
            XCTAssertEqual(document.header.version.name, version)
            XCTAssertGreaterThan(document.entities.count, 0, version)
            XCTAssertFalse(warnings.contains { $0.hasPrefix("Could not read") }, "\(version): \(warnings.filter { $0.hasPrefix("Could not read") })")
        }
    }

    func testDwgRendersLikeTheSameDxf() throws {
        let folder = CadTestFolder()
        let dxf = try CadBuilder.sample().save(folder.path, "sample.dxf")
        let fromDxf = try CadSceneBuilder.build(try CadFile.read(dxf, "dxf"))
        let fromDwg = try CadSceneBuilder.build(try CadFile.read(fixture("sample_AC1032.dwg"), "dwg"))
        XCTAssertEqual(fromDwg.items.count, fromDxf.items.count)
        XCTAssertEqual(fromDwg.skipped, fromDxf.skipped)
        XCTAssertEqual("\(fromDwg.extents)", "\(fromDxf.extents)")
    }

    private func assertSampleContent(_ document: ACad.Document, _ label: String) throws {
        // Before AC1021 text is stored in the code page (ANSI_1252 here): the baseline reads "?? ?? Filee" as well.
        let korean = document.header.version >= .ac1021 ? CadBuilder.koreanText : "?? ?? Filee"
        XCTAssertEqual(document.entities.compactMap { ($0 as? ACad.TextEntity)?.value }, [korean], label)
        XCTAssertFalse(try XCTUnwrap(document.layers["Off"]).isOn, label)
        XCTAssertTrue(try XCTUnwrap(document.layers["Frozen"]).isFrozen, label)
        let inserts = document.entities.compactMap { $0 as? ACad.Insert }
        XCTAssertEqual(inserts.flatMap { $0.attributes.map { "\($0.tag)=\($0.value)" } }, ["ID=B1", "ID=B2"], label)
        let bolt = try XCTUnwrap(inserts.first?.block, label)
        XCTAssertEqual(bolt.name, "BOLT", label)
        XCTAssertEqual(bolt.entities.filter { $0 is ACad.Circle || $0 is ACad.Line }.count, 2, label)
        XCTAssertEqual(document.lineTypes["DASHED"]?.segments.map(\.length), [5, -2.5], label)
        let hatches = document.entities.compactMap { $0 as? ACad.Hatch }
        XCTAssertEqual(hatches.map(\.isSolid), [true, false], label)
        XCTAssertEqual(hatches.last?.pattern.name, "ANSI31", label)
        let dimension = try XCTUnwrap(document.entities.compactMap { $0 as? ACad.Dimension }.first, label)
        XCTAssertEqual(dimension.style.name, "Filee", label)
        XCTAssertNotNil(dimension.block, label)
    }
}
