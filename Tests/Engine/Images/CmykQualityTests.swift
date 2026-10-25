import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class CmykQualityTests: XCTestCase {
    private func read(_ data: Data, format: String = "jpg") throws -> ImageFrame {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "input." + format)
        try data.write(to: URL(fileURLWithPath: path))
        return try ImageReader.read(path, format: format, preset: Preset())[0]
    }

    /// Ink amounts as ImageIO reads them: its stored samples through its decode array.
    private func imageIOInks(_ data: Data) throws -> [UInt8] {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.colorSpace?.model, .cmyk)
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        let decode = image.decode.map { Array(UnsafeBufferPointer(start: $0, count: 8)) } ?? [0, 1, 0, 1, 0, 1, 0, 1]
        var inks: [UInt8] = []
        for y in 0..<image.height { for x in 0..<image.width { for c in 0..<4 {
            let stored = Double(bytes[y * image.bytesPerRow + x * 4 + c])
            inks.append(UInt8((255 * decode[2 * c] + stored * (decode[2 * c + 1] - decode[2 * c])).rounded()))
        } } }
        return inks
    }

    func testJpegCmykIsInvertedInkWithOrWithoutAdobeMarker() throws {
        let unmarked = try XCTUnwrap(Data(base64Encoded: Self.unmarkedBlocks))
        // The same samples behind an Adobe APP14 marker (transform 0: CMYK, not YCCK).
        let marked = unmarked.prefix(2) + Data([0xFF, 0xEE, 0, 14] + Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 0]) + unmarked.dropFirst(2)
        for data in [unmarked, marked] {
            let frame = try read(data)
            XCTAssertEqual(frame.image.colorSpace?.model, .cmyk)
            let inks = ImagePixels.straight(frame.image).samples
            XCTAssertEqual(inks, try imageIOInks(data))
            for (block, expected) in [[0, 0, 0, 0], [0, 0, 0, 255], [255, 0, 0, 0], [30, 80, 120, 90]].enumerated() {
                XCTAssertEqual(inks[block * 32..<block * 32 + 4].map(Int.init), expected)
            }
            let rgb = ImagePixels.bitmap(frame.image).pixels
            XCTAssertEqual(Array(rgb[0..<3]), [255, 255, 255], "no ink is paper white")
            XCTAssertEqual(Array(rgb[32..<35]), [0, 0, 0], "full black ink")
            XCTAssertEqual(Array(rgb[64..<67]), [0, 255, 255], "full cyan ink")
        }
    }

    /// ImageIO-written 32×8 CMYK JPEG (quality 1.0) without its APP0, APP1, APP13 and Adobe APP14 markers: 8×8 blocks
    /// of no ink, K, C and C30 M80 Y120 K90, stored as 255 − ink.
    private static let unmarkedBlocks = "/9j/wAAUCAAIACAEAREAAhEBAxEBBBEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwABAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB/9sAQwEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB/90ABAAE/9oADgQBAAIRAxEEEQA/AP7+K/7+D/v4P+/gKAP/AABz/AHoA/8Af4P9wiv+X8/4Pz/kvP/Z"
}
