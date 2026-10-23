// Port of Filee.Engines/Pdf/PdfSharpConverter.cs: builds PDFs from images, splits / extracts PDF pages and merges PDFs.
// PDFsharp is replaced by a Core Graphics PDF context (image pages) and PDFKit (page copies, merging).

import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Image → PDF, PDF → PDF (split / page range) and PDF merging. Engine id "pdfsharp" is kept from Filee.
final class PdfSharpConverter: Converter, PdfMerger {
    private static let pointsPerInch = 72.0
    private static let millimetresPerInch = 25.4

    let id = "pdfsharp"
    let displayName = "PDF pages (built-in)"
    let maxParallelism = 0

    let edges: [ConversionEdge] = ImageEncoder.sources.map { ConversionEdge($0, "pdf") } + [ConversionEdge("pdf", "pdf")]

    func status() -> EngineStatus { .available(version: EngineVersions.system("PDFKit")) }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        step.from == "pdf" ? try splitOrExtract(step, progress) : try imageToPdf(step, progress)
    }

    func merge(_ inputPaths: [String], into outputPath: String) async throws {
        let output = PDFDocument()
        for input in inputPaths {
            try Task.checkCancellation()
            let source = try Self.open(input)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
                output.insert(page, at: output.pageCount)
            }
        }
        try Self.save(output, to: outputPath)
    }

    /// Places every frame of an image (TIFF pages, ...) on its own PDF page.
    private func imageToPdf(_ step: ConversionStep, _ progress: ProgressHandler?) throws -> [String] {
        let options = step.preset.image
        let pdfOptions = step.preset.pdf
        let images = try ImageReader.read(step.inputPath, format: step.from, preset: step.preset)
        let frames = ImageEncoder.selectFrames(images, sourceFormat: step.from, targetFormat: "pdf")

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConversionError("Could not create the PDF.")
        }
        for (i, original) in frames.enumerated() {
            try Task.checkCancellation()
            // The resolution the file was saved with (ImageMagick's density), before the preset changes anything.
            let dpi = original.dpi.map { $0.x > 0 ? $0.x : 96 } ?? 96

            // "pdf" as target: resize / grayscale / metadata apply, no format-specific encoding settings.
            let frame = try ImageEncoder.applyOptions(original, options, targetFormat: "pdf")
            let image = try Self.encodeForPdf(frame, sourceFormat: step.from, options)

            let imageWidth = Double(frame.image.width) / dpi * Self.pointsPerInch
            let imageHeight = Double(frame.image.height) / dpi * Self.pointsPerInch
            var (pageWidth, pageHeight) = Self.pageSize(pdfOptions.pageSize, landscape: imageWidth > imageHeight)
            if pdfOptions.pageSize == .fitImage { (pageWidth, pageHeight) = (imageWidth, imageHeight) }

            // Fit the image inside the page margins, keeping its aspect ratio, centred.
            let margin = pdfOptions.pageSize == .fitImage ? 0 : pdfOptions.marginMm / Self.millimetresPerInch * Self.pointsPerInch
            let boxWidth = pageWidth - 2 * margin, boxHeight = pageHeight - 2 * margin
            let scale = min(boxWidth / imageWidth, boxHeight / imageHeight)
            let drawWidth = imageWidth * scale, drawHeight = imageHeight * scale

            var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: margin + (boxWidth - drawWidth) / 2, y: margin + (boxHeight - drawHeight) / 2,
                                           width: drawWidth, height: drawHeight))
            context.endPDFPage()
            progress?(Double(i + 1) / Double(frames.count))
        }
        context.closePDF()

        guard let path = try step.output.allocate("pdf") else { return [] }
        try FileManager.default.writeFile(path, data as Data)
        return [path]
    }

    /// PDF → PDF: split into single pages, or extract the configured page range.
    private func splitOrExtract(_ step: ConversionStep, _ progress: ProgressHandler?) throws -> [String] {
        let source = try Self.open(step.inputPath)
        let pages = PageRange.parse(step.preset.pdf.pageRange, pageCount: source.pageCount)
        var written: [String] = []

        if step.preset.pdf.splitPages {
            for (i, index) in pages.enumerated() {
                try Task.checkCancellation()
                let single = PDFDocument()
                if let page = source.page(at: index)?.copy() as? PDFPage { single.insert(page, at: 0) }
                guard let path = try step.output.allocate("pdf", suffix: "_p\(index + 1)") else { continue }
                try Self.save(single, to: path)
                written.append(path)
                progress?(Double(i + 1) / Double(pages.count))
            }
            return written
        }

        let extract = PDFDocument()
        for index in pages {
            if let page = source.page(at: index)?.copy() as? PDFPage { extract.insert(page, at: extract.pageCount) }
        }
        guard let output = try step.output.allocate("pdf") else { return [] }
        try Self.save(extract, to: output)
        return [output]
    }

    /// The image to embed. JPEG sources stay JPEG (passed through as DCT data, after one re-encode at high quality);
    /// everything else is embedded losslessly (Core Graphics compresses it with Flate).
    private static func encodeForPdf(_ frame: ImageFrame, sourceFormat: String, _ options: ImageOptions) throws -> CGImage {
        guard sourceFormat == "jpg", !ImagePixels.hasAlpha(frame.image) else { return frame.image }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return frame.image }
        CGImageDestinationAddImage(destination, frame.image,
                                   [kCGImageDestinationLossyCompressionQuality: ImageEncoder.jpegQuality(max(options.quality, 85))] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return frame.image
        }
        return jpeg
    }

    private static func pageSize(_ size: PdfPageSize, landscape: Bool) -> (Double, Double) {
        let (w, h) = size == .letter ? (612.0, 792.0) : (595.28, 841.89) // A4
        return landscape ? (h, w) : (w, h)
    }

    /// Opens a PDF for reading its pages; password-protected files fail with Filee's message.
    static func open(_ path: String) throws -> PDFDocument {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw ConversionError("\(FilePath.fileName(path)) is not a PDF file that can be read.")
        }
        if document.isLocked {
            throw ConversionError("The PDF is password-protected. Open it with its password and save a copy without one, then convert that copy.")
        }
        return document
    }

    static func save(_ document: PDFDocument, to path: String) throws {
        guard let data = document.dataRepresentation() else { throw ConversionError("Could not write \(FilePath.fileName(path)).") }
        try FileManager.default.writeFile(path, data)
    }
}
