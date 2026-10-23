// Port of Filee.Engines/Magick/MagickImageConverter.cs: raster image ↔ raster image conversion. ImageMagick is replaced
// by ImageIO (decoding, and encoding where this Mac can), libwebp / libjxl and Swift codecs (Netpbm, PSD/PSB, XCF).

import CoreGraphics
import Foundation
import ImageIO

/// Converts between PNG, JPG, WEBP, TIFF, BMP, GIF, ICO, AVIF, JPEG XL, JPEG 2000, PSD/PSB, TGA and PPM, and reads HEIC,
/// XCF and camera RAW. Engine id "magick" is kept from Filee (settings refer to it).
final class MagickImageConverter: Converter, TiffMerger {
    let id = "magick"
    let displayName = "Images (built-in)"
    let maxParallelism = 0

    let edges: [ConversionEdge] = ImageEncoder.sources.flatMap { source in ImageEncoder.writable.map { ConversionEdge(source, $0) } }

    func status() -> EngineStatus {
        .available(version: "\(EngineVersions.system("ImageIO")) · libwebp \(CodecLibraries.webpVersion) · libjxl \(CodecLibraries.jxlVersion)")
    }

    /// Writes the pages into one multi-page TIFF. Each page is flattened onto the preset's background (no alpha) at 8 bits
    /// and marked as a page of a multi-page document (SubfileType 2), so older viewers (Microsoft Office Document
    /// Imaging, fax software) show it page by page; compression is the preset's.
    func merge(_ inputPaths: [String], into outputPath: String, options: ImageOptions) async throws {
        let compression = switch options.tiffCompression { case .lzw: 5; case .zip: 8; case .none: 1 }
        let background = ImagePixels.parseColor(options.background.allSatisfy(\.isWhitespace) ? "#FFFFFF" : options.background)
        var pages: [ImageFrame] = []
        for path in inputPaths {
            try Task.checkCancellation()
            for frame in try ImageReader.read(path, format: FormatRegistry.detect(path)?.id ?? "tiff", preset: Preset()) {
                var page = frame
                // Flattened (or redrawn) as 8-bit pixels.
                page.image = ImagePixels.hasAlpha(page.image) ? ImagePixels.flattened(page.image, background: background)
                    : ImagePixels.image(ImagePixels.bitmap(page.image))
                page.properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: compression]
                pages.append(page)
            }
        }
        try ImageEncoder.save(pages, to: outputPath, format: "tiff")
        try TiffPages.markAsPages(outputPath)
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        let images = try ImageReader.read(step.inputPath, format: step.from, preset: step.preset)
        try Task.checkCancellation()
        progress?(0.3)

        var frames = ImageEncoder.selectFrames(images, sourceFormat: step.from, targetFormat: step.to)
        for i in frames.indices {
            try Task.checkCancellation()
            frames[i] = try ImageEncoder.applyOptions(frames[i], step.preset.image, targetFormat: step.to)
        }
        progress?(0.7)

        let written = try ImageEncoder.write(frames, targetFormat: step.to, output: step.output, options: step.preset.image,
                                             sourcePath: step.inputPath, animation: ImageEncoder.keepsAnimation(step.from, step.to))
        progress?(1)
        return written
    }
}

/// Marks every image of a TIFF as a page of a multi-page document (NewSubfileType = 2), which ImageIO can't set: an IFD
/// without the tag is copied to the end of the file with it added, and the pointer to the IFD is moved there.
enum TiffPages {
    static func markAsPages(_ path: String) throws {
        var bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard bytes.count >= 8 else { return }
        let little = bytes[0] == 0x49
        guard (little && bytes[1] == 0x49 || !little && bytes[0] == 0x4D && bytes[1] == 0x4D) else { return }
        func u16(_ at: Int) -> Int { little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) -> Int { little ? u16(at) | u16(at + 2) << 16 : u16(at) << 16 | u16(at + 2) }
        func put16(_ value: Int, _ out: inout [UInt8]) {
            out += little ? [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] : [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func put32(_ value: Int, _ out: inout [UInt8]) {
            if little { put16(value & 0xFFFF, &out); put16(value >> 16 & 0xFFFF, &out) } else { put16(value >> 16 & 0xFFFF, &out); put16(value & 0xFFFF, &out) }
        }
        func set32(_ value: Int, at: Int) {
            var patch: [UInt8] = []
            put32(value, &patch)
            bytes.replaceSubrange(at..<at + 4, with: patch)
        }
        guard u16(2) == 42 else { return } // classic TIFF only

        var pointerAt = 4
        var seen = Set<Int>()
        while true {
            let ifd = u32(pointerAt)
            guard ifd > 0, ifd + 2 <= bytes.count, seen.insert(ifd).inserted else { break }
            let count = u16(ifd)
            guard ifd + 2 + count * 12 + 4 <= bytes.count else { break }
            let entries = (0..<count).map { Array(bytes[ifd + 2 + $0 * 12..<ifd + 14 + $0 * 12]) }
            let next = u32(ifd + 2 + count * 12)
            if let existing = entries.firstIndex(where: { u16At($0, little) == 254 }) {
                // LONG value 2 in place.
                let at = ifd + 2 + existing * 12
                bytes.replaceSubrange(at + 2..<at + 4, with: little ? [4, 0] : [0, 4])
                set32(1, at: at + 4)
                set32(2, at: at + 8)
                pointerAt = ifd + 2 + count * 12
                continue
            }
            var tag: [UInt8] = []
            put16(254, &tag); put16(4, &tag); put32(1, &tag); put32(2, &tag)
            var all = entries + [tag]
            all.sort { u16At($0, little) < u16At($1, little) }
            if bytes.count % 2 == 1 { bytes.append(0) }
            let moved = bytes.count
            var block: [UInt8] = []
            put16(all.count, &block)
            for entry in all { block += entry }
            put32(next, &block)
            bytes += block
            set32(moved, at: pointerAt)
            pointerAt = moved + 2 + all.count * 12
        }
        try FileManager.default.writeFile(path, Data(bytes))
    }

    private static func u16At(_ entry: [UInt8], _ little: Bool) -> Int {
        little ? Int(entry[0]) | Int(entry[1]) << 8 : Int(entry[0]) << 8 | Int(entry[1])
    }
}
