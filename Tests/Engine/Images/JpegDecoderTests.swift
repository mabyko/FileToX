// RGB sample hashes from the preserved C# helper's ImageMagick 7.1.2-32 Q8 (MagickWand export).
import CJpegTurbo
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class JpegDecoderTests: XCTestCase {
    private func frame(gray: Bool = false, quality: Int = 75) -> ImageFrame {
        var samples: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<41 {
                for c in 0..<3 { samples.append(UInt8((x * 37 + y * 91 + (gray ? 0 : c) * 53 + (x * y) % 17 * 7) & 255)) }
            }
        }
        var frame = ImageFrame(image: ImagePixels.make(samples, 41, 29, components: 3,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false))
        frame.properties[ImageFrame.qualityKey] = quality
        return frame
    }

    private func read(_ data: Data) throws -> ImageFrame {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "source.jpg")
        try data.write(to: URL(fileURLWithPath: path))
        return try ImageReader.read(path, format: "jpg", preset: Preset())[0]
    }

    private func hash(_ image: CGImage) -> String {
        let data = image.dataProvider!.data! as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testDecodedPixelsMatchImageMagick() throws {
        for (gray, quality, expected) in [
            (false, 75, "dc2f4072aba9c591416f380c7b7e414b38e1cbfc23c5875613ed9de8275854ab"),
            (false, 95, "d51f6e874ab9490863c7bbf03430522bf4e5e1e96bd7202fb4b20d2911547057"),
            (true, 75, "c6069c05c28edd22030106607bf5335f7a5a2a112b332dcfafa36c0b02d970a5")
        ] {
            let decoded = try read(JpegEncoder.encode(frame(gray: gray, quality: quality)))
            XCTAssertEqual(hash(decoded.image), expected)
            XCTAssertFalse(ImagePixels.hasAlpha(decoded.image))
            XCTAssertEqual(decoded.image.colorSpace?.model, gray ? .monochrome : .rgb)
        }
        let progressive = try read(Data(base64Encoded: Self.progressive)!)
        XCTAssertEqual(hash(progressive.image), "dc2f4072aba9c591416f380c7b7e414b38e1cbfc23c5875613ed9de8275854ab")
    }

    func testOrientationProfileResolutionAndOptionsSurvivePixelReplacement() throws {
        var original = frame()
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        original.image = original.image.copy(colorSpace: space)!
        original.properties[kCGImagePropertyOrientation] = 6
        original.dpi = (300, 300)
        let decoded = try read(JpegEncoder.encode(original))
        XCTAssertEqual(hash(decoded.image), "dc2f4072aba9c591416f380c7b7e414b38e1cbfc23c5875613ed9de8275854ab")
        XCTAssertEqual(decoded.image.colorSpace?.copyICCData() as Data?, space.copyICCData() as Data?)
        XCTAssertEqual((decoded.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
        XCTAssertNotNil(decoded.properties[ImageFrame.metadataKey])
        XCTAssertEqual(decoded.dpi?.x, 300)
        var options = ImageOptions()
        options.keepMetadata = false
        options.keepColorProfile = false
        options.resize = .longEdge
        options.longEdge = 20
        options.grayscale = true
        let result = try ImageEncoder.applyOptions(decoded, options, targetFormat: "png")
        XCTAssertEqual(result.image.width, 14)
        XCTAssertEqual(result.image.height, 20)
        XCTAssertEqual(result.image.colorSpace?.model, .monochrome)
        XCTAssertNil(result.properties[ImageFrame.metadataKey])
        XCTAssertEqual((result.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
    }

    func testCmykAndInvalidDataKeepImageIOFallback() throws {
        for data in [Data(base64Encoded: Self.cmyk)!, Data([0xFF, 0xD8, 0xFF, 0xD9]), Data()] {
            let fallback = frame().image
            let result = try ImageReader.decodeJpeg(data, fallback: fallback)
            XCTAssertTrue(result === fallback)
        }
    }

    func testCancellationReleasesTheNativeBuffer() throws {
        let data = try JpegEncoder.encode(frame())
        var pixels: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0, components: Int32 = 0
        let status = data.withUnsafeBytes { bytes in
            ftx_jpeg_decode(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &pixels,
                            &width, &height, &components, { 1 })
        }
        XCTAssertEqual(status, 2)
        XCTAssertNil(pixels)
    }

    func testCancellationDuringProgressiveEntropyInput() throws {
        let source = Data(base64Encoded: Self.progressive)!
        let scan = try XCTUnwrap(source.range(of: Data([0xff, 0xda])))
        let offset = scan.lowerBound + 2
        let length = Int(source[offset]) * 256 + Int(source[offset + 1])
        var damaged = Data(source.prefix(offset + length))
        // An invalid marker in the first entropy scan fails inside start_decompress, before output scanlines.
        damaged.append(contentsOf: [0xff, 0x02, 0xff, 0xd9])
        for cancel in [false, true] {
            var pixels: UnsafeMutablePointer<UInt8>?
            var width: Int32 = 0, height: Int32 = 0, components: Int32 = 0
            let status = damaged.withUnsafeBytes { bytes in
                if cancel {
                    return ftx_jpeg_decode(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(damaged.count), &pixels,
                                           &width, &height, &components, { 1 })
                }
                return ftx_jpeg_decode(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(damaged.count), &pixels,
                                       &width, &height, &components, nil)
            }
            XCTAssertEqual(status, cancel ? 2 : 1)
            XCTAssertNil(pixels)
        }
    }

    // Generated from the same 41×29 sample: lossless coefficient transcode to progressive, and ImageMagick CMYK.
    private static let progressive = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wgARCAAdACkDASIAAhEBAxEB/8QAGQAAAgMBAAAAAAAAAAAAAAAAAQIAAwQF/8QAFQEBAQAAAAAAAAAAAAAAAAAAAQL/2gAMAwEAAhADEAAAARLUJDCsXEyW7qikjssofPs5hf8A/8QAHxAAAQMEAwEAAAAAAAAAAAAAAQACEQMSEyEEIiMy/9oACAEBAAEFAjFpaVorTgXFTyF0gxFpFRu018OxU0T5n5DZee7ZN2YqQnHEJOaJ5FD2dlX/xAAgEQEAAQMDBQAAAAAAAAAAAAABAAIDERMhMRIjMmHw/9oACAEDAQE/Acg4gdXE1tN8c/eyPbd5UhzG42KkTef/xAAfEQABBAICAwAAAAAAAAAAAAARAAECEiFBMaFC8PH/2gAIAQIBAT8BJVmTQiQ6wa7f70vOu+e8qLRk9QR7tf/EADEQAAEDAQUEBwkAAAAAAAAAAAEAAhEhEjEyQVEDYZHREyIzgaGi8DRCUlNxkpPB4f/aAAgBAQAGPwKBwHLmi28Thj0FZimtqY70HFpht3Kb0XzeMxH9XabXgt4F0/pBtXdUh2qJdP215LQFtDv+qxDudA4rDsfOqHqnU+iuiizJmznwQY4XXCK+CnGWGfDgEXikaFe0ecp0j3JpnVbMfM+GkFWKRdGS6LNgm0UdN9Vi235F/8QAJRABAAICAgEDBAMAAAAAAAAAAREhADFBUWGRocFx0eHwEIGx/9oACAEBAAE/IYWxGk5qf6/ZlGmDMDDDU6XVXkxJolHD9Cr0uOckRUlyk0tnY4yZCKJ9hy41xn7b74SIQ0EYiSgMtnMecmDGhRMpnQwX38YIIoG6vjz/ALvCtVpmqJTtzvRz4yYfkxjZnl13/CBWBpROx+p9MTNIAYUC4h8uPBiem9nPc7mMZuIS3VvYvCUTkZQvUtHp6GeP+vnCUPBLKGQ2753m0+so1Q1uME7oo59E+e8W7Roibkda25VaAvt1wfjP0fjn/9oADAMBAAIAAwAAABBU9l8cH//EACARAAIBAwQDAAAAAAAAAAAAAAERIQBBUTFhcaGRweH/2gAIAQMBAT8QTEfX1KLJwqRYEgCYNwYecC+6oCZg2QOuxYpRiCnhw4ypHhqUIhAzoQwIcEEECz1YrdbJ0VigQeRX/8QAHhEAAgEFAQEBAAAAAAAAAAAAAREhADFBUWFxkaH/2gAIAQIBAT8QBCYJWw9H7wp34QJloxMqS2HKN3ibUaQiQFKJ3rQU5tigbCSOkD9ApsRFBoHh8F6zMlspqT+YAwIbV3MPNf/EAB8QAQEBAAMBAAIDAAAAAAAAAAERIQAxQVEQYdHw8f/aAAgBAQABPxBu3UmAdtgkXaw2JOKPcrD0t15Qik2nBBpEmJXEMjjC6JyqWgoJsKmxBuscObH6GJBJUgDpEhaqfhQ9FeAatYqO+h44Zg1ACpLIHr55w1DKn3jV8Su4DR2GTHCUD1OJqIRMq4CToplqJVM1wlobXn+T/LhsaElqJaO40+WIqJCHC/eFTsPa2fBvvLBxcIACdXwBeDitQJGSj5AgW6HK0AIVijOVUgnp0PxeI4Cy6KSUxUJ2hK8s+3dUOUXYgvnZ4cIA4sEJjXSGqmYZwHCxrJKFBQ7uAdc/RSiRQQUA0QDsWhOf3rn/2Q=="
    private static let cmyk = "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"
}
