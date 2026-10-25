import COpenJPEG
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
import zlib
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

    // ───────── IPTC into PSD/PSB ─────────

    /// IPTC-NAA datasets (record, number, value) as an IIM record.
    private func iim(_ datasets: [(UInt8, UInt8, String)]) -> [UInt8] {
        datasets.flatMap { record, number, value -> [UInt8] in
            let bytes = Array(value.utf8)
            return [0x1C, record, number, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
        }
    }

    /// A Photoshop image resource block: signature, id, Pascal name and data, each padded to an even length.
    private func resource(_ id: Int, _ data: [UInt8], name: String = "", signature: String = "8BIM") -> [UInt8] {
        var bytes = Array(signature.utf8) + [UInt8(id >> 8), UInt8(id & 255), UInt8(name.utf8.count)] + Array(name.utf8)
        if bytes.count % 2 == 1 { bytes.append(0) }
        bytes += [24, 16, 8, 0].map { UInt8(data.count >> $0 & 255) } + data
        if data.count % 2 == 1 { bytes.append(0) }
        return bytes
    }

    /// Photoshop APP13 segments holding `stream`, split at `cuts`.
    private func app13(_ stream: [UInt8], cuts: [Int] = []) -> [UInt8] {
        let bounds = [0] + cuts + [stream.count]
        return zip(bounds, bounds.dropFirst()).flatMap { start, end -> [UInt8] in
            let payload = Array("Photoshop 3.0\0".utf8) + stream[start..<end]
            return [0xFF, 0xED, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 255)] + payload
        }
    }

    /// A JPEG of `image` with `markers` after its JFIF header, read back by the image engine.
    private func jpegSource(_ markers: [UInt8], _ image: CGImage? = nil, dpi: (x: Double, y: Double)? = nil) throws -> (data: Data, frame: ImageFrame) {
        var frame = ImageFrame(image: image ?? pattern(3), dpi: dpi)
        frame.properties[ImageFrame.jpegMarkersKey] = Data(markers)
        let data = try JpegEncoder.encode(frame)
        return (data, try read(data))
    }

    /// `frame` through the preset's options and the writer of `format`, as the image engine converts it.
    private func written(_ frame: ImageFrame, _ format: String, _ options: ImageOptions = ImageOptions()) throws -> Data {
        try photoshop(frame, format, options)
    }

    /// `frame` through the preset's options and the PSD/PSB writer, as the image engine converts it.
    private func photoshop(_ frame: ImageFrame, _ format: String, _ options: ImageOptions = ImageOptions()) throws -> Data {
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = FilePath.combine(folder, "output." + format)
        try ImageEncoder.save([try ImageEncoder.applyOptions(frame, options, targetFormat: format)], to: path, format: format)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// The image resource blocks of a PSD/PSB file and everything after them (layers and composite).
    private func resources(_ file: Data) -> (blocks: [(id: Int, bytes: [UInt8])], rest: [UInt8]) {
        let bytes = [UInt8](file)
        func number(_ at: Int, _ size: Int) -> Int { bytes[at..<at + size].reduce(0) { $0 << 8 | Int($1) } }
        XCTAssertEqual(Array(bytes.prefix(4)), Array("8BPS".utf8))
        var offset = 30 + number(26, 4)
        let end = offset + 4 + number(offset, 4)
        offset += 4
        var blocks: [(id: Int, bytes: [UInt8])] = []
        while offset < end {
            let data = offset + 6 + (Int(bytes[offset + 6]) + 2) / 2 * 2
            let next = data + 4 + (number(data, 4) + 1) / 2 * 2
            guard Array(bytes[offset..<offset + 4]) == Array("8BIM".utf8), next <= end else { XCTFail("malformed resource at \(offset)"); break }
            blocks.append((number(offset + 4, 2), Array(bytes[offset..<next])))
            offset = next
        }
        return (blocks, Array(bytes[end...]))
    }

    /// The IPTC ImageIO reads from a file.
    private func imageIOIptc(_ data: Data) -> NSDictionary? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyIPTCDictionary] as? NSDictionary
    }

    /// The XMP packet the JPEG writer stores for `frame`: the payload of its "http://ns.adobe.com/xap/1.0/" APP1.
    private func jpegXmp(_ frame: ImageFrame) throws -> [UInt8] {
        let jpeg = try JpegEncoder.encode(try ImageEncoder.applyOptions(frame, ImageOptions(), targetFormat: "jpg"))
        let header = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        return Array(try XCTUnwrap(JpegEncoder.segments(jpeg).first { $0.0 == 0xE1 && $0.1.starts(with: header) }).1.dropFirst(header.count))
    }

    func testJpegIptcResourcesReachPsdAndPsbExactlyBesideTheirOwnResolutionAndProfile() throws {
        let caption = "한글 캡션 · café"
        let record = iim([(1, 90, "\u{1B}%G"), (2, 5, "Object"), (2, 25, "alpha"), (2, 25, "beta"), (2, 25, "gamma"), (2, 120, caption)])
        let iptc = resource(0x0404, record), digest = resource(0x0425, Array(Insecure.MD5.hash(data: record)))
        // The writer makes resolution, profile and version blocks itself; the copyright flag is document metadata.
        let stream = resource(0x03ED, [0, 72, 0, 0, 0, 1, 0, 1, 0, 72, 0, 0, 0, 1, 0, 1]) + iptc + resource(0x040F, Array("not a profile".utf8))
            + resource(0x0421, [0, 0, 0, 1, 0, 0, 0]) + digest + resource(0x040A, [1])
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let icc = try XCTUnwrap(p3.copyICCData() as Data?)
        let source = try jpegSource(app13(stream), pattern(3).copy(colorSpace: p3), dpi: (300, 300))
        let expectedIptc = try XCTUnwrap(imageIOIptc(source.data))
        XCTAssertEqual(expectedIptc[kCGImagePropertyIPTCKeywords] as? [String], ["alpha", "beta", "gamma"])
        XCTAssertEqual(expectedIptc[kCGImagePropertyIPTCCaptionAbstract] as? String, caption)
        let resolution = resource(0x03ED, [0x01, 0x2C, 0, 0, 0, 1, 0, 1, 0x01, 0x2C, 0, 0, 0, 1, 0, 1])
        for format in ["psd", "psb"] {
            let file = try photoshop(source.frame, format)
            let kept = resources(file)
            XCTAssertEqual(kept.blocks.map(\.id), [0x03ED, 0x0404, 0x0425, 0x040A, 0x040F, 0x0424], format)
            XCTAssertEqual(kept.blocks.map(\.bytes), [resolution, iptc, digest, resource(0x040A, [1]), resource(0x040F, [UInt8](icc)),
                                                       resource(0x0424, try jpegXmp(source.frame))], format)
            XCTAssertEqual(imageIOIptc(file), expectedIptc, format)
            let decoded = try read(file, format: format)
            XCTAssertEqual(decoded.image.colorSpace?.copyICCData() as Data?, icc)
            XCTAssertEqual(ImagePixels.straight(decoded.image).samples, ImagePixels.straight(source.frame.image).samples)
            // keepMetadata=false removes the IPTC alone: the profile, layers and composite stay byte for byte.
            var options = ImageOptions()
            options.keepMetadata = false
            let stripped = resources(try photoshop(source.frame, format, options))
            XCTAssertEqual(stripped.blocks.map(\.bytes), [resolution, resource(0x040F, [UInt8](icc))], format)
            XCTAssertEqual(stripped.rest, kept.rest, format)
        }
    }

    func testSplitDuplicateAndBrokenPhotoshopSegmentsCarryOnlyCompleteIptcBlocks() throws {
        let first = resource(0x0404, iim([(2, 25, "one")])), second = resource(0x0404, iim([(2, 25, "two")]), name: "B")
        let odd = resource(0x0404, iim([(2, 120, "odd!")]))
        let mesa = resource(0x0401, [1, 2, 3], signature: "MeSa") // ImageReady's signature is stepped over
        let other: [UInt8] = [0xFF, 0xED, 0, 12] + Array("Adobe_CM\0".utf8) + [1] // not a Photoshop segment
        let truncated = Array(resource(0x0425, [UInt8](repeating: 7, count: 16)).prefix(20))
        let cases: [([UInt8], [[UInt8]])] = [
            // Blocks split between segments, a duplicate with a Pascal name, and a block running past the stream.
            (app13(first + mesa + second, cuts: [5, first.count + 3]) + other + app13(truncated), [first, second]),
            (app13(first + Array("XXXX".utf8) + second.dropFirst(4)), [first]),
            // The last block's padding byte may be missing; the copy has it.
            (app13(first + odd.dropLast()), [first, odd]),
        ]
        for (markers, expected) in cases {
            let source = try jpegSource(markers)
            for format in ["psd", "psb"] {
                let file = try photoshop(source.frame, format)
                XCTAssertEqual(resources(file).blocks.filter { $0.id != 0x0424 }.map(\.bytes), expected, format)
                XCTAssertEqual(ImagePixels.straight(try read(file, format: format).image).samples, ImagePixels.straight(source.frame.image).samples)
            }
        }
    }

    func testMetadataFixtureGainsOnlyItsIptcAndXmpInPsdAndPsb() throws {
        let frame = try read(Data(base64Encoded: Self.jpeg["metadata"]!)!)
        // SHA-256 of the 808c076 engine's PSD/PSB of this conversion (Image parity preset), written without IPTC.
        for (format, frozen) in [("psd", "6bf715fbb554669514c71998366ee8e05fdab116cfddeb6fe09f17f1a46cbd1c"),
                                 ("psb", "addf490c63cfcdb5d29bdfb6fabd9aa96a608c6d40f361e93125859b17925c2b")] {
            var options = ImageOptions()
            options.quality = 75
            let file = try photoshop(frame, format, options)
            options.keepMetadata = false
            let stripped = try photoshop(frame, format, options)
            XCTAssertEqual(hash([UInt8](stripped)), frozen, format)
            // ImageMagick's only resource for this source, the APP13's IPTC block (30 bytes), and the XMP the JPEG writer
            // stores for it too.
            let xmp = resource(0x0424, try jpegXmp(frame))
            XCTAssertEqual(resources(file).blocks.map(\.bytes), [resource(0x0404, iim([(2, 5, "FileToX IPTC")])), xmp], format)
            XCTAssertEqual(file.count, stripped.count + 30 + xmp.count)
            XCTAssertEqual(file.prefix(30), stripped.prefix(30))
            XCTAssertEqual(resources(file).rest, resources(stripped).rest)
            XCTAssertEqual((imageIOIptc(file)?[kCGImagePropertyIPTCObjectName] as? String), "FileToX IPTC")
        }
    }

    /// `psd` with `blocks` after its own image resources (its colour mode data is empty).
    private func addingResources(_ psd: [UInt8], _ blocks: [UInt8]) -> Data {
        let length = psd[30..<34].reduce(0) { $0 << 8 | Int($1) }, total = length + blocks.count
        return Data(psd[0..<30] + [24, 16, 8, 0].map { UInt8(total >> $0 & 255) } + psd[34..<34 + length] + blocks + psd[(34 + length)...])
    }

    func testPsdSourcesKeepTheirIptcButNotTheirStructureResources() throws {
        let iptc = resource(0x0404, iim([(2, 5, "From PSD"), (2, 25, "x"), (2, 25, "y")]))
        let digest = resource(0x0425, [UInt8](repeating: 3, count: 16))
        let layers: [GraphicsBuilders.PsdLayer] = [.init(left: 0, top: 0, width: 12, height: 8, r: 255, g: 0, b: 0),
                                                   .init(left: 6, top: 2, width: 4, height: 3, r: 0, g: 0, b: 255)]
        for realComposite in [true, false] {
            // Without a real composite (its VersionInfo says so) the layers are composited; the copy never repeats that claim.
            let built = GraphicsBuilders.layeredPsd(12, 8, composite: { x, y in (6..<10).contains(x) && (2..<5).contains(y) ? (0, 0, 255) : (255, 0, 0) },
                                                    layers: layers, realComposite: realComposite)
            let frame = try read(addingResources(built, iptc + resource(0x040C, [1, 2, 3, 4]) + digest), format: "psd")
            for format in ["psd", "psb"] {
                let file = try photoshop(frame, format)
                let blocks = resources(file).blocks
                XCTAssertEqual(blocks.filter { $0.id != 0x0424 }.map(\.bytes), [iptc, digest], "\(realComposite) \(format)")
                let decoded = try read(file, format: format)
                XCTAssertEqual(ImagePixels.straight(decoded.image).samples, ImagePixels.straight(frame.image).samples)
                // Read back, the XMP the copy gained is written the same again.
                XCTAssertEqual(resources(try photoshop(decoded, "psb")).blocks.map(\.bytes), blocks.map(\.bytes))
            }
        }
        // A resource running past its section ends what is read of it; the earlier block still counts.
        let broken = GraphicsBuilders.layeredPsd(12, 8, composite: { _, _ in (9, 9, 9) }, layers: layers)
        let truncated = try read(addingResources(broken, iptc + Array(resource(0x0425, [UInt8](repeating: 3, count: 16)).prefix(14))), format: "psd")
        XCTAssertEqual(resources(try photoshop(truncated, "psd")).blocks.filter { $0.id != 0x0424 }.map(\.bytes), [iptc])
        // A transparent composite (read here, not by ImageIO) keeps the IPTC as well.
        var transparent = ImageFrame(image: pattern(4))
        transparent.properties[ImageFrame.jpegMarkersKey] = Data(app13(iptc))
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let png = FilePath.combine(folder, "transparent.png")
        try ImageEncoder.save([transparent], to: png, format: "png")
        let layered = try photoshop(try read(try Data(contentsOf: URL(fileURLWithPath: png)), format: "png"), "psd")
        // ImageIO's PNG also has eXIf, which comes along as EXIF.
        XCTAssertEqual(resources(layered).blocks.filter { ![0x0422, 0x0424].contains($0.id) }.map(\.bytes), [iptc])
        let composite = try read(layered, format: "psd")
        XCTAssertTrue(ImagePixels.hasAlpha(composite.image))
        XCTAssertEqual(resources(try photoshop(composite, "psb")).blocks.filter { ![0x0422, 0x0424].contains($0.id) }.map(\.bytes), [iptc])
    }

    func testLayerCompositeKeepsTheDocumentProfileLikeTheMergedComposite() throws {
        let layers: [GraphicsBuilders.PsdLayer] = [.init(left: 0, top: 0, width: 12, height: 8, r: 250, g: 20, b: 10),
                                                   .init(left: 3, top: 2, width: 5, height: 4, r: 10, g: 200, b: 40)]
        let composite: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in (3..<8).contains(x) && (2..<6).contains(y) ? (10, 200, 40) : (250, 20, 10) }
        for (gray, name) in [(false, CGColorSpace.displayP3), (true, CGColorSpace.genericGrayGamma2_2)] {
            let icc = try XCTUnwrap(CGColorSpace(name: name)?.copyICCData() as Data?)
            // Photoshop's merged composite, as ImageIO decodes it, is the oracle for the one composited from the layers.
            let merged = try read(addingResources(GraphicsBuilders.layeredPsd(12, 8, composite: composite, layers: layers, gray: gray),
                                                  resource(0x040F, [UInt8](icc))), format: "psd")
            let layered = try read(addingResources(GraphicsBuilders.layeredPsd(12, 8, composite: composite, layers: layers, realComposite: false,
                                                                               gray: gray), resource(0x040F, [UInt8](icc))), format: "psd")
            XCTAssertEqual(merged.image.colorSpace?.copyICCData() as Data?, icc, name as String)
            XCTAssertTrue(CFEqual(layered.image.colorSpace, merged.image.colorSpace), name as String)
            let colors = gray ? 1 : 3
            func color(_ image: CGImage) -> [UInt8] {
                let (samples, channels, _) = ImagePixels.straight(image)
                return (0..<image.width * image.height).flatMap { samples[$0 * channels..<$0 * channels + colors] }
            }
            XCTAssertEqual(color(layered.image), color(merged.image), name as String)
            for frame in [merged, layered] {
                XCTAssertEqual(frame.properties[ImageFrame.iccKey] as? Data, icc, name as String)
                XCTAssertEqual(JpegEncoder.embeddedProfile(try JpegEncoder.encode(try ImageEncoder.applyOptions(frame, ImageOptions(), targetFormat: "jpg"))),
                               icc, name as String)
            }
        }
    }

    func testPngRawProfilesCarryIptcWithinOneInflationBudget() throws {
        let record = iim([(2, 5, "From PNG"), (2, 25, "k1"), (2, 25, "k2")])
        let iptc = resource(0x0404, record)
        // FileToX's own PNG of a JPEG: "Raw profile type 8bim" with every Photoshop resource of its APP13.
        let jpeg = try jpegSource(app13(resource(0x03ED, [0, 72, 0, 0, 0, 1, 0, 1, 0, 72, 0, 0, 0, 1, 0, 1]) + iptc + resource(0x0421, [0, 0, 0, 1, 0, 0, 0])))
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let own = FilePath.combine(folder, "own.png")
        try ImageEncoder.save([jpeg.frame], to: own, format: "png")
        let plain = FilePath.combine(folder, "plain.png")
        try ImageEncoder.save([ImageFrame(image: pattern(3))], to: plain, format: "png")
        let base = try Data(contentsOf: URL(fileURLWithPath: plain))
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + payload
            let crc = Int(body.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
            return [24, 16, 8, 0].map { UInt8(payload.count >> $0 & 255) } + body + [24, 16, 8, 0].map { UInt8(crc >> $0 & 255) }
        }
        // ImageMagick's layout: "\n<name>\n<length>\n" and 36 bytes per line of lowercase hex.
        func raw(_ name: String, _ bytes: [UInt8]) -> [UInt8] {
            Array("\n\(name)\n\(String(format: "%8lu", bytes.count))".utf8) + stride(from: 0, to: bytes.count, by: 36).flatMap { start in
                [10] + bytes[start..<min(start + 36, bytes.count)].flatMap { Array(String(format: "%02x", $0).utf8) }
            } + [10]
        }
        func text(_ name: String, _ value: [UInt8]) -> [UInt8] { chunk("tEXt", Array("Raw profile type \(name)".utf8) + [0] + value) }
        func ztxt(_ name: String, _ value: [UInt8]) throws -> [UInt8] {
            chunk("zTXt", Array("Raw profile type \(name)".utf8) + [0, 0] + (try Deflate.deflate(Data(value), windowBits: 15)))
        }
        // iTXt: compression flag and method, language tag and translated keyword, then the (possibly deflated) text.
        func itxt(_ name: String, _ value: [UInt8], flag: UInt8 = 0, method: UInt8 = 0, language: String = "", translated: String = "",
                  terminated: Bool = true) throws -> [UInt8] {
            let text = flag == 1 ? [UInt8](try Deflate.deflate(Data(value), windowBits: 15)) : value
            return chunk("iTXt", Array("Raw profile type \(name)".utf8) + [0, flag, method] + Array(language.utf8) + [0]
                         + Array(translated.utf8) + (terminated ? [0] : []) + text)
        }
        func png(_ chunks: [[UInt8]], afterImage: [[UInt8]] = []) -> Data {
            Data(base.prefix(33) + chunks.joined() + base.dropFirst(33).dropLast(12) + afterImage.joined() + base.suffix(12))
        }
        let bare = iim([(2, 5, "Bare IIM")])
        // A stream inflating to 9 MiB, cut short: it fails after handing out nearly all of it.
        let large = [UInt8](try Deflate.deflate(Data(repeating: 0x30, count: 9 << 20), windowBits: 15))
        let failing = chunk("zTXt", Array("Raw profile type 8bim".utf8) + [0, 0] + large.dropLast(8))
        var badDigit = raw("8bim", iptc), badCrc = text("8bim", raw("8bim", iptc))
        badDigit[badDigit.count - 2] = UInt8(ascii: "g")
        badCrc[badCrc.count - 1] ^= 1
        let cases: [(Data, [[UInt8]])] = [
            (try Data(contentsOf: URL(fileURLWithPath: own)), [iptc]),
            // ImageMagick writes both profiles; the IIM of the 8bim one is not doubled.
            (png([try ztxt("8bim", raw("8bim", iptc)), text("iptc", raw("iptc", record))]), [iptc]),
            // A bare IIM record (also after the image data) becomes an IPTC block.
            (png([], afterImage: [try ztxt("iptc", raw("iptc", bare))]), [resource(0x0404, bare)]),
            // Two failing streams exhaust the budget together; no later chunk is inflated, uncompressed text still counts.
            (png([failing, failing, try ztxt("iptc", raw("iptc", bare))]), []),
            (png([failing, failing, try ztxt("iptc", raw("iptc", iim([(2, 5, "skipped")]))), text("iptc", raw("iptc", bare))]), [resource(0x0404, bare)]),
            // Too few or invalid hex digits and a bad CRC carry nothing; text after the declared length is ignored.
            (png([text("8bim", Array(raw("8bim", iptc).dropLast(3)))]), []),
            (png([text("8bim", badDigit)]), []),
            (png([badCrc]), []),
            (png([text("8bim", raw("8bim", iptc) + Array("zz\n".utf8))]), [iptc]),
            // iTXt as libpng reads it: plain or deflated text after the language tag and translated keyword.
            (png([try itxt("8bim", raw("8bim", iptc))]), [iptc]),
            (png([try itxt("8bim", raw("8bim", iptc), flag: 1, language: "en", translated: "8BIM")]), [iptc]),
            (png([], afterImage: [try itxt("iptc", raw("iptc", bare), flag: 1)]), [resource(0x0404, bare)]),
            (png([try itxt("8bim", raw("8bim", iptc), method: 7)]), [iptc]), // the method of plain text is ignored
            (png([try itxt("8bim", raw("8bim", iptc), flag: 1, method: 1)]), []),
            (png([try itxt("8bim", raw("8bim", iptc), flag: 2)]), []),
            (png([try itxt("8bim", raw("8bim", iptc), language: "en", terminated: false)]), []),
            // Deflated iTXt shares the zTXt budget; plain iTXt still counts once it is spent.
            (png([failing, failing, try itxt("iptc", raw("iptc", iim([(2, 5, "skipped")])), flag: 1),
                  try itxt("iptc", raw("iptc", bare))]), [resource(0x0404, bare)]),
        ]
        for (index, (file, expected)) in cases.enumerated() {
            let frame = try read(file, format: "png")
            for format in ["psd", "psb"] {
                let output = try photoshop(frame, format)
                // ImageIO's own PNGs carry eXIf (and XMP for IPTC): written as EXIF/XMP resources, checked elsewhere.
                XCTAssertEqual(resources(output).blocks.filter { ![0x0422, 0x0424].contains($0.id) }.map(\.bytes), expected, "case \(index) \(format)")
                XCTAssertEqual(ImagePixels.straight(try read(output, format: format).image).samples, ImagePixels.straight(frame.image).samples)
            }
        }
    }

    /// Every property of an XMP packet as "path=value", read by ImageIO (without its own "iio" reading markers), so
    /// packets compare regardless of order.
    private func xmpValues(_ packet: [UInt8]) -> Set<String> {
        guard let metadata = CGImageMetadataCreateFromXMPData(Data(packet) as CFData) else { return [] }
        var values = Set<String>()
        func add(_ tag: CGImageMetadataTag, _ path: String) {
            let name = path + ((CGImageMetadataTagCopyPrefix(tag) as String?).map { $0 + ":" } ?? "") + ((CGImageMetadataTagCopyName(tag) as String?) ?? "")
            if let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
                items.forEach { add($0, name + "/") }
            } else {
                values.insert(name + "=" + (CGImageMetadataTagCopyValue(tag).map { "\($0)" } ?? ""))
            }
        }
        for tag in (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]) ?? [] where CGImageMetadataTagCopyPrefix(tag) as String? != "iio" {
            add(tag, "")
        }
        return values
    }

    /// A little-endian 2 × 2 RGB TIFF with Photoshop resources (34377, BYTE) and an IPTC record (33723, LONG, padded to
    /// whole LONGs as Photoshop writes it).
    private func tiffWithPhotoshopData(_ resources: [UInt8], _ record: [UInt8]) -> Data {
        let padded = record + [UInt8](repeating: 0, count: (4 - record.count % 4) % 4), pixels = [UInt8](repeating: 120, count: 12)
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24)] }
        let entries = 11, data = 8 + 2 + 12 * entries + 4
        let bits = data, iptc = bits + 6, photoshop = iptc + padded.count, image = photoshop + resources.count
        let fields: [(Int, Int, Int, Int)] = [(256, 3, 1, 2), (257, 3, 1, 2), (258, 3, 3, bits), (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, image),
                                              (277, 3, 1, 3), (278, 3, 1, 2), (279, 4, 1, 12), (33723, 4, padded.count / 4, iptc), (34377, 1, resources.count, photoshop)]
        var file: [UInt8] = [0x49, 0x49, 42, 0] + u32(8) + u16(entries)
        for (tag, type, count, value) in fields { file += u16(tag) + u16(type) + u32(count) + (type == 3 && count == 1 ? u16(value) + [0, 0] : u32(value)) }
        return Data(file + u32(0) + u16(8) + u16(8) + u16(8) + padded + resources + pixels)
    }

    func testIptcOfPngPsdAndTiffSourcesReachJpegAndPngToo() throws {
        let record = iim([(2, 5, "Carried"), (2, 25, "k1")]), iptc = resource(0x0404, record), copyright = resource(0x040A, [1])
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + payload
            let crc = Int(body.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
            return [24, 16, 8, 0].map { UInt8(payload.count >> $0 & 255) } + body + [24, 16, 8, 0].map { UInt8(crc >> $0 & 255) }
        }
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let plain = FilePath.combine(folder, "plain.png")
        try ImageEncoder.save([ImageFrame(image: pattern(3, width: 6, height: 4))], to: plain, format: "png")
        let png = [UInt8](try Data(contentsOf: URL(fileURLWithPath: plain)))
        let raw = Array("\niptc\n\(String(format: "%8lu", record.count))\n".utf8) + Array(record.map { String(format: "%02x", $0) }.joined().utf8) + [10]
        let imageIOTiff = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(imageIOTiff, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pattern(3, width: 6, height: 4),
                                   [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCObjectName: "Carried", kCGImagePropertyIPTCKeywords: ["k1"]]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let built = GraphicsBuilders.layeredPsd(6, 4, composite: { _, _ in (9, 99, 199) }, layers: [])
        let sources: [(String, Data, [[UInt8]])] = [
            ("png", Data(png.prefix(33) + chunk("tEXt", Array("Raw profile type iptc".utf8) + [0] + raw) + png.dropFirst(33)), [iptc]),
            ("psd", addingResources(built, iptc + copyright), [iptc, copyright]),
            ("tiff", tiffWithPhotoshopData(copyright, record), [copyright, iptc]),
            ("tiff", imageIOTiff as Data, []),
        ]
        for (format, data, expected) in sources {
            let frame = try read(data, format: format)
            let jpeg = try written(frame, "jpg")
            let blocks = PsdCodec.metadataResources(jpeg, format: "jpg")
            // ImageIO's own TIFF keeps the record it serialized; its first dataset is the one written.
            let wanted = expected.isEmpty ? [UInt8](PsdCodec.metadataResources(data, format: "tiff")) : expected.flatMap { $0 }
            XCTAssertFalse(wanted.isEmpty, format)
            XCTAssertEqual([UInt8](blocks), wanted, "\(format) → JPEG APP13")
            XCTAssertEqual(imageIOIptc(jpeg)?[kCGImagePropertyIPTCObjectName] as? String, "Carried", "\(format) → JPEG, read by ImageIO")
            XCTAssertEqual([UInt8](PsdCodec.metadataResources(try written(frame, "png"), format: "png")), wanted, "\(format) → PNG")
            XCTAssertEqual(resources(try photoshop(frame, "psd")).blocks.filter { [0x0404, 0x040A].contains($0.id) }.flatMap(\.bytes), wanted, "\(format) → PSD")
            var options = ImageOptions()
            options.keepMetadata = false
            XCTAssertTrue(PsdCodec.metadataResources(try written(frame, "jpg", options), format: "jpg").isEmpty, format)
            XCTAssertTrue(PsdCodec.metadataResources(try written(frame, "png", options), format: "png").isEmpty, format)
        }
        // A TIFF record cut inside its second dataset's header keeps the first (zero padding could complete a cut value);
        // a value that isn't IIM is no IPTC.
        let cut = try read(tiffWithPhotoshopData([], Array(record.dropLast(4))), format: "tiff")
        XCTAssertEqual(cut.properties[ImageFrame.photoshopKey] as? Data, Data(resource(0x0404, iim([(2, 5, "Carried")]))))
        XCTAssertNil(try read(tiffWithPhotoshopData([], [0, 1, 2, 3]), format: "tiff").properties[ImageFrame.photoshopKey])
    }

    func testPngCommentsReachJpegAndPngOutputsBesideTheirIptc() throws {
        let record = iim([(2, 5, "With comment")]), iptc = resource(0x0404, record)
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + payload
            let crc = Int(body.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
            return [24, 16, 8, 0].map { UInt8(payload.count >> $0 & 255) } + body + [24, 16, 8, 0].map { UInt8(crc >> $0 & 255) }
        }
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let plain = FilePath.combine(folder, "plain.png")
        try ImageEncoder.save([ImageFrame(image: pattern(3, width: 6, height: 4))], to: plain, format: "png")
        let png = [UInt8](try Data(contentsOf: URL(fileURLWithPath: plain)))
        let latin = Array("Plain comment".utf8), korean = Array("한글 메모".utf8)
        let raw = Array("\niptc\n\(String(format: "%8lu", record.count))\n".utf8) + Array(record.map { String(format: "%02x", $0) }.joined().utf8) + [10]
        let chunks = chunk("tEXt", Array("Comment".utf8) + [0] + latin)
            + chunk("iTXt", Array("Comment".utf8) + [0, 1, 0, 0, 0] + [UInt8](try Deflate.deflate(Data(korean), windowBits: 15)))
            + chunk("tEXt", Array("Raw profile type iptc".utf8) + [0] + raw)
        let frame = try read(Data(png.prefix(33) + chunks + png.dropFirst(33)), format: "png")
        let jpeg = try written(frame, "jpg")
        XCTAssertEqual(JpegEncoder.segments(jpeg).filter { $0.0 == 0xFE }.map { [UInt8]($0.1) }, [latin, korean])
        XCTAssertEqual([UInt8](PsdCodec.metadataResources(jpeg, format: "jpg")), iptc)
        XCTAssertEqual(imageIOIptc(jpeg)?[kCGImagePropertyIPTCObjectName] as? String, "With comment")
        let output = try written(frame, "png")
        XCTAssertEqual(PsdCodec.pngText(output, keywords: ["Comment"]).map { [UInt8]($0.text) }, [latin + korean])
        XCTAssertEqual([UInt8](PsdCodec.metadataResources(output, format: "png")), iptc)
        var options = ImageOptions()
        options.keepMetadata = false
        XCTAssertTrue(JpegEncoder.preservedMarkers(try written(frame, "jpg", options)).isEmpty)
        XCTAssertTrue(PsdCodec.pngText(try written(frame, "png", options), keywords: ["Comment", "Raw profile type 8bim"]).isEmpty)
    }

    func testPsdAndPsbKeepExifXmpAndDocumentResourcesButHaveNoPlaceForComments() throws {
        let caption = resource(0x03F0, [5] + Array("Notes".utf8)), iptc = resource(0x0404, iim([(2, 5, "Resources"), (2, 25, "kw")]))
        let copyright = resource(0x040A, [1]), url = resource(0x040B, Array("https://example.com/a".utf8))
        let digest = resource(0x0425, [UInt8](repeating: 9, count: 16))
        // Version info, thumbnail, slices, guides, channel names and the slices' URL list describe the source document.
        let structure = [resource(0x0421, [0, 0, 0, 1, 0]), resource(0x040C, [1, 2, 3]), resource(0x041A, [0, 0, 0, 6]),
                         resource(0x0408, [0, 0, 0, 1]), resource(0x03EE, [5] + Array("Alpha".utf8)), resource(0x041E, [0, 0, 0, 0])]
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, "TestPhone" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 6 as CFNumber)
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.example.com/ftx/1.0/" as CFString, "ftx" as CFString, nil)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "ftx:Custom" as CFString, "custom value" as CFString))
        var original = ImageFrame(image: pattern(3, width: 31, height: 17))
        original.properties[ImageFrame.metadataKey] = metadata
        original.properties[kCGImagePropertyOrientation] = 6
        original.properties[ImageFrame.jpegMarkersKey] = Data([0xFF, 0xFE, 0, 17] + Array("FileToX comment".utf8)
            + app13(caption + structure[0] + iptc + copyright + structure.dropFirst().joined() + url + digest))
        let source = try read(try JpegEncoder.encode(original))
        XCTAssertEqual((source.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
        for format in ["psd", "psb"] {
            let file = try photoshop(source, format)
            let kept = resources(file)
            // No resolution or profile: the source has neither.
            XCTAssertEqual(kept.blocks.map(\.id), [0x03F0, 0x0404, 0x040A, 0x040B, 0x0425, 0x0422, 0x0424], format)
            guard kept.blocks.count == 7 else { continue }
            XCTAssertEqual(kept.blocks.prefix(5).map(\.bytes), [caption, iptc, copyright, url, digest], format)
            // EXIF data 1 is TIFF-structured, upright like the pixels, with their size.
            let exif = Array(kept.blocks[5].bytes.dropFirst(12))
            XCTAssertTrue(exif.starts(with: [0x4D, 0x4D, 0, 42]) || exif.starts(with: [0x49, 0x49, 42, 0]), format)
            let entries = exifEntries(exif)
            XCTAssertNotNil(entries[0x0110], format)
            XCTAssertEqual(entries[0x0112]?.value, 1, format)
            XCTAssertEqual(entries[0xA002]?.value, 17, format)
            XCTAssertEqual(entries[0xA003]?.value, 31, format)
            let xmp = String(decoding: kept.blocks[6].bytes.dropFirst(12), as: UTF8.self)
            XCTAssertTrue(xmp.contains("custom value"), format)
            XCTAssertFalse(xmp.contains("ns.apple.com/ImageIO"), format) // ImageIO's private reading markers stay out
            // A JPEG comment is free text without a Photoshop resource; the caption resource is a different field.
            XCTAssertNil(file.range(of: Data("FileToX comment".utf8)), format)
            // ImageIO reads all of it back from the Photoshop file.
            let decoded = try read(file, format: format)
            let back = try XCTUnwrap(CGImageSourceCreateWithData(file as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(back, 0, nil) as? [CFString: Any])
            XCTAssertEqual((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String, "TestPhone")
            XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
            XCTAssertEqual(imageIOIptc(file)?[kCGImagePropertyIPTCObjectName] as? String, "Resources")
            let readMetadata = try XCTUnwrap(decoded.properties[ImageFrame.metadataKey].map { $0 as! CGImageMetadata })
            XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(readMetadata, nil, "ftx:Custom" as CFString) as String?, "custom value")
            XCTAssertEqual(ImagePixels.straight(decoded.image).samples, ImagePixels.straight(ImagePixels.oriented(source.image, 6)).samples)
            // Written again from the Photoshop file, the same blocks (ImageIO may order the XMP properties differently);
            // JPEG keeps its EXIF and XMP.
            let again = resources(try photoshop(decoded, format == "psd" ? "psb" : "psd")).blocks
            XCTAssertEqual(again.dropLast().map(\.bytes), kept.blocks.dropLast().map(\.bytes), format)
            XCTAssertEqual(xmpValues(Array(again.last?.bytes.dropFirst(12) ?? [])), xmpValues(Array(kept.blocks[6].bytes.dropFirst(12))), format)
            XCTAssertEqual(xmpValues(Array(kept.blocks[6].bytes.dropFirst(12))), ["ftx:Custom=custom value", "dc:subject/dc:[0]=kw",
                                                                                   "dc:title/dc:[0]=Resources"], format)
            let jpeg = try XCTUnwrap(CGImageSourceCreateWithData(try JpegEncoder.encode(try ImageEncoder.applyOptions(decoded, ImageOptions(), targetFormat: "jpg")) as CFData, nil))
            XCTAssertEqual((CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil) as? [CFString: Any])?[kCGImagePropertyTIFFDictionary]
                .flatMap { ($0 as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String }, "TestPhone")
            XCTAssertEqual(CGImageSourceCopyMetadataAtIndex(jpeg, 0, nil).flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "ftx:Custom" as CFString) } as String?,
                           "custom value")
            // keepMetadata=false removes every metadata block; layers and composite stay byte for byte.
            var options = ImageOptions()
            options.keepMetadata = false
            let stripped = resources(try photoshop(source, format, options))
            XCTAssertTrue(stripped.blocks.isEmpty, format)
            XCTAssertEqual(stripped.rest, kept.rest, format)
        }
    }

    // ───────── EXIF ─────────

    /// IFD0 and Exif IFD entries of a TIFF-structured EXIF blob, read without ImageIO: tag → (type, count, first value
    /// for SHORT/LONG entries).
    private func exifEntries(_ blob: [UInt8]) -> [Int: (type: Int, count: Int, value: Int)] {
        let little = blob.starts(with: [0x49, 0x49])
        func number(_ at: Int, _ size: Int) -> Int { (0..<size).reduce(0) { $0 << 8 | Int(blob[at + (little ? size - 1 - $1 : $1)]) } }
        var result: [Int: (type: Int, count: Int, value: Int)] = [:]
        func read(_ ifd: Int) {
            for entry in (0..<number(ifd, 2)).map({ ifd + 2 + 12 * $0 }) {
                let (tag, type, count) = (number(entry, 2), number(entry + 2, 2), number(entry + 4, 4))
                result[tag] = (type, count, type == 3 ? number(entry + 8, 2) : number(entry + 8, 4))
                if tag == 0x8769 { read(number(entry + 8, 4)) }
            }
        }
        read(number(4, 4))
        return result
    }

    /// The EXIF blob of a JPEG (APP1), WebP (EXIF chunk) or JPEG XL (Exif box) file.
    private func exifBlob(_ file: [UInt8]) -> [UInt8]? {
        func u32(_ at: Int, little: Bool = false) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(file[at + (little ? 3 - $1 : $1)]) } }
        var i = file.starts(with: [0xFF, 0xD8]) ? 2 : file.starts(with: Array("RIFF".utf8)) ? 12 : 0
        while i + 8 <= file.count {
            if file.starts(with: [0xFF, 0xD8]) {
                guard file[i] == 0xFF, file[i + 1] != 0xDA else { return nil }
                let length = Int(file[i + 2]) << 8 | Int(file[i + 3])
                if file[i + 1] == 0xE1, Array(file[i + 4..<i + 10]) == Array("Exif\0\0".utf8) { return Array(file[i + 10..<i + 2 + length]) }
                i += 2 + length
            } else if file.starts(with: Array("RIFF".utf8)) {
                let length = u32(i + 4, little: true)
                if Array(file[i..<i + 4]) == Array("EXIF".utf8) { return Array(file[i + 8..<i + 8 + length]) }
                i += 8 + length + length % 2
            } else {
                let length = u32(i)
                guard length >= 8 else { return nil }
                if Array(file[i + 4..<i + 8]) == Array("Exif".utf8) { return Array(file[i + 12..<i + length]) } // after the TIFF offset
                i += length
            }
        }
        return nil
    }

    func testExifRecordsThePicturesOwnSizeAndColourSpaceWithoutTheSourceFileStructure() throws {
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, "TestPhone" as CFString)
        // A TIFF source's sample layout describes that file, not the JPEG, WebP or JPEG XL written from it.
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFPhotometricInterpretation, 2 as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, 9 as CFNumber)
        let folder = GraphicsTestKit.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for (name, colorSpaceTag) in [(CGColorSpace.sRGB, 1 as Int?), (CGColorSpace.displayP3, nil)] {
            let image = try XCTUnwrap(pattern(3, width: 300, height: 7).copy(colorSpace: try XCTUnwrap(CGColorSpace(name: name))))
            for format in ["jpg", "webp", "jxl"] {
                let path = FilePath.combine(folder, "exif.\(format)")
                try ImageEncoder.save([ImageFrame(image: image, properties: [ImageFrame.metadataKey: metadata])], to: path, format: format)
                let entries = exifEntries(try XCTUnwrap(exifBlob([UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))), "\(format) \(name)"))
                XCTAssertNotNil(entries[0x0110], "\(format) \(name)") // the camera model stays
                XCTAssertNil(entries[0x0106], "\(format) \(name)")
                XCTAssertEqual(entries[0xA002]?.value, 300, "\(format) \(name)")
                XCTAssertEqual(entries[0xA003]?.value, 7, "\(format) \(name)")
                XCTAssertEqual(entries[0xA001]?.value, colorSpaceTag, "\(format) \(name)")
            }
        }
    }

    /// A big-endian EXIF APP1 segment: IFD0 with Model "TestPhone" and an Exif IFD with ColorSpace = `colorSpace`.
    private func exifSegment(colorSpace: Int) -> [UInt8] {
        var tiff: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8]
        tiff += [0, 2] + [0x01, 0x10, 0, 2, 0, 0, 0, 10, 0, 0, 0, 56] + [0x87, 0x69, 0, 4, 0, 0, 0, 1, 0, 0, 0, 38] + [0, 0, 0, 0]
        tiff += [0, 1] + [0xA0, 0x01, 0, 3, 0, 0, 0, 1, UInt8(colorSpace >> 8), UInt8(colorSpace & 255), 0, 0] + [0, 0, 0, 0]
        let payload = Array("Exif\0\0".utf8) + tiff + Array("TestPhone\0".utf8)
        return [0xFF, 0xE1, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 255)] + payload
    }

    func testGrayAndCmykExifNeverClaimsSrgb() throws {
        let grayProfile = try XCTUnwrap(CGColorSpace(iccData: try Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic Gray Profile.icc")) as CFData))
        let cmykProfile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericCMYK))
        let gray = ImagePixels.make((0..<23 * 9).map { UInt8($0 * 11 & 255) }, 23, 9, components: 1, space: grayProfile, alpha: false)
        let cmyk = ImagePixels.make((0..<23 * 9 * 4).map { UInt8($0 * 7 & 255) }, 23, 9, components: 4, space: cmykProfile, alpha: false)
        for (image, targets) in [(gray, ["jpg", "psd", "jxl"]), (cmyk, ["jpg", "psd", "webp"])] {
            // A camera-style source: a real profile and EXIF ColorSpace = uncalibrated, after the JFIF/Adobe header.
            let encoded = [UInt8](try JpegEncoder.encode(ImageFrame(image: image)))
            let header = 4 + (Int(encoded[4]) << 8 | Int(encoded[5]))
            let source = try read(Data(encoded.prefix(header) + exifSegment(colorSpace: 0xFFFF) + encoded.dropFirst(header)))
            XCTAssertEqual(source.image.colorSpace?.model, image.colorSpace?.model)
            let folder = GraphicsTestKit.folder()
            defer { try? FileManager.default.removeItem(atPath: folder) }
            for format in targets {
                let path = FilePath.combine(folder, "exif.\(format)")
                try ImageEncoder.save([try ImageEncoder.applyOptions(source, ImageOptions(), targetFormat: format)], to: path, format: format)
                let file = try Data(contentsOf: URL(fileURLWithPath: path))
                let blob = format == "psd" ? resources(file).blocks.first { $0.id == 0x0422 }.map { Array($0.bytes.dropFirst(12)) } : exifBlob([UInt8](file))
                let entries = exifEntries(try XCTUnwrap(blob, format))
                XCTAssertNotNil(entries[0x0110], format)
                XCTAssertEqual(entries[0xA002]?.value, 23, format)
                // ImageIO marks only sRGB pictures; WebP holds the converted sRGB samples of the CMYK source.
                XCTAssertEqual(entries[0xA001]?.value, format == "webp" ? 1 : nil, "\(format) \(String(describing: image.colorSpace?.model))")
            }
        }
    }

    func testExifPixelDimensionsArePatchedInPlace() {
        // Little-endian SHORT dimensions become LONGs in place; a cut-short directory is left as it is.
        let little: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x69, 0x87, 4, 0, 1, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0,
                               2, 0, 0x02, 0xA0, 3, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0x03, 0xA0, 3, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
        let patched = exifEntries([UInt8](CodecPixels.withPixelDimensions(Data(little), 70_000, 5)))
        XCTAssertEqual(patched[0xA002]?.type, 4)
        XCTAssertEqual(patched[0xA002]?.value, 70_000)
        XCTAssertEqual(patched[0xA003]?.value, 5)
        for broken in [Array(little.prefix(30)), Array(little.prefix(7)), [0x4D, 0x49] + little.dropFirst(2)] {
            XCTAssertEqual([UInt8](CodecPixels.withPixelDimensions(Data(broken), 70_000, 5)), broken)
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
