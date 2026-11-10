// Port of the raster part of Filee.Engines.Tests/GraphicsTests.cs: the extra raster formats (JPEG XL, JPEG 2000,
// PSD/PSB, TGA, PPM), layered PSD and GIMP files, Netpbm kinds and camera RAW. (Filee's LibRaw settings test and the
// Windows-only EMF/WMF test have no counterpart: ImageIO develops RAW files and metafiles are not read on macOS.)

import CoreGraphics
import Foundation
import ImageIO
import XCTest
import zlib
@testable import FileToXEngineKit

final class RasterFormatTests: XCTestCase {
    private let engine = MagickImageConverter()
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }
    override func tearDown() { FileManager.default.removeIfPresent(dir) }

    private func preset(_ change: (inout Preset) -> Void) -> Preset {
        var preset = Preset()
        change(&preset)
        return preset
    }

    func testPngConvertsToTheNewRasterFormatsAndBack() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "a.png")
        let expected: [(String, String, Bool)] = [("jxl", "public.jpeg-xl", true), ("jp2", "public.jpeg-2000", true),
                                                  ("psd", "com.adobe.photoshop-image", true), ("psb", "com.adobe.photoshop-image", true),
                                                  ("tga", "com.truevision.tga-image", true), ("ppm", "public.pbm", false)]
        for (target, type, keepsAlpha) in expected {
            let output = try await GraphicsTestKit.convert(engine, source, to: target, preset: preset { $0.image.quality = 100 })
            XCTAssertEqual(FilePath.extension(output[0]), "." + target)
            let result = try GraphicsTestKit.decode(output[0])
            XCTAssertEqual(result.type, type, target)
            XCTAssertEqual([result.width, result.height], [320, 200], target)
            // The transparent corner survives where the format has alpha, else it becomes the white background.
            let corner = GraphicsTestKit.pixel(result.frames[0], 5, 5)
            if keepsAlpha {
                XCTAssertEqual(corner.a, 0, target)
            } else {
                XCTAssertTrue(corner.r > 250 && corner.g > 250 && corner.b > 250, "\(target): \(corner)")
            }
            // … and back to PNG through the same engine.
            let back = try await GraphicsTestKit.convert(engine, output[0], to: "png", name: "a_\(target)_back")
            let png = try GraphicsTestKit.decode(back[0])
            XCTAssertEqual([png.width, png.height], [320, 200], target)
        }
    }

    func testJpegXlQualityComesFromThePresetAnd100IsLossless() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "a.png", width: 640, height: 400)
        let low = try await GraphicsTestKit.convert(engine, source, to: "jxl", preset: preset { $0.image.quality = 40 }, name: "a_40")
        let high = try await GraphicsTestKit.convert(engine, source, to: "jxl", preset: preset { $0.image.quality = 95 }, name: "a_95")
        let lossless = try await GraphicsTestKit.convert(engine, source, to: "jxl", preset: preset { $0.image.quality = 100 }, name: "a_100")
        func size(_ path: String) throws -> Int { try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int }
        XCTAssertLessThan(try size(low[0]), try size(high[0]))
        let original = try GraphicsTestKit.decode(source).frames[0], exact = try GraphicsTestKit.decode(lossless[0]).frames[0]
        XCTAssertEqual(GraphicsTestKit.psnr(original, exact), .infinity)
    }

    func testWebpQualityLosslessAndNearLossless() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "a.png", width: 640, height: 400)
        let low = try await GraphicsTestKit.convert(engine, source, to: "webp", preset: preset { $0.image.quality = 40 }, name: "a_40")
        let high = try await GraphicsTestKit.convert(engine, source, to: "webp", preset: preset { $0.image.quality = 95 }, name: "a_95")
        let exact = try await GraphicsTestKit.convert(engine, source, to: "webp", preset: preset { $0.image.quality = 100 }, name: "a_100")
        func size(_ path: String) throws -> Int { try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int }
        XCTAssertLessThan(try size(low[0]), try size(high[0]))
        // Quality 100 is lossless, like ImageMagick's WebP coder.
        let original = try GraphicsTestKit.decode(source).frames[0]
        XCTAssertEqual(GraphicsTestKit.psnr(original, try GraphicsTestKit.decode(exact[0]).frames[0]), .infinity)
    }

    func testLayeredPsdBecomesOneImageOfTheComposite() async throws {
        let path = FilePath.combine(dir, "layers.psd")
        // Photoshop stores the composite first, then the layers.
        let data = GraphicsBuilders.layeredPsd(120, 80, composite: { x, y in (60..<100).contains(x) && (20..<50).contains(y) ? (0, 0, 255) : (255, 0, 0) },
                                               layers: [.init(left: 0, top: 0, width: 120, height: 80, r: 255, g: 0, b: 0),
                                                        .init(left: 60, top: 20, width: 40, height: 30, r: 0, g: 0, b: 255)])
        try Data(data).write(to: URL(fileURLWithPath: path))

        let output = try await GraphicsTestKit.convert(engine, path, to: "png")
        XCTAssertEqual(output.map(FilePath.fileName), ["layers.png"])
        let result = try GraphicsTestKit.decode(output[0]).frames[0]
        XCTAssertEqual([result.width, result.height], [120, 80])
        XCTAssertGreaterThan(GraphicsTestKit.pixel(result, 10, 10).r, 200, "background layer")
        let box = GraphicsTestKit.pixel(result, 80, 35)
        XCTAssertTrue(box.b > 200 && box.r < 50, "the upper layer is composited at its offset: \(box)")
    }

    func testPsdWithoutARealCompositeIsBuiltFromItsLayers() async throws {
        let path = FilePath.combine(dir, "nocomposite.psd")
        let data = GraphicsBuilders.layeredPsd(120, 80, composite: { _, _ in (0, 0, 0) },
                                               layers: [.init(left: 0, top: 0, width: 120, height: 80, r: 255, g: 0, b: 0),
                                                        .init(left: 60, top: 20, width: 40, height: 30, r: 0, g: 0, b: 255)],
                                               realComposite: false)
        try Data(data).write(to: URL(fileURLWithPath: path))

        let result = try GraphicsTestKit.decode(try await GraphicsTestKit.convert(engine, path, to: "png")[0]).frames[0]
        XCTAssertGreaterThan(GraphicsTestKit.pixel(result, 10, 10).r, 200, "background layer")
        let box = GraphicsTestKit.pixel(result, 80, 35)
        XCTAssertTrue(box.b > 200 && box.r < 50, "the upper layer, not the white placeholder: \(box)")
    }

    func testGimpLayersAreFlattenedAtTheirOffsetsAndHiddenLayersAreLeftOut() async throws {
        let path = FilePath.combine(dir, "drawing.xcf")
        try Data(GraphicsBuilders.xcf(96, 64, [
            .init(name: "Hidden", width: 96, height: 64, x: 0, y: 0, r: 0, g: 0, b: 255, visible: false),
            .init(name: "Box", width: 16, height: 16, x: 60, y: 8, r: 0, g: 200, b: 0),
            .init(name: "Background", width: 48, height: 64, x: 0, y: 0, r: 220, g: 30, b: 30),
        ])).write(to: URL(fileURLWithPath: path))

        let output = try await GraphicsTestKit.convert(engine, path, to: "png")
        let result = try GraphicsTestKit.decode(output[0]).frames[0]
        XCTAssertEqual([result.width, result.height], [96, 64])
        let background = GraphicsTestKit.pixel(result, 10, 10)
        XCTAssertTrue(background.r > 200 && background.b < 50, "background: \(background)")
        let box = GraphicsTestKit.pixel(result, 66, 12)
        XCTAssertTrue(box.g > 180 && box.r < 50 && box.b < 50, "box: \(box)")
        XCTAssertEqual(GraphicsTestKit.pixel(result, 80, 50).a, 0) // outside every visible layer: transparent, not the hidden blue
    }

    func testUnreadableGimpFilesExplainWhatToDo() async throws {
        let path = FilePath.combine(dir, "broken.xcf")
        try Data("gimp xcf v011\0".utf8 + [0, 0, 0, 10, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 200]).write(to: URL(fileURLWithPath: path))
        do {
            try await GraphicsTestKit.convert(engine, path, to: "png")
            XCTFail("a 16-bit XCF can't be read")
        } catch {
            XCTAssertTrue("\(error)".contains("export the picture as PNG or PSD"), "\(error)")
        }
    }

    func testNetpbmKeepsItsKindAndGrayscaleBecomesPgm() async throws {
        let png = try GraphicsTestKit.makeImage(dir, "a.png")
        let pgm = try GraphicsTestKit.makeImage(dir, "scan.pgm")
        let gray = try await GraphicsTestKit.convert(engine, png, to: "ppm", preset: preset { $0.image.grayscale = true })
        let half = try await GraphicsTestKit.convert(engine, pgm, to: "ppm", preset: preset {
            $0.image.resize = .percent
            $0.image.resizePercent = 50
        }, name: "scan_50")
        XCTAssertEqual(gray.map(FilePath.fileName), ["a.pgm"])
        XCTAssertEqual(half.map(FilePath.fileName), ["scan_50.pgm"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: half[0]))
        XCTAssertEqual(String(decoding: bytes.prefix(2), as: UTF8.self), "P5")
        XCTAssertEqual(try GraphicsTestKit.decode(half[0]).width, 160)
        XCTAssertEqual(String(decoding: try Data(contentsOf: URL(fileURLWithPath: gray[0])).prefix(2), as: UTF8.self), "P5")
    }

    func testNetpbmReadsAsciiBitmapAndSixteenBitKinds() throws {
        let ascii = FilePath.combine(dir, "a.pbm")
        try Data("P1\n# comment\n3 2\n1 0 1\n0 1 0\n".utf8).write(to: URL(fileURLWithPath: ascii))
        let wide = FilePath.combine(dir, "b.pgm")
        try Data("P5 2 1 65535\n".utf8 + [0xFF, 0xFF, 0x80, 0x00]).write(to: URL(fileURLWithPath: wide))
        let bitmap = try NetpbmCodec.read(ascii)[0].image
        XCTAssertEqual([bitmap.width, bitmap.height], [3, 2])
        XCTAssertEqual(GraphicsTestKit.pixel(bitmap, 0, 0).r, 0) // 1 is black
        XCTAssertEqual(GraphicsTestKit.pixel(bitmap, 1, 0).r, 255)
        let gray = try NetpbmCodec.read(wide)[0].image
        XCTAssertEqual(GraphicsTestKit.pixel(gray, 0, 0).r, 255)
        XCTAssertEqual(GraphicsTestKit.pixel(gray, 1, 0).r, 128)
    }

    func testCameraRawIsDecodedAndTurnedUpright() async throws {
        for name in ["photo.dng", "photo.raw"] { // a ".raw" file must not be taken for headerless pixels
            let path = FilePath.combine(dir, name)
            // Orientation 6: the camera was turned; the picture must be rotated 90° clockwise for display.
            try Data(GraphicsBuilders.dng(60, 40, orientation: 6)).write(to: URL(fileURLWithPath: path))

            let output = try await GraphicsTestKit.convert(engine, path, to: "jpg", name: "photo-" + name)
            let result = try GraphicsTestKit.decode(output[0]).frames[0]
            XCTAssertEqual([result.width, result.height], [40, 60], name)
            // Left half red → after turning clockwise it is the top half.
            let top = GraphicsTestKit.pixel(result, 20, 10), bottom = GraphicsTestKit.pixel(result, 20, 50)
            XCTAssertGreaterThan(top.r, top.b + 60, "\(name) top should be red: \(top)")
            XCTAssertGreaterThan(bottom.b, bottom.r + 60, "\(name) bottom should be blue: \(bottom)")
        }
    }

    func testGrayscaleAndOrientationKeepGrayAndUpright() async throws {
        // An EXIF-rotated JPEG (orientation 8) becomes an upright grayscale PNG.
        let image = GraphicsTestKit.solid(30, 20, (200, 50, 50, 255))
        let path = FilePath.combine(dir, "turned.jpg")
        try ImageEncoder.save([ImageFrame(image: image, properties: [kCGImagePropertyOrientation: 8])], to: path, format: "jpg")
        let output = try await GraphicsTestKit.convert(engine, path, to: "png", preset: preset { $0.image.grayscale = true })
        let result = try GraphicsTestKit.decode(output[0])
        XCTAssertEqual([result.width, result.height], [20, 30])
        XCTAssertEqual(result.frames[0].colorSpace?.model, .monochrome)
        XCTAssertEqual((result.properties[0][kCGImagePropertyOrientation] as? Int) ?? 1, 1)
    }
}

