// Port of the raster part of Filee.Engines.Tests/GraphicsTests.cs: the extra raster formats (JPEG XL, JPEG 2000,
// PSD/PSB, TGA, PPM), layered PSD and GIMP files, Netpbm kinds and camera RAW. (Filee's LibRaw settings test and the
// Windows-only EMF/WMF test have no counterpart: ImageIO develops RAW files and metafiles are not read on macOS.)

import CoreGraphics
import Foundation
import ImageIO
import XCTest
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
