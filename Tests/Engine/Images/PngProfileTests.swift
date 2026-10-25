import CoreGraphics
import Foundation
import ImageIO
import XCTest
import zlib
@testable import FileToXEngineKit

final class PngProfileTests: XCTestCase {
    private let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func chunk(_ type: String, _ payload: Data) -> Data {
        let bytes = Data(type.utf8) + payload
        let crc = UInt32(bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
        return withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + bytes + withUnsafeBytes(of: crc.bigEndian) { Data($0) }
    }

    private func iccp(_ profile: Data, keyword: String = "icc", method: UInt8 = 0) throws -> Data {
        chunk("iCCP", Data(keyword.utf8) + [0, method] + (try Deflate.deflate(profile, windowBits: 15)))
    }

    /// A 6 × 4 gray, RGB or four-colour palette PNG with extra chunks after IHDR, after PLTE and after IDAT.
    private func png(colorType: UInt8, before: [Data] = [], afterPalette: [Data] = [], after: [Data] = []) throws -> Data {
        let channels = [0: 1, 2: 3, 3: 1][Int(colorType)]!
        var raw = Data()
        for y in 0..<4 { raw.append(0); for x in 0..<6 * channels { raw.append(UInt8((x * 41 + y * 67) % (colorType == 3 ? 4 : 256))) } }
        var header = withUnsafeBytes(of: UInt32(6).bigEndian) { Data($0) } + withUnsafeBytes(of: UInt32(4).bigEndian) { Data($0) }
        header += [8, colorType, 0, 0, 0]
        let palette = colorType == 3 ? [chunk("PLTE", Data([200, 30, 30, 30, 200, 30, 30, 30, 200, 240, 240, 240]))] : []
        var file = signature + chunk("IHDR", header)
        for extra in before + palette + afterPalette { file += extra }
        file += chunk("IDAT", try Deflate.deflate(raw, windowBits: 15))
        for extra in after { file += extra }
        return file + chunk("IEND", Data())
    }

    private func chunks(_ png: Data) -> [(type: String, payload: Data)] {
        var result: [(String, Data)] = [], i = 8
        while i + 12 <= png.count {
            let length = png[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            result.append((String(decoding: png[i + 4..<i + 8], as: UTF8.self), Data(png[i + 8..<i + 8 + length])))
            i += 12 + length
        }
        return result
    }

    /// The inflated profile of the only iCCP chunk, nil without one.
    private func writtenProfile(_ png: Data) throws -> Data? {
        let profiles = chunks(png).filter { $0.type == "iCCP" }
        XCTAssertLessThanOrEqual(profiles.count, 1)
        guard let payload = profiles.first?.payload, let nul = payload.firstIndex(of: 0) else { return nil }
        return try Deflate.inflate(payload[(nul + 2)...], windowBits: 15)
    }

    private func profile(_ name: CFString) throws -> Data {
        try XCTUnwrap(CGColorSpace(name: name)?.copyICCData() as Data?)
    }

    private func read(_ data: Data, _ format: String) throws -> ImageFrame {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "source.\(format)")
        try data.write(to: URL(fileURLWithPath: path))
        return try ImageReader.read(path, format: format, preset: Preset())[0]
    }

    private func write(_ frame: ImageFrame, _ format: String = "png", options: ImageOptions? = nil) throws -> Data {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "output.\(format)")
        let prepared = try options.map { try ImageEncoder.applyOptions(frame, $0, targetFormat: format) } ?? frame
        try ImageEncoder.save([prepared], to: path, format: format)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func samples(_ data: Data) throws -> [UInt8] {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        return ImagePixels.straight(image).samples
    }

    func testParserCollectsEveryCompleteProfileBeforeImageData() throws {
        let srgb = try profile(CGColorSpace.sRGB), p3 = try profile(CGColorSpace.displayP3)
        let valid = try iccp(srgb)
        func parsed(_ png: Data) -> [Data]? { ImageEncoder.pngProfiles(png).map(\.profiles) }
        XCTAssertEqual(parsed(try png(colorType: 2, before: [valid])), [srgb])
        XCTAssertEqual(ImageEncoder.pngProfiles(try png(colorType: 2, before: [valid]))?.declared, false)
        XCTAssertEqual(parsed(try png(colorType: 2)), [])
        XCTAssertNil(ImageEncoder.pngProfiles(try JpegEncoder.encode(ImageFrame(image: GraphicsTestKit.solid(2, 2, (9, 9, 9, 255))))))
        for declared in [chunk("sRGB", Data([0])), chunk("gAMA", Data([0, 1, 0x86, 0xA0])), chunk("cHRM", Data(count: 32)),
                         chunk("cICP", Data([1, 13, 0, 1]))] {
            XCTAssertEqual(ImageEncoder.pngProfiles(try png(colorType: 2, before: [declared]))?.declared, true)
            XCTAssertEqual(parsed(try png(colorType: 2, before: [declared, valid])), [srgb])
        }
        var badCRC = valid
        badCRC[badCRC.count - 1] ^= 1
        let compressed = try Deflate.deflate(srgb, windowBits: 15)
        var oversized = srgb
        oversized[0..<4] = Data([0, 0, 0x10, 0]) // header claims 4096 bytes
        let invalid = [badCRC, try iccp(srgb, method: 1), chunk("iCCP", Data("icc".utf8) + [0, 0] + compressed.dropLast(4)),
                       chunk("iCCP", Data(repeating: 0x41, count: 80) + [0, 0] + compressed), chunk("iCCP", Data([0, 0]) + compressed),
                       try iccp(oversized), try iccp(Data(srgb.prefix(127)))]
        for chunk in invalid {
            XCTAssertEqual(parsed(try png(colorType: 2, before: [chunk])), [])
            XCTAssertEqual(parsed(try png(colorType: 2, before: [chunk, valid])), [srgb], "a broken chunk leaves later profiles")
        }
        // A chunk inflating past 16 MiB uses up the budget of every chunk after it too.
        XCTAssertEqual(parsed(try png(colorType: 2, before: [try iccp(Data(count: (1 << 24) + 1)), valid])), [])
        XCTAssertEqual(parsed(try png(colorType: 2, before: [valid, try iccp(p3)])), [srgb, p3])
        // One 16 MiB inflation budget covers all chunks: a second 10 MiB profile is not read.
        var large = srgb + Data(count: 10 << 20)
        large.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(large.count).bigEndian) { Data($0) })
        XCTAssertEqual(parsed(try png(colorType: 2, before: [try iccp(large), try iccp(large), valid])), [large])
        XCTAssertEqual(parsed(try png(colorType: 2, after: [valid])), [])
        XCTAssertEqual(parsed(try png(colorType: 3, afterPalette: [valid])), [])
        XCTAssertEqual(parsed(try png(colorType: 3, before: [valid])), [srgb])
        XCTAssertEqual(parsed(Data((try png(colorType: 2, before: [valid])).prefix(60))), [])
    }

    func testProfileScanInflatesNoMoreThanItsBudget() throws {
        let srgb = try profile(CGColorSpace.sRGB), p3 = try profile(CGColorSpace.displayP3)
        var badCRC = try iccp(srgb)
        badCRC[badCRC.count - 1] ^= 1
        // Ordinary scans inflate exactly the profiles they check; chunks failing CRC or method are not inflated.
        XCTAssertEqual(ImageEncoder.pngProfiles(try png(colorType: 2, before: [try iccp(srgb), try iccp(p3)]))?.inflated, srgb.count + p3.count)
        XCTAssertEqual(ImageEncoder.pngProfiles(try png(colorType: 2, before: [badCRC, try iccp(srgb, method: 1), try iccp(p3)]))?.inflated, p3.count)
        // A 16 MiB chunk and 64 more compressed ones: once the budget is spent no further chunk is inflated at all.
        let large = try iccp(Data(count: 1 << 24)), more = try iccp(Data(count: 4 << 20))
        let scan = try XCTUnwrap(ImageEncoder.pngProfiles(try png(colorType: 2, before: [large] + Array(repeating: more, count: 64) + [try iccp(p3)])))
        XCTAssertEqual(scan.profiles, [])
        XCTAssertGreaterThan(scan.inflated, 1 << 24)
        XCTAssertLessThanOrEqual(scan.inflated, (1 << 24) + (1 << 20), "at most one 1 MiB inflate buffer past the budget")
    }

    func testProfileScanCountsOutputOfChunksWithABadChecksum() throws {
        // R3: 64 iCCP chunks of 1048575 zero bytes whose zlib Adler-32 is wrong (PNG CRCs intact). zlib produces each
        // chunk's whole output before it finds the checksum, so all of it counts: 16 chunks fit the budget, the 17th
        // passes it and nothing after it is inflated.
        var zlib = try Deflate.deflate(Data(count: (1 << 20) - 1), windowBits: 15)
        zlib[zlib.count - 1] ^= 1
        let bad = chunk("iCCP", Data("icc".utf8) + [0, 0] + zlib)
        let scan = try XCTUnwrap(ImageEncoder.pngProfiles(try png(colorType: 2, before: Array(repeating: bad, count: 64))))
        XCTAssertEqual(scan.profiles, [])
        XCTAssertEqual(scan.inflated, 17 * ((1 << 20) - 1))
        XCTAssertLessThanOrEqual(scan.inflated, (1 << 24) + (1 << 20))
        // A single bad-checksum chunk is counted and still rejected; a later valid profile is read.
        let srgb = try profile(CGColorSpace.sRGB)
        let one = try XCTUnwrap(ImageEncoder.pngProfiles(try png(colorType: 2, before: [bad, try iccp(srgb)])))
        XCTAssertEqual(one.profiles, [srgb])
        XCTAssertEqual(one.inflated, (1 << 20) - 1 + srgb.count)
    }

    func testRecordedProfileIsTheOneTheDecoderUsed() throws {
        let srgb = try profile(CGColorSpace.sRGB), p3 = try profile(CGColorSpace.displayP3), adobe = try profile(CGColorSpace.adobeRGB1998)
        func space(_ name: CFString) -> CGColorSpace { CGColorSpace(name: name)! }
        XCTAssertEqual(CodecPixels.sourceProfile([srgb, p3], decoded: space(CGColorSpace.displayP3)), p3)
        XCTAssertEqual(CodecPixels.sourceProfile([p3, srgb], decoded: space(CGColorSpace.sRGB)), srgb)
        XCTAssertEqual(CodecPixels.sourceProfile([p3], decoded: space(CGColorSpace.sRGB)), Data(), "the decoder ignored it")
        XCTAssertEqual(CodecPixels.sourceProfile([], decoded: space(CGColorSpace.genericGrayGamma2_2)), Data())
        XCTAssertEqual(CodecPixels.sourceProfile([], decoded: CGColorSpaceCreateDeviceCMYK()), Data())
        XCTAssertNil(CodecPixels.sourceProfile([], decoded: space(CGColorSpace.adobeRGB1998)), "colour the decoder took from elsewhere")
        XCTAssertNil(CodecPixels.sourceProfile([], decoded: space(CGColorSpace.sRGB), declared: true))
        let indexed = try XCTUnwrap(CGColorSpace(indexedBaseSpace: space(CGColorSpace.adobeRGB1998), last: 1, colorTable: [0, 0, 0, 255, 255, 255]))
        XCTAssertEqual(CodecPixels.sourceProfile([adobe], decoded: indexed), adobe)
    }

    func testRepeatedAndMalformedProfilesFollowTheDecodedFrame() throws {
        let adobe = try profile(CGColorSpace.adobeRGB1998), srgb = try profile(CGColorSpace.sRGB), p3 = try profile(CGColorSpace.displayP3)
        var badAdobe = try iccp(adobe)
        badAdobe[badAdobe.count - 1] ^= 1
        // ImageIO ignores CRCs and decodes with the last profile.
        for (chunks, expected) in [([badAdobe, try iccp(p3)], p3), ([try iccp(srgb), try iccp(p3)], p3), ([try iccp(p3), try iccp(srgb)], srgb)] {
            let frame = try read(try png(colorType: 2, before: chunks), "png")
            XCTAssertTrue(CFEqual(try XCTUnwrap(frame.image.colorSpace), try XCTUnwrap(CGColorSpace(iccData: expected as CFData))))
            XCTAssertEqual(frame.properties[ImageFrame.iccKey] as? Data, expected)
            XCTAssertEqual(try writtenProfile(try write(frame)), expected)
            XCTAssertEqual(JpegEncoder.embeddedProfile(try write(frame, "jpg")), expected)
        }
        // A profile only ImageIO accepts is not lost: it stays inferred from the decoded space, as before.
        let recovered = try read(try png(colorType: 2, before: [badAdobe]), "png")
        XCTAssertTrue(CFEqual(try XCTUnwrap(recovered.image.colorSpace), CGColorSpace(name: CGColorSpace.adobeRGB1998)!))
        XCTAssertNil(recovered.properties[ImageFrame.iccKey])
        let imageIO = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(imageIO, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, recovered.image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertNotNil(try writtenProfile(imageIO as Data))
        XCTAssertEqual(try writtenProfile(try write(recovered)), try writtenProfile(imageIO as Data))
        XCTAssertEqual(JpegEncoder.embeddedProfile(try write(recovered, "jpg")), adobe)
        // ImageIO gives up on every profile after a broken first one: untagged sRGB in, untagged sRGB out.
        let broken = chunk("iCCP", Data("icc".utf8) + [0, 0] + (try Deflate.deflate(adobe, windowBits: 15)).dropLast(6))
        let ignored = try read(try png(colorType: 2, before: [broken, try iccp(adobe)]), "png")
        XCTAssertEqual(ignored.image.colorSpace?.name as String?, CGColorSpace.sRGB as String)
        XCTAssertEqual(ignored.properties[ImageFrame.iccKey] as? Data, Data())
        XCTAssertNil(try writtenProfile(try write(ignored)))
        XCTAssertNil(JpegEncoder.embeddedProfile(try write(ignored, "jpg")))
    }

    func testIndexedPictureLeavingItsSpaceDropsTheSourceProfileForEveryWriter() throws {
        let adobe = try profile(CGColorSpace.adobeRGB1998)
        var half = ImageOptions()
        half.resize = .percent
        half.resizePercent = 50
        // A palette in Adobe RGB is resized as sRGB samples: no writer may label them Adobe RGB.
        let palette = try read(try png(colorType: 3, before: [try iccp(adobe)]), "png")
        XCTAssertEqual(palette.image.colorSpace?.model, .indexed)
        XCTAssertEqual(palette.properties[ImageFrame.iccKey] as? Data, adobe)
        let resized = try ImageEncoder.applyOptions(palette, half, targetFormat: "png")
        XCTAssertEqual(resized.image.colorSpace?.name as String?, CGColorSpace.sRGB as String)
        XCTAssertNil(resized.properties[ImageFrame.iccKey])
        let written = try write(resized)
        XCTAssertNil(try writtenProfile(written))
        XCTAssertTrue(chunks(written).contains { $0.type == "sRGB" })
        XCTAssertEqual(try samples(written), ImagePixels.straight(resized.image).samples)
        XCTAssertNil(JpegEncoder.embeddedProfile(try write(resized, "jpg")))
        XCTAssertNil(CodecPixels.colorProfile(resized), "WebP, JPEG XL and PSD share this guard")
        for format in ["webp", "jxl", "psd"] { XCTAssertFalse(try write(resized, format).isEmpty) }
        // A stale key alone cannot label the converted samples either.
        var stale = resized
        stale.properties[ImageFrame.iccKey] = adobe
        XCTAssertNil(CodecPixels.colorProfile(stale))
        XCTAssertNil(try writtenProfile(try write(stale)))
        // Truecolour Adobe RGB keeps its space, its samples' meaning and its exact profile through the same resize.
        let truecolour = try ImageEncoder.applyOptions(try read(try png(colorType: 2, before: [try iccp(adobe)]), "png"), half, targetFormat: "png")
        XCTAssertEqual(truecolour.properties[ImageFrame.iccKey] as? Data, adobe)
        XCTAssertEqual(CodecPixels.colorProfile(truecolour), adobe)
        XCTAssertEqual(try writtenProfile(try write(truecolour)), adobe)
        XCTAssertEqual(JpegEncoder.embeddedProfile(try write(truecolour, "jpg")), adobe)
    }

    func testUntaggedGraySourcesGetNoInventedProfileAndKeepTheirSamples() throws {
        let gray = (0..<12 * 8).map { UInt8($0 * 29 & 255) }
        let jpeg = try JpegEncoder.encode(ImageFrame(image: ImagePixels.make(gray, 12, 8, components: 1, space: CGColorSpaceCreateDeviceGray(),
                                                                            alpha: false)))
        for (source, format) in [(try png(colorType: 0), "png"), (jpeg, "jpg")] {
            let frame = try read(source, format)
            XCTAssertEqual(frame.image.colorSpace?.name as String?, CGColorSpace.genericGrayGamma2_2 as String, "ImageIO's default for untagged gray")
            XCTAssertEqual(frame.properties[ImageFrame.iccKey] as? Data, Data())
            let output = try write(frame)
            XCTAssertNil(try writtenProfile(output))
            XCTAssertEqual(try samples(output), ImagePixels.straight(frame.image).samples)
            XCTAssertNil(JpegEncoder.embeddedProfile(try write(frame, "jpg")))
        }
    }

    func testActualProfilesAreWrittenByteForByte() throws {
        let adobe = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/AdobeRGB1998.icc"))
        let cases: [(Data, UInt8)] = [(try profile(CGColorSpace.sRGB), 2), (adobe, 2), (try profile(CGColorSpace.displayP3), 2),
                                      (try profile(CGColorSpace.genericGrayGamma2_2), 0), (try profile(CGColorSpace.sRGB), 3)]
        for (icc, colorType) in cases {
            let frame = try read(try png(colorType: colorType, before: [try iccp(icc)]), "png")
            XCTAssertEqual(frame.properties[ImageFrame.iccKey] as? Data, icc)
            let output = try write(frame)
            XCTAssertEqual(try writtenProfile(output), icc)
            XCTAssertFalse(chunks(output).contains { $0.type == "sRGB" || $0.type == "cICP" })
            XCTAssertEqual(try samples(output), ImagePixels.straight(frame.image).samples)
            guard colorType != 3 else { continue } // palette samples become sRGB for the other writers
            XCTAssertEqual(JpegEncoder.embeddedProfile(try write(frame, "jpg")), icc)
            XCTAssertEqual(CodecPixels.colorProfile(frame), icc, "WebP, JPEG XL and PSD share this guard")
            for format in ["webp", "jxl", "psd"] { XCTAssertFalse(try write(frame, format).isEmpty) }
        }
        // A JPEG's genuine sRGB profile, which ImageIO alone writes as a bare sRGB chunk.
        var tagged = ImageFrame(image: GraphicsTestKit.solid(12, 8, (200, 90, 40, 255)))
        tagged.image = ImagePixels.image(ImagePixels.bitmap(tagged.image))
        tagged.properties[ImageFrame.iccKey] = try profile(CGColorSpace.sRGB)
        let jpeg = try read(try JpegEncoder.encode(tagged), "jpg")
        XCTAssertEqual(try writtenProfile(try write(jpeg)), try profile(CGColorSpace.sRGB))
    }

    func testStaleStrippedOrDeclaredOnlyColourIsNotLabelledWithAProfile() throws {
        let srgb = try profile(CGColorSpace.sRGB)
        let frame = try read(try png(colorType: 2, before: [try iccp(srgb)]), "png")
        var strip = ImageOptions(), keepProfile = ImageOptions(), gray = ImageOptions()
        strip.keepMetadata = false
        strip.keepColorProfile = false
        keepProfile.keepMetadata = false
        gray.grayscale = true
        XCTAssertNil(try writtenProfile(try write(frame, options: strip)))
        XCTAssertEqual(try writtenProfile(try write(frame, options: keepProfile)), srgb)
        XCTAssertNil(try writtenProfile(try write(frame, options: gray)))
        // A spec-invalid RGB profile in a gray PNG, and a CMYK profile beside converted RGB samples.
        XCTAssertNil(try writtenProfile(try write(try read(try png(colorType: 0, before: [try iccp(srgb)]), "png"))))
        var cmyk = ImageFrame(image: ImagePixels.make((0..<12 * 8 * 4).map { UInt8($0 * 13 & 255) }, 12, 8, components: 4,
                                                      space: CGColorSpace(name: CGColorSpace.genericCMYK)!, alpha: false))
        cmyk.properties[ImageFrame.iccKey] = try profile(CGColorSpace.genericCMYK)
        let converted = try write(try read(try JpegEncoder.encode(cmyk), "jpg"))
        XCTAssertNil(try writtenProfile(converted))
        XCTAssertTrue(chunks(converted).contains { $0.type == "sRGB" })
        // gAMA alone keeps ImageIO's own colour space and chunks.
        let linear = try read(try png(colorType: 2, before: [chunk("gAMA", Data([0, 1, 0x86, 0xA0]))]), "png")
        XCTAssertNil(linear.properties[ImageFrame.iccKey])
        XCTAssertEqual(linear.image.colorSpace?.name as String?, CGColorSpace.linearSRGB as String)
        XCTAssertNotNil(try writtenProfile(try write(linear)))
    }
}
