// Ports of Filee.Engines.Tests ImageAndPdfTests (image part) and MultiPageTiffTests: the image engine ("magick") end to
// end through its converter and TIFF merger.

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class ImageEngineTests: XCTestCase {
    private let engine = MagickImageConverter()
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }
    override func tearDown() { FileManager.default.removeIfPresent(dir) }

    private func preset(_ change: (inout Preset) -> Void) -> Preset {
        var preset = Preset()
        change(&preset)
        return preset
    }

    func testPngConvertsToEveryCommonFormat() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "a.png")
        let expected = ["jpg": "public.jpeg", "webp": "org.webmproject.webp", "tiff": "public.tiff", "bmp": "com.microsoft.bmp",
                        "gif": "com.compuserve.gif", "avif": "public.avif"]
        for (target, type) in expected.sorted(by: { $0.key < $1.key }) {
            guard ImageEncoder.writable.contains(target) else { continue } // AVIF: when this Mac's ImageIO encodes it
            let output = try await GraphicsTestKit.convert(engine, source, to: target)
            let result = try GraphicsTestKit.decode(XCTUnwrap(output.first))
            XCTAssertEqual(result.type, type, target)
            XCTAssertEqual(result.width, 320, target)
        }
    }

    /// A 3-frame animated GIF (red, green, blue; 0.2, 0.3 and 0.4 s, looping).
    private func makeAnimatedGif() throws -> String {
        let colors: [(UInt8, UInt8, UInt8, UInt8)] = [(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)]
        let delays = [0.2, 0.3, 0.4]
        let frames = zip(colors, delays).map { color, delay in
            ImageFrame(image: GraphicsTestKit.solid(64, 48, color), delay: delay, properties: [ImageFrame.loopCountKey: 0])
        }
        let path = FilePath.combine(dir, "anim.gif")
        try ImageEncoder.save(frames, to: path, format: "gif")
        return path
    }

    private func delays(_ decoded: GraphicsTestKit.Decoded) -> [Double] {
        decoded.properties.map { properties in
            let animation = (properties[kCGImagePropertyGIFDictionary] ?? properties[kCGImagePropertyWebPDictionary]) as? [CFString: Any]
            let value = animation?[kCGImagePropertyGIFUnclampedDelayTime] ?? animation?[kCGImagePropertyWebPUnclampedDelayTime]
            return (((value as? NSNumber)?.doubleValue ?? -1) * 100).rounded() / 100
        }
    }

    func testAnimatedGifBecomesAnAnimatedWebpAndBack() async throws {
        for lossless in [false, true] {
            let gif = try makeAnimatedGif()
            let webp = try await GraphicsTestKit.convert(engine, gif, to: "webp", preset: preset { $0.image.webpLossless = lossless },
                                                         name: "anim-\(lossless)")
            let frames = try GraphicsTestKit.decode(XCTUnwrap(webp.first))
            XCTAssertEqual(frames.type, "org.webmproject.webp")
            XCTAssertEqual(frames.frames.count, 3)
            XCTAssertEqual(delays(frames), [0.2, 0.3, 0.4])
            XCTAssertGreaterThan(GraphicsTestKit.pixel(frames.frames[1], 32, 24).g, 200, "second frame should be green")

            let back = try await GraphicsTestKit.convert(engine, webp[0], to: "gif", name: "anim-\(lossless)_back")
            let again = try GraphicsTestKit.decode(XCTUnwrap(back.first))
            XCTAssertEqual(again.frames.count, 3)
            XCTAssertEqual(delays(again), [0.2, 0.3, 0.4])
        }
    }

    func testAnimatedGifToAStillFormatTakesTheFirstFrame() async throws {
        let output = try await GraphicsTestKit.convert(engine, makeAnimatedGif(), to: "png")
        XCTAssertEqual(output.count, 1)
        XCTAssertGreaterThan(GraphicsTestKit.pixel(try GraphicsTestKit.decode(output[0]).frames[0], 32, 24).r, 200, "first frame is red")
    }

    func testMultiPageTiffToWebpWritesOneImagePerPage() async throws {
        let tiff = try GraphicsTestKit.makeMultiPageTiff(dir, 2)
        let output = try await GraphicsTestKit.convert(engine, tiff, to: "webp")
        XCTAssertEqual(output.map(FilePath.fileName), ["pages_p1.webp", "pages_p2.webp"])
    }

    /// A JPEG with EXIF (camera model) and a wide-gamut profile (Adobe RGB, like Display P3 from a phone).
    private func makePhoto() throws -> String {
        let space = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        let image = GraphicsTestKit.solid(64, 48, (135, 206, 235, 255)).copy(colorSpace: space)!
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, "TestPhone" as CFString)
        let path = FilePath.combine(dir, "photo.jpg")
        try ImageEncoder.save([ImageFrame(image: image, properties: [ImageFrame.metadataKey: metadata])], to: path, format: "jpg")
        return path
    }

    func testRemovingMetadataCanKeepTheColourProfile() async throws {
        let source = try makePhoto()
        for (keepMetadata, keepProfile, exifExpected) in [(true, true, true), (false, true, false), (false, false, false)] {
            for target in ["webp", "jpg", "png", "jxl"] {
                let output = try await GraphicsTestKit.convert(engine, source, to: target, preset: preset {
                    $0.image.keepMetadata = keepMetadata
                    $0.image.keepColorProfile = keepProfile
                }, name: "photo-\(keepMetadata)-\(keepProfile)")
                let result = try GraphicsTestKit.decode(output[0])
                let model = (result.properties[0][kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String
                XCTAssertEqual(model == "TestPhone", exifExpected, "\(target) EXIF \(keepMetadata) \(keepProfile)")
                // Lossy JPEG XL stores Adobe RGB as its primaries and gamma: any profile other than sRGB counts.
                let profile = result.properties[0][kCGImagePropertyProfileName] as? String
                XCTAssertEqual(profile != nil && profile != "sRGB IEC61966-2.1", keepMetadata || keepProfile,
                               "\(target) ICC \(keepMetadata) \(keepProfile): \(profile ?? "nil")")
            }
        }
    }

    func testJpgOutputFlattensTransparencyAndAppliesQuality() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "a.png")
        let output = try await GraphicsTestKit.convert(engine, source, to: "jpg", preset: preset {
            $0.image.quality = 40
            $0.image.background = "#FF0000"
        })
        let result = try GraphicsTestKit.decode(output[0])
        XCTAssertFalse(ImagePixels.hasAlpha(result.frames[0]))
        let quality = try JpegQuality.estimate(output[0])
        XCTAssertTrue((35...45).contains(quality), "estimated quality \(quality)")
        let corner = GraphicsTestKit.pixel(result.frames[0], 5, 5)
        XCTAssertTrue(corner.r > 200 && corner.g < 60, "transparent corner should become the background colour: \(corner)")
    }

    func testResizeByLongEdgeAndPercent() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "a.png", width: 1000, height: 500)
        let longEdge = try await GraphicsTestKit.convert(engine, source, to: "png", preset: preset {
            $0.image.resize = .longEdge
            $0.image.longEdge = 400
        }, name: "a_le")
        let percent = try await GraphicsTestKit.convert(engine, source, to: "png", preset: preset {
            $0.image.resize = .percent
            $0.image.resizePercent = 50
        }, name: "a_50")
        let small = try GraphicsTestKit.decode(longEdge[0]), half = try GraphicsTestKit.decode(percent[0])
        XCTAssertEqual([small.width, small.height], [400, 200])
        XCTAssertEqual([half.width, half.height], [500, 250])
        // Never upscaled.
        let same = try await GraphicsTestKit.convert(engine, source, to: "png", preset: preset {
            $0.image.resize = .longEdge
            $0.image.longEdge = 4000
        }, name: "a_big")
        XCTAssertEqual(try GraphicsTestKit.decode(same[0]).width, 1000)
    }

    func testIcoContainsSeveralSizes() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "logo.png", width: 300, height: 200)
        let output = try await GraphicsTestKit.convert(engine, source, to: "ico", preset: preset { $0.image.icoSizes = [64, 32, 16] })
        let icons = try GraphicsTestKit.decode(output[0])
        XCTAssertEqual(icons.frames.map(\.width), [64, 32, 16])
        XCTAssertEqual(icons.frames.map(\.height), [64, 32, 16])
        XCTAssertEqual(GraphicsTestKit.pixel(icons.frames[0], 32, 4).a, 0, "padding above the landscape picture")
    }

    func testMultiPageTiffToPngWritesOneFilePerPage() async throws {
        let output = try await GraphicsTestKit.convert(engine, GraphicsTestKit.makeMultiPageTiff(dir, 3), to: "png")
        XCTAssertEqual(output.map(FilePath.fileName).sorted(), ["pages_p1.png", "pages_p2.png", "pages_p3.png"])
    }

    func testImagesAndAMultiPageTiffBecomeOneTiffWithEveryPage() async throws {
        let red = FilePath.combine(dir, "a.png")
        try ImageEncoder.save([ImageFrame(image: GraphicsTestKit.solid(40, 30, (255, 0, 0, 128)))], to: red, format: "png")
        let two = FilePath.combine(dir, "b.tif")
        try ImageEncoder.save([ImageFrame(image: GraphicsTestKit.solid(20, 20, (0, 128, 0, 255))),
                               ImageFrame(image: GraphicsTestKit.solid(20, 20, (0, 0, 255, 255)))], to: two, format: "tiff")
        var options = ImageOptions()
        options.multiPageTiff = true
        options.tiffCompression = .lzw
        // The queue converts every non-TIFF file to TIFF first, then merges.
        let page = try await GraphicsTestKit.convert(engine, red, to: "tiff", preset: preset { $0.image = options })
        let output = FilePath.combine(dir, "merged.tiff")
        try await engine.merge([page[0], two], into: output, options: options)

        let result = try GraphicsTestKit.decode(output)
        XCTAssertEqual(result.frames.count, 3) // the PNG, then both pages of the TIFF
        for (frame, properties) in zip(result.frames, result.properties) {
            XCTAssertEqual((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int, 5)
            XCTAssertFalse(ImagePixels.hasAlpha(frame)) // flattened for old viewers
        }
        XCTAssertEqual(result.frames[0].width, 40)
        XCTAssertEqual(try TiffTags.values(output, tag: 254), [2, 2, 2], "every image is a page (NewSubfileType 2)")
    }
}

