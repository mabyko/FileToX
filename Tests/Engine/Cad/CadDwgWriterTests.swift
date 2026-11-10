// Keep ACadSharp's document sections, with corrected R2010+ free-space and page-map metadata.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class CadDwgWriterTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// dwgwriter_*.acadsharp.dwg is what Filee's CadFile.Write (ACadSharp 3.8.0) makes of dwgwriter_*.dxf with the
    /// header and summary dates set to 2020-01-01 12:00 and the GUIDs below.
    private func assertWritesModernDwg(_ name: String, version: ACad.Version = .ac1032,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
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
        document.header.version = version

        let written = try ACad.DwgWriter(document: document).write()
        let actual = ACad.DwgReader(data: written), reference = ACad.DwgReader(data: expected)
        _ = try actual.read(); _ = try reference.read()
        let header = try XCTUnwrap(actual.fileHeader), oldHeader = try XCTUnwrap(reference.fileHeader)
        XCTAssertEqual(header.version, version, file: file, line: line)
        XCTAssertEqual(header.sectionAmount, UInt32(header.records.count), "Include the page map's own record", file: file, line: line)

        let name = ACad.DwgSectionDefinition.objFreeSpace
        // The real ACadSharp fixture uses the old 53-byte layout; retain its object count as the oracle.
        let oldFree = try XCTUnwrap(reference.sectionBuffer18(name))
        try oldFree.seek(4)
        let countBytes = Array(oldFree.read(4))
        let count = countBytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        XCTAssertGreaterThan(count, 0, file: file, line: line)
        var expectedFree = ACad.DwgLE.bytes(UInt64(0)) + ACad.DwgLE.bytes(count)
        let date = fixed.dwgJulian
        expectedFree += ACad.DwgLE.bytes(date.jdate) + ACad.DwgLE.bytes(date.milliseconds)
        expectedFree.append(4)
        for value: UInt64 in [0x32, 0, 0x64, 0, 0x200, 0, 0xFFFF_FFFF, 0] {
            expectedFree += ACad.DwgLE.bytes(value)
        }
        XCTAssertEqual(header.descriptors[name]?.compressedSize, 89, file: file, line: line)
        let free = try XCTUnwrap(actual.sectionBuffer18(name))
        XCTAssertEqual(Array(free.read(89)), expectedFree, file: file, line: line)

        if version == .ac1032 {
            XCTAssertEqual(Set(header.descriptors.keys), Set(oldHeader.descriptors.keys), file: file, line: line)
            for (section, descriptor) in oldHeader.descriptors where section != name {
                let new = try XCTUnwrap(actual.sectionBuffer18(section)), old = try XCTUnwrap(reference.sectionBuffer18(section))
                XCTAssertEqual(header.descriptors[section]?.compressedSize, descriptor.compressedSize, section, file: file, line: line)
                XCTAssertEqual(Array(new.read(Int(descriptor.compressedSize))), Array(old.read(Int(descriptor.compressedSize))),
                               section, file: file, line: line)
            }
        }
    }

    func testKeepsACadSharpSectionsAndCorrectsModernDwgMetadata() throws {
        try assertWritesModernDwg("dwgwriter_sample")
        try assertWritesModernDwg("dwgwriter_mix")
    }

    func testR2010AndR2013UseTheModernFreeSpaceLayout() throws {
        for version: ACad.Version in [.ac1024, .ac1027] {
            try assertWritesModernDwg("dwgwriter_sample", version: version)
        }
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
