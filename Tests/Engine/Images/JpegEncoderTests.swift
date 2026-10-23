// JPEG writing like the C# helper's ImageMagick 7.1.2-32 (libjpeg-turbo 3.2.0, coders/jpeg.c with Filee's settings).
// The SHA-256 values are of the files that ImageMagick (the C# helper's Magick.Native) wrote from the same pixels.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class JpegEncoderTests: XCTestCase {
    /// 41 × 29 deterministic RGB samples; `gray` repeats the red channel in all three.
    private static func samples(gray: Bool = false) -> [UInt8] {
        var samples: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<41 {
                for c in 0..<3 { samples.append(UInt8((x * 37 + y * 91 + (gray ? 0 : c) * 53 + (x * y) % 17 * 7) & 255)) }
            }
        }
        return samples
    }

    private static func frame(gray: Bool = false, quality: Int) -> ImageFrame {
        var frame = ImageFrame(image: ImagePixels.make(samples(gray: gray), 41, 29, components: 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       alpha: false))
        frame.properties[ImageFrame.qualityKey] = quality
        return frame
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Marker segments before the scan: (marker, payload).
    private static func segments(_ data: Data) -> [(UInt8, [UInt8])] {
        let bytes = [UInt8](data)
        var result: [(UInt8, [UInt8])] = []
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF, bytes[i + 1] != 0xDA {
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            result.append((bytes[i + 1], Array(bytes[i + 4..<i + 2 + length])))
            i += 2 + length
        }
        return result
    }

    /// Skia-style files (comic pages, PDF scans): SHA-256 of what the C# helper's libSkiaSharp (SkiaSharp 3.119.4,
    /// libjpeg-turbo 2.1.5.1) wrote from the same pixels through SkJpegEncoder with SKBitmap.Encode's options.
    func testSkiaFilesAreByteIdenticalToSkiaSharp() throws {
        let expected: [(gray: Bool, quality: Int, sha256: String)] = [
            (false, 50, "87a6eb98f914283fdb83e8fb366160f674a36ed144d7f6d8d7fb9be22a8ef3c0"),
            (false, 85, "7e7f50cf7f1c3cf252c22f8b9a3c02a467280215204138dcd0fe9c00c9d71878"),
            (false, 90, "9f6c4aa3c9d72d73e7cfee153da8300e8c2a3708bd9ba5b8876e6a773f634c65"),
            (false, 92, "34e3f70120a86fc42e76c45e8f4257244358bab8c6639f28307d38109dfdaebc"),
            (false, 100, "c665d3547f12649be35844fb44e46af199434133666c6800e105a2b2d51ac30e"),
            (true, 85, "da55606feb8b3cfddc5505c58516fc0fdbf14bfae21a82f12d7ead5f52b03fcb"),
            (true, 90, "c14e0439ba1457b497d153a38ebe855b97c2d81c38f8816b929abda30486eae1"),
        ]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ftx-skia-jpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for case let (gray, quality, sha256) in expected {
            let path = folder.appendingPathComponent("\(gray)-\(quality).jpg").path
            try JpegEncoder.writeSkia(Self.frame(gray: gray, quality: quality).image, quality: quality, to: path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(Self.sha256(data), sha256, "gray \(gray) quality \(quality)")
            let sof = Self.segments(data).first { $0.0 == 0xC0 }?.1
            XCTAssertEqual(sof.map { Array($0[6...]) }, [1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1], "Skia always writes three components 4:2:0")
        }
    }

    func testFilesAreByteIdenticalToImageMagick() throws {
        let expected: [(gray: Bool, quality: Int, sha256: String)] = [
            (false, 50, "6ae5b6d4b29154176f8f7142331099ad9c2f28f6eafabf956e0a5459cef5e24e"),
            (false, 75, "d4ac091d1e98d87b7b9ec5261dd70d0959b2fdae2551c873535926890c6cfaa0"),
            (false, 90, "81a03fc0bb2bd5165df930149e01e280d7c5c57dcee08e31df1a89d755f4d278"),
            (false, 95, "17db9a2b58c59eaef83f88eb042a6a98b5f7f218f88ddf3d0c56e9304ce225db"),
            (false, 100, "cc57c364677b4dfa2c1137d352e8bee1dd62ea9cdb9c8462804f5adc875f5403"),
            (true, 50, "23b84d5bd28e167ab22abed7c14a3eab61d3ec3f8d832ab4324d7a5f2d8168a5"),
            (true, 75, "35cae9f99e968ad225ec7261a75fc6abeedeb1d05f49d04208ec2ba05b4281a8"),
            (true, 90, "e7a466df6ab3349711801a7a19a259843fc8a2da097b01315bdb6055f5230360"),
            (true, 95, "1e611bce4b670e3b26526246ccb5a1c7bb20b9164d1a5b2a2800cc0dd684b5fd"),
            (true, 100, "66fb4e58c0dba3063e3737afb079bd8975e4c533344a5a0411ef8bc3b7432b86"),
        ]
        for case let (gray, quality, sha256) in expected {
            let data = try JpegEncoder.encode(Self.frame(gray: gray, quality: quality))
            XCTAssertEqual(Self.sha256(data), sha256, "gray \(gray), quality \(quality)")
        }
        XCTAssertEqual(JpegEncoder.version, "3.2.0")
    }

    func testQuantizationTablesAreTheIjgTablesScaledByQuality() throws {
        // IJG Annex K tables in natural order; DQT stores them in zigzag order.
        let luminance = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80,
                         62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95,
                         98, 112, 100, 103, 99]
        var chrominance = [Int](repeating: 99, count: 64)
        for (i, value) in [(0, 17), (1, 18), (2, 24), (3, 47), (8, 18), (9, 21), (10, 26), (11, 66), (16, 24), (17, 26), (18, 56), (24, 47),
                           (25, 66)] { chrominance[i] = value }
        let zigzag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42,
                      49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
        for quality in [1, 25, 50, 70, 90, 100] {
            let scale = quality < 50 ? 5000 / quality : 200 - 2 * quality
            let tables = Self.segments(try JpegEncoder.encode(Self.frame(quality: quality))).filter { $0.0 == 0xDB }.map(\.1)
            XCTAssertEqual(tables.count, 2)
            for (table, standard) in zip(tables, [luminance, chrominance]) {
                XCTAssertEqual(Array(table.dropFirst()), zigzag.map { UInt8(min(max((standard[$0] * scale + 50) / 100, 1), 255)) }, "quality \(quality)")
            }
        }
    }

    func testSamplingIsFourFourFourFromQualityNinetyAndKeptFromJpegSources() throws {
        func sampling(_ data: Data) -> [UInt8]? {
            Self.segments(data).first { $0.0 == 0xC0 }.map { sof in (0..<Int(sof.1[5])).map { sof.1[7 + 3 * $0] } }
        }
        XCTAssertEqual(sampling(try JpegEncoder.encode(Self.frame(quality: 89))), [0x22, 0x11, 0x11])
        XCTAssertEqual(sampling(try JpegEncoder.encode(Self.frame(quality: 90))), [0x11, 0x11, 0x11])
        XCTAssertEqual(sampling(try JpegEncoder.encode(Self.frame(gray: true, quality: 50))), [0x11])

        // A 4:2:0 JPEG stays 4:2:0 at quality 95 and a 4:4:4 one stays 4:4:4 at quality 70 (ImageMagick's
        // "jpeg:sampling-factor" property).
        let folder = GraphicsTestKit.folder()
        for (sourceQuality, targetQuality, expected) in [(75, 95, [UInt8]([0x22, 0x11, 0x11])), (95, 70, [0x11, 0x11, 0x11])] {
            let source = FilePath.combine(folder, "source-\(sourceQuality).jpg")
            try JpegEncoder.write(Self.frame(quality: sourceQuality), to: source)
            var frame = try ImageReader.read(source, format: "jpg", preset: Preset())[0]
            XCTAssertEqual(frame.properties[ImageFrame.jpegSamplingKey] as? [Int], expected.flatMap { [Int($0 >> 4), Int($0 & 15)] })
            var options = ImageOptions()
            options.quality = targetQuality
            frame = try ImageEncoder.applyOptions(frame, options, targetFormat: "jpg")
            XCTAssertEqual(sampling(try JpegEncoder.encode(frame)), expected)
        }
    }

    func testBaselineWithOptimizedHuffmanTablesAndTheResolutionInJfif() throws {
        func jfif(_ frame: ImageFrame) throws -> [UInt8] {
            let data = try JpegEncoder.encode(frame)
            let segments = Self.segments(data)
            XCTAssertTrue(segments.contains { $0.0 == 0xC0 } && !segments.contains { $0.0 == 0xC2 }, "baseline, not progressive")
            // Optimized Huffman tables: the DC luminance table is not Annex K's (12 symbols, 29 bytes long).
            XCTAssertNotEqual(segments.first { $0.0 == 0xC4 }?.1.count, 29)
            return Array(segments.first { $0.0 == 0xE0 }!.1[7..<12]) // unit, X density, Y density
        }
        var frame = Self.frame(quality: 90)
        XCTAssertEqual(try jfif(frame), [0, 0, 1, 0, 1])
        frame.dpi = (300, 300)
        XCTAssertEqual(try jfif(frame), [1, 1, 44, 1, 44])
        // A PNG's pHYs in pixels per centimetre, truncated like ImageMagick.
        frame.properties[ImageFrame.resolutionKey] = [28.35, 28.35, 2.0]
        XCTAssertEqual(try jfif(frame), [2, 0, 28, 0, 28])
    }

    func testResolutionIsReadTheWayImageMagickReadsIt() {
        // pHYs only: pixels per centimetre. EXIF/TIFF resolution wins (ImageMagick's SyncResolutionFromProperties).
        let png: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGXPixelsPerMeter: 2835, kCGImagePropertyPNGYPixelsPerMeter: 2835]]
        XCTAssertEqual(ImageReader.storedResolution(png, format: "png"), [28.35, 28.35, 2])
        var exif = png
        exif[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFXResolution: 300, kCGImagePropertyTIFFYResolution: 300,
                                                kCGImagePropertyTIFFResolutionUnit: 2]
        XCTAssertEqual(ImageReader.storedResolution(exif, format: "png"), [300, 300, 1])
        let bmp: [CFString: Any] = [kCGImagePropertyDPIWidth: 11811 * 0.0254, kCGImagePropertyDPIHeight: 11811 * 0.0254]
        XCTAssertEqual(ImageReader.storedResolution(bmp, format: "bmp"), [118.11, 118.11, 2])
        let jfif: [CFString: Any] = [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFXDensity: 2, kCGImagePropertyJFIFYDensity: 2,
                                                                      kCGImagePropertyJFIFDensityUnit: 0]]
        XCTAssertEqual(ImageReader.storedResolution(jfif, format: "jpg"), [2, 2, 0])
    }
}
