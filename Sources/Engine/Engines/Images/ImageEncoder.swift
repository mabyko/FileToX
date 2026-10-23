// Port of Filee.Engines/Magick/ImageEncoder.cs: applies preset ImageOptions and writes frames in the requested format.
// Used by MagickImageConverter and by every engine that writes raster images (PDF pages, SVG, CAD, ICNS, Ghostscript).
// ImageMagick is replaced by ImageIO for the formats this Mac encodes, and by Swift codecs for Netpbm and PSD/PSB.

import CoreGraphics
import Foundation
import ImageIO

/// One frame (page, animation frame, icon size) of a raster image: pixels plus what ImageMagick kept beside them.
struct ImageFrame {
    var image: CGImage
    /// Seconds the frame is shown (animations).
    var delay: Double? = nil
    /// Pixels per inch stored in the file; nil when the file has none (Filee then assumes 96 for PDF pages).
    var dpi: (x: Double, y: Double)? = nil
    /// ImageIO destination properties used when the frame is written: EXIF orientation, lossy quality, TIFF
    /// compression … plus the frame's metadata (`ImageFrame.metadataKey`) and the encoder settings of `applyOptions`.
    var properties: [CFString: Any] = [:]

    /// EXIF, XMP, IPTC and GPS of the frame as a `CGImageMetadata` (ImageMagick's profiles other than ICC).
    static let metadataKey = "FileToXMetadata" as CFString
    /// Loop count of an animation (0 = forever).
    static let loopCountKey = "FileToXLoopCount" as CFString
    /// Icon sizes of an ICO target, largest first (ImageMagick's icon:auto-resize).
    static let icoSizesKey = "FileToXIcoSizes" as CFString
    /// Lossless WebP requested (`ImageOptions.webpLossless`).
    static let losslessKey = "FileToXLossless" as CFString
    /// Preset quality 1…100 for the WebP and JPEG XL encoders (ImageMagick's `image.Quality`).
    static let qualityKey = "FileToXQuality" as CFString
}

enum ImageEncoder {
    /// Image formats read as input (see `ImageReader` for RAW, layered sources and Netpbm). Camera RAW, XCF and HEIC are
    /// read only. EMF/WMF (Filee's Windows-only metafiles) are not offered on macOS.
    static let readable: [String] = ["png", "jpg", "webp", "tiff", "bmp", "gif", "ico", "avif", "heic", "jxl", "jp2", "psd", "psb",
                                     "tga", "ppm", "xcf", "raw"].filter(canRead)

    /// Image formats written. HEIC is left out like in Filee (AVIF is offered instead). WebP and JPEG XL are encoded by
    /// libwebp / libjxl; AVIF, JPEG 2000, ICO and TGA follow what this Mac's ImageIO can encode.
    static let writable: [String] = ["png", "jpg", "webp", "tiff", "bmp", "gif", "ico", "avif", "jxl", "jp2", "psd", "psb", "tga", "ppm"]
        .filter(canWrite)

    /// Every format read as input (Filee adds EMF/WMF on Windows only).
    static var sources: [String] { readable }

    /// Formats that store several frames/pages in one file.
    private static let multiFrame: Set<String> = ["tiff", "gif"]

    /// Formats whose frames are an animation. Between these, all frames are kept with their timing (an animated GIF
    /// becomes an animated WebP and the other way round); any other target gets the first frame.
    private static let animated: Set<String> = ["gif", "webp"]

    /// Formats without an alpha channel: transparent pixels are flattened onto the background colour.
    private static let noAlpha: Set<String> = ["jpg", "ppm"]

    /// Uniform types of the formats ImageIO reads and writes.
    static let typeIdentifiers: [String: String] = [
        "png": "public.png", "jpg": "public.jpeg", "webp": "org.webmproject.webp", "tiff": "public.tiff", "bmp": "com.microsoft.bmp",
        "gif": "com.compuserve.gif", "ico": "com.microsoft.ico", "avif": "public.avif", "heic": "public.heic", "jxl": "public.jpeg-xl",
        "jp2": "public.jpeg-2000", "psd": "com.adobe.photoshop-image", "psb": "com.adobe.photoshop-image", "tga": "com.truevision.tga-image",
        "raw": "com.adobe.raw-image",
    ]

    private static let imageIOReads = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    private static let imageIOWrites = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    private static func canRead(_ format: String) -> Bool {
        ["ppm", "xcf"].contains(format) || typeIdentifiers[format].map(imageIOReads.contains) == true
    }

    private static func canWrite(_ format: String) -> Bool {
        switch format {
        case "ppm", "psd", "psb", "webp", "jxl": true
        default: typeIdentifiers[format].map(imageIOWrites.contains) == true
        }
    }

