import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import FileToXEngineKit

final class ImageQualityFollowupTests: XCTestCase {
    private func hash(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    func testCmykIconResamplesAllFiveChannelsBeforeRgbConversion() {
        var inks: [UInt8] = []
        for y in 0..<5 { for x in 0..<7 { for c in 0..<4 { inks.append(UInt8((x * 37 + y * 91 + c * 53 + x * y * 7) & 255)) } } }
        let source = ImagePixels.make(inks, 7, 5, components: 4, space: CGColorSpaceCreateDeviceCMYK(), alpha: false)
        let padded = ImagePixels.paddedInSourceSpace(source, side: 7)
        XCTAssertEqual(padded.colorSpace?.model, .cmyk)
        XCTAssertEqual(ImagePixels.straight(padded).channels, 5)
        let resized = ImagePixels.resized(padded, width: 5, height: 5)
        // ImageMagick 7.1.2-32 Q8: constitute CMYK, transparent extent 7x7 (0,-1), undefined-filter resize 5x5.
        XCTAssertEqual(hash(ImagePixels.straight(resized).samples), "06af4224f962d8c7851d6feff6b4d729985e4c5d07a2dad02d2e14e1380c0a63")
        let rgb = ImagePixels.rgb(resized)
        XCTAssertEqual(rgb.colorSpace?.model, .rgb)
        XCTAssertEqual(hash(ImagePixels.straight(rgb).samples), "6d01fb94e9bd5b298fd798c1ec3c31fb983592cce7ea6c7681bd1c3779dd338e")
        // Other callers (ICNS) retain their existing RGB-before-padding behavior.
        XCTAssertEqual(ImagePixels.padded(source, side: 7).colorSpace?.model, .rgb)
    }

    func testCmykaKeepsStraightAlphaIncludingTransparentInk() {
        let image = ImagePixels.make([0, 0, 0, 255, 255, 255, 0, 0, 0, 128, 0, 0, 0, 0, 0], 3, 1,
                                     components: 5, space: CGColorSpaceCreateDeviceCMYK(), alpha: true, premultiplied: false)
        XCTAssertEqual(ImagePixels.straight(ImagePixels.rgb(image)).samples, [0, 0, 0, 255, 0, 255, 255, 128, 255, 255, 255, 0])
        XCTAssertEqual(ImagePixels.bitmap(image).pixels, [0, 0, 0, 255, 0, 128, 128, 128, 0, 0, 0, 0])
    }

    func testCmykIconWriterForSquarePaddedAndLargeSources() throws {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        // Q8 transparent extent, optional 256x256 resize, icon:auto-resize=32,16; RGB transform happens last.
        for (width, height, hashes) in [
            (7, 5, ["edbd6037dc5321b09d54f433beccd6e23f73214e9b104e596507c39579e59759", "e81fa9a79b83975544c84c4d4d121ad3e686c17ffeb96a25b0b5f64258936974"]),
            (7, 7, ["87e5084ffcea8be70119ad25d2f854301e0aefffe7c608e3ff8b203881f24af5", "be21d0a72b7382fb87ef34bd4a4a3aab5d87d66274509aec96b807b0b57dccfb"]),
            (321, 273, ["989cf325affd19874db6b5df8c4927b50baaa76c2fa9ef0c16936da8f6a8f2d7", "820e29ac1bca33e72e5179f2553eccfc07551e7fefb7c0183566fb1874bdf0ca"]),
        ] {
            var inks: [UInt8] = []
            for y in 0..<height { for x in 0..<width { for c in 0..<4 { inks.append(UInt8((x * 37 + y * 91 + c * 53 + x * y * 7) & 255)) } } }
            let image = ImagePixels.make(inks, width, height, components: 4, space: CGColorSpaceCreateDeviceCMYK(), alpha: false)
            var options = ImageOptions()
            options.icoSizes = [32, 16]
            let frame = try ImageEncoder.applyOptions(ImageFrame(image: image), options, targetFormat: "ico")
            let path = FilePath.combine(folder, "\(width)x\(height).ico")
            try ImageEncoder.save([frame], to: path, format: "ico")
            let decoded = try GraphicsTestKit.decode(path)
            XCTAssertEqual(decoded.frames.count, 2)
            for (icon, expected) in zip(decoded.frames, hashes) {
                let (samples, channels, _) = ImagePixels.straight(icon)
                let rgba = channels == 4 ? samples : stride(from: 0, to: samples.count, by: 3).flatMap { Array(samples[$0..<$0 + 3]) + [255] }
                XCTAssertEqual(hash(rgba), expected, "\(width)x\(height) -> \(icon.width)")
            }
        }
    }

    func testTaggedCmykaUsesIndependentOpaqueIccConversionAndRetainsAlpha() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK))
        let inks: [UInt8] = [255, 0, 0, 0, 30, 80, 120, 90, 0, 0, 0, 255]
        let opaque = ImagePixels.make(inks, 3, 1, components: 4, space: space, alpha: false)
        var expected = [UInt8](repeating: 0, count: 12)
        expected.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(opaque, in: CGRect(x: 0, y: 0, width: 3, height: 1))
        }
        let alpha: [UInt8] = [0, 83, 255]
        let samples = (0..<3).flatMap { i in Array(inks[i * 4..<i * 4 + 4]) + [alpha[i]] }
        for i in 0..<3 { expected[i * 4 + 3] = alpha[i] }
        let image = ImagePixels.make(samples, 3, 1, components: 5, space: space, alpha: true, premultiplied: false)
        XCTAssertEqual(ImagePixels.straight(ImagePixels.rgb(image)).samples, expected)
    }
}
