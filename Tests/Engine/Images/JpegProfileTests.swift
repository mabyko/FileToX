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
        original.properties[ImageFrame.iccKey] = profile
        original.properties[kCGImagePropertyOrientation] = orientation
        return (try read(JpegEncoder.encode(original)), profile)
    }

    func testUntaggedRGBGrayAndCMYKDoNotAcquireICC() throws {
        for space in [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpaceCreateDeviceGray(), CGColorSpaceCreateDeviceCMYK()] {
            let original = try JpegEncoder.encode(frame(space))
            XCTAssertNil(JpegEncoder.embeddedProfile(original))
            let decoded = try read(original)
            XCTAssertEqual(decoded.properties[ImageFrame.iccKey] as? Data, Data())
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
        equalRGB.properties[ImageFrame.iccKey] = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?
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
            // The output keeps the space ImageIO decoded with: its sRGB default, or for a duplicated first chunk the
            // 4716 bytes it reads by concatenating the markers in file order.
            let space = try XCTUnwrap(decoded.image.colorSpace)
            let used = CFEqual(space, CGColorSpace(name: CGColorSpace.sRGB)!) ? nil : space.copyICCData() as Data?
            XCTAssertEqual(used?.count, markers == first + first + second ? 4716 : nil)
            XCTAssertEqual(CodecPixels.colorProfile(decoded), used)
            XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(decoded)), used)
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
                // WebP and JPEG XL are RGB-only; Photoshop documents keep CMYK inks.
                XCTAssertEqual(output.image.colorSpace?.model == .cmyk, name == CGColorSpace.genericCMYK && format.hasPrefix("ps"))
            }
        }
    }

    func testNativeICCMarkerCountsAtMultipartBoundaries() throws {
        let pixels = [UInt8](repeating: 100, count: 2 * 2 * 3)
        for length in [0, 65518, 65519, 65520, 131037, 131038, 131039, 65519 * 255 - 1, 65519 * 255] {
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

    func testNativeJPEGRejectsICCAboveMarkerCapacityWithoutReadingIt() {
        var byte: UInt8 = 100
        for length in [65519 * 255 + 1, Int.max] {
            var image = FTXJpegImage()
            (image.width, image.height, image.components, image.quality) = (1, 1, 1, 75)
            var output: UnsafeMutablePointer<UInt8>?
            var count: UInt = 123
            var message = [CChar](repeating: 0, count: 256)
            let status = withUnsafePointer(to: &byte) { pointer in
                image.pixels = pointer
                (image.icc, image.icc_length) = (pointer, length)
                return ftx_jpeg_encode(&image, &output, &count, &message)
            }
            defer { free(output) }
            XCTAssertEqual(status, 1)
            XCTAssertNil(output)
            XCTAssertEqual(count, 0)
            XCTAssertTrue(String(cString: message).contains("255 marker limit"))
        }
    }

    func testMalformedJpegProfilesFollowTheSpaceImageIODecoded() throws {
        let adobe = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData() as Data?)
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData() as Data?)
        let base = try JpegEncoder.encode(frame(CGColorSpace(name: CGColorSpace.sRGB)!))
        func jpeg(_ markers: Data) -> Data { base.prefix(2) + markers + base.dropFirst(2) }
        let middle = adobe.count / 2
        let first = app2(Data(adobe.prefix(middle)), sequence: 1, total: 2)
        // Markers we reject but ImageIO decodes with: the profile stays inferred from the decoded space, not dropped.
        for markers in [app2(adobe, sequence: 0), app2(adobe, total: 0), first + app2(Data(adobe.dropFirst(middle)), sequence: 2, total: 3),
                        app2(adobe) + app2(p3)] {
            XCTAssertNil(JpegEncoder.embeddedProfile(jpeg(markers)))
            let decoded = try read(jpeg(markers))
            XCTAssertTrue(CFEqual(try XCTUnwrap(decoded.image.colorSpace), CGColorSpace(name: CGColorSpace.adobeRGB1998)!))
            XCTAssertNil(decoded.properties[ImageFrame.iccKey])
            XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(decoded)), adobe)
        }
    }

    /// The JPEG with `markers` inserted after SOI.
    private func inserting(_ markers: Data, into jpeg: Data) -> Data { jpeg.prefix(2) + markers + jpeg.dropFirst(2) }

    /// `profile` as two APP2 markers, in order or with the second first.
    private func twoMarkers(_ profile: Data, reordered: Bool) -> Data {
        let middle = profile.count / 2
        let first = app2(Data(profile.prefix(middle)), sequence: 1, total: 2), second = app2(Data(profile.dropFirst(middle)), sequence: 2, total: 2)
        return reordered ? second + first : first + second
    }

    /// The picture as ColorSync renders it into sRGB: an oracle independent of the engine's pixel helpers.
    private func rendered(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    func testReorderedProfileChunksGiveTheNativeFrameTheSameMeaningAndOutputs() throws {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for (name, untagged) in [(CGColorSpace.adobeRGB1998, CGColorSpace(name: CGColorSpace.sRGB)!), (CGColorSpace.genericGrayGamma2_2, CGColorSpaceCreateDeviceGray()),
                                 (CGColorSpace.genericCMYK, CGColorSpaceCreateDeviceCMYK())] {
            let named = try XCTUnwrap(CGColorSpace(name: name))
            let profile = try XCTUnwrap(named.copyICCData() as Data?)
            let base = try JpegEncoder.encode(frame(untagged))
            XCTAssertNil(JpegEncoder.embeddedProfile(base))
            var frames: [ImageFrame] = []
            for reordered in [false, true] {
                let file = inserting(twoMarkers(profile, reordered: reordered), into: base)
                XCTAssertEqual(JpegEncoder.embeddedProfile(file), profile)
                let decoded = try read(file)
                XCTAssertTrue(CFEqual(try XCTUnwrap(decoded.image.colorSpace), named), "\(name) reordered \(reordered)")
                XCTAssertEqual(decoded.properties[ImageFrame.iccKey] as? Data, profile)
                XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(decoded)), profile)
                if named.model != .cmyk { XCTAssertEqual(CodecPixels.colorProfile(decoded), profile, "WebP, JPEG XL, PSD and PNG share this guard") }
                frames.append(decoded)
            }
            // Same native samples, same colours through ColorSync, and the profile's own meaning rather than the default's.
            XCTAssertEqual(frames[0].image.dataProvider?.data as Data?, frames[1].image.dataProvider?.data as Data?)
            let meaning = rendered(try XCTUnwrap(frames[0].image.copy(colorSpace: named)))
            XCTAssertEqual(rendered(frames[0].image), meaning)
            XCTAssertEqual(rendered(frames[1].image), meaning)
            if name == CGColorSpace.adobeRGB1998 { XCTAssertNotEqual(rendered(try XCTUnwrap(frames[1].image.copy(colorSpace: untagged))), meaning) }
            var outputs: [Data] = []
            for (index, decoded) in frames.enumerated() {
                let path = FilePath.combine(folder, "\(index)-\(named.model.rawValue).png")
                try ImageEncoder.save([decoded], to: path, format: "png")
                outputs.append(try Data(contentsOf: URL(fileURLWithPath: path)))
            }
            XCTAssertEqual(outputs[0], outputs[1])
        }
    }

    func testHigherPrecisionJpegKeepsImageIOPixelsAndTheProfileImageIOUsed() throws {
        // 12-bit samples are beyond the native decoder: ImageIO's pixels and its colour space stay the frame's.
        let base = try XCTUnwrap(Data(base64Encoded: Self.twelveBit))
        let adobe = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData() as Data?)
        let untagged = try read(base)
        XCTAssertEqual(untagged.image.bitsPerComponent, 16)
        XCTAssertEqual(untagged.properties[ImageFrame.iccKey] as? Data, Data())
        let ordered = inserting(twoMarkers(adobe, reordered: false), into: base)
        XCTAssertTrue(try ImageReader.decodeJpeg(ordered, fallback: untagged.image) === untagged.image)
        let tagged = try read(ordered)
        XCTAssertEqual(tagged.image.bitsPerComponent, 16)
        XCTAssertTrue(CFEqual(try XCTUnwrap(tagged.image.colorSpace), CGColorSpace(name: CGColorSpace.adobeRGB1998)!))
        XCTAssertEqual(tagged.properties[ImageFrame.iccKey] as? Data, adobe)
        XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(tagged)), adobe)
        // ImageIO does not decode 12-bit samples behind out-of-order chunks at all: the read fails instead of guessing.
        XCTAssertThrowsError(try read(inserting(twoMarkers(adobe, reordered: true), into: base)))
    }

    func testJpegRefusesProfilesBeyondMarkerCapacityInsteadOfDroppingThem() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?)
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for length in [JpegEncoder.maxProfileLength, JpegEncoder.maxProfileLength + 1] {
            // A usable profile of exactly `length` bytes: sRGB's tags followed by padding the header counts.
            var profile = srgb + Data(count: length - srgb.count)
            profile.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(length).bigEndian) { Data($0) })
            let space = try XCTUnwrap(CGColorSpace(iccData: profile as CFData))
            var tagged = ImageFrame(image: ImagePixels.make([200, 90, 40, 10, 120, 230], 2, 1, components: 3, space: space, alpha: false))
            tagged.properties[ImageFrame.iccKey] = profile
            XCTAssertEqual(CodecPixels.colorProfile(tagged), profile)
            let path = FilePath.combine(folder, "\(length).jpg")
            if length <= JpegEncoder.maxProfileLength {
                try ImageEncoder.save([tagged], to: path, format: "jpg")
                XCTAssertEqual(JpegEncoder.embeddedProfile(try Data(contentsOf: URL(fileURLWithPath: path))), profile)
                continue
            }
            XCTAssertThrowsError(try ImageEncoder.save([tagged], to: path, format: "jpg")) { error in
                XCTAssertTrue("\(error)".contains("too large for JPEG"), "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            // Writers without the marker limit keep the profile.
            let png = FilePath.combine(folder, "\(length).png")
            try ImageEncoder.save([tagged], to: png, format: "png")
            XCTAssertEqual(ImageEncoder.pngProfiles(try Data(contentsOf: URL(fileURLWithPath: png)))?.profiles, [profile])
        }
    }

    // `cjpeg -precision 12 -quality 90` (libjpeg-turbo 3.2.0) of an 8×4 RGB gradient, no ICC profile.
    private static let twelveBit = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wQARDAAEAAgDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAgEAACAgEEAwEAAAAAAAAAAAAFBgQHAwACCQoBCAsV/8QAFAEBAAAAAAAAAAAAAAAAAAAACv/EACERAAICAgEEAwAAAAAAAAAAAAMEAgUGBwgAAQojCRQi/9oADAMBAAIRAxEAPwCzdr+gIvEZ9Aev+iBxhuDLxO9eFvqRPppvrL0T3Q6lsdvCM1C1i2t+M09CI2MyUiHoN/NaqRCS5GUHIEAlSR+XsPCPB/M0008bwyNeYZvX4itf8kNsUyt9n2Zym7f39iuJ26vHBDEqJu4tGYFes2hqhEsNh05ywAIYYz7DhGPYvvkk8idz8BNicXdU8Qs0tNfY05pjWtuxW43YN0aB7a0pfsWdoZOrKquWxsWPe87McmWze1gpJ/rr/9k="
}
