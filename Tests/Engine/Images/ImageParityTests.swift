import COpenJPEG
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class ImageParityTests: XCTestCase {
    private func hash(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ data: Data, format: String = "jpg") throws -> ImageFrame {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "input." + format)
        try data.write(to: URL(fileURLWithPath: path))
        return try ImageReader.read(path, format: format, preset: Preset())[0]
    }

    func testAdobeCmykAndYcckKeepNativeSamplesThroughOperations() throws {
        // Conventional CMYK and untagged RGBA hashes from ImageMagick 7.1.2-32 Q8, synthetic 41x29 JPEGs.
        for (name, expected, rgb) in [("adobe", "44ab3a9ceb5744358b2af7890291b4428805ea2a2281fbbae138bcf9ceca0fa3", "3ebacd427349e2f146285ddf8243b13befb8f97110bb0e088c38670759ce3c63"),
                                      ("ycck", "a1579d370fe6adda14bdd1d1b55351c632921a660bdc563bd67751f1cd1704c0", "668e92f4d885f37ec5f70d54625754d3485312288d3a066bc26a8ae6ab385df9")] {
            let decoded = try read(Data(base64Encoded: Self.jpeg[name]!)!)
            XCTAssertEqual(decoded.image.colorSpace?.model, .cmyk)
            let samples = ImagePixels.straight(decoded.image)
            XCTAssertEqual(samples.channels, 4)
            XCTAssertEqual(hash(samples.samples), expected)
            XCTAssertFalse(ImagePixels.hasColorProfile(decoded.image))
            XCTAssertEqual(hash(ImagePixels.bitmap(decoded.image).pixels), rgb)
            XCTAssertFalse(ImagePixels.hasAlpha(decoded.image))
            let resized = ImagePixels.resized(decoded.image, width: 19, height: 13)
            XCTAssertEqual(resized.colorSpace?.model, .cmyk)
            let oriented = ImagePixels.oriented(decoded.image, 6)
            XCTAssertEqual(oriented.colorSpace?.model, .cmyk)
            XCTAssertEqual(oriented.width, 29)
            XCTAssertEqual(oriented.height, 41)
            let restored = ImagePixels.oriented(oriented, 8)
            XCTAssertEqual(hash(ImagePixels.straight(restored).samples), expected)
            let reencoded = try read(JpegEncoder.encode(decoded))
            XCTAssertEqual(reencoded.image.colorSpace?.model, .cmyk)
            XCTAssertEqual(JpegEncoder.samplingFactors(try JpegEncoder.encode(decoded))?.count, 8)
        }
    }

    func testUnmarkedCmykIsInvertedInkAndGrayUsesLightRatherThanInk() throws {
        let decoded = try read(Data(base64Encoded: Self.jpeg["plain"]!)!)
        XCTAssertFalse(ImagePixels.hasColorProfile(decoded.image))
        let samples = ImagePixels.straight(decoded.image).samples
        // Stored 0, 56, 103, 162 without an Adobe marker: inverted ink, as ImageIO and ImageMagick read it.
        XCTAssertEqual(Array(samples.prefix(4)), [255, 199, 152, 93])
        let black = ImagePixels.make([0, 0, 0, 255], 1, 1, components: 4, space: CGColorSpaceCreateDeviceCMYK(), alpha: false)
        let white = ImagePixels.make([0, 0, 0, 0], 1, 1, components: 4, space: CGColorSpaceCreateDeviceCMYK(), alpha: false)
        XCTAssertEqual(ImagePixels.straight(ImagePixels.grayscale(black)).samples, [0])
        XCTAssertEqual(ImagePixels.straight(ImagePixels.grayscale(white)).samples, [255])
    }

    func testProfiledCmykUsesColorManagedRgbConversion() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK))
        let inks: [UInt8] = [255, 0, 0, 0, 0, 255, 0, 0, 30, 80, 120, 90]
        let source = ImagePixels.make(inks, 3, 1, components: 4, space: space, alpha: false)
        let decoded = try read(JpegEncoder.encode(ImageFrame(image: source)))
        XCTAssertTrue(ImagePixels.hasColorProfile(decoded.image))
        var expected = [UInt8](repeating: 0, count: 12)
        expected.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 3, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(decoded.image, in: CGRect(x: 0, y: 0, width: 3, height: 1))
        }
        XCTAssertEqual(ImagePixels.bitmap(decoded.image).pixels, expected)
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "profiled-cmyk.png")
        try ImageEncoder.save([decoded], to: path, format: "png")
        let png = try XCTUnwrap(GraphicsTestKit.decode(path).frames.first)
        XCTAssertEqual(ImagePixels.bitmap(png).pixels, expected)
        XCTAssertEqual(png.colorSpace?.model, .rgb)
    }

    func testJpegCommentsAndIptcSurviveAndStripRemovesThem() throws {
        var frame = try read(Data(base64Encoded: Self.jpeg["metadata"]!)!)
        let markers = try XCTUnwrap(frame.properties[ImageFrame.jpegMarkersKey] as? Data)
        XCTAssertEqual(JpegEncoder.preservedMarkers(try JpegEncoder.encode(frame)), markers)
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let pngPath = FilePath.combine(folder, "metadata.png")
        try ImageEncoder.save([frame], to: pngPath, format: "png")
        let png = try GraphicsTestKit.decode(pngPath)
        let properties = png.properties[0][kCGImagePropertyPNGDictionary] as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyPNGComment] as? String, "FileToX comment AFileToX comment B")
        // Metadata preservation must not silently depend on retaining the color profile.
        var options = ImageOptions()
        options.keepMetadata = false
        options.keepColorProfile = false
        frame = try ImageEncoder.applyOptions(frame, options, targetFormat: "jpg")
        XCTAssertNil(frame.properties[ImageFrame.jpegMarkersKey])
        XCTAssertTrue(JpegEncoder.preservedMarkers(try JpegEncoder.encode(frame)).isEmpty)
        // Fill bytes, restart/stuffed entropy and an inter-scan comment do not confuse the parser.
        let comment = Data([0xff, 0xfe, 0, 3, 65])
        let scanned = Data([0xff, 0xd8, 0xff, 0xff, 0xda, 0, 2, 1, 0xff, 0, 2, 0xff, 0xd0]) + comment + Data([0xff, 0xd9])
        XCTAssertEqual(JpegEncoder.preservedMarkers(scanned), comment)
        for invalid in [Data(), Data([0xff, 0xd8, 0xff, 0xed, 0xff, 0xff]), Data([0xff, 0xd8, 0xff])] {
            XCTAssertTrue(JpegEncoder.preservedMarkers(invalid).isEmpty)
            XCTAssertNil(JpegEncoder.samplingFactors(invalid))
        }
    }

    private func pattern(_ channels: Int, width: Int = 71, height: Int = 71) -> CGImage {
        var values: [UInt8] = []
        for y in 0..<height { for x in 0..<width { for c in 0..<channels {
            values.append(UInt8((x * 37 + y * 91 + c * 53 + (x * y) % 17 * 7) & 255))
        } } }
        return ImagePixels.make(values, width, height, components: channels,
                                space: channels < 3 ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                                alpha: channels == 2 || channels == 4, premultiplied: false)
    }

    func testGrayIconFilterTracksDirectAndPaletteClasses() throws {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for sourceGray in [false, true] {
            let original = pattern(sourceGray ? 1 : 3)
            var options = ImageOptions()
            options.icoSizes = [48, 32, 16]
            options.grayscale = true
            let frame = try ImageEncoder.applyOptions(ImageFrame(image: original), options, targetFormat: "ico")
            let path = FilePath.combine(folder, "gray-\(sourceGray).ico")
            try ImageEncoder.save([frame], to: path, format: "ico")
            let icons = try GraphicsTestKit.decode(path).frames
            XCTAssertEqual(icons.count, 3)
            for (icon, size) in zip(icons, [48, 32, 16]) {
                let expected = ImagePixels.resized(ImagePixels.grayscale(original), width: size, height: size, filter: .lanczos)
                XCTAssertEqual(CodecPixels.straight(icon).samples, CodecPixels.straight(expected).samples)
            }
        }
        var options = ImageOptions()
        options.icoSizes = [16]
        let gray = pattern(1)
        let frame = try ImageEncoder.applyOptions(ImageFrame(image: gray), options, targetFormat: "ico")
        let path = FilePath.combine(folder, "palette.ico")
        try ImageEncoder.save([frame], to: path, format: "ico")
        let icon = try XCTUnwrap(GraphicsTestKit.decode(path).frames.first)
        let expected = ImagePixels.resized(gray, width: 16, height: 16, filter: .mitchell)
        XCTAssertEqual(CodecPixels.straight(icon).samples, CodecPixels.straight(expected).samples)
    }

    func testNetpbmGrayKeepsDirectClassForResizeAndIcon() throws {
        let samples = ImagePixels.straight(pattern(1)).samples
        let data = Data("P7\nWIDTH 71\nHEIGHT 71\nDEPTH 1\nMAXVAL 255\nTUPLTYPE GRAYSCALE\nENDHDR\n".utf8) + Data(samples)
        let frame = try read(data, format: "ppm")
        var options = ImageOptions()
        options.resize = .longEdge
        options.longEdge = 32
        let resized = try ImageEncoder.applyOptions(frame, options, targetFormat: "ico")
        let expected = ImagePixels.resized(frame.image, width: 32, height: 32, filter: .lanczos)
        XCTAssertEqual(ImagePixels.straight(resized.image).samples, ImagePixels.straight(expected).samples)
    }

    func testJp2QualityIsPsnrAndLosslessRemainsExact() throws {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for channels in [1, 3, 4] {
            let source = pattern(channels)
            var outputs: [Data] = []
            var scores: [Double] = []
            for quality in [25, 50, 100] {
                var options = ImageOptions()
                options.quality = quality
                let frame = try ImageEncoder.applyOptions(ImageFrame(image: source), options, targetFormat: "jp2")
                let path = FilePath.combine(folder, "\(channels)-\(quality).jp2")
                try ImageEncoder.save([frame], to: path, format: "jp2")
                outputs.append(try Data(contentsOf: URL(fileURLWithPath: path)))
                let decoded = try XCTUnwrap(GraphicsTestKit.decode(path).frames.first)
                scores.append(GraphicsTestKit.psnr(source, decoded))
            }
            XCTAssertGreaterThan(scores[0], 20)
            XCTAssertGreaterThan(scores[1], scores[0])
            XCTAssertLessThan(scores[0], 40)
            XCTAssertNotEqual(outputs[0], outputs[1])
            XCTAssertEqual(scores[2], .infinity)
        }
    }

    func testJp2SixteenBitAndTinyImagesRemainReadable() throws {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for channels in [1, 2] { for (width, height) in [(1, 1), (17, 13)] {
            let values = (0..<width * height * channels).map { UInt16(($0 * 1009 + 10000) & 65535) }
            let bytes = values.withUnsafeBytes { Data($0) }
            let alpha: CGImageAlphaInfo = channels == 2 ? .last : .none
            let info = CGBitmapInfo.byteOrder16Little.union(CGBitmapInfo(rawValue: alpha.rawValue))
            let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16 * channels,
                                               bytesPerRow: width * channels * 2, space: CGColorSpaceCreateDeviceGray(),
                                               bitmapInfo: info, provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                                               shouldInterpolate: false, intent: .defaultIntent))
            var options = ImageOptions()
            options.quality = 50
            let frame = try ImageEncoder.applyOptions(ImageFrame(image: source), options, targetFormat: "jp2")
            let path = FilePath.combine(folder, "sixteen-\(channels)-\(width).jp2")
            try ImageEncoder.save([frame], to: path, format: "jp2")
            let result = try XCTUnwrap(GraphicsTestKit.decode(path).frames.first)
            XCTAssertEqual(result.width, width)
            XCTAssertEqual(result.height, height)
            let baselinePath = FilePath.combine(folder, "baseline-\(channels)-\(width).jp2")
            var lossless = frame
            lossless.properties[ImageFrame.qualityKey] = 100
            lossless.properties[kCGImageDestinationLossyCompressionQuality] = 1.0
            try ImageEncoder.save([lossless], to: baselinePath, format: "jp2")
            let baseline = try XCTUnwrap(GraphicsTestKit.decode(baselinePath).frames.first)
            XCTAssertEqual(result.bitsPerComponent, baseline.bitsPerComponent)
            XCTAssertEqual(ImagePixels.hasAlpha(result), channels == 2)
            // Compare the platform-normalized baseline; its 16-bit gray/alpha reader has different bitmap semantics.
            if width > 1 { XCTAssertGreaterThan(GraphicsTestKit.psnr(baseline, result), 40) }
            else { XCTAssertEqual(GraphicsTestKit.psnr(baseline, result), .infinity) }

        } }
    }

    func testJp2ContainerMetadataAndNativeFailureCleanup() throws {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        var frame = ImageFrame(image: pattern(3).copy(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)!, dpi: (300, 300))
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, "FileToX test" as CFString)
        frame.properties[ImageFrame.metadataKey] = metadata
        var options = ImageOptions()
        options.quality = 50
        frame = try ImageEncoder.applyOptions(frame, options, targetFormat: "jp2")
        let path = FilePath.combine(folder, "profile.jp2")
        try ImageEncoder.save([frame], to: path, format: "jp2")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try XCTUnwrap(GraphicsTestKit.decode(path).frames.first)
        let baselinePath = FilePath.combine(folder, "profile-lossless.jp2")
        var lossless = frame
        lossless.properties[ImageFrame.qualityKey] = 100
        lossless.properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        try ImageEncoder.save([lossless], to: baselinePath, format: "jp2")
        let baseline = try XCTUnwrap(GraphicsTestKit.decode(baselinePath).frames.first)
        XCTAssertEqual(decoded.colorSpace?.copyICCData() as Data?, baseline.colorSpace?.copyICCData() as Data?)
        var converted = [UInt8](repeating: 0, count: frame.image.width * frame.image.height * 4)
        converted.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: frame.image.width, height: frame.image.height,
                                    bitsPerComponent: 8, bytesPerRow: frame.image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(frame.image, in: CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))
        }
        let expected = ImagePixels.make(converted, frame.image.width, frame.image.height, components: 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
        XCTAssertGreaterThan(GraphicsTestKit.psnr(expected, decoded), 45)
        let replacement = Data([0xff, 0x4f, 0xff, 0xd9])
        let replaced = try Jpeg2000Encoder.replaceCodestream(in: data, with: replacement)
        XCTAssertEqual(try Jpeg2000Encoder.replaceCodestream(in: data, with: replacement),
                       try Jpeg2000Encoder.replaceCodestream(in: replaced, with: replacement))
        for invalid in [Data(), Data([0, 0, 0, 1, 106, 112, 50, 99]), Data([0, 0, 0, 4, 106, 112, 50, 99])] {
            XCTAssertThrowsError(try Jpeg2000Encoder.replaceCodestream(in: invalid, with: replacement))
        }
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        var message = [CChar](repeating: 0, count: 256)
        let samples: [UInt8] = [0, 0, 0]
        let status = samples.withUnsafeBytes { buffer in
            ftx_j2k_encode(buffer.baseAddress, 1, 1, 3, 3, 8, 50, &bytes, &count, &message, { 1 })
        }
        XCTAssertEqual(status, 2)
        XCTAssertNil(bytes)
        XCTAssertEqual(count, 0)
    }

    private static let jpeg: [String: String] = [
        "adobe": "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",
        "ycck": "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",
        "plain": "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",
        "metadata": "/9j//gATRmlsZVRvWCBjb21tZW50IEH/7QAuUGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAABEcAgUADEZpbGVUb1ggSVBUQwD//gATRmlsZVRvWCBjb21tZW50IEL/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAdACkDASIAAhEBAxEB/8QAGgAAAgMBAQAAAAAAAAAAAAAAAQMCBAUABv/EADQQAAICAQMDAQUDDQAAAAAAAAECAxEEABIhBRMxIgYUFSNBMlHSJTNCVFVWZJGTlJXR4v/EABYBAQEBAAAAAAAAAAAAAAAAAAIDAf/EACgRAAICAAUDBAIDAAAAAAAAAAERAiEAAzFBUQQSYRMycZEigqHB4f/aAAwDAQACEQMRAD8AjKYExXgjdCt7GhgQMAobz2LCiqJ+aSdoN0RWjJjTET4y7pY++u/G7asUcq1puPykp/SNoLCxXNjVlBhtAqLseWKP0xtMoQLvU7UiVtzkspPrK+Bu8aVOInjjxV72WjY0kGQoUNIGLbjSK2xSGH6R+76LoiRmDRK5D4P34KevgjuhCQiT/X+pVsnSxANDIUxmgZolDss7ZAmSPgk7ZWpRxR9I3bRe6xWmbosqKPInx50jxmLQuGZS4CM3b7jkyE71IpRzyaPA0Ex5Y+oyTZDToyopt8Qd1OQbJ/MpQ3HzQB3EbuRXxFadmd2MUE+OFgkYbSsgctzK9UxO40qkUxNWp1gzYhlo1dqy2HaOr2vTCjH1Q4gkAXR3Bp88DfysNnyJN0uf3UQyR7S8kZjJAIraa7jAArypFLRNkkaHe9of2l1f+n/1rsXMEeQ7HJiJBI+RlCOL1MVJMjsXI9Tn0gi2sG7Osj4V039X6N/LM/3qsMnKMjCQJAVonnjgK99NsIdaOmkXliT5A/juj9rjG5LOr9MZY5UGPMQjLLI9WWRgTYMrtyORs+hogkitIznFbpTRtjpLKsy44S5URfVt7aEkeQPW3N3X3SSSEPkrNCxVMMTt2n2NKGlUU7UWJpjbAjyQKs6TkzfC4umQHffUza+7N2FhkJTa9KLfbYoE/TyPoAY93pr8pGvJA7vuIV6EVgzXTTAlSv4dOuVY+mrbDiPJmwYGTEEeBSYoTCDInB4HbCgAMTyxb7W7aATpkzpn44lBfMlw5WkLAhqTt7hYPyo+FAagTfIGlpLK3WhhAQiMOkZiCEQjcCPSga/DEG2NjjgcaLQtP7Rv0lmV5MKASDIlTdbFlckICFFsw83wAPGqB+sMse73L9lI/LN2WymrOZKMEJVQ50IYFOiCCBs9WMNWWf3iXMhZYzGBuaKYOq2xpC7jYoskUFJ8H0qRrP8Ajc37xp/ez/i1sdB/LGXIn2Y0V2qcCarAUhAQFUcggAeVF2BWvM/Ff4nrP+SP4NDKhlZszldvcYgbCm17j42e+LS6mXQZsoTj+W96LYoEH5GP/9k=",
    ]
}