/// IJG quality of a JPEG estimated from its luminance quantization table (what ImageMagick reports as Quality).
enum JpegQuality {
    private static let luminance = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29,
                                    51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121,
                                    120, 101, 72, 92, 95, 98, 112, 100, 103, 99]

    static func estimate(_ path: String) throws -> Int {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var i = 2
        var table: [Int] = []
        while i + 4 < bytes.count, bytes[i] == 0xFF {
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if bytes[i + 1] == 0xDB, bytes[i + 4] >> 4 == 0 { table = (0..<64).map { Int(bytes[i + 5 + $0]) }; break }
            i += 2 + length
        }
        guard table.count == 64 else { return 0 }
        func scaled(_ quality: Int) -> [Int] {
            let scale = quality < 50 ? 5000 / quality : 200 - 2 * quality
            return luminance.map { min(255, max(1, ($0 * scale + 50) / 100)) }
        }
        return (1...100).min { a, b in
            zip(scaled(a).sorted(), table.sorted()).map { abs($0 - $1) }.reduce(0, +) < zip(scaled(b).sorted(), table.sorted()).map { abs($0 - $1) }.reduce(0, +)
        }!
    }
}

/// Values of a tag in every IFD of a classic TIFF.
enum TiffTags {
    static func values(_ path: String, tag: Int) throws -> [Int] {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let little = bytes[0] == 0x49
        func u16(_ at: Int) -> Int { little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { little ? u16(at) | u16(at + 2) << 16 : u16(at) << 16 | u16(at + 2) }
        var result: [Int] = []
        var ifd = u32(4)
        while ifd > 0 && ifd < bytes.count {
            let count = u16(ifd)
            for e in 0..<count where u16(ifd + 2 + e * 12) == tag {
                let at = ifd + 2 + e * 12
                result.append(u16(at + 2) == 3 ? u16(at + 8) : u32(at + 8))
            }
            ifd = u32(ifd + 2 + count * 12)
        }
        return result
    }
}

extension ImageEngineTests {
    /// Other engines write side files through ImageEncoder.save: Korean names must stay composed (NFC) like .NET writes them.
    func testKoreanFileNamesStayComposed() throws {
        let name = "한글 그림.png"
        for format in ["png", "webp", "ppm", "psd"] {
            let path = FilePath.combine(dir, FilePath.changeExtension(name, format))
            try ImageEncoder.save([ImageFrame(image: GraphicsTestKit.solid(8, 8, (10, 20, 30, 255)))], to: path, format: format)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("한") || $0.unicodeScalars.first?.value == 0x1112 }
        XCTAssertEqual(names.count, 4)
        for stored in names {
            XCTAssertEqual(Array(stored.unicodeScalars.prefix(1)).map(\.value), [0xD55C], "\(stored) is decomposed (NFD)")
        }
    }
}
