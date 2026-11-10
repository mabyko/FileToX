// Test support for the image, PDF and vector engines: a temp folder per test, an output allocator with Filee's naming
// ({name}{suffix}.{ext}, " (2)" on clashes), direct conversion through a converter, and generated sample pictures
// (Filee's EngineFixture.MakeImage / MakeMultiPageTiff).

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

final class GraphicsTestOutput: OutputAllocator {
    let folder: String
    let name: String
    private(set) var allocated: [String] = []

    init(folder: String, name: String) {
        self.folder = folder
        self.name = name
    }

    func allocate(_ extension: String, suffix: String?) throws -> String? {
        let stem = FilePath.combine(folder, name + (suffix ?? ""))
        func candidate(_ n: Int) -> String {
            let numbered = n == 1 ? stem : "\(stem) (\(n))"
            return `extension`.isEmpty ? numbered : numbered + "." + `extension`
        }
        var n = 1
        while FileManager.default.fileExists(atPath: candidate(n)) || allocated.contains(candidate(n)) { n += 1 }
        allocated.append(candidate(n))
        return candidate(n)
    }
}

enum GraphicsTestKit {
    /// A new empty folder below the temp directory.
    static func folder() -> String {
        let path = FilePath.combine(NSTemporaryDirectory(), "ftx-graphics-tests", UUID().uuidString.prefix(8).lowercased())
        try! FileManager.default.createDirectoryIfNeeded(path)
        return path
    }

    /// Converts `input` with `converter` to `to`, writing next to the input as `{name}` (or `name`).
    @discardableResult
    static func convert(_ converter: Converter, _ input: String, to: String, preset: Preset = Preset(), name: String? = nil,
                        from: String? = nil) async throws -> [String] {
        var preset = preset
        preset.targetFormat = to
        let folder = FilePath.directoryName(input)!
        let output = GraphicsTestOutput(folder: folder, name: name ?? FormatRegistry.nameWithoutExtension(input))
        let work = FilePath.combine(folder, ".work-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectoryIfNeeded(work)
        defer { FileManager.default.removeIfPresent(work) }
        let step = ConversionStep(inputPath: input, from: from ?? FormatRegistry.detect(input)!.id, to: to, preset: preset, output: output,
                                  workDirectory: work)
        return try await converter.convert(step, progress: nil)
    }

    /// A `width` × `height` gradient (#7F77DD → #1D9E75, top to bottom) with a fully transparent 40 × 40 top-left corner,
    /// written in the format of the file's extension.
    @discardableResult
    static func makeImage(_ folder: String, _ name: String, width: Int = 320, height: Int = 200) throws -> String {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let t = height > 1 ? Double(y) / Double(height - 1) : 0
            let rgb = [0x7F + (0x1D - 0x7F) * t, 0x77 + (0x9E - 0x77) * t, 0xDD + (0x75 - 0xDD) * t]
            for x in 0..<width where !(x < 40 && y < 40) {
                let i = (y * width + x) * 4
                for c in 0..<3 { pixels[i + c] = UInt8(rgb[c].rounded()) }
                pixels[i + 3] = 255
            }
        }
        let image = ImagePixels.make(pixels, width, height, components: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true,
                                     premultiplied: false)
        let path = FilePath.combine(folder, name)
        let format = FormatRegistry.detect(path)!.id
        var frame = ImageFrame(image: image)
        if format == "jpg" || format == "ppm" { frame.image = ImagePixels.flattened(image, background: (255, 255, 255)) }
        let kind = format == "ppm" ? String(FilePath.extension(path).dropFirst()) : format
        try ImageEncoder.save([frame], to: path, format: kind)
        return path
    }

    /// A solid colour picture.
    static func solid(_ width: Int, _ height: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height { (pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]) = rgba }
        return ImagePixels.make(pixels, width, height, components: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: rgba.3 != 255,
                                premultiplied: false)
    }

    /// A multi-page TIFF "pages.tiff" of 120 × 80 pages, coral and teal in turn.
    @discardableResult
    static func makeMultiPageTiff(_ folder: String, _ pages: Int) throws -> String {
        let frames = (0..<pages).map { ImageFrame(image: solid(120, 80, $0 % 2 == 0 ? (0xFF, 0x7F, 0x50, 255) : (0x00, 0x80, 0x80, 255))) }
        let path = FilePath.combine(folder, "pages.tiff")
        try ImageEncoder.save(frames, to: path, format: "tiff")
        return path
    }

    // ───────────────────────── Reading results ─────────────────────────

    struct Decoded {
        let type: String
        let frames: [CGImage]
        let properties: [[CFString: Any]]
        let fileProperties: [CFString: Any]
        var width: Int { frames[0].width }
        var height: Int { frames[0].height }
    }

    static func decode(_ path: String) throws -> Decoded {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), path)
        let count = CGImageSourceGetCount(source)
        XCTAssertGreaterThan(count, 0, path)
        return Decoded(type: CGImageSourceGetType(source) as String? ?? "",
                       frames: (0..<count).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) },
                       properties: (0..<count).map { CGImageSourceCopyPropertiesAtIndex(source, $0, nil) as? [CFString: Any] ?? [:] },
                       fileProperties: CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:])
    }

    /// Straight RGBA of one pixel (x, y from the top left), in sRGB.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let bitmap = ImagePixels.bitmap(image)
        let i = (y * bitmap.width + x) * 4
        let a = Int(bitmap.pixels[i + 3])
        func straight(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, (Int(v) * 255 + a / 2) / a) }
        return (straight(bitmap.pixels[i]), straight(bitmap.pixels[i + 1]), straight(bitmap.pixels[i + 2]), a)
    }

    /// Mean squared error based PSNR of two same-sized pictures over RGBA (∞ when identical).
    static func psnr(_ a: CGImage, _ b: CGImage) -> Double {
        let x = ImagePixels.bitmap(a), y = ImagePixels.bitmap(b)
        guard x.width == y.width, x.height == y.height else { return 0 }
        var sum = 0.0
        for i in 0..<x.pixels.count { let d = Double(x.pixels[i]) - Double(y.pixels[i]); sum += d * d }
        let mse = sum / Double(x.pixels.count)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }
}
