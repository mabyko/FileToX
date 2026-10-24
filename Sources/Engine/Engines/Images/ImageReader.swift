// Port of Filee.Engines/Magick/ImageReader.cs: reads source images, handling the formats that need more than "open
// the file": camera RAW, layered PSD/PSB/XCF (one flattened picture instead of one file per layer) and Netpbm. Used by
// every engine that takes a raster image as input. JPEG uses libjpeg-turbo with ImageIO metadata and fallback;
// camera RAW uses LibRaw; other formats use ImageIO or Swift readers. (Filee's EMF/WMF branch is Windows-only.)

import CLibRaw
import CJpegTurbo
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum ImageReader {
    /// "0.22.2": the LibRaw that develops camera RAW.
    static let libRawVersion = String(String(cString: ftx_libraw_version()).prefix { $0 != "-" })

    /// Reads `path` as format `format`. Layered formats come back as a single, flattened image; other multi-frame
    /// formats (TIFF pages, GIF frames, ICO sizes) keep all frames.
    static func read(_ path: String, format: String, preset: Preset) throws -> [ImageFrame] {
        _ = preset // Filee uses the preset only for the DPI of Windows metafiles.
        switch format {
        case "ppm":
            return try NetpbmCodec.read(path)
        case "raw":
            return [try readRaw(path)]
        case "xcf":
            do {
                return [try XcfReader.read(path)]
            } catch let error as CancellationError {
                throw error
            } catch {
                throw ConversionError("This GIMP file can't be read. Filee reads 8-bit XCF files saved without \"better but slower compression\"; " +
                                      "in GIMP, export the picture as PNG or PSD instead. (" + error.localizedDescription + ")")
            }
        default:
            return try readImageIO(path, format: format)
        }
    }

    private static func readImageIO(_ path: String, format: String) throws -> [ImageFrame] {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ConversionError("\(FilePath.fileName(path)) is not a picture this Mac can read.")
        }
        let count = CGImageSourceGetCount(source)
        // ImageMagick reads every page/frame of TIFF, GIF, WebP, ICO and JPEG XL; of the others only the main image
        // (PSD/PSB: the composite; HEIC: the primary image; PNG: no APNG frames).
        let indexes: [Int] = switch format {
        case "tiff", "gif", "webp", "ico", "jxl": Array(0..<count)
        case "heic", "avif": [CGImageSourceGetPrimaryImageIndex(source)]
        default: [0]
        }
        let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        // ImageMagick's "jpeg:sampling-factor", which its JPEG writer reuses.
        let jpeg = format == "jpg" ? try Data(contentsOf: URL(fileURLWithPath: path)) : nil
        let sampling = jpeg.flatMap(JpegEncoder.samplingFactors)
        let markers = jpeg.map(JpegEncoder.preservedMarkers)
        let animation = (fileProperties[kCGImagePropertyGIFDictionary] ?? fileProperties[kCGImagePropertyWebPDictionary]) as? [CFString: Any]
        let loops = (animation?[kCGImagePropertyGIFLoopCount] ?? animation?[kCGImagePropertyWebPLoopCount]) as? NSNumber

        if format == "psd" || format == "psb" {
            // Saved without "maximize compatibility": the file has no real composite; ImageMagick builds it from the layers.
            // With transparency, ImageMagick unblends the white matte Photoshop puts under the composite.
            if var composite = try PsdCodec.layerComposite(path) ?? PsdCodec.transparentComposite(path) {
                if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) { composite.properties[ImageFrame.metadataKey] = metadata }
                return [composite]
            }
        }

        var frames: [ImageFrame] = []
        for index in indexes {
            try Task.checkCancellation()
            let options = [kCGImageSourceShouldCacheImmediately: jpeg == nil] as CFDictionary
            guard var image = CGImageSourceCreateImageAtIndex(source, index, options) else {
                throw ConversionError("Could not decode \(FilePath.fileName(path)).")
            }
            if let jpeg { image = try decodeJpeg(jpeg, fallback: image) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var frame = ImageFrame(image: image, delay: delay(properties), dpi: storedDpi(properties, format: format))
            if let resolution = storedResolution(properties, format: format) { frame.properties[ImageFrame.resolutionKey] = resolution }
            if format == "gif" { frame.properties[ImageFrame.icoPaletteKey] = true }
            if image.colorSpace?.model == .monochrome && !["jpg", "png", "bmp"].contains(format) {
                frame.properties[ImageFrame.icoPaletteKey] = false
            }
            if let sampling { frame.properties[ImageFrame.jpegSamplingKey] = sampling }
            if let markers, !markers.isEmpty { frame.properties[ImageFrame.jpegMarkersKey] = markers }
            if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 {
                frame.properties[kCGImagePropertyOrientation] = orientation.intValue
            }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) { frame.properties[ImageFrame.metadataKey] = metadata }
            if let loops { frame.properties[ImageFrame.loopCountKey] = loops.intValue }
            frames.append(frame)
        }
        return frames
    }

    /// Replace only pixels; ImageIO still supplies the ICC space, EXIF orientation, resolution and metadata.
    static func decodeJpeg(_ data: Data, fallback: CGImage) throws -> CGImage {
        try Task.checkCancellation()
        var pixels: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0, components: Int32 = 0
        let status = data.withUnsafeBytes { bytes in
            ftx_jpeg_decode(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &pixels,
                            &width, &height, &components, { Task.isCancelled ? 1 : 0 })
        }
        if status == 2 { throw CancellationError() }
        guard status == 0, let pixels else { return fallback }
        let samples = Data(bytesNoCopy: pixels, count: Int(width) * Int(height) * Int(components), deallocator: .free)
        try Task.checkCancellation()
        let model: CGColorSpaceModel = components == 4 ? .cmyk : components == 1 ? .monochrome : .rgb
        guard let fallbackSpace = fallback.colorSpace, fallbackSpace.model == model else { return fallback }
        var space = fallbackSpace
        if model == .cmyk {
            let iccHeader = Data("ICC_PROFILE\0".utf8)
            let embedded = JpegEncoder.segments(data).contains { marker, payload in
                marker == 0xE2 && payload.count > 14 && payload.starts(with: iccHeader)
            }
            // ImageIO assigns Generic CMYK to untagged JPEGs too; that is not an embedded source profile.
            if !embedded { space = CGColorSpaceCreateDeviceCMYK() }
        }
        guard let provider = CGDataProvider(data: samples as CFData),
              let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 8 * Int(components),
                                  bytesPerRow: Int(width) * Int(components), space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: fallback.renderingIntent) else { return fallback }
        return image
    }

    /// Camera RAW developed by LibRaw exactly as the C# helper's ImageMagick did (Filee: camera white balance, sRGB, AHD,
    /// auto-brightness, then 8 bits), so the colours are the same. The picture comes as stored, with its orientation for
    /// ApplyOptions' AutoOrient. Files LibRaw can't develop (cameras LibRaw doesn't know) go to Core Image's RAW pipeline
    /// set up to look like LibRaw.
    private static func readRaw(_ path: String) throws -> ImageFrame {
        var raw = FTXRawImage()
        let error = ftx_libraw_develop(path, &raw)
        guard error == 0 else {
            let reason = String(cString: ftx_libraw_strerror(error))
            FileHandle.standardError.write(Data("[magick] LibRaw can't develop \(FilePath.fileName(path)) (\(reason)); using Core Image instead.\n".utf8))
            return try readRawWithCoreImage(path)
        }
        let (width, height, colors) = (Int(raw.width), Int(raw.height), Int(raw.colors))
        let pixels = Data(bytesNoCopy: raw.pixels, count: width * height * colors, deallocator: .free) // malloc'ed by the shim
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * colors, bytesPerRow: width * colors,
                                  space: colors < 3 ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: (colors % 2 == 0 ? CGImageAlphaInfo.last : .none).rawValue),
                                  provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ConversionError("Could not decode \(FilePath.fileName(path)).")
        }
        try Task.checkCancellation()
        var frame = ImageFrame(image: image)
        let orientation = Int(raw.orientation)
        if (2...8).contains(orientation) { frame.properties[kCGImagePropertyOrientation] = orientation }
        frame.properties[ImageFrame.metadataKey] = rawMetadata(path, orientation: (1...8).contains(orientation) ? orientation : 1)
        return frame
    }

    /// The fallback: Core Image's RAW pipeline with Apple's own look switched off (boost, tone map, noise reduction,
    /// sharpening, baseline exposure), rendered as linear sRGB, then LibRaw's auto-brightness and BT.709 curve and
    /// ImageMagick's 8-bit scaling. Measured on ten cameras: ΔE00 2.7 from LibRaw on average. Comes out upright.
    private static func readRawWithCoreImage(_ path: String) throws -> ImageFrame {
        let url = URL(fileURLWithPath: path)
        let filter = CIRAWFilter(imageURL: url)
            ?? (try? Data(contentsOf: url)).flatMap { CIRAWFilter(imageData: $0, identifierHint: ImageEncoder.typeIdentifiers["raw"]) }
        if let filter {
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            filter.baselineExposure = 0
            filter.shadowBias = 0
            filter.extendedDynamicRangeAmount = 0
            filter.isGamutMappingEnabled = false
            if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
            if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
            if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
            if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
            if filter.isDetailSupported { filter.detailAmount = 0 }
            if filter.isContrastSupported { filter.contrastAmount = 0 }
            if filter.isMoireReductionSupported { filter.moireReductionAmount = 0 }
            if filter.isDespeckleSupported { filter.despeckleAmount = 0 }
            if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = false }
            if #available(macOS 26, *), filter.isHighlightRecoverySupported { filter.isHighlightRecoveryEnabled = false }
        }
        guard let filter, let output = filter.outputImage, !output.extent.isInfinite, output.extent.width >= 1, output.extent.height >= 1 else {
            throw ConversionError("\(FilePath.fileName(path)) is not a camera RAW picture this Mac can read.")
        }
        try Task.checkCancellation()
        let bounds = output.extent.integral
        let (width, height) = (Int(bounds.width), Int(bounds.height))
        var linear = [UInt16](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh,
                                          .cacheIntermediates: false])
        linear.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: width * 8, bounds: bounds, format: .RGBA16,
                           colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        }
        try Task.checkCancellation()

        // LibRaw's auto-brightness (copy_mem_image): per channel, the level of the 16-bit values >> 3 above which 1 % of
        // the pixels lie; the brightest channel's level becomes white.
        var histogram = [Int](repeating: 0, count: 3 * 0x2000)
        for i in 0..<width * height { for c in 0..<3 { histogram[c * 0x2000 + Int(linear[i * 4 + c] >> 3)] += 1 } }
        let limit = Int(Double(width * height) * 0.01)
        var white = 0
        for c in 0..<3 {
            var level = 0x2000, total = 0
            while true {
                level -= 1
                if level <= 32 { break }
                total += histogram[c * 0x2000 + level]
                if total > limit { break }
            }
            white = max(white, level)
        }
        // LibRaw's gamma_curve(0.45, 4.5, mode 2, white): BT.709 with a linear toe, then ImageMagick's (v + 128) / 257.
        var bisect = [0.0, 1.0], knee = 0.0
        for _ in 0..<48 {
            knee = (bisect[0] + bisect[1]) / 2
            bisect[(pow(knee / 4.5, -0.45) - 1) / 0.45 - 1 / knee > -1 ? 1 : 0] = knee
        }
        let toe = knee / 4.5, offset = knee * (1 / 0.45 - 1), top = Double(white << 3)
        let curve = (0..<0x10000).map { i -> UInt8 in
            let r = Double(i) / top
            let value = r >= 1 ? 0xFFFF : Int(0x10000 * (r < toe ? r * 4.5 : pow(r, 0.45) * (1 + offset) - offset))
            return UInt8((value + 128) / 257)
        }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<width * height { for c in 0..<3 { rgb[i * 3 + c] = curve[Int(linear[i * 4 + c])] } }
        let image = ImagePixels.make(rgb, width, height, components: 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)

        // macOS develops some DNG variants (e.g. lossy DNGs from Camera Raw 15) as an all-black picture.
        if isBlack(image) {
            throw ConversionError("\(FilePath.fileName(path)) can't be developed on this Mac: macOS's camera RAW decoder returned an empty (black) picture.")
        }
        var frame = ImageFrame(image: image)
        frame.properties[ImageFrame.metadataKey] = rawMetadata(path, orientation: 1)
        return frame
    }

    /// The RAW file's EXIF / XMP as ImageIO reads them, with `orientation` as the picture's EXIF orientation.
    private static func rawMetadata(_ path: String, orientation: Int) -> CGImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let copy = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        return copy
    }

    /// True when a 64 × 64 thumbnail of the picture has no light at all.
    private static func isBlack(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return !pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 0 }
    }

    /// Seconds an animation frame is shown (the delay as written, not ImageIO's clamped value).
    private static func delay(_ properties: [CFString: Any]) -> Double? {
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyWebPDictionary, kCGImagePropertyPNGDictionary] {
            guard let animation = properties[key] as? [CFString: Any] else { continue }
            let unclamped = animation[kCGImagePropertyGIFUnclampedDelayTime] ?? animation[kCGImagePropertyWebPUnclampedDelayTime]
                ?? animation[kCGImagePropertyAPNGUnclampedDelayTime]
            let clamped = animation[kCGImagePropertyGIFDelayTime] ?? animation[kCGImagePropertyWebPDelayTime] ?? animation[kCGImagePropertyAPNGDelayTime]
            if let seconds = (unclamped ?? clamped) as? NSNumber { return seconds.doubleValue }
        }
        return nil
    }

    /// The resolution ImageMagick reads from the file, in pixels per inch; nil when it has none (or no unit).
    /// PNG pHYs in metres, BMP pixels per metre, PSD resolution info, TIFF XResolution with its unit, and for JPEG the
    /// EXIF (or JFIF) value with the EXIF (or JFIF) unit: a value without any unit counts as none.
    /// The resolution ImageMagick reads, [x, y, unit] (unit 0 = undefined, 1 = per inch, 2 = per centimetre), for the
    /// JFIF header of a JPEG written from it: EXIF/TIFF tags first (its SyncResolutionFromProperties), else PNG's pHYs
    /// and BMP's header in pixels per centimetre, JFIF as stored, PSD's resolution in inches.
    static func storedResolution(_ properties: [CFString: Any], format: String) -> [Double]? {
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let x = number(tiff?[kCGImagePropertyTIFFXResolution]), let y = number(tiff?[kCGImagePropertyTIFFYResolution]) {
            let unit = (tiff?[kCGImagePropertyTIFFResolutionUnit] as? NSNumber)?.intValue ?? 2
            return [x, y, unit == 2 ? 1 : unit == 3 ? 2 : 0]
        }
        switch format {
        case "png":
            let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            guard let x = number(png?[kCGImagePropertyPNGXPixelsPerMeter]), x > 0 else { return nil }
            return [x / 100, (number(png?[kCGImagePropertyPNGYPixelsPerMeter]) ?? x) / 100, 2]
        case "jpg":
            let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
            guard let x = number(jfif?[kCGImagePropertyJFIFXDensity]), let y = number(jfif?[kCGImagePropertyJFIFYDensity]) else { return nil }
            return [x, y, number(jfif?[kCGImagePropertyJFIFDensityUnit]) ?? 0]
        case "bmp":
            // ImageIO reports pixels per metre × 0.0254; ImageMagick keeps pixels per metre / 100.
            guard let x = number(properties[kCGImagePropertyDPIWidth]), x > 0 else { return nil }
            let y = number(properties[kCGImagePropertyDPIHeight]) ?? x
            return [(x / 0.0254).rounded() / 100, (y / 0.0254).rounded() / 100, 2]
        case "psd", "psb":
            guard let x = number(properties[kCGImagePropertyDPIWidth]), x > 0 else { return nil }
            return [x, number(properties[kCGImagePropertyDPIHeight]) ?? x, 1]
        default:
            return nil
        }
    }

    static func storedDpi(_ properties: [CFString: Any], format: String) -> (x: Double, y: Double)? {
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        var x: Double?, y: Double?, unit = 0
        switch format {
        case "png", "bmp", "psd", "psb":
            (x, y, unit) = (number(properties[kCGImagePropertyDPIWidth]), number(properties[kCGImagePropertyDPIHeight]), 1)
        case "tiff":
            (x, y) = (number(tiff?[kCGImagePropertyTIFFXResolution]), number(tiff?[kCGImagePropertyTIFFYResolution]))
            unit = (tiff?[kCGImagePropertyTIFFResolutionUnit] as? NSNumber)?.intValue ?? 2
            unit = unit == 2 ? 1 : unit == 3 ? 2 : 0
        case "jpg":
            let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
            x = number(tiff?[kCGImagePropertyTIFFXResolution]) ?? number(jfif?[kCGImagePropertyJFIFXDensity])
            y = number(tiff?[kCGImagePropertyTIFFYResolution]) ?? number(jfif?[kCGImagePropertyJFIFYDensity])
            // The EXIF unit when there is one (ImageIO writes JFIF without unit), else the JFIF unit.
            if let exifUnit = (tiff?[kCGImagePropertyTIFFResolutionUnit] as? NSNumber)?.intValue {
                unit = exifUnit == 2 ? 1 : exifUnit == 3 ? 2 : 0
            } else {
                unit = (jfif?[kCGImagePropertyJFIFDensityUnit] as? NSNumber)?.intValue ?? 0
            }
        default:
            return nil
        }
        guard let x, x > 0, unit == 1 || unit == 2 else { return nil }
        let factor = unit == 2 ? 2.54 : 1
        return (x * factor, (y.flatMap { $0 > 0 ? $0 : nil } ?? x) * factor)
    }
}