extension RasterFormatTests {
    func testPsdAndPsbCompositeSamplesMatchFileeWriter() async throws {
        let source = FilePath.combine(dir, "semi.png")
        try ImageEncoder.save([ImageFrame(image: GraphicsTestKit.solid(8, 4, (200, 40, 40, 128)))], to: source, format: "png")
        let expected = GraphicsTestKit.pixel(try GraphicsTestKit.decode(source).frames[0], 2, 2)
        for target in ["psd", "psb"] {
            let document = try await GraphicsTestKit.convert(engine, source, to: target)
            // ImageIO's PSD decoder applies alpha to the stored channel samples.
            // Filee writes straight samples; adding a white matte changed these
            // displayed values. Our white-unblending reader masks that difference.
            let pixel = GraphicsTestKit.pixel(try GraphicsTestKit.decode(document[0]).frames[0], 2, 2)
            XCTAssertEqual(pixel.a, 128, target)
            XCTAssertTrue(abs(pixel.r - expected.r * 128 / 255) <= 2
                          && abs(pixel.g - expected.g * 128 / 255) <= 2
                          && abs(pixel.b - expected.b * 128 / 255) <= 2, "\(target): \(pixel)")
        }
    }

    func testPhotoshopWhiteMattedCompositeIsUnblended() throws {
        for large in [false, true] {
            let path = FilePath.combine(dir, large ? "photoshop.psb" : "photoshop.psd")
            // Stored Photoshop samples: red 200 / green-blue 40 over white at alpha 128.
            let image = GraphicsTestKit.solid(8, 4, (227, 147, 147, 128))
            try PsdCodec.write(ImageFrame(image: image), to: path, large: large)
            let frame = try XCTUnwrap(PsdCodec.transparentComposite(path))
            let pixel = GraphicsTestKit.pixel(frame.image, 2, 2)
            XCTAssertEqual(pixel.a, 128)
            XCTAssertTrue(abs(pixel.r - 200) <= 2 && abs(pixel.g - 40) <= 2 && abs(pixel.b - 40) <= 2, "\(pixel)")
        }
    }

