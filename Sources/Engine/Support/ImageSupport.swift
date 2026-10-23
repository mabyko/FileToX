// Small ImageIO helpers for engines that embed pictures (HWPX/DOCX writers, EPUB, comics, cover art): what Filee did
// with MagickImageInfo and "write as PNG". The image engine has the full decoder/encoder set (Engines/Images).

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageSupport {
    public struct Info: Sendable {
        public let width: Int
        public let height: Int
        /// Pixels per inch from the file, when it says.
        public let dpiX: Double?
        public let dpiY: Double?
        /// Uniform type of the file ("public.png", "public.svg-image" ...).
        public let typeIdentifier: String
        public let frameCount: Int
    }

    /// Size and type of a picture ImageIO (or, for SVG, AppKit) can read; nil when it is no picture.
    public static func info(_ path: String) -> Info? {
        if isSvg(path) {
            guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)), image.size.width > 0 else { return nil }
            return Info(width: Int(image.size.width.rounded()), height: Int(image.size.height.rounded()), dpiX: nil, dpiY: nil,
                        typeIdentifier: UTType.svg.identifier, frameCount: 1)
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        return Info(width: rotated ? height : width, height: rotated ? width : height,
                    dpiX: (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
                    dpiY: (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
                    typeIdentifier: type as String, frameCount: CGImageSourceGetCount(source))
    }

    /// True for .svg / .svgz names.
    public static func isSvg(_ path: String) -> Bool {
        ["svg", "svgz"].contains(FilePath.extension(path).dropFirst().lowercased())
    }

    /// The first frame of a picture, upright (EXIF orientation applied), as PNG. SVG is rendered at `svgScale`
    /// (1.5 = 144 dpi, what Filee used for pictures in documents).
    public static func pngData(_ path: String, svgScale: CGFloat = 1.5) throws -> Data {
        let image = try cgImage(path, svgScale: svgScale)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError("Could not encode \(FilePath.fileName(path)) as PNG.") }
        return output as Data
    }

    /// The first frame of a picture as a CGImage, with its EXIF orientation applied.
    public static func cgImage(_ path: String, svgScale: CGFloat = 1.5) throws -> CGImage {
        if isSvg(path) {
            guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)), image.size.width > 0, image.size.height > 0 else {
                throw ConversionError("\(FilePath.fileName(path)) is not a readable SVG picture.")
            }
            var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * svgScale, height: image.size.height * svgScale))
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw ConversionError("Could not render \(FilePath.fileName(path)).")
            }
            return cg
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError("\(FilePath.fileName(path)) is not a picture this Mac can read.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(source),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError("Could not decode \(FilePath.fileName(path)).")
        }
        return image
    }

    private static func maxPixelSize(_ source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(width, height, 1)
    }
}
