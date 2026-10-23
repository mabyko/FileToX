// Camera RAW: FileToX's LibRaw shim on generated DNGs (lossy ones through libjpeg-turbo), and an opt-in comparison
// with the C# helper. FILETOX_RAW_SAMPLES=<folder> holding samples/<id>/<id>.<raw extension> and the C# helper's PNG of
// each sample as out/cs/<id>.png (the 2026-10 measurement in /tmp/ftx-raw) converts every sample with the "magick"
// engine and wants the C# pixels exactly, except for files LibRaw can't develop here (Core Image fallback).

import CLibRaw
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class CameraRawTests: XCTestCase {
    private let engine = MagickImageConverter()
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }
    override func tearDown() { FileManager.default.removeIfPresent(dir) }

    /// A 60 × 40 DNG, left half red, right half blue.
    private func dng(_ kind: GraphicsBuilders.DngKind, orientation: UInt16 = 6, name: String? = nil) throws -> String {
        let path = FilePath.combine(dir, name ?? "\(kind)-\(orientation).dng")
        try FileManager.default.writeFile(path, Data(GraphicsBuilders.dng(60, 40, orientation: orientation, kind: kind)))
        return path
    }

    func testShimDevelopsABayerDngAsStoredWithImageMagicksOrientation() throws {
        // EXIF orientation → LibRaw flip → ImageMagick orientation: upright gives 0 (undefined), and the 90° turns come
        // back as they were (LibRaw's flip 5 and 6).
        for (tag, expected) in [(1, 0), (3, 3), (6, 6), (8, 8)] as [(UInt16, Int32)] {
            var image = FTXRawImage()
            XCTAssertEqual(ftx_libraw_develop(try dng(.bayer, orientation: tag), &image), 0)
            defer { free(image.pixels) }
            XCTAssertEqual([image.width, image.height, image.colors], [60, 40, 3], "orientation \(tag)")
            XCTAssertEqual(image.orientation, expected, "orientation \(tag)")
            // Demosaiced with the camera's white balance and auto-brightness: the halves stay red and blue, at full level.
            let left = (0..<3).map { Int(image.pixels[(20 * 60 + 10) * 3 + $0]) }
            let right = (0..<3).map { Int(image.pixels[(20 * 60 + 50) * 3 + $0]) }
            XCTAssertGreaterThan(left[0], 240, "\(left)")
            XCTAssertLessThan(max(left[1], left[2]), 100, "\(left)")
            XCTAssertGreaterThan(right[2], 240, "\(right)")
            XCTAssertLessThan(max(right[0], right[1]), 100, "\(right)")
        }
    }

    func testBayerDngConvertsUprightAsRgbWithoutAlpha() async throws {
        // LibRaw opens the file itself: a Korean (NFC) name must reach it unchanged.
        let output = try await GraphicsTestKit.convert(engine, try dng(.bayer, name: "카메라 원본.dng"), to: "png")
        let result = try GraphicsTestKit.decode(output[0])
        XCTAssertEqual([result.width, result.height], [40, 60])
        XCTAssertFalse(ImagePixels.hasAlpha(result.frames[0])) // like ImageMagick's three-channel RAW pictures
        XCTAssertEqual((result.properties[0][kCGImagePropertyOrientation] as? Int) ?? 1, 1)
        // Orientation 6: the left half (red) is on top once turned clockwise.
        let top = GraphicsTestKit.pixel(result.frames[0], 20, 10), bottom = GraphicsTestKit.pixel(result.frames[0], 20, 50)
        XCTAssertGreaterThan(top.r, top.b + 60, "\(top)")
        XCTAssertGreaterThan(bottom.b, bottom.r + 60, "\(bottom)")
    }

    func testLossyDngIsDevelopedByLibRawWithLibjpeg() async throws {
        let path = try dng(.lossy)
        // LibRaw built with USE_JPEG (libjpeg-turbo), like ImageMagick's: lossy DNGs no longer need Core Image.
        var image = FTXRawImage()
        XCTAssertEqual(ftx_libraw_develop(path, &image), 0)
        free(image.pixels)

        let output = try await GraphicsTestKit.convert(engine, path, to: "png")
        let result = try GraphicsTestKit.decode(output[0])
        XCTAssertEqual([result.width, result.height], [40, 60]) // turned upright by AutoOrient
        XCTAssertFalse(ImagePixels.hasAlpha(result.frames[0]))
        let top = GraphicsTestKit.pixel(result.frames[0], 20, 10), bottom = GraphicsTestKit.pixel(result.frames[0], 20, 50)
        // LibRaw's auto-brightness: the brightest channel reaches white.
        XCTAssertGreaterThan(top.r, 240, "\(top)")
        XCTAssertLessThan(max(top.g, top.b), 100, "\(top)")
        XCTAssertGreaterThan(bottom.b, 240, "\(bottom)")
        XCTAssertLessThan(max(bottom.r, bottom.g), 100, "\(bottom)")
    }

    func testAFileNeitherDecoderReadsIsReported() async throws {
        let path = FilePath.combine(dir, "notes.dng")
        try Data("not a picture".utf8).write(to: URL(fileURLWithPath: path))
        do {
            _ = try await GraphicsTestKit.convert(engine, path, to: "png")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual("\(error)", "notes.dng is not a camera RAW picture this Mac can read.")
        }
    }

    func testCameraRawMatchesTheCSharpHelper() async throws {
        guard let root = ProcessInfo.processInfo.environment["FILETOX_RAW_SAMPLES"] else {
            throw XCTSkip("set FILETOX_RAW_SAMPLES to a folder with samples/ and the C# helper's out/cs/ PNGs")
        }
        let references = try FileManager.default.contentsOfDirectory(atPath: FilePath.combine(root, "out", "cs"))
            .filter { $0.hasSuffix(".png") }.sorted()
        XCTAssertFalse(references.isEmpty)
        for reference in references {
            let id = String(reference.dropLast(4))
            let folder = FilePath.combine(root, "samples", id)
            guard let name = try? FileManager.default.contentsOfDirectory(atPath: folder).first(where: { FormatRegistry.detect($0)?.id == "raw" })
            else { continue }
            // Linked into the test folder, so the PNG is written there.
            let input = FilePath.combine(dir, name)
            try FileManager.default.createSymbolicLink(atPath: input, withDestinationPath: FilePath.combine(folder, name))
            let started = Date()
            let output = try await GraphicsTestKit.convert(engine, input, to: "png")
            let seconds = Date().timeIntervalSince(started)
            let ours = try GraphicsTestKit.decode(output[0]).frames[0]
            let theirs = try GraphicsTestKit.decode(FilePath.combine(root, "out", "cs", reference)).frames[0]
            let sameSize = ours.width == theirs.width && ours.height == theirs.height
            let same = sameSize && ImagePixels.bitmap(ours).pixels == ImagePixels.bitmap(theirs).pixels
            var image = FTXRawImage()
            let libRaw = same || ftx_libraw_develop(input, &image) == 0
            free(image.pixels)
            let psnr = same || !sameSize ? nil : GraphicsTestKit.psnr(ours, theirs)
            print("raw \(id): \(ours.width)×\(ours.height) via \(libRaw ? "LibRaw" : "Core Image") in \(String(format: "%.1f", seconds)) s; "
                  + (same ? "identical to C#" : "C# \(theirs.width)×\(theirs.height), PSNR \(psnr.map { String(format: "%.2f", $0) } ?? "-")"))
            if libRaw {
                XCTAssertTrue(same, "\(id) must match the C# helper's pixels")
            } else if let psnr {
                XCTAssertGreaterThan(psnr, 25, "\(id): the Core Image fallback is too far from the C# helper")
            }
        }
    }
}
