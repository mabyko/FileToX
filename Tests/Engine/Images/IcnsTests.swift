// Port of the ICNS part of Filee.Engines.Tests/GraphicsTests.cs.

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class IcnsTests: XCTestCase {
    private let engine = IcnsConverter()
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }
    override func tearDown() { FileManager.default.removeIfPresent(dir) }

    func testIcnsHoldsEverySizeAsAPaddedSquare() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "app.png", width: 300, height: 200)
        let output = try await GraphicsTestKit.convert(engine, source, to: "icns")
        let entries = try IcnsFile.parse([UInt8](Data(contentsOf: URL(fileURLWithPath: output[0]))))
        XCTAssertEqual(entries.map(\.type), ["TOC ", "icp4", "ic11", "icp5", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"])
        for (type, size) in IcnsFile.writtenTypes {
            let data = try XCTUnwrap(entries.first { $0.type == type }?.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(data) as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual([image.width, image.height], [size, size], type)
        }
        let large = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(Data(entries.first { $0.type == "ic10" }!.data) as CFData, nil)!, 0, nil))
        XCTAssertEqual(GraphicsTestKit.pixel(large, 512, 20).a, 0) // padding above the landscape picture
        XCTAssertEqual(GraphicsTestKit.pixel(large, 512, 512).a, 255) // the picture itself
        // macOS reads the icon too.
        XCTAssertEqual(try GraphicsTestKit.decode(output[0]).type, "com.apple.icns")
    }

    func testIcnsConvertsBackFromItsLargestImage() async throws {
        let source = try GraphicsTestKit.makeImage(dir, "app.png", width: 256, height: 256)
        let icns = try await GraphicsTestKit.convert(engine, source, to: "icns")[0]
        let png = try await GraphicsTestKit.convert(engine, icns, to: "png", name: "app_icon")
        var preset = Preset()
        preset.image.resize = .longEdge
        preset.image.longEdge = 100
        let jpg = try await GraphicsTestKit.convert(engine, icns, to: "jpg", preset: preset)
        let big = try GraphicsTestKit.decode(png[0]), small = try GraphicsTestKit.decode(jpg[0])
        XCTAssertEqual([big.width, big.height], [1024, 1024])
        XCTAssertEqual([small.width, small.height], [100, 100])
    }

    func testLegacyAndJpeg2000IcnsEntriesAreRead() async throws {
        var mask = [UInt8](repeating: 0, count: 128 * 128)
        for i in 0..<64 * 128 { mask[i] = 255 } // top half opaque, bottom half transparent
        let legacy = FilePath.combine(dir, "legacy.icns")
        try Data(GraphicsBuilders.icns([
            ("is32", GraphicsBuilders.legacyRgb(16, 200, 0, 0)),
            ("s8mk", [UInt8](repeating: 255, count: 256)),
            ("it32", GraphicsBuilders.legacyRgb(128, 0, 180, 40, it32: true)),
            ("t8mk", mask),
        ])).write(to: URL(fileURLWithPath: legacy))

        let jp2Path = FilePath.combine(dir, "navy.jp2")
        try ImageEncoder.save([ImageFrame(image: GraphicsTestKit.solid(256, 256, (0, 0, 128, 255)))], to: jp2Path, format: "jp2")
        let jpeg2000 = FilePath.combine(dir, "jp2.icns")
        try Data(GraphicsBuilders.icns([
            ("il32", GraphicsBuilders.legacyRgb(32, 0, 0, 200)),
            ("ic08", [UInt8](try Data(contentsOf: URL(fileURLWithPath: jp2Path)))),
        ])).write(to: URL(fileURLWithPath: jpeg2000))

        let legacyPng = try GraphicsTestKit.decode(try await GraphicsTestKit.convert(engine, legacy, to: "png")[0]).frames[0]
        XCTAssertEqual([legacyPng.width, legacyPng.height], [128, 128]) // it32 is larger than is32
        let top = GraphicsTestKit.pixel(legacyPng, 64, 32)
        XCTAssertTrue(top.g > 170 && top.r < 10 && top.a == 255, "\(top)")
        XCTAssertEqual(GraphicsTestKit.pixel(legacyPng, 64, 100).a, 0)

        let jp2Png = try GraphicsTestKit.decode(try await GraphicsTestKit.convert(engine, jpeg2000, to: "png")[0]).frames[0]
        XCTAssertEqual([jp2Png.width, jp2Png.height], [256, 256])
        XCTAssertGreaterThan(GraphicsTestKit.pixel(jp2Png, 10, 10).b, 100)
    }

    func testIcnsRleDecodesLiteralAndRepeatRuns() {
        let data = (0..<300).map { UInt8($0 < 100 ? $0 : 7) }
        XCTAssertEqual(IcnsFile.unpackBits(GraphicsBuilders.packBits(data), data.count), data)
    }

    func testFilesWithoutReadableImagesFail() async throws {
        let empty = FilePath.combine(dir, "mono.icns")
        try Data(GraphicsBuilders.icns([("ICN#", [UInt8](repeating: 0, count: 256))])).write(to: URL(fileURLWithPath: empty))
        let fake = FilePath.combine(dir, "fake.icns")
        try Data("not an icon".utf8).write(to: URL(fileURLWithPath: fake))
        for (path, message) in [(empty, "only 1-bit or 8-bit palette icons"), (fake, "the 'icns' signature is missing")] {
            do {
                try await GraphicsTestKit.convert(engine, path, to: "png")
                XCTFail(path)
            } catch {
                XCTAssertTrue("\(error)".contains(message), "\(error)")
            }
        }
    }
}