    /// True when frames of `sourceFormat` are written as one animation in `targetFormat`.
    static func keepsAnimation(_ sourceFormat: String, _ targetFormat: String) -> Bool {
        animated.contains(sourceFormat) && animated.contains(targetFormat)
    }

    /// Encoder format and file extension for writing `targetFormat`. The "ppm" format covers the Netpbm family: a
    /// grayscale result, or a .pgm/.pbm source kept as such, is written as PGM/PBM with its own extension.
    /// - Parameter sourcePath: input file of the step, used to keep the Netpbm sub-format of .pgm/.pbm sources.
    static func outputFormat(_ targetFormat: String, _ options: ImageOptions, sourcePath: String? = nil) -> (format: String, extension: String) {
        guard targetFormat == "ppm" else { return (targetFormat, targetFormat) }
        let sourceExtension = sourcePath.map { String(FilePath.extension($0).drop { $0 == "." }).lowercased() } ?? ""
        switch sourceExtension {
        case "pbm": return ("pbm", "pbm")
        case "pgm": return ("pgm", "pgm")
        default: return options.grayscale ? ("pgm", "pgm") : ("ppm", "ppm")
        }
    }

    /// Chooses which frames of a (possibly multi-frame) source are converted. ICO: the largest icon. Animated
    /// GIF/WebP: every frame for a GIF/WebP/TIFF target, else the first frame. PSD/PSB: the composite. Otherwise: all
    /// frames/pages. (ImageIO hands out animation frames already coalesced into full images.)
    static func selectFrames(_ frames: [ImageFrame], sourceFormat: String, targetFormat: String) -> [ImageFrame] {
        guard frames.count > 1 else { return frames }
        if sourceFormat == "psd" || sourceFormat == "psb" { return [frames[0]] }
        if sourceFormat == "ico" {
            // OrderByDescending is stable: the first of equally large icons wins.
            var best = frames[0]
            for frame in frames.dropFirst() where frame.image.width * frame.image.height > best.image.width * best.image.height { best = frame }
            return [best]
        }
        if animated.contains(sourceFormat) && !multiFrame.contains(targetFormat) && !keepsAnimation(sourceFormat, targetFormat) {
            return [frames[0]]
        }
        return frames
    }

