// The ACadSharp 3.8.0 DWG writer port: a DXF read and written as AC1032 DWG (Filee's CadFile.Write) gives the bytes
// ACadSharp writes once the values it takes from the clock and random GUIDs are fixed.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class CadDwgWriterTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// dwgwriter_*.acadsharp.dwg is what Filee's CadFile.Write (ACadSharp 3.8.0) makes of dwgwriter_*.dxf with the
    /// header and summary dates set to 2020-01-01 12:00 and the GUIDs below.
    private func assertWritesACadSharpBytes(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = Self.fixtures.appendingPathComponent("\(name).dxf").path
        let expected = try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).acadsharp.dwg"))
        let document = try CadFile.read(source, "dxf")
        let fixed = try XCTUnwrap(ACad.CadDateTime(2020, 1, 1, 12, 0, 0))
        document.summaryInfo?.createdDate = fixed
        document.summaryInfo?.modifiedDate = fixed
        document.header.createDateTime = fixed
        document.header.updateDateTime = fixed
        document.header.universalCreateDateTime = fixed
        document.header.universalUpdateDateTime = fixed
        document.header.fingerPrintGuid = "{00000000-0000-0000-0000-000000000001}"
        document.header.versionGuid = "{00000000-0000-0000-0000-000000000002}"

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dwg").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try CadFile.write(document, path, "dwg")
        let written = try Data(contentsOf: URL(fileURLWithPath: path))

        XCTAssertEqual(written.count, expected.count, file: file, line: line)
        let first = zip(written, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertNil(first, "first differing byte", file: file, line: line)
    }

    func testWritesTheBytesACadSharpWrites() throws {
        try assertWritesACadSharpBytes("dwgwriter_sample")
        try assertWritesACadSharpBytes("dwgwriter_mix")
    }

    /// The parts of the format that are fixed: R2004+ page layout, LZ77 and the checksums.
    func testCompressorAndChecksums() throws {
        XCTAssertEqual(ACad.DwgCheckSum.magicSequence.prefix(4), [0x29, 0x23, 0xBE, 0x84])
        XCTAssertEqual(ACad.DwgCrc.crc32(0, Array("123456789".utf8)), 0xCBF4_3926)

        // A run compresses into a back reference and decompresses to the same bytes with the reader's LZ77.
        let source = Array(repeating: Array("ACadSharp DWG ".utf8), count: 64).flatMap { $0 }
        let compressed = ACad.DwgMemoryStream()
        try ACad.DwgLZ77AC18Compressor().compress(source, 0, source.count, compressed)
        XCTAssertLessThan(compressed.length, source.count / 4)
        let decompressed = try ACad.DwgLZ77AC18Decompressor.decompress(ACad.DwgStream(compressed.bytes), Int64(source.count))
        XCTAssertEqual(Array(decompressed.read(source.count)), source)
    }
}
