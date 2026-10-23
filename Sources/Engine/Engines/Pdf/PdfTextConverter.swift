// Port of Filee.Engines/Pdf/PdfTextConverter.cs: PDF → TXT, the text in reading order (also on two-column pages), one
// paragraph per line and an empty line between paragraphs. The invisible text layer of OCR-processed scans is
// included; scans without one have no text to extract (there is no OCR).

import Foundation

/// Extracts the text of PDF files.
final class PdfTextConverter: Converter {
    let id = "pdf-text"
    let displayName = "PDF text (built-in)"
    let maxParallelism = 0

    let edges = [ConversionEdge("pdf", "txt")]

    func status() -> EngineStatus {
        .available(detail: "PDF → TXT", version: "\(EngineVersions.builtIn) · \(EngineVersions.system("PDFKit"))")
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        progress?(0.1)
        let text = PdfDocumentReader.plainText(try PdfDocumentReader.readText(step.inputPath))
        try Task.checkCancellation()
        if text.isEmpty {
            throw ConversionError("The PDF contains no text (it may be scanned; Filee does not recognise text in images).")
        }
        guard let output = try step.output.allocate("txt") else { return [] }
        // UTF-8 with BOM, so Notepad and Excel-era tools pick the right encoding for Korean and Chinese text.
        try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: URL(fileURLWithPath: output))
        progress?(1)
        return [output]
    }
}
