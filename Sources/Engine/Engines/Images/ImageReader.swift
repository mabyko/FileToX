// Port of Filee.Engines/Magick/ImageReader.cs: reads source images, handling the formats that need more than "open
// the file": camera RAW, layered PSD/PSB/XCF (one flattened picture instead of one file per layer) and Netpbm. Used by
// every engine that takes a raster image as input. ImageIO decodes what ImageMagick decoded; XCF and Netpbm have Swift
// readers. (Filee's EMF/WMF branch is Windows-only and not ported.)

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum ImageReader {
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
        let animation = (fileProperties[kCGImagePropertyGIFDictionary] ?? fileProperties[kCGImagePropertyWebPDictionary]) as? [CFString: Any]
        let loops = (animation?[kCGImagePropertyGIFLoopCount] ?? animation?[kCGImagePropertyWebPLoopCount]) as? NSNumber

        if format == "psd" || format == "psb", let composite = try PsdCodec.layerComposite(path) {
            // Saved without "maximize compatibility": the file has no real composite; ImageMagick builds it from the layers.
            return [composite]
        }

        var frames: [ImageFrame] = []
        for index in indexes {
            try Task.checkCancellation()
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else {
                throw ConversionError("Could not decode \(FilePath.fileName(path)).")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            var frame = ImageFrame(image: image, delay: delay(properties), dpi: storedDpi(properties, format: format))
            if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 {
                frame.properties[kCGImagePropertyOrientation] = orientation.intValue
            }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) { frame.properties[ImageFrame.metadataKey] = metadata }
            if let loops { frame.properties[ImageFrame.loopCountKey] = loops.intValue }
            frames.append(frame)
        }
        return frames
    }

    /// Camera RAW developed by Core Image's RAW pipeline (Filee: LibRaw) with the camera's white balance, into 8-bit
    /// sRGB. The picture comes out upright, so its EXIF orientation is reset; the metadata is kept.
    private static func readRaw(_ path: String) throws -> ImageFrame {
        let url = URL(fileURLWithPath: path)
        let filter = CIRAWFilter(imageURL: url)
            ?? (try? Data(contentsOf: url)).flatMap { CIRAWFilter(imageData: $0, identifierHint: ImageEncoder.typeIdentifiers["raw"]) }
        guard let filter, let output = filter.outputImage, !output.extent.isInfinite, output.extent.width >= 1, output.extent.height >= 1 else {
            throw ConversionError("\(FilePath.fileName(path)) is not a camera RAW picture this Mac can read.")
        }
        try Task.checkCancellation()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space) else {
            throw ConversionError("Could not decode \(FilePath.fileName(path)).")
        }
        var frame = ImageFrame(image: image)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let copy = CGImageMetadataCreateMutableCopy(metadata) {
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
            frame.properties[ImageFrame.metadataKey] = copy
        }
        return frame
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
    /// EXIF (or JFIF) value with the JFIF unit (a JFIF density without unit counts as none, as does EXIF alone).
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
            if let jfif {
                unit = (jfif[kCGImagePropertyJFIFDensityUnit] as? NSNumber)?.intValue ?? 0
            } else {
                let exifUnit = (tiff?[kCGImagePropertyTIFFResolutionUnit] as? NSNumber)?.intValue ?? 0
                unit = exifUnit == 2 ? 1 : exifUnit == 3 ? 2 : 0
            }
        default:
            return nil
        }
        guard let x, x > 0, unit == 1 || unit == 2 else { return nil }
        let factor = unit == 2 ? 2.54 : 1
        return (x * factor, (y.flatMap { $0 > 0 ? $0 : nil } ?? x) * factor)
    }
}