    func testGifTransparencyUsesTheFileeHalfAlphaThreshold() throws {
        let pixels: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 127, 255, 0, 0, 128, 255, 0, 0, 255]
        let image = ImagePixels.make(pixels, 4, 1, components: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true, premultiplied: false)
        let file = FilePath.combine(dir, "threshold.gif")
        try ImageEncoder.save([ImageFrame(image: image)], to: file, format: "gif")
        let decoded = try GraphicsTestKit.decode(file).frames[0]
        XCTAssertEqual((0..<4).map { GraphicsTestKit.pixel(decoded, $0, 0).a }, [0, 0, 255, 255])
        XCTAssertGreaterThan(GraphicsTestKit.pixel(decoded, 2, 0).r, 250)
    }

    func testGifLogicalScreenKeepsFirstPageGeometry() throws {
        let file = FilePath.combine(dir, "pages.gif")
        let frames = [ImageFrame(image: GraphicsTestKit.solid(150, 100, (255, 0, 0, 255))),
                      ImageFrame(image: GraphicsTestKit.solid(100, 150, (0, 255, 0, 255)))]
        try ImageEncoder.save(frames, to: file, format: "gif")
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: file)))
        XCTAssertEqual(Array(data[6..<10]), [150, 0, 100, 0])
        // Frame rectangles remain intact, including the taller second page.
        let decoded = try GraphicsTestKit.decode(file)
        XCTAssertEqual(decoded.frames.count, 2)
    }
}

