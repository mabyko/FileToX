// Port of tests/Filee.Engines.Tests/CoverArtTests.cs: the METADATA_BLOCK_PICTURE comment Ogg files carry their album art
// in (no FFmpeg needed).

import Foundation
import XCTest
@testable import FileToXEngineKit

final class CoverArtTests: XCTestCase {
    func testPictureBlockIsAFlacFrontCoverInBase64() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])

        let block = try XCTUnwrap(Data(base64Encoded: CoverArt.pictureBlock(jpeg, "image/jpeg", 300, 200)))

        func at(_ offset: Int) -> Int32 { BinaryPrimitives.readInt32BigEndian(block, offset) }
        XCTAssertEqual(at(0), 3) // front cover
        XCTAssertEqual(at(4), 10)
        XCTAssertEqual(String(decoding: block.subdata(in: 8..<18), as: UTF8.self), "image/jpeg")
        XCTAssertEqual(at(18), 0) // no description
        XCTAssertEqual([at(22), at(26), at(30), at(34)], [300, 200, 24, 0])
        XCTAssertEqual(at(38), Int32(jpeg.count))
        XCTAssertEqual(block.subdata(in: 42..<block.count), jpeg)
    }

    func testMetadataValuesEscapeFfmetadataSpecials() {
        XCTAssertEqual(CoverArt.escape(##"a=b;c#d\e"##), ##"a\=b\;c\#d\\e"##)
    }

    func testOnlyJpegAndPngCoversAreUsed() {
        XCTAssertEqual(CoverArt.mimeOf(Data([0xFF, 0xD8, 0xFF, 0xDB, 0])), "image/jpeg")
        XCTAssertEqual(CoverArt.mimeOf(Data([0x89, UInt8(ascii: "P"), UInt8(ascii: "N"), UInt8(ascii: "G"), 0x0D, 0x0A, 0x1A, 0x0A, 0])), "image/png")
        XCTAssertNil(CoverArt.mimeOf(Data([UInt8(ascii: "B"), UInt8(ascii: "M"), 0, 0, 0])))
    }
}
