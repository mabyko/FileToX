// Port of Filee.Engines/Vector/SvgRenderer.cs: loads SVG/SVGZ and draws it onto PDF pages as real vector graphics or onto
// a bitmap for raster targets. Self-contained primitive raster drawings use a bounded native Skia bridge;
// CoreSVG keeps all other SVG features and vector PDF after CSS/text/resource normalization.

import AppKit
import CoreGraphics
import Foundation

/// SVG → PDF and SVG → bitmap.
enum SvgRenderer {
    /// CSS pixels per inch: SVG user units are CSS pixels.
    static let cssDpi: Float = 96

    /// Small drawings (icons) are rendered at least this large on the long edge.
    static let minimumLongEdge: Float = 1024

    /// Upper bounds for rendered bitmaps, so a huge drawing doesn't exhaust memory.
    private static let maximumLongEdge: Float = 16384
    private static let maximumPixels: Float = 100_000_000

    /// A loaded drawing.
    struct Drawing {
        let image: NSImage
        let nativeData: Data?
        /// The SVG viewport (width/height or viewBox) in CSS pixels.
        let bounds: CGRect
    }

    /// Loads an SVG or SVGZ (gzip) file.
    static func load(_ path: String) throws -> Drawing {
        let bytes = try readSvgBytes(path)
        let prepared = SvgNormalizer.normalize(bytes, baseDirectory: FilePath.directoryName(FilePath.fullPath(path)))
        guard let image = NSImage(data: prepared), image.representations.first != nil else {
            throw ConversionError("The SVG file could not be read: it is not a drawing AppKit can parse.")
        }
        let size = image.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw ConversionError("The SVG file has no drawable content or no size.")
        }
        return Drawing(image: image, nativeData: NativeSvgRasterizer.supports(bytes) ? prepared : nil, bounds: CGRect(origin: .zero, size: size))
    }

    /// The file's SVG text as bytes: SVGZ (or a gzipped .svg) is decompressed.
    static func readSvgBytes(_ path: String) throws -> Data {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        guard isGzip(bytes) else { return bytes }
        do {
            return try Deflate.inflate(bytes, windowBits: 31)
        } catch {
            throw ConversionError("The SVG file could not be read: the gzip data is damaged.")
        }
    }

    /// True when the data starts with the gzip magic number.
    static func isGzip(_ data: Data) -> Bool { data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B }

    /// Writes a one-page PDF the size of the drawing. Paths, gradients and text stay vector (text as glyph outlines);
    /// effects PDF can't express (filters such as blur, masks) are rasterized by CoreSVG.
    static func writePdf(_ drawing: Drawing, _ output: String, title: String, pdfA: Bool) throws {
        _ = pdfA // shortcut: no PDF/A (Core Graphics can't write it, Filee's Skia could), upgrade if PDF/A drawings are needed
        let pointsPerPixel: CGFloat = 72 / CGFloat(cssDpi)
        var mediaBox = CGRect(x: 0, y: 0, width: drawing.bounds.width * pointsPerPixel, height: drawing.bounds.height * pointsPerPixel)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "FileToX"]
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ConversionError("Could not create the PDF.")
        }
        context.beginPDFPage(nil)
        draw(drawing, into: context, size: mediaBox.size)
        context.endPDFPage()
        context.closePDF()
        if data.length == 0 { throw ConversionError("Core Graphics could not write the PDF.") }
        try FileManager.default.writeFile(output, data as Data)
    }

    /// Scale from CSS pixels to output pixels. Vector drawings are rendered at the size they end up at: at the preset's
    /// render DPI, at least `minimumLongEdge` on the long edge, or exactly at the preset's resize target.
    static func rasterScale(_ bounds: CGRect, _ image: ImageOptions, _ pdf: PdfOptions) -> Float {
        let width = Float(bounds.width), height = Float(bounds.height)
        let longEdge = max(width, height)
        let dpi = Float(min(max(pdf.renderDpi, 36), 1200))
        var scale = max(dpi / cssDpi, minimumLongEdge / longEdge)
        switch image.resize {
        case .longEdge where image.longEdge > 0:
            scale = Float(image.longEdge) / longEdge
        case .percent where image.resizePercent > 0 && image.resizePercent != 100:
            scale *= Float(image.resizePercent) / 100
        default:
            break
        }
        let limit = min(maximumLongEdge / longEdge, (maximumPixels / (width * height)).squareRoot())
        return max(min(scale, limit), 1e-3)
    }

    /// Renders the drawing on a transparent bitmap.
    static func rasterize(_ drawing: Drawing, scale: Float) throws -> ImageFrame {
        let width = max(1, Int((Float(drawing.bounds.width) * scale).rounded(.up)))
        let height = max(1, Int((Float(drawing.bounds.height) * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ConversionError("The drawing is too large to render (\(width) × \(height) pixels).")
        }
        if let data = drawing.nativeData, try NativeSvgRasterizer.render(data, bounds: drawing.bounds, scale: scale, into: context),
           let image = context.makeImage() {
            let dpi = Double(cssDpi * scale)
            return ImageFrame(image: image, dpi: (dpi, dpi))
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // The drawing's own size times the scale; the bitmap is rounded up to whole pixels at the bottom and right.
        let size = CGSize(width: drawing.bounds.width * CGFloat(scale), height: drawing.bounds.height * CGFloat(scale))
        context.translateBy(x: 0, y: CGFloat(height) - size.height)
        draw(drawing, into: context, size: size)
        guard let image = context.makeImage() else { throw ConversionError("Could not read the rendered SVG.") }
        let dpi = Double(cssDpi * scale)
        return ImageFrame(image: image, dpi: (dpi, dpi))
    }

    private static func draw(_ drawing: Drawing, into context: CGContext, size: CGSize) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawing.image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
    }
}