extension RasterFormatTests {
    /// A 24-bit BI_RGB BMP laid out like ImageIO's (40-byte header, unpadded biSizeImage) with 0xA5 in every row's padding.
    private func poisonedBmp(width: Int, height: Int) -> Data {
        let used = width * 3, stride = (used + 3) / 4 * 4, rows = abs(height)
        let writer = BinaryWriter()
        writer.write([0x42, 0x4D] as [UInt8])
        for value in [UInt32(54 + stride * rows), 0, 54, 40] { writer.write(value) }
        writer.write(Int32(width))
        writer.write(Int32(height))
        writer.write(UInt16(1))
        writer.write(UInt16(24))
        writer.write(UInt32(0))
        writer.write(UInt32(used * rows))
        writer.write([UInt8](repeating: 0, count: 16))
        for row in 0..<rows {
            writer.write((0..<used).map { UInt8(($0 * 7 + row * 31) & 0xFF | 1) })
            writer.write([UInt8](repeating: 0xA5, count: stride - used))
        }
        return writer.data
    }

    private func isPadding(_ index: Int, width: Int) -> Bool {
        let stride = (width * 3 + 3) / 4 * 4
        return index >= 54 && (index - 54) % stride >= width * 3
    }

    func testBmpRowPaddingIsZeroedOnlyWithinAStrictHeader() {
        for width in 1...9 {
            for height in [-3, 3, 1] {
                let poisoned = poisonedBmp(width: width, height: height)
                let zeroed = ImageEncoder.zeroingBmpPadding(poisoned)
                XCTAssertEqual(zeroed.count, poisoned.count)
                for i in 0..<poisoned.count {
                    XCTAssertEqual(zeroed[i], isPadding(i, width: width) ? 0 : poisoned[i], "width \(width), height \(height), byte \(i)")
                }
            }
        }
        // biSizeImage may also be 0 or the padded size.
        for size in [UInt32(0), UInt32(16 * 3)] {
            var bmp = poisonedBmp(width: 5, height: 3)
            BinaryPrimitives.writeUInt32LittleEndian(&bmp, 34, size)
            XCTAssertFalse(ImageEncoder.zeroingBmpPadding(bmp).enumerated().contains { isPadding($0.offset, width: 5) && $0.element != 0 })
        }
        // Anything the header does not describe exactly is left byte for byte as it is.
        let valid = poisonedBmp(width: 5, height: 3)
        func patched(_ offset: Int, _ value: UInt32, bytes: Int = 4) -> Data {
            var bmp = valid
            if bytes == 2 { BinaryPrimitives.writeUInt16LittleEndian(&bmp, offset, UInt16(value)) } else { BinaryPrimitives.writeUInt32LittleEndian(&bmp, offset, value) }
            return bmp
        }
        func resized(_ bmp: Data) -> Data {
            var bmp = bmp
            BinaryPrimitives.writeUInt32LittleEndian(&bmp, 2, UInt32(bmp.count))
            return bmp
        }
        let rejected = [
            Data("BA".utf8) + valid.dropFirst(2), patched(2, UInt32(valid.count + 1)), patched(2, UInt32(valid.count - 1)),
            patched(14, 12), patched(14, 39), patched(10, 53), patched(10, UInt32(valid.count + 1)), patched(10, 0xFFFF_FFFF),
            patched(26, 2, bytes: 2), patched(28, 32, bytes: 2), patched(28, 8, bytes: 2), patched(30, 1), patched(30, 3),
            patched(18, 0), patched(18, UInt32(bitPattern: -5)), patched(18, 0x7FFF_FFFF), patched(22, 0), patched(22, 0x7FFF_FFFF),
            patched(34, 7), resized(valid + [0]), resized(valid.dropLast()), resized(valid + Data(repeating: 0xA5, count: 16)),
            Data(valid.prefix(53)), poisonedBmp(width: 4, height: 3),
        ]
        for (index, bmp) in rejected.enumerated() { XCTAssertEqual(ImageEncoder.zeroingBmpPadding(bmp), bmp, "variant \(index)") }
    }