    /// Applies resize / colour / metadata options to one frame and records the target's encoder settings.
    static func applyOptions(_ frame: ImageFrame, _ options: ImageOptions, targetFormat: String) throws -> ImageFrame {
        var frame = frame
        try Task.checkCancellation()
        if let orientation = (frame.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            frame.image = ImagePixels.oriented(frame.image, orientation)
            setOrientation(&frame, 1)
        }

        let (width, height) = (frame.image.width, frame.image.height)
        switch options.resize {
        case .percent where options.resizePercent > 0 && options.resizePercent != 100:
            let scale = Double(options.resizePercent) / 100
            frame.image = ImagePixels.resized(frame.image, width: max(1, Int((Double(width) * scale + 0.5).rounded(.down))),
                                              height: max(1, Int((Double(height) * scale + 0.5).rounded(.down))))
        case .longEdge where options.longEdge > 0 && (width > options.longEdge || height > options.longEdge):
            // Only shrink images larger than the box, never upscale (ImageMagick's ">" geometry).
            let scale = min(Double(options.longEdge) / Double(width), Double(options.longEdge) / Double(height))
            frame.image = ImagePixels.resized(frame.image, width: max(1, Int((Double(width) * scale + 0.5).rounded(.down))),
                                              height: max(1, Int((Double(height) * scale + 0.5).rounded(.down))))
        default:
            break
        }

        if options.grayscale { frame.image = ImagePixels.grayscale(frame.image) }

        if let dpi = options.dpi, dpi > 0 { frame.dpi = (Double(dpi), Double(dpi)) }

        if !options.keepMetadata {
            frame.properties[ImageFrame.metadataKey] = nil
            if !options.keepColorProfile { frame.image = ImagePixels.untagged(frame.image) }
        }

        if noAlpha.contains(targetFormat) && ImagePixels.hasAlpha(frame.image) {
            frame.image = ImagePixels.flattened(frame.image, background: ImagePixels.parseColor(options.background))
        }

        let quality = min(max(options.quality, 1), 100)
        switch targetFormat {
        case "jpg":
            frame.properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality(quality)
        case "avif":
            // ImageIO's AVIF encoder rejects 1.0.
            frame.properties[kCGImageDestinationLossyCompressionQuality] = min(Double(quality) / 100, 0.99)
        case "jxl":
            // 100 means lossless (JPEG XL distance 0).
            frame.properties[ImageFrame.qualityKey] = quality
        case "jp2":
            // 100 means lossless (ImageIO's reversible wavelet at quality 1).
            frame.properties[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100
        case "webp":
            frame.properties[ImageFrame.qualityKey] = quality
            if options.webpLossless { frame.properties[ImageFrame.losslessKey] = true }
        case "tiff":
            let compression = switch options.tiffCompression { case .lzw: 5; case .zip: 8; case .none: 1 }
            var tiff = frame.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = compression
            frame.properties[kCGImagePropertyTIFFDictionary] = tiff
        case "ico":
            prepareIcon(&frame, options)
        default:
            break
        }
        return frame
    }

    /// Writes frames using the allocator. Multi-frame targets (and animations, see `keepsAnimation`) get one file;
    /// other targets get one file per frame with a `_p{n}` suffix when there is more than one frame.
    /// - Parameters:
    ///   - options: options of the preset (the Netpbm sub-format depends on them).
    ///   - sourcePath: input file of the step, see `outputFormat`.
    ///   - animation: the frames are an animation: write them into one file even for a WebP target.
    static func write(_ frames: [ImageFrame], targetFormat: String, output: OutputAllocator, options: ImageOptions = ImageOptions(),
                      sourcePath: String? = nil, animation: Bool = false) throws -> [String] {
        let (format, ext) = outputFormat(targetFormat, options, sourcePath: sourcePath)
        if frames.count > 1 && (multiFrame.contains(targetFormat) || animation) {
            guard let path = try output.allocate(ext) else { return [] }
            try save(frames, to: path, format: format)
            return [path]
        }
        var written: [String] = []
        for (i, frame) in frames.enumerated() {
            guard let path = try output.allocate(ext, suffix: frames.count > 1 ? "_p\(i + 1)" : nil) else { continue }
            try save([frame], to: path, format: format)
            written.append(path)
        }
        return written
    }

    /// Writes the frames into one file of `format` (an id of `writable`, or "pgm"/"pbm"): ImageMagick's
    /// `image.Write(path, format)` and `collection.Write(path, format)`.
    static func save(_ frames: [ImageFrame], to path: String, format: String) throws {
        guard let first = frames.first else { throw ConversionError("There is no image to write.") }
        switch format {
        case "ppm", "pgm", "pbm":
            try NetpbmCodec.write(first, to: path, kind: format)
        case "psd", "psb":
            try PsdCodec.write(first, to: path, large: format == "psb")
        case "ico":
            try writeIcon(first, to: path)
        case "webp":
            try WebpEncoder.write(frames, to: path, animation: frames.count > 1)
        case "jxl":
            try JpegXlEncoder.write(first, to: path)
        default:
            try writeImageIO(frames, to: path, format: format)
        }
    }

    // ───────────────────────── ImageIO ─────────────────────────

    private static func writeImageIO(_ frames: [ImageFrame], to path: String, format: String) throws {
        guard let type = typeIdentifiers[format], imageIOWrites.contains(type) else {
            throw ConversionError("Images cannot be written as '\(format)' on this Mac.")
        }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames.count, nil) else {
            throw ConversionError("Could not create the \(format.uppercased()) file \(FilePath.fileName(path)).")
        }
        if format == "gif", frames.count > 1 {
            let loops = (frames[0].properties[ImageFrame.loopCountKey] as? NSNumber)?.intValue ?? 0
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]] as CFDictionary)
        }
        for frame in frames {
            var properties = frame.properties.filter { !privateKeys.contains($0.key) }
            if let dpi = frame.dpi, dpi.x > 0, dpi.y > 0 {
                properties[kCGImagePropertyDPIWidth] = dpi.x
                properties[kCGImagePropertyDPIHeight] = dpi.y
            }
            if format == "gif" {
                properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: frame.delay ?? 0, kCGImagePropertyGIFUnclampedDelayTime: frame.delay ?? 0]
            }
            if format == "tga" {
                // ImageMagick writes uncompressed TGA.
                properties["{TGA}" as CFString] = ["Compression": 0]
            }
            if format != "tiff" { properties[kCGImagePropertyTIFFDictionary] = nil }
            if let metadata = frame.properties[ImageFrame.metadataKey], CFGetTypeID(metadata as CFTypeRef) == CGImageMetadataGetTypeID() {
                CGImageDestinationAddImageAndMetadata(destination, frame.image, encoderMetadata(metadata as! CGImageMetadata, frame.dpi),
                                                      properties as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            FileManager.default.removeIfPresent(path)
            throw ConversionError("Could not write \(FilePath.fileName(path)) as \(format.uppercased()).")
        }
    }

    /// The frame's metadata without the source's file structure (compression, sample layout, tiles), which would
    /// override the encoder's, and with the frame's resolution.
    private static func encoderMetadata(_ metadata: CGImageMetadata, _ dpi: (x: Double, y: Double)?) -> CGImageMetadata {
        guard let copy = CGImageMetadataCreateMutableCopy(metadata) else { return metadata }
        for tag in ["Compression", "PhotometricInterpretation", "BitsPerSample", "SamplesPerPixel", "PlanarConfiguration", "TileWidth",
                    "TileLength", "ImageWidth", "ImageLength"] {
            CGImageMetadataRemoveTagWithPath(copy, nil, "tiff:\(tag)" as CFString)
        }
        if let dpi, dpi.x > 0, dpi.y > 0 {
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFXResolution, dpi.x as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFYResolution, dpi.y as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFResolutionUnit, 2 as CFNumber)
        }
        return copy
    }

    private static let privateKeys: Set<CFString> = [ImageFrame.metadataKey, ImageFrame.loopCountKey, ImageFrame.icoSizesKey, ImageFrame.losslessKey,
                                                     ImageFrame.qualityKey]

    /// Sets the EXIF orientation of the frame and of its metadata.
    private static func setOrientation(_ frame: inout ImageFrame, _ orientation: Int) {
        frame.properties[kCGImagePropertyOrientation] = orientation
        if let metadata = frame.properties[ImageFrame.metadataKey], CFGetTypeID(metadata as CFTypeRef) == CGImageMetadataGetTypeID(),
           let copy = CGImageMetadataCreateMutableCopy(metadata as! CGImageMetadata) {
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            frame.properties[ImageFrame.metadataKey] = copy
        }
    }

    /// ImageIO quality (0…1) that gives about the IJG/ImageMagick JPEG quality `quality` (1…100): ImageIO's own
    /// scale is far steeper (0.65 is IJG 90). Measured from the quantization tables ImageIO writes.
    /// shortcut: one table for every macOS; re-measure if Apple changes its JPEG encoder.
    static func jpegQuality(_ quality: Int) -> Double {
        jpegQualities[min(max(quality, 1), 100) - 1]
    }

    private static let jpegQualities: [Double] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0875, 0.125, 0.15, 0.165, 0.1825, 0.195,
        0.2075, 0.215, 0.225, 0.235, 0.24, 0.25, 0.255, 0.2625, 0.2625, 0.27, 0.28, 0.2875, 0.29, 0.2975, 0.3, 0.3075, 0.31, 0.315,
        0.3175, 0.3225, 0.325, 0.33, 0.335, 0.3375, 0.345, 0.35, 0.3525, 0.3525, 0.36, 0.3675, 0.3725, 0.3775, 0.3825, 0.39, 0.395,
        0.4, 0.405, 0.41, 0.4175, 0.4225, 0.4325, 0.44, 0.445, 0.4525, 0.46, 0.4675, 0.4775, 0.485, 0.49, 0.505, 0.515, 0.5275,
        0.5375, 0.55, 0.5625, 0.58, 0.595, 0.6125, 0.6325, 0.65, 0.68, 0.7, 0.735, 0.7775, 0.8225, 0.885, 0.975, 0.975, 0.995, 1,
    ]

    // ───────────────────────── ICO ─────────────────────────

    /// Icons must be square: pads the shorter side with transparency; every requested size is written into one .ico.
    private static func prepareIcon(_ frame: inout ImageFrame, _ options: ImageOptions) {
        var side = max(frame.image.width, frame.image.height)
        if frame.image.width != frame.image.height { frame.image = ImagePixels.padded(frame.image, side: side) }
        if side > 256 {
            frame.image = ImagePixels.resized(frame.image, width: 256, height: 256)
            side = 256
        }
        var sizes: [Int] = []
        for size in options.icoSizes.sorted(by: >) where size > 0 && size <= 256 && !sizes.contains(size) { sizes.append(size) }
        frame.properties[ImageFrame.icoSizesKey] = sizes.isEmpty ? [256, 48, 32, 16] : sizes
    }

    /// One icon per size (ImageMagick's icon:auto-resize), written by ImageIO as 32-bit BMP entries like ImageMagick.
    private static func writeIcon(_ frame: ImageFrame, to path: String) throws {
        var square = frame
        if square.properties[ImageFrame.icoSizesKey] == nil { prepareIcon(&square, ImageOptions()) }
        let sizes = square.properties[ImageFrame.icoSizesKey] as? [Int] ?? [256, 48, 32, 16]
        let icons = sizes.map { size in
            ImageFrame(image: ImagePixels.resized(square.image, width: size, height: size))
        }
        try writeImageIO(icons, to: path, format: "ico")
    }
}
