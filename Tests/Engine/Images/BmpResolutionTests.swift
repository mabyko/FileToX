import Foundation
import XCTest
@testable import FileToXEngineKit

enum BmpResolutionFixture {
    static func data(header: Int = 40, x: Int32, y: Int32, topDown: Bool = false) -> Data {
        let offset = 14 + header, pixels = 96 * 64 * 3
        var bytes = [UInt8](repeating: 0, count: offset + pixels)
        func put(_ at: Int, _ value: Int32) {
            for byte in 0..<4 { bytes[at + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        bytes[0] = 0x42; bytes[1] = 0x4D
        put(2, Int32(bytes.count)); put(10, Int32(offset)); put(14, Int32(header))
        put(18, 96); put(22, topDown ? -64 : 64)
        bytes[26] = 1; bytes[28] = 24
        put(34, Int32(pixels)); put(38, x); put(42, y)
        return Data(bytes)
    }
}

final class BmpResolutionTests: XCTestCase {
    func testOnlyCompleteKnownWindowsHeadersSupplyDensity() throws {
        for header in [40, 52, 56, 108, 124] {
            let dpi = try XCTUnwrap(ImageReader.bmpDpi(BmpResolutionFixture.data(header: header, x: 3780, y: 2835)))
            XCTAssertEqual(dpi.x, 96.012, accuracy: 1e-9)
            XCTAssertEqual(dpi.y, 72.009, accuracy: 1e-9)
        }
        for header in [12, 16, 64, 41, 128] {
            XCTAssertNil(ImageReader.bmpDpi(BmpResolutionFixture.data(header: header, x: 3780, y: 2835)))
        }
        let valid = BmpResolutionFixture.data(x: 3780, y: 3780)
        for length in [0, 14, 38, 42, 53] { XCTAssertNil(ImageReader.bmpDpi(Data(valid.prefix(length)))) }
        var badSignature = valid; badSignature[0] = 0
        var badLength = valid; badLength[2] = 0
        var overlappingPixels = valid; overlappingPixels[10] = 40
        var incompleteHeader = valid; incompleteHeader[14] = 124
        for data in [badSignature, badLength, overlappingPixels, incompleteHeader] { XCTAssertNil(ImageReader.bmpDpi(data)) }
        for (x, y) in [(0, 0), (3780, 0), (0, 3780), (-1, -1), (3780, -1)] {
            XCTAssertNil(ImageReader.bmpDpi(BmpResolutionFixture.data(x: Int32(x), y: Int32(y))))
        }
    }

    func testReaderKeepsPhysicalDensityInsteadOfImageIOSnapping() throws {
        let folder = GraphicsTestKit.folder()
        defer { FileManager.default.removeIfPresent(folder) }
        let path = FilePath.combine(folder, "density.bmp")
        for (x, y) in [(3780, 3780), (2835, 2835), (3000, 11811)] {
            try BmpResolutionFixture.data(x: Int32(x), y: Int32(y), topDown: true).write(to: URL(fileURLWithPath: path))
            let frame = try XCTUnwrap(ImageReader.read(path, format: "bmp", preset: Preset()).first)
            let dpi = try XCTUnwrap(frame.dpi)
            XCTAssertEqual(dpi.x, Double(x) * 0.0254, accuracy: 1e-9)
            XCTAssertEqual(dpi.y, Double(y) * 0.0254, accuracy: 1e-9)
            XCTAssertEqual(frame.properties[ImageFrame.resolutionKey] as? [Double], [Double(x) / 100, Double(y) / 100, 2])
        }
    }

    func testZeroAndNegativeDensityStayUnspecified() throws {
        let folder = GraphicsTestKit.folder()
        defer { FileManager.default.removeIfPresent(folder) }
        let path = FilePath.combine(folder, "unspecified.bmp")
        for (x, y) in [(0, 0), (3780, 0), (0, 3780), (-1, -1), (3780, -1)] {
            try BmpResolutionFixture.data(x: Int32(x), y: Int32(y)).write(to: URL(fileURLWithPath: path))
            let frame = try XCTUnwrap(ImageReader.read(path, format: "bmp", preset: Preset()).first)
            XCTAssertNil(frame.dpi)
            XCTAssertNil(frame.properties[ImageFrame.resolutionKey])
        }
    }
}
