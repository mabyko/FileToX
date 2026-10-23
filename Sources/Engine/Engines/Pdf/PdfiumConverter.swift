// Port of Filee.Engines/Pdf/PdfiumConverter.cs using the same bundled PDFium as PDFtoImage 5.2.1.

import CoreGraphics
import Foundation

/// PDF → every raster format the image engine writes (PNG, JPG, WEBP, TIFF, …, PSD, TGA, PPM).
final class PdfiumConverter: Converter {
    private static let multiPageTargets: Set<String> = ["tiff", "gif"]

    let id = "pdfium"
    let displayName = "PDFium"
    /// One page renderer at a time, like Filee's PDFium.
    let maxParallelism = 1

    let edges: [ConversionEdge] = ImageEncoder.writable.map { ConversionEdge("pdf", $0) }

    func status() -> EngineStatus { .available(version: PdfiumDocument.version) }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        let document = try PdfiumDocument(step.inputPath)
        let pages = PageRange.parse(step.preset.pdf.pageRange, pageCount: document.pageCount)
        let dpi = min(max(step.preset.pdf.renderDpi, 36), 1200)
        let (format, ext) = ImageEncoder.outputFormat(step.to, step.preset.image)
        var written: [String] = []
        var collected: [ImageFrame] = []

        for (index, pageIndex) in pages.enumerated() {
            try Task.checkCancellation()
            var frame = ImageFrame(image: try document.render(pageIndex, dpi: dpi), dpi: (Double(dpi), Double(dpi)))
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
}
