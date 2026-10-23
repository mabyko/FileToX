// Port of Filee.Engines/Pdf/PdfiumConverter.cs: renders PDF pages to raster images. PDFium (PDFtoImage) is replaced by
// PDFKit drawing the page (with annotations and form fields) on white at the preset's render DPI.

import CoreGraphics
import Foundation
import PDFKit

/// PDF → every raster format the image engine writes (PNG, JPG, WEBP, TIFF, …, PSD, TGA, PPM).
final class PdfiumConverter: Converter {
    private static let multiPageTargets: Set<String> = ["tiff", "gif"]

    let id = "pdfium"
    let displayName = "PDF rendering (built-in)"
    /// One page renderer at a time, like Filee's PDFium.
    let maxParallelism = 1

    let edges: [ConversionEdge] = ImageEncoder.writable.map { ConversionEdge("pdf", $0) }

    func status() -> EngineStatus { .available(version: EngineVersions.system("PDFKit")) }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        let document = try PdfSharpConverter.open(step.inputPath)
        let pages = PageRange.parse(step.preset.pdf.pageRange, pageCount: document.pageCount)
        let dpi = min(max(step.preset.pdf.renderDpi, 36), 1200)
        let (format, ext) = ImageEncoder.outputFormat(step.to, step.preset.image)
        var written: [String] = []
        var collected: [ImageFrame] = []

        for (index, pageIndex) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else { continue }
            var frame = ImageFrame(image: try Self.render(page, dpi: dpi), dpi: (Double(dpi), Double(dpi)))
            frame = try ImageEncoder.applyOptions(frame, step.preset.image, targetFormat: step.to)

            if Self.multiPageTargets.contains(step.to) {
                collected.append(frame) // one multi-page file, written after the loop
            } else if let path = try step.output.allocate(ext, suffix: pages.count > 1 ? "_p\(pageIndex + 1)" : nil) {
                try ImageEncoder.save([frame], to: path, format: format)
                written.append(path)
            }
            progress?(Double(index + 1) / Double(pages.count))
        }
        if !collected.isEmpty {
            written += try ImageEncoder.write(collected, targetFormat: step.to, output: step.output, options: step.preset.image)
        }
        return written
    }

    /// The page (crop box, turned by its rotation) at `dpi` on white, with its annotations and form fields; RGBA like
    /// PDFium's bitmaps. Pixel size as PDFtoImage computes it: points × (dpi / 72) in single precision, truncated.
    static func render(_ page: PDFPage, dpi: Int) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let (widthPt, heightPt) = turned ? (box.height, box.width) : (box.width, box.height)
        let scale = Float(dpi) / 72
        let width = max(1, Int(Float(widthPt) * scale)), height = max(1, Int(Float(heightPt) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError("The page is too large to render (\(width) × \(height) pixels).")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / widthPt, y: CGFloat(height) / heightPt)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError("The page could not be rendered.") }
        return image
    }
}
