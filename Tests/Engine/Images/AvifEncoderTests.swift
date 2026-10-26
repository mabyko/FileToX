// AVIF writing (AvifEncoder): libavif in the FileToXAvifEncoder helper for 8-bit colour pictures and ImageIO for the rest,
// the helper's checks of its hand-off file, metadata, cancellation and clean-up, also through the job queue.

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class AvifEncoderTests: XCTestCase {
    // ───────────────────────── Route ─────────────────────────

    func testHelperIsBuiltNextToTheEngine() throws {
        let helper = try XCTUnwrap(AvifEncoder.helper, "Build the FileToXAvifEncoder product.")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper))
    }

    func testColourPicturesAreEncodedAt444WithTheRequestedQuality() throws {
        let folder = GraphicsTestKit.folder()
        let source = Self.colour(96, 64)
        var previous: (psnr: Double, bytes: Int)?
        for quality in [25, 50, 75, 90, 100] {
            let path = folder + "/q\(quality).avif"
            try ImageEncoder.save([try Self.prepared(source, quality: quality)], to: path, format: "avif")
            let file = try AvifBoxes(path)
            XCTAssertEqual(file.colour.map(\.chroma), [[0, 0]], "q\(quality): one 4:4:4 colour item")
            XCTAssertEqual(file.colr.map(\.type), ["nclx"], "untagged: sRGB nclx only")
            XCTAssertEqual(file.nclx, [1, 13, 6, 1], "BT.709 primaries, sRGB transfer, BT.601 matrix, full range")
            let decoded = try GraphicsTestKit.decode(path)
            XCTAssertEqual([decoded.width, decoded.height], [96, 64])
            let psnr = GraphicsTestKit.psnr(source, decoded.frames[0]), bytes = try Data(contentsOf: URL(fileURLWithPath: path)).count
            if let previous { XCTAssertGreaterThan(psnr, previous.psnr, "q\(quality)"); XCTAssertGreaterThan(bytes, previous.bytes, "q\(quality)") }
            previous = (psnr, bytes)
        }
        XCTAssertGreaterThan(previous!.psnr, 50, "quality 100 is a lossless AV1 encode of BT.601 4:4:4")
    }

    func testGrayFloatDeepAndUnpreparedPicturesStayWithImageIO() throws {
        let folder = GraphicsTestKit.folder()
        let gray = Self.make(48, 32, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, components: 1) { x, y, _ in UInt8((x * 5 + y * 3) & 255) }
        let grayRGB = Self.make(48, 32) { x, y, _ in UInt8((x * 5 + y * 3) & 255) }
        let grayRGBA = Self.make(48, 32, components: 4, alpha: true) { x, y, c in c == 3 ? UInt8(128 + x) : UInt8((x * 5 + y * 3) & 255) }
        for (name, image) in [("gray", gray), ("gray-rgb", grayRGB), ("gray-rgba", grayRGBA), ("16-bit", Self.deep(48, 32))] {
            let frame = try Self.prepared(image, quality: 60)
            let imageIO = try Self.imageIO(frame)
            try imageIO.write(to: URL(fileURLWithPath: folder + "/\(name)-direct.avif"))
            XCTAssertFalse(try AvifEncoder.improve([frame], at: folder + "/\(name)-direct.avif"), name)
            // The route writes exactly ImageIO's file.
            try ImageEncoder.save([frame], to: folder + "/\(name).avif", format: "avif")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: folder + "/\(name).avif")), imageIO, name)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: folder + "/\(name)-direct.avif")), imageIO, name)
        }
        let colour = try Self.prepared(Self.colour(48, 32), quality: 60)
        var unprepared = colour
        unprepared.properties[ImageFrame.qualityKey] = nil
        try Self.imageIO(colour).write(to: URL(fileURLWithPath: folder + "/colour.avif"))
        XCTAssertFalse(try AvifEncoder.improve([unprepared], at: folder + "/colour.avif"))
        XCTAssertFalse(try AvifEncoder.improve([colour, colour], at: folder + "/colour.avif"))
        XCTAssertFalse(try AvifEncoder.improve([colour], at: folder + "/colour.avif", helper: nil))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: folder + "/colour.avif")), try Self.imageIO(colour))
        XCTAssertTrue(try AvifEncoder.improve([colour], at: folder + "/colour.avif"))
        XCTAssertEqual(try AvifBoxes(folder + "/colour.avif").colour.map(\.chroma), [[0, 0]])
    }

    func testANativeFileThatKeepsLessThanImageIOsIsNotUsed() throws {
        let folder = GraphicsTestKit.folder()
        let frame = try Self.prepared(Self.colour(64, 48), quality: 60), path = folder + "/kept.avif"
        let imageIO = try Self.imageIO(frame)
        try imageIO.write(to: URL(fileURLWithPath: path))
        // Valid AVIF files of a flat picture, the same size and smaller: they keep less of the picture than ImageIO's.
        for (name, width) in [("flat", 64), ("narrow", 32)] {
            let flat = folder + "/\(name).avif"
            try Self.imageIO(try Self.prepared(GraphicsTestKit.solid(width, 48, (90, 120, 150, 255)), quality: 60)).write(to: URL(fileURLWithPath: flat))
            let helper = folder + "/\(name).sh"
            try "#!/bin/sh\ncp '\(flat)' \"$2\"\n".write(toFile: helper, atomically: true, encoding: .utf8)
            chmod(helper, 0o755)
            XCTAssertFalse(try AvifEncoder.improve([frame], at: path, helper: helper), name)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), imageIO, name)
        }
    }

    func testNearGrayPicturesKeepWhicheverFileIsMoreFaithful() throws {
        // Gray-square's samples (compare.py) with a +1 blue tint, so not every pixel is gray. Both encoders run; the kept
        // file is never worse in colour or alpha than the other one.
        let folder = GraphicsTestKit.folder()
        let tinted = Self.make(71, 71) { x, y, c in
            let v = (x * 37 + y * 91 + (x * y) % 17 * 7) & 255
            return UInt8(c == 2 ? min(255, v + 1) : v)
        }
        let capture = folder + "/capture.sh"
        try "#!/bin/sh\n'\(try XCTUnwrap(AvifEncoder.helper))' \"$1\" \"$2\" && cp \"$2\" '\(folder)/native.avif'\n"
            .write(toFile: capture, atomically: true, encoding: .utf8)
        chmod(capture, 0o755)
        for quality in [25, 50, 75, 90] {
            let frame = try Self.prepared(tinted, quality: quality), path = folder + "/q\(quality).avif"
            let imageIO = try Self.imageIO(frame)
            try imageIO.write(to: URL(fileURLWithPath: path))
            let replaced = try AvifEncoder.improve([frame], at: path, helper: capture)
            let source = ImagePixels.bitmap(frame.image)
            let native = try XCTUnwrap(AvifEncoder.errors(try Data(contentsOf: URL(fileURLWithPath: folder + "/native.avif")), source))
            let theirs = try XCTUnwrap(AvifEncoder.errors(imageIO, source))
            XCTAssertEqual(replaced, native.colour <= theirs.colour && native.alpha <= theirs.alpha && (native.colour < theirs.colour || native.alpha < theirs.alpha), "q\(quality)")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), replaced ? try Data(contentsOf: URL(fileURLWithPath: folder + "/native.avif")) : imageIO, "q\(quality)")
        }
    }

    // ───────────────────────── Metadata ─────────────────────────

    func testProfileExifAndXmpAreKeptWithoutOrientationTransform() throws {
        let folder = GraphicsTestKit.folder()
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let jpeg = folder + "/tagged.jpg"
        try Self.writeJpeg(Self.make(40, 24, space: p3) { x, y, c in UInt8([x * 6, y * 10, 255 - x * 6][c] & 255) }, to: jpeg, orientation: 6)
        let source = try XCTUnwrap(ImageReader.read(jpeg, format: "jpg", preset: Preset()).first)
        let profile = try XCTUnwrap(source.properties[ImageFrame.iccKey] as? Data)
        XCTAssertFalse(profile.isEmpty)

        let path = folder + "/tagged.avif"
        try ImageEncoder.save([try ImageEncoder.applyOptions(source, Self.options(quality: 75), targetFormat: "avif")], to: path, format: "avif")
        let file = try AvifBoxes(path)
        XCTAssertEqual(file.colour.map(\.chroma), [[0, 0]])
        XCTAssertEqual(file.colr.map(\.type).sorted(), ["nclx", "prof"])
        XCTAssertEqual(file.colr.first { $0.type == "prof" }?.payload, profile, "the source's exact ICC bytes")
        XCTAssertEqual(file.nclx, [2, 2, 6, 1], "the profile describes the colour; nclx only the matrix and range")
        XCTAssertEqual(file.itemTypes.filter { $0 != "av01" }.sorted(), ["Exif", "mime"])
        XCTAssertFalse(file.properties.contains("irot") || file.properties.contains("imir"))

        let decoded = try GraphicsTestKit.decode(path)
        XCTAssertEqual([decoded.width, decoded.height], [24, 40], "turned upright once")
        let exif = try XCTUnwrap(decoded.properties[0][kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension] as? Int, 24)
        XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension] as? Int, 40)
        XCTAssertEqual(exif[kCGImagePropertyExifUserComment] as? String, "AVIF metadata")
        XCTAssertEqual(decoded.properties[0][kCGImagePropertyOrientation] as? Int ?? 1, 1)
        let source2 = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source2, 0, nil))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString) as String?, "FileToX test")

        // Without metadata (and without the profile) the pixels, an sRGB nclx and, as ImageIO writes it, the resolution remain.
        var strip = Self.options(quality: 75)
        strip.keepMetadata = false
        strip.keepColorProfile = false
        let stripped = folder + "/stripped.avif"
        try ImageEncoder.save([try ImageEncoder.applyOptions(source, strip, targetFormat: "avif")], to: stripped, format: "avif")
        let bare = try AvifBoxes(stripped)
        XCTAssertEqual(bare.colr.map(\.type), ["nclx"])
        XCTAssertEqual(bare.nclx, [1, 13, 6, 1])
        XCTAssertEqual(bare.itemTypes, source.dpi == nil ? ["av01"] : ["av01", "Exif"])
        let strippedProperties = try GraphicsTestKit.decode(stripped).properties[0]
        XCTAssertNil((strippedProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertEqual(strippedProperties[kCGImagePropertyDPIWidth] as? Double, source.dpi?.x)
    }

    func testMetadataImageIOKeepsIsNeverLostToTheNativeFile() throws {
        // Exif that does not fit the shared serializer's JPEG APP1 segment (64 KB): a 100,005-character comment beside GPS.
        // ImageIO's AVIF keeps both, so its file stays; a short comment fits and the native file keeps everything.
        let folder = GraphicsTestKit.folder()
        for (name, length, keep, native) in [("long", 100_000, true, false), ("short", 100, true, true), ("stripped", 100_000, false, true)] {
            let tiff = folder + "/\(name).tiff", comment = "test-" + String(repeating: "z", count: length)
            try Self.writeTiff(Self.colour(65, 39), to: tiff, comment: comment)
            let source = try XCTUnwrap(ImageReader.read(tiff, format: "tiff", preset: Preset()).first)
            var options = Self.options(quality: 75)
            options.keepMetadata = keep
            let path = folder + "/\(name).avif"
            try ImageEncoder.save([try ImageEncoder.applyOptions(source, options, targetFormat: "avif")], to: path, format: "avif")
            XCTAssertEqual(try AvifBoxes(path).colour.map(\.chroma), [native ? [0, 0] : [1, 1]], "\(name): \(native ? "native" : "ImageIO's") file")
            let properties = try GraphicsTestKit.decode(path).properties[0]
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any], gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            XCTAssertEqual(exif?[kCGImagePropertyExifUserComment] as? String, keep ? comment : nil, name)
            XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude] as? Double, keep ? 37.5 : nil, name)
            XCTAssertEqual(gps?[kCGImagePropertyGPSLatitudeRef] as? String, keep ? "N" : nil, name)
        }
    }

    func testStructuredMetadataKeepsItsInnerValues() throws {
        // Arrays and structures that both files keep leave the helper's file in place; their items, read back from it.
        let folder = GraphicsTestKit.folder(), tiff = folder + "/structured.tiff", path = folder + "/structured.avif"
        let iptc = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/", dc = "http://purl.org/dc/elements/1.1/"
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, iptc as CFString, "Iptc4xmpCore" as CFString, nil)
        CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString,
                                      CGImageMetadataTagCreate(dc as CFString, "dc" as CFString, "subject" as CFString, .arrayUnordered, ["alpha", "beta"] as CFArray)!)
        CGImageMetadataSetTagWithPath(metadata, nil, "Iptc4xmpCore:CreatorContactInfo" as CFString,
                                      CGImageMetadataTagCreate(iptc as CFString, "Iptc4xmpCore" as CFString, "CreatorContactInfo" as CFString, .structure,
                                                               ["CiAdrCity": "Seoul", "CiEmailWork": "avif@example.com"] as CFDictionary)!)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, "structured" as CFString)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: tiff) as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, Self.colour(65, 39), metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(ImageReader.read(tiff, format: "tiff", preset: Preset()).first)
        try ImageEncoder.save([try ImageEncoder.applyOptions(source, Self.options(quality: 75), targetFormat: "avif")], to: path, format: "avif")
        XCTAssertEqual(try AvifBoxes(path).colour.map(\.chroma), [[0, 0]], "the native file")
        let read = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)), 0, nil))
        let subject = Set(["dc:subject[0]", "dc:subject[1]"].compactMap { CGImageMetadataCopyStringValueWithPath(read, nil, $0 as CFString) as String? })
        XCTAssertEqual(subject, ["alpha", "beta"])
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(read, nil, "Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiAdrCity" as CFString) as String?, "Seoul")
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(read, nil, "Iptc4xmpCore:CreatorContactInfo.Iptc4xmpCore:CiEmailWork" as CFString) as String?, "avif@example.com")
        XCTAssertEqual((try GraphicsTestKit.decode(path).properties[0][kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String, "structured")
    }

    func testExifAuxiliaryTagsKeepTheNativeFile() throws {
        // Lens and serial number in the Exif auxiliary namespace, as Adobe's applications write them. Exif cannot hold them;
        // ImageIO's own AVIF keeps them as XMP, and so does the helper's, which is then used.
        let folder = GraphicsTestKit.folder(), tiff = folder + "/aux.tiff", path = folder + "/aux.avif"
        let values = [("Lens", "Probe 24-70mm"), ("SerialNumber", "AUX-123"), ("LensID", "77")]
        let metadata = CGImageMetadataCreateMutable()
        for (name, value) in values { XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "aux:\(name)" as CFString, value as CFString)) }
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, "auxiliary" as CFString)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: tiff) as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, Self.colour(65, 39), metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(ImageReader.read(tiff, format: "tiff", preset: Preset()).first)
        let frame = try ImageEncoder.applyOptions(source, Self.options(quality: 75), targetFormat: "avif")
        try ImageEncoder.save([frame], to: path, format: "avif")
        XCTAssertEqual(try AvifBoxes(path).colour.map(\.chroma), [[0, 0]], "the native file")
        let read = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)), 0, nil))
        for (name, value) in values { XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(read, nil, "aux:\(name)" as CFString) as String?, value, name) }
        XCTAssertEqual((try GraphicsTestKit.decode(path).properties[0][kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String, "auxiliary")
        // The other writers' shared serializer is unchanged: its XMP still leaves the auxiliary tags out.
        let shared = String(decoding: try XCTUnwrap(CodecPixels.metadataBlobs(frame, colorModel: .rgb).xmp), as: UTF8.self)
        XCTAssertFalse(shared.contains("aux:Lens"))
    }

    func testANativeFileThatChangesInnerMetadataValuesIsNotUsed() throws {
        // Helper files that keep every top-level tag but change an item, a field, a language or an order inside one keep
        // ImageIO's file; the helper's file without a change replaces it. The order is that of an XMP-only sequence: ImageIO
        // reads dc:creator back from the Exif Artist as well, so a change to its XMP alone does not show.
        let folder = GraphicsTestKit.folder(), tiff = folder + "/inner.tiff"
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
             xmlns:ftx="http://example.com/filetox/1.0/">
            <dc:subject><rdf:Bag><rdf:li>alpha</rdf:li><rdf:li>beta</rdf:li></rdf:Bag></dc:subject>
            <ftx:Steps><rdf:Seq><rdf:li>first step</rdf:li><rdf:li>second step</rdf:li></rdf:Seq></ftx:Steps>
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Title</rdf:li><rdf:li xml:lang="ko-KR">제목</rdf:li></rdf:Alt></dc:title>
            <Iptc4xmpCore:CreatorContactInfo rdf:parseType="Resource"><Iptc4xmpCore:CiAdrCity>Seoul</Iptc4xmpCore:CiAdrCity></Iptc4xmpCore:CreatorContactInfo>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: tiff) as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, Self.colour(65, 39), try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData)), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let frame = try ImageEncoder.applyOptions(try XCTUnwrap(ImageReader.read(tiff, format: "tiff", preset: Preset()).first), Self.options(quality: 75),
                                                  targetFormat: "avif")
        let metadata = try XCTUnwrap(frame.properties[ImageFrame.metadataKey].map { $0 as! CGImageMetadata })
        // ImageIO's file of the frame and its metadata, as the writer makes it first.
        let data = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.avif" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(writer, frame.image, ImageEncoder.encoderMetadata(metadata, frame.dpi),
                                              [kCGImageDestinationLossyCompressionQuality: frame.properties[kCGImageDestinationLossyCompressionQuality]!] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let imageIO = data as Data
        // The helper's own file of the frame, from a hand-off whose XMP has one change.
        let (samples, channels) = CodecPixels.straight(frame.image)
        let blobs = CodecPixels.metadataBlobs(frame, colorModel: .rgb)
        let icc = blobs.icc ?? Data(), exif = blobs.exif ?? Data(), packet = String(decoding: try XCTUnwrap(blobs.xmp), as: UTF8.self)
        let mutations: [(String, [(String, String)])] = [
            ("unchanged", []), ("item", [(">beta<", ">BETA<")]), ("field", [(">Seoul<", ">Busan<")]), ("language", [("\"ko-KR\"", "\"ja-JP\"")]),
            ("order", [("first step", "\u{1}"), ("second step", "first step"), ("\u{1}", "second step")]),
        ]
        for (name, changes) in mutations {
            let changed = changes.reduce(packet) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            XCTAssertEqual(changed == packet, changes.isEmpty, name)
            let input = folder + "/\(name).in", made = folder + "/\(name)-helper.avif", path = folder + "/\(name).avif", helper = folder + "/\(name).sh"
            let xmpData = Data(changed.utf8)
            try Self.handOff(UInt32(frame.image.width), UInt32(frame.image.height), UInt32(channels), 75, Data(samples) + icc + exif + xmpData,
                             sizes: [UInt64(icc.count), UInt64(exif.count), UInt64(xmpData.count)]).write(to: URL(fileURLWithPath: input))
            XCTAssertEqual(try ProcessRunner.runBlocking(try XCTUnwrap(AvifEncoder.helper), [input, made], timeout: 60).exitCode, 0, name)
            try "#!/bin/sh\ncp '\(made)' \"$2\"\n".write(toFile: helper, atomically: true, encoding: .utf8)
            chmod(helper, 0o755)
            try imageIO.write(to: URL(fileURLWithPath: path))
            let replaced = try AvifEncoder.improve([frame], at: path, helper: helper)
            XCTAssertEqual(replaced, changes.isEmpty, name)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), changes.isEmpty ? try Data(contentsOf: URL(fileURLWithPath: made)) : imageIO, name)
        }
    }

    func testResolutionIsKeptAsImageIODoes() throws {
        let folder = GraphicsTestKit.folder()
        let png = try ImageEncoder.applyOptions(ImageFrame(image: Self.colour(48, 32), dpi: (300, 300)), Self.options(quality: 60), targetFormat: "avif")
        try ImageEncoder.save([png], to: folder + "/dpi.avif", format: "avif")
        XCTAssertEqual(try AvifBoxes(folder + "/dpi.avif").colour.map(\.chroma), [[0, 0]])
        XCTAssertEqual(try AvifBoxes(folder + "/dpi.avif").itemTypes, ["av01", "Exif"])
        let properties = try GraphicsTestKit.decode(folder + "/dpi.avif").properties[0]
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double, 300)
        XCTAssertEqual(properties[kCGImagePropertyDPIHeight] as? Double, 300)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: folder + "/dpi.avif")).count < 4096, true)
        // The preset's DPI replaces the source's, in Exif that also carries the source's tags.
        try Self.writeJpeg(Self.colour(48, 32), to: folder + "/exif.jpg", orientation: 1)
        var options = Self.options(quality: 60)
        options.dpi = 144
        let source = try XCTUnwrap(ImageReader.read(folder + "/exif.jpg", format: "jpg", preset: Preset()).first)
        try ImageEncoder.save([try ImageEncoder.applyOptions(source, options, targetFormat: "avif")], to: folder + "/preset.avif", format: "avif")
        let preset = try GraphicsTestKit.decode(folder + "/preset.avif").properties[0]
        XCTAssertEqual(preset[kCGImagePropertyDPIWidth] as? Double, 144)
        XCTAssertEqual((preset[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String, "AVIF metadata")
        // No resolution: no Exif at all.
        try ImageEncoder.save([try Self.prepared(Self.colour(48, 32), quality: 60)], to: folder + "/none.avif", format: "avif")
        XCTAssertEqual(try AvifBoxes(folder + "/none.avif").itemTypes, ["av01"])
    }

    func testExifOrientationNeverBecomesATransformProperty() throws {
        // A frame whose Exif still says "rotate" (the helper must not add irot/imir: the engine owns orientation).
        let folder = GraphicsTestKit.folder()
        let jpeg = folder + "/turned.jpg"
        try Self.writeJpeg(Self.colour(40, 24), to: jpeg, orientation: 6)
        var frame = try XCTUnwrap(ImageReader.read(jpeg, format: "jpg", preset: Preset()).first)
        frame.properties[ImageFrame.qualityKey] = 75
        let path = folder + "/turned.avif"
        try ImageEncoder.save([frame], to: path, format: "avif")
        let file = try AvifBoxes(path)
        XCTAssertEqual(file.colour.map(\.chroma), [[0, 0]])
        XCTAssertEqual(file.itemTypes.filter { $0 == "Exif" }.count, 1)
        XCTAssertFalse(file.properties.contains("irot") || file.properties.contains("imir"))
        XCTAssertEqual(try [GraphicsTestKit.decode(path).width, GraphicsTestKit.decode(path).height], [40, 24])
    }

    // ───────────────────────── Alpha ─────────────────────────

    func testAlphaIsKeptAndTransparentPixelsStayTransparent() throws {
        let folder = GraphicsTestKit.folder()
        let source = Self.make(64, 48, components: 4, alpha: true) { x, y, c in
            c == 3 ? UInt8(x < 8 ? 0 : x >= 56 ? 255 : (x * 4 + y) & 255) : UInt8([x * 4, y * 5, (x + y) * 3][c] & 255)
        }
        for quality in [25, 50, 75, 90, 100] {
            let path = folder + "/alpha\(quality).avif", frame = try Self.prepared(source, quality: quality)
            try ImageEncoder.save([frame], to: path, format: "avif")
            let file = try AvifBoxes(path)
            XCTAssertEqual(file.alpha.count, 1, "q\(quality): one monochrome alpha item")
            let kept = try XCTUnwrap(AvifEncoder.errors(try Data(contentsOf: URL(fileURLWithPath: path)), ImagePixels.bitmap(frame.image)))
            let imageIO = try XCTUnwrap(AvifEncoder.errors(try Self.imageIO(frame), ImagePixels.bitmap(frame.image)))
            XCTAssertTrue(kept.colour <= imageIO.colour && kept.alpha <= imageIO.alpha, "q\(quality)")
            let decoded = try GraphicsTestKit.decode(path).frames[0]
            for y in [0, 20, 47] {
                XCTAssertEqual(GraphicsTestKit.pixel(decoded, 2, y).a, 0, "q\(quality): transparent stays transparent")
                XCTAssertEqual(GraphicsTestKit.pixel(decoded, 60, y).a, 255, "q\(quality): opaque stays opaque")
            }
        }
    }

    // ───────────────────────── Helper input checks ─────────────────────────

    func testHelperRejectsMalformedHandOffFilesWithoutWritingOutput() throws {
        let helper = try XCTUnwrap(AvifEncoder.helper)
        let folder = GraphicsTestKit.folder()
        func run(_ name: String, _ data: Data) throws -> Int32 {
            let input = folder + "/\(name).in", output = folder + "/\(name).avif"
            try data.write(to: URL(fileURLWithPath: input))
            let status = try ProcessRunner.runBlocking(helper, [input, output], timeout: 60).exitCode
            if status != 0 { XCTAssertFalse(FileManager.default.fileExists(atPath: output), name) }
            return status
        }
        let pixels = Data((0..<8 * 4 * 3).map { UInt8($0 & 255) })
        XCTAssertEqual(try run("valid", Self.handOff(8, 4, 3, 50, pixels)), 0)
        XCTAssertEqual(try run("magic", Self.handOff(8, 4, 3, 50, pixels, magic: "FTXAVIF2")), 2)
        XCTAssertEqual(try run("version", Self.handOff(8, 4, 3, 50, pixels, version: 2)), 2)
        XCTAssertEqual(try run("flags", Self.handOff(8, 4, 3, 50, pixels, flags: 1)), 2)
        XCTAssertEqual(try run("channels", Self.handOff(8, 4, 2, 50, pixels)), 2)
        XCTAssertEqual(try run("quality0", Self.handOff(8, 4, 3, 0, pixels)), 2)
        XCTAssertEqual(try run("quality101", Self.handOff(8, 4, 3, 101, pixels)), 2)
        XCTAssertEqual(try run("width0", Self.handOff(0, 4, 3, 50, Data())), 2)
        XCTAssertEqual(try run("wide", Self.handOff(32769, 1, 3, 50, Data(count: 32769 * 3))), 2)
        // 16385 × 16385 passes the dimension limit, not the pixel limit; the size check never allocates for it.
        XCTAssertEqual(try run("pixels", Self.handOff(16385, 16385, 3, 50, Data())), 2)
        XCTAssertEqual(try run("short", Self.handOff(8, 4, 3, 50, pixels.dropLast())), 2)
        XCTAssertEqual(try run("long", Self.handOff(8, 4, 3, 50, pixels + [0])), 2)
        XCTAssertEqual(try run("metadata", Self.handOff(8, 4, 3, 50, pixels, sizes: [UInt64(64 << 20) + 1, 0, 0])), 2)
        // A metadata length that overflows the payload size when summed.
        XCTAssertEqual(try run("overflow", Self.handOff(8, 4, 3, 50, pixels, sizes: [UInt64.max, 0, 0])), 2)
        XCTAssertEqual(try run("header", Data("FTXAVIF\0".utf8)), 2)
        // An existing output is never replaced.
        try Data("keep".utf8).write(to: URL(fileURLWithPath: folder + "/existing.avif"))
        try Self.handOff(8, 4, 3, 50, pixels).write(to: URL(fileURLWithPath: folder + "/existing.in"))
        XCTAssertEqual(try ProcessRunner.runBlocking(helper, [folder + "/existing.in", folder + "/existing.avif"], timeout: 60).exitCode, 5)
        XCTAssertEqual(try String(contentsOfFile: folder + "/existing.avif", encoding: .utf8), "keep")
    }

    // ───────────────────────── Cancellation and failures ─────────────────────────

    func testCancelledBeforeEncodingStartsNoHelper() async throws {
        let folder = GraphicsTestKit.folder(), scratch = Self.scratchFolders()
        let frame = try Self.prepared(Self.colour(64, 48), quality: 60), path = folder + "/cancelled.avif"
        let imageIO = try Self.imageIO(frame)
        try imageIO.write(to: URL(fileURLWithPath: path))
        let task = Task { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return try AvifEncoder.improve([frame], at: path)
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), imageIO)
        XCTAssertEqual(Self.scratchFolders(), scratch)
        XCTAssertEqual(Self.helperProcesses(), [])
    }

    func testCancellationDuringTheEncodeKillsTheHelperAndLeavesNoFiles() async throws {
        let folder = GraphicsTestKit.folder(), scratch = Self.scratchFolders()
        let frame = try Self.prepared(Self.noise(3000, 2000), quality: 60), path = folder + "/big.avif"
        try Data("ImageIO's file".utf8).write(to: URL(fileURLWithPath: path))
        let task = Task { try AvifEncoder.improve([frame], at: path) }
        let helpers = try await Self.waitForHelper()
        let cancelled = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1)
        for pid in helpers { XCTAssertTrue(Self.isGone(pid), "helper \(pid) killed and reaped") }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "ImageIO's file")
        XCTAssertEqual(Self.scratchFolders(), scratch)
    }

    func testHelperFailuresAndLateWritesPublishNothing() async throws {
        let folder = GraphicsTestKit.folder(), scratch = Self.scratchFolders()
        let frame = try Self.prepared(Self.colour(64, 48), quality: 60)
        let imageIO = try Self.imageIO(frame)
        for name in ["failing", "garbage", "late"] { try imageIO.write(to: URL(fileURLWithPath: folder + "/\(name).avif")) }
        func helper(_ name: String, _ body: String) throws -> String {
            let path = folder + "/\(name).sh"
            try ("#!/bin/sh\necho \"$1\" >> '\(folder)/inputs'\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            return path
        }
        let failing = try helper("failing", "echo 'deliberate failure' >&2\nexit 7\n")
        XCTAssertThrowsError(try AvifEncoder.improve([frame], at: folder + "/failing.avif", helper: failing)) { error in
            XCTAssertTrue("\(error)".contains("deliberate failure"), "\(error)")
        }
        let garbage = try helper("garbage", "printf 'not an AVIF file' > \"$2\"\nexit 0\n")
        XCTAssertThrowsError(try AvifEncoder.improve([frame], at: folder + "/garbage.avif", helper: garbage))
        let late = try helper("late", "printf 'partial' > \"$2\"\nexec /bin/sleep 30\n")
        let task = Task { try AvifEncoder.improve([frame], at: folder + "/late.avif", helper: late) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}

        for name in ["failing", "garbage", "late"] { XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: folder + "/\(name).avif")), imageIO, name) }
        let inputs = try String(contentsOfFile: folder + "/inputs", encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(inputs.count, 3)
        for input in inputs { XCTAssertFalse(FileManager.default.fileExists(atPath: FilePath.directoryName(input)!), "hand-off folder removed") }
        XCTAssertEqual(Self.scratchFolders(), scratch)
    }

    // ───────────────────────── Job queue ─────────────────────────

    func testQueueConversionPublishesTheHelpersFile() async throws {
        let d = CoreTempDir()
        let png = d.path + "/photo.png"
        try ImageEncoder.save([ImageFrame(image: Self.colour(80, 60))], to: png, format: "png")
        let job = await coreRun(JobQueue(ConverterCatalog([MagickImageConverter()])), [png], corePreset("avif") { $0.image.quality = 60 })
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.outputs, [d.path + "/photo.avif"])
        XCTAssertEqual(try AvifBoxes(d.path + "/photo.avif").colour.map(\.chroma), [[0, 0]])
        XCTAssertTrue(d.leftovers().isEmpty)
    }

    func testCancellingAQueuedConversionStopsTheHelperAndPublishesNothing() async throws {
        let d = CoreTempDir(), scratch = Self.scratchFolders()
        let png = d.path + "/big.png"
        try ImageEncoder.save([ImageFrame(image: Self.noise(3000, 2000))], to: png, format: "png")
        let queue = JobQueue(ConverterCatalog([MagickImageConverter()]))
        let job = ConversionJob([png], corePreset("avif") { $0.image.quality = 60 }, "AVIF")
        let run = Task { await queue.run(job) }
        let helpers = try await Self.waitForHelper()
        let cancelled = Date()
        job.cancel()
        await run.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1)
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertEqual(job.files[0].state, .cancelled)
        XCTAssertEqual(job.outputs, [])
        for pid in helpers { XCTAssertTrue(Self.isGone(pid), "helper \(pid) killed and reaped") }
        XCTAssertEqual(try d.names(), ["big.png"])
        XCTAssertTrue(d.leftovers().isEmpty)
        XCTAssertEqual(Self.scratchFolders(), scratch)
    }

    // ───────────────────────── Helpers ─────────────────────────

    static func options(quality: Int) -> ImageOptions {
        var options = ImageOptions()
        options.quality = quality
        return options
    }

    /// The frame as the image engine hands it to the writer for an AVIF target.
    static func prepared(_ image: CGImage, quality: Int) throws -> ImageFrame {
        try ImageEncoder.applyOptions(ImageFrame(image: image), options(quality: quality), targetFormat: "avif")
    }

    /// ImageIO's AVIF of the frame (a frame without metadata), as ImageEncoder writes it first.
    static func imageIO(_ frame: ImageFrame) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.avif" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, frame.image, [kCGImageDestinationLossyCompressionQuality: frame.properties[kCGImageDestinationLossyCompressionQuality]!] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func make(_ width: Int, _ height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, components: Int = 3, alpha: Bool = false,
                     _ value: (Int, Int, Int) -> UInt8) -> CGImage {
        var samples = [UInt8](repeating: 0, count: width * height * components)
        for y in 0..<height { for x in 0..<width { for c in 0..<components { samples[(y * width + x) * components + c] = value(x, y, c) } } }
        return ImagePixels.make(samples, width, height, components: components, space: space, alpha: alpha, premultiplied: false)
    }

    static func colour(_ width: Int, _ height: Int) -> CGImage {
        make(width, height) { x, y, c in UInt8([x * 255 / max(1, width - 1), y * 255 / max(1, height - 1), (x * 7 + y * 13) % 256][c]) }
    }

    /// Pseudo-random colour samples, slow to encode.
    static func noise(_ width: Int, _ height: Int) -> CGImage {
        var state: UInt32 = 12345
        var samples = [UInt8](repeating: 0, count: width * height * 3)
        for i in samples.indices { state = state &* 1103515245 &+ 12345; samples[i] = UInt8(state >> 24) }
        return ImagePixels.make(samples, width, height, components: 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
    }

    /// A 16-bit RGB picture.
    static func deep(_ width: Int, _ height: Int) -> CGImage {
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for i in samples.indices { samples[i] = UInt16(truncatingIfNeeded: i &* 2654435761 >> 7) }
        let provider = CGDataProvider(data: samples.withUnsafeBytes { Data($0) } as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A JPEG with the picture's ICC profile, an EXIF orientation and comment, and an XMP creator tool.
    static func writeJpeg(_ image: CGImage, to path: String, orientation: Int) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString, "FileToX test" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, "AVIF metadata" as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A TIFF with an EXIF comment, a GPS latitude and an XMP creator tool.
    static func writeTiff(_ image: CGImage, to path: String, comment: String) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.tiff" as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, comment as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, 37.5 as CFNumber)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, "N" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString, "FileToX test" as CFString)
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A FileToXAvifEncoder hand-off file (see Vendor/LibAVIF/FileToX/avifenc.c).
    static func handOff(_ width: UInt32, _ height: UInt32, _ channels: UInt32, _ quality: UInt32, _ pixels: Data, magic: String = "FTXAVIF\0",
                        version: UInt32 = 1, flags: UInt32 = 0, sizes: [UInt64] = [0, 0, 0]) -> Data {
        var data = Data(magic.utf8)
        for value in [version, width, height, channels, quality, flags] { withUnsafeBytes(of: value.littleEndian) { data += $0 } }
        for value in sizes + [0] { withUnsafeBytes(of: value.littleEndian) { data += $0 } }
        return data + pixels
    }

    /// The hand-off folders in the temporary folder.
    static func scratchFolders() -> Set<String> {
        let temp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return Set(((try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []).filter { $0.hasPrefix("FileToX-avif-") })
    }

    /// Running FileToXAvifEncoder children of this process.
    static func helperProcesses() -> [pid_t] {
        ProcessRunner.childProcesses(of: getpid()).filter { pid in
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasSuffix("/FileToXAvifEncoder")
        }
    }

    static func waitForHelper() async throws -> [pid_t] {
        for _ in 0..<500 {
            let helpers = helperProcesses()
            if !helpers.isEmpty { return helpers }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw XCTSkip("The helper never started.")
    }

    /// The process no longer exists (killed and reaped).
    static func isGone(_ pid: pid_t) -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(10_000)
        }
        return false
    }
}

/// The boxes of an AVIF file the tests look at: av1C (monochrome flag and chroma subsampling per item), colr, the other
/// item properties and the item types.
struct AvifBoxes {
    var av1C: [(monochrome: Bool, chroma: [Int])] = []
    var colr: [(type: String, payload: Data)] = []
    var properties: [String] = []
    var itemTypes: [String] = []
    var colour: [(monochrome: Bool, chroma: [Int])] { av1C.filter { !$0.monochrome } }
    var alpha: [(monochrome: Bool, chroma: [Int])] { av1C.filter(\.monochrome) }
    /// Colour primaries, transfer, matrix and full-range flag of the nclx colr box.
    var nclx: [Int]? {
        colr.first { $0.type == "nclx" }.map { p in
            let b = [UInt8](p.payload)
            return [Int(b[0]) << 8 | Int(b[1]), Int(b[2]) << 8 | Int(b[3]), Int(b[4]) << 8 | Int(b[5]), Int(b[6] >> 7)]
        }
    }

    init(_ path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        func boxes(_ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
            var result: [(String, Range<Int>)] = [], at = range.lowerBound
            while at + 8 <= range.upperBound {
                var size = data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }, header = 8
                if size == 1 { size = data[at + 8..<at + 16].reduce(0) { $0 << 8 | Int($1) }; header = 16 }
                if size == 0 { size = range.upperBound - at }
                guard size >= header, at + size <= range.upperBound else { break }
                result.append((String(decoding: data[at + 4..<at + 8], as: UTF8.self), at + header..<at + size))
                at += size
            }
            return result
        }
        let meta = try XCTUnwrap(boxes(0..<data.count).first { $0.type == "meta" }, path)
        let children = boxes(meta.body.lowerBound + 4..<meta.body.upperBound)
        if let iprp = children.first(where: { $0.type == "iprp" }), let ipco = boxes(iprp.body).first(where: { $0.type == "ipco" }) {
            for property in boxes(ipco.body) {
                properties.append(property.type)
                if property.type == "av1C" {
                    let flags = data[property.body.lowerBound + 2]
                    av1C.append((flags & 0x10 != 0, [Int(flags >> 3 & 1), Int(flags >> 2 & 1)]))
                }
                if property.type == "colr" {
                    colr.append((String(decoding: data[property.body.prefix(4)], as: UTF8.self), Data(data[property.body.dropFirst(4)])))
                }
            }
        }
        if let iinf = children.first(where: { $0.type == "iinf" }) {
            let start = iinf.body.lowerBound + 4 + (data[iinf.body.lowerBound] == 0 ? 2 : 4)
            for entry in boxes(start..<iinf.body.upperBound) where entry.type == "infe" {
                let type = entry.body.lowerBound + 4 + (data[entry.body.lowerBound] >= 3 ? 4 : 2) + 2
                itemTypes.append(String(decoding: data[type..<type + 4], as: UTF8.self))
            }
        }
    }
}