    func testBmpWriterZeroesPaddingAndKeepsImageIOPixelsAcrossWidths() throws {
        for width in Array(1...9) + [41] {
            for (space, components) in [(CGColorSpace(name: CGColorSpace.sRGB)!, 3), (CGColorSpaceCreateDeviceGray(), 1)] {
                let samples = (0..<width * 3 * components).map { UInt8(($0 * 53 + width * 17) & 255) }
                let image = ImagePixels.make(samples, width, 3, components: components, space: space, alpha: false)
                let file = FilePath.combine(dir, "w\(width)-\(components).bmp")
                try ImageEncoder.save([ImageFrame(image: image)], to: file, format: "bmp")
                let written = try Data(contentsOf: URL(fileURLWithPath: file))
                // ImageIO alone writes the same file except for the padding it leaves undefined.
                let raw = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(raw, "com.microsoft.bmp" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                let imageIO = raw as Data
                XCTAssertEqual(written.count, imageIO.count)
                XCTAssertEqual(BinaryPrimitives.readUInt16LittleEndian(written, 28), 24)
                for i in 0..<min(written.count, imageIO.count) {
                    XCTAssertEqual(written[i], isPadding(i, width: width) ? 0 : imageIO[i], "width \(width), byte \(i)")
                }
                let decoded = try GraphicsTestKit.decode(file).frames[0]
                let reference = try XCTUnwrap(CGImageSourceCreateWithData(imageIO as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                XCTAssertEqual(ImagePixels.straight(decoded).samples, ImagePixels.straight(reference).samples)
                if components == 3 { XCTAssertEqual(ImagePixels.straight(decoded).samples, samples) }
            }
        }
    }

    private static let palette: [[UInt8]] = [[200, 30, 30], [30, 200, 30], [30, 30, 200], [240, 240, 240]]
    private func paletteIndex(_ x: Int, _ y: Int) -> Int { (x + 2 * y) % 4 }

    /// A palette PNG (colour type 3) with four colours, optionally an iCCP profile and tRNS alpha.
    private func palettePng(width: Int, height: Int = 3, transparency: [UInt8]? = nil, profile: Data? = nil) throws -> Data {
        func chunk(_ type: String, _ payload: Data) -> Data {
            let bytes = Data(type.utf8) + payload
            let crc = UInt32(bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) })
            return withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + bytes + withUnsafeBytes(of: crc.bigEndian) { Data($0) }
        }
        var raw = Data()
        for y in 0..<height { raw.append(0); for x in 0..<width { raw.append(UInt8(paletteIndex(x, y))) } }
        var header = withUnsafeBytes(of: UInt32(width).bigEndian) { Data($0) } + withUnsafeBytes(of: UInt32(height).bigEndian) { Data($0) }
        header += [8, 3, 0, 0, 0]
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", header)
        if let profile { png += chunk("iCCP", Data("icc".utf8) + [0, 0] + (try Deflate.deflate(profile, windowBits: 15))) }
        png += chunk("PLTE", Data(Self.palette.joined()))
        if let transparency { png += chunk("tRNS", Data(transparency)) }
        return png + chunk("IDAT", try Deflate.deflate(raw, windowBits: 15)) + chunk("IEND", Data())
    }

    /// Straight RGBA rows top to bottom, read from the BMP bytes themselves (24-bit, or 32-bit with BGRA masks).
    private func bmpRGBA(_ bmp: Data) throws -> (width: Int, height: Int, bitsPerPixel: Int, rgba: [UInt8]) {
        XCTAssertTrue(bmp.starts(with: [0x42, 0x4D]))
        let offset = Int(BinaryPrimitives.readUInt32LittleEndian(bmp, 10)), width = Int(BinaryPrimitives.readInt32LittleEndian(bmp, 18))
        let height = Int(BinaryPrimitives.readInt32LittleEndian(bmp, 22)), bits = Int(BinaryPrimitives.readUInt16LittleEndian(bmp, 28))
        let channels = bits / 8, stride = (width * bits + 31) / 32 * 4
        if bits == 32 {
            XCTAssertEqual((0..<4).map { BinaryPrimitives.readUInt32LittleEndian(bmp, 54 + 4 * $0) }, [0xFF0000, 0xFF00, 0xFF, 0xFF00_0000])
        }
        XCTAssertEqual(offset + stride * abs(height), bmp.count)
        var rgba: [UInt8] = []
        for y in 0..<abs(height) {
            let row = offset + (height < 0 ? y : abs(height) - 1 - y) * stride
            for x in 0..<width {
                let p = row + x * channels
                rgba += [bmp[p + 2], bmp[p + 1], bmp[p], channels == 4 ? bmp[p + 3] : 255]
            }
        }
        return (width, abs(height), bits, rgba)
    }

    func testPalettePngsBecomeReadableBmpsWithTheirColoursAndAlpha() throws {
        let adobe = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/AdobeRGB1998.icc"))
        let alphas: [UInt8] = [255, 128, 0, 255]
        for width in [1, 2, 3, 4, 5, 6, 7, 9, 41] {
            for kind in ["opaque", "adobe", "transparent"] {
                let source = FilePath.combine(dir, "\(kind)-\(width).png"), target = FilePath.combine(dir, "\(kind)-\(width).bmp")
                try palettePng(width: width, transparency: kind == "transparent" ? alphas : nil, profile: kind == "adobe" ? adobe : nil)
                    .write(to: URL(fileURLWithPath: source))
                let frame = try ImageReader.read(source, format: "png", preset: Preset())[0]
                // ImageIO keeps opaque palettes indexed and expands tRNS palettes to RGBA.
                XCTAssertEqual(frame.image.colorSpace?.model == .indexed, kind != "transparent", "\(kind) \(width)")
                try ImageEncoder.save([frame], to: target, format: "bmp")
                let written = try Data(contentsOf: URL(fileURLWithPath: target))
                guard ImageEncoder.isBmp(written) else { XCTFail("\(kind) \(width): no BMP header"); continue }
                let bmp = try bmpRGBA(written)
                XCTAssertEqual([bmp.width, bmp.height, bmp.bitsPerPixel], [width, 3, kind == "transparent" ? 32 : 24])
                if bmp.bitsPerPixel == 24 {
                    let stride = (width * 3 + 3) / 4 * 4
                    for row in 0..<3 { XCTAssertTrue(written[54 + row * stride + width * 3..<54 + (row + 1) * stride].allSatisfy { $0 == 0 }) }
                }
                // Expected colours: the palette itself, or for Adobe RGB what ImageIO's BMP writer makes of the same colours
                // as an Adobe RGB truecolour picture.
                let indexes = (0..<3).flatMap { y in (0..<width).map { paletteIndex($0, y) } }
                var expected = indexes.flatMap { Self.palette[$0] + [kind == "transparent" ? alphas[$0] : 255] }
                if kind == "adobe" {
                    let samples = indexes.flatMap { Self.palette[$0] }
                    let truecolour = try XCTUnwrap(CGImage(width: width, height: 3, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                                           space: try XCTUnwrap(CGColorSpace(iccData: adobe as CFData)), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                                           provider: try XCTUnwrap(CGDataProvider(data: Data(samples) as CFData)), decode: nil,
                                                           shouldInterpolate: false, intent: .defaultIntent))
                    let data = NSMutableData()
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.microsoft.bmp" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, truecolour, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                    expected = try bmpRGBA(data as Data).rgba
                    XCTAssertNotEqual(expected, indexes.flatMap { Self.palette[$0] + [255] }, "Adobe RGB colours are converted")
                }
                for i in 0..<indexes.count where expected[i * 4 + 3] > 0 {
                    XCTAssertEqual(Array(bmp.rgba[i * 4..<i * 4 + 4]), Array(expected[i * 4..<i * 4 + 4]), "\(kind) \(width) pixel \(i)")
                }
                XCTAssertEqual(stride(from: 3, to: bmp.rgba.count, by: 4).map { bmp.rgba[$0] }, stride(from: 3, to: expected.count, by: 4).map { expected[$0] })
            }
        }
    }

    func testTgaConvertsProfiledColoursToSrgbWithoutLosingAlpha() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func rendered(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.adobeRGB1998] {
            let space = try XCTUnwrap(CGColorSpace(name: name))
            let colours: [[UInt8]] = [[200, 100, 50], [38, 19, 47], [32, 190, 120], [255, 0, 0]]
            for alpha in [false, true] {
                let alphas: [UInt8] = [255, 128, 64, 0]
                let samples: [UInt8] = (0..<8).flatMap { colours[$0 % 4] + (alpha ? [alphas[$0 % 4]] : []) }
                let source = ImagePixels.make(samples, 4, 2, components: alpha ? 4 : 3, space: space, alpha: alpha, premultiplied: false)
                let expected = try rendered(source)
                if name != CGColorSpace.sRGB { XCTAssertNotEqual(Array(expected.prefix(3)), colours[0]) }
                let path = FilePath.combine(dir, "colour-\(name)-\(alpha).tga")
                try ImageEncoder.save([ImageFrame(image: source)], to: path, format: "tga")
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                XCTAssertEqual(data[2], 2, "uncompressed truecolour")
                XCTAssertEqual(data[16], alpha ? 32 : 24)
                let reader = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
                let actual = try rendered(decoded)
                XCTAssertEqual(actual.count, expected.count)
                for i in actual.indices { XCTAssertEqual(Double(actual[i]), Double(expected[i]), accuracy: 1, "\(name), alpha=\(alpha), component=\(i)") }
            }
            let palette = try XCTUnwrap(CGColorSpace(indexedBaseSpace: space, last: 3, colorTable: colours.flatMap { $0 }))
            let indexed = try XCTUnwrap(CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 4,
                space: palette, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: try XCTUnwrap(CGDataProvider(data: Data([0, 1, 2, 3, 3, 2, 1, 0]) as CFData)),
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let path = FilePath.combine(dir, "indexed-\(name).tga")
            try ImageEncoder.save([ImageFrame(image: indexed)], to: path, format: "tga")
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            XCTAssertEqual(try rendered(try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))), try rendered(indexed))
        }
    }

    func testTgaSrgbAndGrayKeepTheImageIoBytes() throws {
        for (space, channels) in [(CGColorSpace(name: CGColorSpace.sRGB)!, 3), (CGColorSpaceCreateDeviceGray(), 1)] {
            let image = ImagePixels.make((0..<24 * channels).map { UInt8(($0 * 31) % 256) }, 6, 4,
                                        components: channels, space: space, alpha: false)
            let original = NSMutableData()
            let writer = try XCTUnwrap(CGImageDestinationCreateWithData(original, "com.truevision.tga-image" as CFString, 1, nil))
            CGImageDestinationAddImage(writer, image, ["{TGA}": ["Compression": 0]] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            let path = FilePath.combine(dir, "control-\(channels).tga")
            try ImageEncoder.save([ImageFrame(image: image)], to: path, format: "tga")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original as Data)
        }
    }

    func testBmpWithoutAHeaderIsNeverAccepted() throws {
        // What ImageIO writes for an indexed picture: bare BGR pixels, no header.
        let indexed = try XCTUnwrap(CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!, last: 3, colorTable: Self.palette.joined().map { $0 }))
        let picture = try XCTUnwrap(CGImage(width: 6, height: 3, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 6, space: indexed,
                                            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: try XCTUnwrap(CGDataProvider(data: Data((0..<18).map { UInt8($0 % 4) }) as CFData)),
                                            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.microsoft.bmp" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "ImageIO reports success")
        XCTAssertFalse(ImageEncoder.isBmp(data as Data))
        let valid = poisonedBmp(width: 5, height: 3)
        XCTAssertTrue(ImageEncoder.isBmp(valid))
        var wrongLength = valid, pixelsMissing = valid, insideHeader = valid
        BinaryPrimitives.writeUInt32LittleEndian(&wrongLength, 2, UInt32(valid.count + 1))
        BinaryPrimitives.writeUInt32LittleEndian(&pixelsMissing, 10, UInt32(valid.count))
        BinaryPrimitives.writeUInt32LittleEndian(&insideHeader, 10, 25)
        for bmp in [wrongLength, pixelsMissing, insideHeader, Data(valid.prefix(25)), Data("BA".utf8) + valid.dropFirst(2)] {
            XCTAssertFalse(ImageEncoder.isBmp(bmp))
        }
    }
}
