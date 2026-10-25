// Port of Filee.Engines/Magick/ImageEncoder.cs: applies preset ImageOptions and writes frames in the requested format.
// Used by MagickImageConverter and by every engine that writes raster images (PDF pages, SVG, CAD, ICNS, Ghostscript).
// ImageMagick is replaced by ImageIO for the formats this Mac encodes, libjpeg-turbo set up like ImageMagick for JPEG,
// libwebp / libjxl for WebP and JPEG XL, OpenJPEG for lossy JP2 codestreams, Swift codecs for Netpbm and PSD/PSB,
// and ImageMagick's resize ported to Swift.

import CoreGraphics
import Foundation
import ImageIO
import zlib

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
    /// ImageMagick storage class used for ICO filter choice; grayscale alone does not imply a palette.
    static let icoPaletteKey = "FileToXIcoPalette" as CFString
    /// Icon sizes of an ICO target, largest first (ImageMagick's icon:auto-resize).
    static let icoSizesKey = "FileToXIcoSizes" as CFString
    /// Lossless WebP requested (`ImageOptions.webpLossless`).
    static let losslessKey = "FileToXLossless" as CFString
    /// Preset quality 1…100 for the JPEG, JP2, WebP and JPEG XL encoders (ImageMagick's `image.Quality`).
    static let qualityKey = "FileToXQuality" as CFString
    /// Sampling factors of a JPEG source, [h, v] per component (ImageMagick's "jpeg:sampling-factor" property).
    static let jpegSamplingKey = "FileToXJpegSampling" as CFString
    /// Opaque JPEG COM and Photoshop APP13 marker segments, removed by keepMetadata=false.
    static let jpegMarkersKey = "FileToXJpegMarkers" as CFString
    /// The source's Photoshop metadata resource blocks (IPTC, its digest, caption, copyright flag, URL) as stored
    /// (`PsdCodec.metadataResources`), written into PSD/PSB, and for sources other than JPEG (whose own marker segments
    /// are kept) into JPEG APP13 and PNG's raw profile; removed by keepMetadata=false.
    static let photoshopKey = "FileToXPhotoshop" as CFString
    /// Exact ICC bytes of the embedded profile ImageIO decoded the frame with (JPEG APP2, PNG iCCP, `EmbeddedProfiles`
    /// for TIFF, PSD/PSB, WebP, GIF, HEIF/AVIF, JPEG XL and JPEG 2000); empty when it used its untagged default. Absent
    /// for other sources, for colour ImageIO took from elsewhere and once the samples leave that colour space: the
    /// profile is then inferred from the image's current space.
    static let iccKey = "FileToXICC" as CFString
    /// Resolution as the file stored it, [x, y, unit] with unit 1 = per inch, 2 = per centimetre (ImageMagick's
    /// `resolution` and `units`, which the JPEG writer copies into JFIF). `dpi` holds the same in inches.
    static let resolutionKey = "FileToXResolution" as CFString
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
        let decodedSpace = frame.image.colorSpace
        try Task.checkCancellation()
        if let orientation = (frame.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            frame.image = ImagePixels.oriented(frame.image, orientation)
            setOrientation(&frame, 1)
        }

        let (width, height) = (frame.image.width, frame.image.height)
        let model = frame.image.colorSpace?.model
        var palette = frame.properties[ImageFrame.icoPaletteKey] as? Bool ?? (model == .indexed || model == .monochrome)
        switch options.resize {
        case .percent where options.resizePercent > 0 && options.resizePercent != 100:
            // ParseMetaGeometry of "N%".
            let percent = Double(options.resizePercent)
            frame.image = ImagePixels.resized(frame.image, width: max(1, Int(percent * Double(width) / 100.0 + 0.5)),
                                              height: max(1, Int(percent * Double(height) / 100.0 + 0.5)), palette: palette)
        case .longEdge where options.longEdge > 0 && (width > options.longEdge || height > options.longEdge):
            // Only shrink images larger than the box, never upscale (ImageMagick's ">" geometry).
            let scale = min(Double(options.longEdge) / Double(width), Double(options.longEdge) / Double(height))
            frame.image = ImagePixels.resized(frame.image, width: max(1, Int((Double(width) * scale + 0.5).rounded(.down))),
                                              height: max(1, Int((Double(height) * scale + 0.5).rounded(.down))), palette: palette)
        default:
            break
        }

        if (frame.image.width, frame.image.height) != (width, height) { palette = false }
        if options.grayscale {
            frame.image = ImagePixels.grayscale(frame.image)
            palette = false // GrayscaleImage promotes PseudoClass to DirectClass.
        }

        if let dpi = options.dpi, dpi > 0 {
            frame.dpi = (Double(dpi), Double(dpi))
            frame.properties[ImageFrame.resolutionKey] = nil
        }

        if !options.keepMetadata {
            frame.properties[ImageFrame.metadataKey] = nil
            frame.properties[ImageFrame.jpegMarkersKey] = nil
            frame.properties[ImageFrame.photoshopKey] = nil
            if !options.keepColorProfile {
                frame.image = ImagePixels.untagged(frame.image)
                frame.properties[ImageFrame.iccKey] = Data()
            }
        }

        if noAlpha.contains(targetFormat) && ImagePixels.hasAlpha(frame.image) {
            frame.image = ImagePixels.flattened(frame.image, background: ImagePixels.parseColor(options.background))
        }

        let quality = min(max(options.quality, 1), 100)
        switch targetFormat {
        case "jpg":
            frame.properties[ImageFrame.qualityKey] = quality
        case "avif":
            // ImageIO's AVIF encoder rejects 1.0.
            frame.properties[kCGImageDestinationLossyCompressionQuality] = min(Double(quality) / 100, 0.99)
        case "jxl":
            // 100 means lossless (JPEG XL distance 0).
            frame.properties[ImageFrame.qualityKey] = quality
        case "jp2":
            // ImageMagick uses quality as a PSNR target in dB; 100 keeps ImageIO's lossless codestream.
            frame.properties[ImageFrame.qualityKey] = quality
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
            frame.properties[ImageFrame.icoPaletteKey] = palette
            prepareIcon(&frame, options)
        default:
            break
        }
        // Source ICC bytes describe the samples only in the space they were decoded in (an indexed picture resized or
        // turned upright is sRGB now); otherwise the profile is inferred from the current space.
        if let space = frame.image.colorSpace, let decodedSpace, !CFEqual(space, decodedSpace) { frame.properties[ImageFrame.iccKey] = nil }
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
        var frames = frames
        if !["jpg", "tiff", "ico", "psd", "psb"].contains(format) {
            for i in frames.indices where frames[i].image.colorSpace?.model == .cmyk || (format == "bmp" && frames[i].image.colorSpace?.model == .indexed) {
                // RGB-only writers must not attach a CMYK ICC profile to converted RGB samples. ImageIO writes an indexed
                // picture to BMP as bare pixels without a header; drawn as sRGB, its colours match the BMP writer's own
                // conversion of RGB in the palette's colour space.
                frames[i].image = ImagePixels.image(ImagePixels.bitmap(frames[i].image))
                frames[i].properties[ImageFrame.iccKey] = nil
            }
        }
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
        case "jpg":
            try JpegEncoder.write(first, to: path)
        default:
            try writeImageIO(frames, to: path, format: format)
        }
    }

    // ───────────────────────── ImageIO ─────────────────────────

    private static func writeImageIO(_ frames: [ImageFrame], to path: String, format: String) throws {
        guard let type = typeIdentifiers[format], imageIOWrites.contains(type) else {
            throw ConversionError("Images cannot be written as '\(format)' on this Mac.")
        }
        // Encoded in memory and written with open(2), which keeps the file name as given (NFC).
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, frames.count, nil) else {
            throw ConversionError("Could not create the \(format.uppercased()) file \(FilePath.fileName(path)).")
        }
        if format == "gif", frames.count > 1 {
            let loops = (frames[0].properties[ImageFrame.loopCountKey] as? NSNumber)?.intValue ?? 0
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]] as CFDictionary)
        }
        for frame in frames {
            var image = format == "gif" ? ImagePixels.gifImage(frame.image) : frame.image
            // TGA has no ICC profile, and ImageIO otherwise writes RGB samples in their source space unchanged.
            if format == "tga", let source = image.colorSpace, [.rgb, .indexed].contains(source.model),
               let srgb = CGColorSpace(name: CGColorSpace.sRGB), !CFEqual(source.baseColorSpace ?? source, srgb) {
                let alpha: CGImageAlphaInfo = ImagePixels.hasAlpha(image) ? .premultipliedLast : .noneSkipLast
                guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: srgb, bitmapInfo: alpha.rawValue) else {
                    throw ConversionError("Could not convert the image to sRGB for TGA.")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let converted = context.makeImage() else { throw ConversionError("Could not convert the image to sRGB for TGA.") }
                image = converted
            }
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
                CGImageDestinationAddImageAndMetadata(destination, image, encoderMetadata(metadata as! CGImageMetadata, frame.dpi),
                                                      properties as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError("Could not write \(FilePath.fileName(path)) as \(format.uppercased()).")
        }
        if format == "gif", let first = frames.first, frames.count > 1, data.length >= 10 {
            // ImageMagick uses the first frame's logical screen even when subsequent
            // page rectangles are larger. ImageIO chooses their union, changing video
            // dimensions when this GIF is the intermediate of a PDF → video route.
            let size = [UInt8(first.image.width & 255), UInt8(first.image.width >> 8 & 255),
                        UInt8(first.image.height & 255), UInt8(first.image.height >> 8 & 255)]
            data.replaceBytes(in: NSRange(location: 6, length: 4), withBytes: size)
        }
        var encoded = data as Data
        // shortcut: retain ImageIO for one-pixel JP2s to avoid OpenJPEG's alpha DC loss; revisit after an upstream fix.
        if format == "jp2", let frame = frames.first, let quality = frame.properties[ImageFrame.qualityKey] as? Int,
           quality < 100, frame.image.width > 1 || frame.image.height > 1 {
            encoded = try Jpeg2000Encoder.replacingCodestream(in: encoded, image: frame.image, quality: quality)
        }
        if format == "png", let frame = frames.first { encoded = try preservingJpegMetadata(withSourceProfile(encoded, frame), frame) }
        if format == "bmp" {
            // ImageIO reports success for pictures it can't write as BMP; never hand on a file without a BMP header.
            guard isBmp(encoded) else { throw ConversionError("Could not write \(FilePath.fileName(path)) as BMP.") }
            encoded = zeroingBmpPadding(encoded)
        }
        try FileManager.default.writeFile(path, encoded)
    }

    /// A BMP header at all: the signature, the file's own length and pixel data after the smallest header.
    static func isBmp(_ data: Data) -> Bool {
        data.count >= 26 && data.starts(with: [0x42, 0x4D]) && Int(BinaryPrimitives.readUInt32LittleEndian(data, 2)) == data.count
            && (26..<data.count).contains(Int(BinaryPrimitives.readUInt32LittleEndian(data, 10)))
    }

    /// ImageIO leaves the row padding of an uncompressed 24-bit BMP uninitialized (stray memory, different every run).
    /// Zeroed only when the header describes exactly the pixel rows that end the file; anything else stays as written.
    static func zeroingBmpPadding(_ bmp: Data) -> Data {
        guard bmp.count >= 54, bmp.starts(with: [0x42, 0x4D]) else { return bmp }
        let offset = Int(BinaryPrimitives.readUInt32LittleEndian(bmp, 10)), header = Int(BinaryPrimitives.readUInt32LittleEndian(bmp, 14))
        let width = Int(BinaryPrimitives.readInt32LittleEndian(bmp, 18)), rows = abs(Int(BinaryPrimitives.readInt32LittleEndian(bmp, 22)))
        let used = width * 3, stride = (used + 3) / 4 * 4
        guard Int(BinaryPrimitives.readUInt32LittleEndian(bmp, 2)) == bmp.count, header >= 40, offset >= 14 + header, offset <= bmp.count,
              BinaryPrimitives.readUInt16LittleEndian(bmp, 26) == 1, BinaryPrimitives.readUInt16LittleEndian(bmp, 28) == 24,
              BinaryPrimitives.readUInt32LittleEndian(bmp, 30) == 0, width > 0, rows > 0, stride > used,
              (bmp.count - offset) % stride == 0, (bmp.count - offset) / stride == rows,
              // ImageIO records the unpadded size; 0 and the padded size are the other valid values.
              [0, used * rows, stride * rows].contains(Int(BinaryPrimitives.readUInt32LittleEndian(bmp, 34))) else { return bmp }
        var result = bmp
        for row in 0..<rows {
            let start = result.startIndex + offset + row * stride
            result.resetBytes(in: start + used..<start + stride)
        }
        return result
    }

    /// A PNG's valid iCCP profiles before PLTE/IDAT in file order (intact CRC, compression method 0, complete zlib
    /// stream, usable ICC), whether it declares colour with sRGB, gAMA, cHRM or cICP, and the bytes inflated to find
    /// them: no chunk is inflated once 16 MiB are (one 1 MiB inflate buffer may pass it). Nil when it is no PNG.
    static func pngProfiles(_ file: Data) -> (profiles: [Data], declared: Bool, inflated: Int)? {
        guard file.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        var i = file.startIndex + 8, declared = false, profiles: [Data] = [], inflated = 0
        while file.endIndex - i >= 12 {
            let length = file[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: file[i + 4..<i + 8], as: UTF8.self)
            guard length <= file.endIndex - i - 12, type != "PLTE", type != "IDAT" else { break }
            if type == "iCCP" && inflated <= 1 << 24 {
                let crc = file[i + 4..<i + 8 + length].withUnsafeBytes { zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                let payload = file[i + 8..<i + 8 + length]
                if crc == file[i + 8 + length..<i + 12 + length].reduce(0, { $0 << 8 | UInt($1) }),
                   let nul = payload.prefix(80).firstIndex(of: 0), nul > payload.startIndex, payload.endIndex - nul > 2, payload[nul + 1] == 0 {
                    var profile = Data()
                    // Real profiles are far smaller (a JPEG can carry at most 255 × 65519 bytes); the budget covers every
                    // iCCP chunk, so repeated compressed chunks can't make reading inflate more.
                    let complete = (try? Deflate.inflate(payload[(nul + 2)...], windowBits: 15) { chunk in
                        profile += chunk
                        inflated += chunk.count
                        if inflated > 1 << 24 { throw ConversionError("The PNG colour profiles are too large.") }
                    }) != nil
                    if complete, let valid = CodecPixels.validProfile(profile) { profiles.append(valid) }
                }
            }
            declared = declared || ["sRGB", "gAMA", "cHRM", "cICP"].contains(type)
            i += 12 + length
        }
        return (profiles, declared, inflated)
    }

    /// PNG colour chunks for the source's actual ICC bytes instead of ImageIO's choice for the colour space, which turns
    /// untagged gray into Generic Gray Gamma 2.2, a genuine sRGB profile into an sRGB chunk and Adobe RGB into its own
    /// copy. Untracked frames (rendered pages) keep ImageIO's chunks; so does the sRGB chunk of untagged RGB.
    private static func withSourceProfile(_ png: Data, _ frame: ImageFrame) throws -> Data {
        guard frame.properties[ImageFrame.iccKey] is Data else { return png }
        // ImageIO keeps an indexed picture's palette, written in its base space.
        let space = frame.image.colorSpace
        let profile = CodecPixels.colorProfile(frame, space: space?.model == .indexed ? space?.baseColorSpace : space)
        let dropped: Set<String> = profile == nil ? ["iCCP", "cICP"] : ["iCCP", "cICP", "sRGB"]
        var result = png.prefix(33) // signature and IHDR
        if let profile { result += try pngChunk("iCCP", Data("icc".utf8) + [0, 0] + Deflate.deflate(profile, windowBits: 15)) }
        var offset = 33
        while png.count - offset >= 12 {
            let end = offset + 12 + png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard end <= png.count else { break }
            if !dropped.contains(String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)) { result += png[offset..<end] }
            offset = end
        }
        return result + png[offset...]
    }

    /// One PNG chunk: big-endian length, type, payload and CRC.
    private static func pngChunk(_ type: String, _ payload: Data) throws -> Data {
        guard payload.count <= Int32.max else { throw ConversionError("The PNG metadata is too large.") }
        let bytes = Data(type.utf8) + payload
        let crc = bytes.withUnsafeBytes { zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        return withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + bytes + withUnsafeBytes(of: UInt32(crc).bigEndian) { Data($0) }
    }

    /// ImageMagick's PNG raw-profile convention keeps Photoshop resources that ImageIO cannot serialize.
    private static func preservingJpegMetadata(_ png: Data, _ frame: ImageFrame) throws -> Data {
        var comments = Data(), photoshop = Data()
        if let markers = frame.properties[ImageFrame.jpegMarkersKey] as? Data {
            for (marker, payload) in JpegEncoder.segments(Data([0xFF, 0xD8]) + markers + Data([0xFF, 0xD9])) {
                if marker == 0xFE { comments.append(payload) }
                if marker == 0xED { photoshop.append(payload.dropFirst(14)) }
            }
        } else if let blocks = frame.properties[ImageFrame.photoshopKey] as? Data {
            photoshop = blocks
        }
        guard !comments.isEmpty || !photoshop.isEmpty else { return png }
        var chunks = Data()
        func text(_ name: String, _ value: Data) throws { chunks += try pngChunk("tEXt", Data(name.utf8) + Data([0]) + value) }
        if !comments.isEmpty { try text("Comment", Data(comments.prefix { $0 != 0 })) }
        if !photoshop.isEmpty {
            var profile = Data(("\n8bim\n" + String(format: "%8lu", photoshop.count)).utf8)
            let hex = Array("0123456789abcdef".utf8)
            for (i, byte) in photoshop.enumerated() {
                if i % 36 == 0 { profile.append(10) }
                profile.append(hex[Int(byte >> 4)])
                profile.append(hex[Int(byte & 15)])
            }
            profile.append(10)
            try text("Raw profile type 8bim", profile)
        }
        // Put metadata after IHDR so readers that stop metadata scanning at IDAT also see it.
        return png.prefix(33) + chunks + png.dropFirst(33)
    }

    /// The frame's metadata without the source's file structure (compression, sample layout, tiles), which would
    /// override the encoder's, and with the frame's resolution.
    static func encoderMetadata(_ metadata: CGImageMetadata, _ dpi: (x: Double, y: Double)?) -> CGImageMetadata {
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
                                                     ImageFrame.qualityKey, ImageFrame.jpegSamplingKey, ImageFrame.resolutionKey, ImageFrame.jpegMarkersKey, ImageFrame.iccKey, ImageFrame.icoPaletteKey,
                                                     ImageFrame.photoshopKey]

    /// Sets the EXIF orientation of the frame and of its metadata.
    private static func setOrientation(_ frame: inout ImageFrame, _ orientation: Int) {
        frame.properties[kCGImagePropertyOrientation] = orientation
        if let metadata = frame.properties[ImageFrame.metadataKey], CFGetTypeID(metadata as CFTypeRef) == CGImageMetadataGetTypeID(),
           let copy = CGImageMetadataCreateMutableCopy(metadata as! CGImageMetadata) {
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            frame.properties[ImageFrame.metadataKey] = copy
        }
    }


    // ───────────────────────── ICO ─────────────────────────

    /// Icons must be square: pads the shorter side with transparency; every requested size is written into one .ico.
    private static func prepareIcon(_ frame: inout ImageFrame, _ options: ImageOptions) {
        var side = max(frame.image.width, frame.image.height)
        if frame.image.width != frame.image.height {
            frame.image = ImagePixels.paddedInSourceSpace(frame.image, side: side)
            frame.properties[ImageFrame.icoPaletteKey] = false
        }
        if side > 256 {
            let palette = frame.properties[ImageFrame.icoPaletteKey] as? Bool
            frame.image = ImagePixels.resized(frame.image, width: 256, height: 256, palette: palette)
            frame.properties[ImageFrame.icoPaletteKey] = false
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
        let palette = square.properties[ImageFrame.icoPaletteKey] as? Bool ??
            (square.image.colorSpace?.model == .monochrome || square.image.colorSpace?.model == .indexed)
        let icons = sizes.map { size in
            let filter = MagickResize.defaultFilter(from: (square.image.width, square.image.height), to: (size, size),
                                                   alpha: ImagePixels.hasAlpha(square.image), palette: palette)
            let image = ImagePixels.resized(square.image, width: size, height: size, filter: filter)
            return ImageFrame(image: image.colorSpace?.model == .cmyk ? ImagePixels.rgb(image) : image)
        }
        try writeImageIO(icons, to: path, format: "ico")
    }
}
