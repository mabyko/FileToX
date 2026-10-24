import CJpegTurbo
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class JpegProfileTests: XCTestCase {
    private func frame(_ space: CGColorSpace) -> ImageFrame {
        let channels = space.numberOfComponents
        let samples = (0..<12 * 8 * channels).map { UInt8(($0 * 37 + $0 / channels * 13) & 255) }
        return ImageFrame(image: ImagePixels.make(samples, 12, 8, components: channels, space: space, alpha: false))
    }

    private func read(_ data: Data) throws -> ImageFrame {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "profile.jpg")
        try data.write(to: URL(fileURLWithPath: path))
        return try ImageReader.read(path, format: "jpg", preset: Preset())[0]
    }

    private func app2(_ bytes: Data, sequence: UInt8 = 1, total: UInt8 = 1) -> Data {
        let payload = Data("ICC_PROFILE\0".utf8) + Data([sequence, total]) + bytes
        let length = payload.count + 2
        return Data([0xFF, 0xE2, UInt8(length >> 8), UInt8(length & 255)]) + payload
    }

    private func tagged(_ space: CGColorSpace, orientation: Int = 1) throws -> (frame: ImageFrame, profile: Data) {
        let profile = try XCTUnwrap(space.copyICCData() as Data?)
        var original = frame(space)
        original.properties[ImageFrame.jpegICCKey] = profile
        original.properties[kCGImagePropertyOrientation] = orientation
        return (try read(JpegEncoder.encode(original)), profile)
    }

    func testUntaggedRGBGrayAndCMYKDoNotAcquireICC() throws {
        for space in [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpaceCreateDeviceGray(), CGColorSpaceCreateDeviceCMYK()] {
            let original = try JpegEncoder.encode(frame(space))
            XCTAssertNil(JpegEncoder.embeddedProfile(original))
            let decoded = try read(original)
            XCTAssertEqual(decoded.properties[ImageFrame.jpegICCKey] as? Data, Data())
            XCTAssertNil(CodecPixels.colorProfile(decoded))
            XCTAssertNil(JpegEncoder.embeddedProfile(try JpegEncoder.encode(decoded)))
            var options = ImageOptions()
            options.resize = .percent
            options.resizePercent = 50
            let resized = try ImageEncoder.applyOptions(decoded, options, targetFormat: "jpg")
            XCTAssertNil(JpegEncoder.embeddedProfile(try JpegEncoder.encode(resized)))
        }
    }

    func testActualRGBGrayAndCMYKICCBytesSurviveResizeAndOrientation() throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.genericGrayGamma2_2, CGColorSpace.genericCMYK] {
            let space = try XCTUnwrap(CGColorSpace(name: name))
            let (decoded, profile) = try tagged(space, orientation: 6)
            XCTAssertEqual(CodecPixels.colorProfile(decoded), profile)
            var options = ImageOptions()
            options.resize = .longEdge
            options.longEdge = 6
            let result = try ImageEncoder.applyOptions(decoded, options, targetFormat: "jpg")
            XCTAssertEqual(result.image.width, 4)
            XCTAssertEqual(result.image.height, 6)
            XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(result)), profile)
        }
    }

    func testMetadataAndProfileOptionsKeepTheirExistingSemantics() throws {
        let (decoded, profile) = try tagged(CGColorSpace(name: CGColorSpace.sRGB)!, orientation: 6)
        for keepMetadata in [true, false] {
            for keepProfile in [true, false] {
                var options = ImageOptions()
                options.keepMetadata = keepMetadata
                options.keepColorProfile = keepProfile
                let result = try ImageEncoder.applyOptions(decoded, options, targetFormat: "jpg")
                XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(result)), keepMetadata || keepProfile ? profile : nil)
                XCTAssertEqual(result.properties[ImageFrame.metadataKey] != nil, keepMetadata)
            }
        }
    }

    func testColorModelChangesNeverAttachTheSourceProfileToDifferentSamples() throws {
        for name in [CGColorSpace.sRGB, CGColorSpace.genericCMYK] {
            let (decoded, _) = try tagged(try XCTUnwrap(CGColorSpace(name: name)))
            var options = ImageOptions()
            options.grayscale = true
            let gray = try ImageEncoder.applyOptions(decoded, options, targetFormat: "jpg")
            XCTAssertNil(CodecPixels.metadataBlobs(gray).icc)
            XCTAssertNil(JpegEncoder.embeddedProfile(try JpegEncoder.encode(gray)))
            var rgb = decoded
            rgb.image = ImagePixels.image(ImagePixels.bitmap(decoded.image))
            if name == CGColorSpace.genericCMYK { XCTAssertNil(CodecPixels.metadataBlobs(rgb).icc) }
        }
        let (gray, profile) = try tagged(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!)
        XCTAssertEqual(CodecPixels.metadataBlobs(gray).icc, profile)
        XCTAssertNil(CodecPixels.metadataBlobs(gray, colorModel: .rgb).icc)

        var equalRGB = frame(CGColorSpace(name: CGColorSpace.sRGB)!)
        equalRGB.image = ImagePixels.make([UInt8](repeating: 100, count: 12 * 8 * 3), 12, 8, components: 3,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
        equalRGB.properties[ImageFrame.jpegICCKey] = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?
        let encoded = try JpegEncoder.encode(equalRGB)
        XCTAssertEqual(try read(encoded).image.colorSpace?.model, .monochrome)
        XCTAssertNil(JpegEncoder.embeddedProfile(encoded))
    }

    func testMultipartProfilesAreAssembledInSequenceAndRejectedWhenIncomplete() throws {
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?)
        let middle = profile.count / 2
        let first = app2(Data(profile.prefix(middle)), sequence: 1, total: 2)
        let second = app2(Data(profile.dropFirst(middle)), sequence: 2, total: 2)
        let base = try JpegEncoder.encode(frame(CGColorSpace(name: CGColorSpace.sRGB)!))
        func jpeg(_ markers: Data) -> Data { base.prefix(2) + markers + base.dropFirst(2) }
        let reordered = jpeg(second + first)
        XCTAssertEqual(JpegEncoder.embeddedProfile(reordered), profile)
        XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(read(reordered))), profile)
        for markers in [first, second, first + first + second, first + app2(Data(profile.dropFirst(middle)), sequence: 2, total: 3),
                        app2(profile, sequence: 0), app2(profile, total: 0), app2(Data(profile.dropLast())),
                        app2(Data(repeating: 0, count: 128))] {
            XCTAssertNil(JpegEncoder.embeddedProfile(jpeg(markers)))
            let decoded = try read(jpeg(markers))
            XCTAssertNil(CodecPixels.colorProfile(decoded))
            XCTAssertNil(JpegEncoder.embeddedProfile(try JpegEncoder.encode(decoded)))
        }
        XCTAssertNil(JpegEncoder.embeddedProfile(jpeg(Data(first.dropLast()))))
    }

    func testOtherWritersAcceptTrackedProfilesAfterColorModelChanges() throws {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in [CGColorSpace.sRGB, CGColorSpace.genericGrayGamma2_2, CGColorSpace.genericCMYK] {
            let (decoded, _) = try tagged(try XCTUnwrap(CGColorSpace(name: name)))
            for format in ["webp", "jxl", "psd", "psb"] {
                let path = FilePath.combine(folder, "\(name).\(format)")
                try ImageEncoder.save([decoded], to: path, format: format)
                let output = try ImageReader.read(path, format: format, preset: Preset())[0]
                XCTAssertEqual(output.image.width, decoded.image.width)
                XCTAssertEqual(output.image.height, decoded.image.height)
                XCTAssertNotEqual(output.image.colorSpace?.model, .cmyk)
            }
        }
    }

    func testNativeICCMarkerCountsAtMultipartBoundaries() throws {
        let pixels = [UInt8](repeating: 100, count: 2 * 2 * 3)
        for length in [0, 65518, 65519, 65520, 131037, 131038, 131039] {
            let profile = Data(repeating: 0x61, count: length)
            var image = FTXJpegImage()
            (image.width, image.height, image.components, image.quality) = (2, 2, 3, 75)
            var output: UnsafeMutablePointer<UInt8>?
            var count: UInt = 0
            var message = [CChar](repeating: 0, count: 256)
            let status = pixels.withUnsafeBufferPointer { samples in
                profile.withUnsafeBytes { bytes in
                    image.pixels = samples.baseAddress
                    (image.icc, image.icc_length) = (bytes.bindMemory(to: UInt8.self).baseAddress, length)
                    return ftx_jpeg_encode(&image, &output, &count, &message)
                }
            }
            defer { free(output) }
            XCTAssertEqual(status, 0)
            let data = Data(bytes: try XCTUnwrap(output), count: Int(count))
            let markers = JpegEncoder.segments(data).filter { $0.0 == 0xE2 && $0.1.starts(with: Data("ICC_PROFILE\0".utf8)) }.map(\.1)
            let expected = length / 65519 + (length % 65519 == 0 ? 0 : 1)
            XCTAssertEqual(markers.count, expected, "length \(length)")
            var joined = Data()
            for (index, marker) in markers.enumerated() {
                XCTAssertEqual(Int(marker[12]), index + 1)
                XCTAssertEqual(Int(marker[13]), expected, "length \(length)")
                joined.append(marker.dropFirst(14))
            }
            XCTAssertEqual(joined, profile)
        }
    }
}
