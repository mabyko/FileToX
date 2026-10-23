// Stand-ins for the image engine API (feat/port-image-pdf-engines, Sources/Engine/Engines/Images), with the same
// signatures. Deleted when that branch is integrated; the real ImageEncoder then writes the CAD rasters.

import CoreGraphics
import Foundation

/// One frame of a raster image (see the image engine's `ImageFrame`).
struct ImageFrame {
    var image: CGImage
    var delay: Double? = nil
    var dpi: (x: Double, y: Double)? = nil
    var properties: [CFString: Any] = [:]
}

enum ImageEncoder {
    static let writable: [String] = ["png", "jpg", "webp", "tiff", "bmp", "gif", "ico", "avif", "jxl", "jp2", "psd", "psb", "tga", "ppm"]

    static func applyOptions(_ frame: ImageFrame, _ options: ImageOptions, targetFormat: String) throws -> ImageFrame {
        throw ConversionError("not ported yet")
    }

    static func save(_ frames: [ImageFrame], to path: String, format: String) throws {
        throw ConversionError("not ported yet")
    }
}
