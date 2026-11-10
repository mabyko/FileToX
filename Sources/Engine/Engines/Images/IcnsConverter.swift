// Port of Filee.Engines/Icns/IcnsConverter.cs: macOS icons (.icns) written from any raster image and read back, built
// in. The container is handled by IcnsFile; ImageIO decodes the PNG and JPEG 2000 entries and encodes the PNG ones.

import CoreGraphics
import Foundation
import ImageIO

/// Raster image → ICNS and ICNS → raster image.
final class IcnsConverter: Converter {
    let id = "icns"
    let displayName = "ICNS (built-in)"
    let maxParallelism = 0

    let edges: [ConversionEdge] = ImageEncoder.sources.map { ConversionEdge($0, "icns") } + ImageEncoder.writable.map { ConversionEdge("icns", $0) }

    func status() -> EngineStatus { .available(version: EngineVersions.builtIn) }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        step.from == "icns" ? try readIcon(step, progress) : try writeIcon(step, progress)
    }

    /// Makes an icon with every size iconutil produces (16 to 1024 px, PNG encoded). The picture is centred on a
    /// transparent square first, so nothing is stretched or cut off.
    private func writeIcon(_ step: ConversionStep, _ progress: ProgressHandler?) throws -> [String] {
        let images = try ImageReader.read(step.inputPath, format: step.from, preset: step.preset)
        // An icon holds one picture: the first page/frame, or the largest icon of an .ico.
        var master = try ImageEncoder.applyOptions(ImageEncoder.selectFrames(images, sourceFormat: step.from, targetFormat: "icns")[0],
                                                   step.preset.image, targetFormat: "icns")
        master.image = Self.makeSquare(master.image)
        progress?(0.2)

        var entries: [IcnsEntry] = []
        var encoded: [Int: [UInt8]] = [:]
        for (type, size) in IcnsFile.writtenTypes {
            try Task.checkCancellation()
            if encoded[size] == nil {
                // Lanczos to the exact size; no metadata (EXIF/XMP/ICC would be repeated in all ten entries).
                let icon = ImagePixels.untagged(ImagePixels.resized(master.image, width: size, height: size, filter: .lanczos))
                encoded[size] = try Self.png32(icon)
            }
            entries.append(IcnsEntry(type: type, data: encoded[size]!))
            progress?(0.2 + 0.7 * Double(entries.count) / Double(IcnsFile.writtenTypes.count))
        }

        guard let path = try step.output.allocate("icns") else { return [] }
        try FileManager.default.writeFile(path, Data(IcnsFile.write(entries)))
        progress?(1)
        return [path]
    }

    /// Converts the largest image of an .icns file to `step.to`.
    private func readIcon(_ step: ConversionStep, _ progress: ProgressHandler?) throws -> [String] {
        let entries = try IcnsFile.parse([UInt8](try Data(contentsOf: URL(fileURLWithPath: step.inputPath))))
        let candidates = IcnsFile.candidates(entries)
        if candidates.isEmpty {
            throw ConversionError("The ICNS file contains no image Filee can read (only 1-bit or 8-bit palette icons).")
        }
        progress?(0.2)

        let image = try ImageEncoder.applyOptions(try Self.decodeLargest(candidates), step.preset.image, targetFormat: step.to)
        progress?(0.7)
        let written = try ImageEncoder.write([image], targetFormat: step.to, output: step.output, options: step.preset.image)
        progress?(1)
        return written
    }

    /// Decodes the largest image; a broken entry falls back to the next smaller one.
    private static func decodeLargest(_ candidates: [IcnsFile.Candidate]) throws -> ImageFrame {
        for candidate in candidates {
            try Task.checkCancellation()
            if let encoded = candidate.encoded {
                if let source = CGImageSourceCreateWithData(Data(encoded) as CFData, nil), CGImageSourceGetCount(source) > 0,
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    return ImageFrame(image: image)
                }
            } else if let bitmap = candidate.decode?(), bitmap.width > 0 {
                return ImageFrame(image: ImagePixels.make(bitmap.rgba, bitmap.width, bitmap.height, components: 4,
                                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true, premultiplied: false))
            }
        }
        throw ConversionError("No image in the ICNS file could be decoded.")
    }

    /// Pads the shorter side with transparency so the picture becomes a centred square, with an alpha channel.
    private static func makeSquare(_ image: CGImage) -> CGImage {
        let side = max(image.width, image.height)
        return image.width == image.height && ImagePixels.hasAlpha(image) ? image : ImagePixels.padded(image, side: side)
    }

    /// 8-bit RGBA PNG (ImageMagick's PNG32), also for grayscale pictures.
    private static func png32(_ image: CGImage) throws -> [UInt8] {
        // Straight samples (premultiplying would round semi-transparent pixels); gray is spread over R, G and B.
        let (samples, channels, space) = ImagePixels.straight(image)
        let colors = ImagePixels.hasAlpha(image) ? channels - 1 : channels
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for i in 0..<image.width * image.height {
            for c in 0..<3 { rgba[i * 4 + c] = samples[i * channels + (colors == 1 ? 0 : c)] }
            if colors < channels { rgba[i * 4 + 3] = samples[i * channels + colors] }
        }
        let rgbSpace = colors == 1 ? CGColorSpace(name: CGColorSpace.sRGB)! : space
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ConversionError("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(destination, ImagePixels.make(rgba, image.width, image.height, components: 4, space: rgbSpace, alpha: true,
                                                                 premultiplied: false), nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError("Could not encode the icon as PNG.") }
        return [UInt8](data as Data)
    }
}
