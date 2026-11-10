// Port of Filee.Engines/Pdf/PdfTextConverter.cs: PDF → TXT, the text in reading order (also on two-column pages), one
// paragraph per line and an empty line between paragraphs. The invisible text layer of OCR-processed scans is
// included, and pages without any text (scans; pictures made into PDF pages) are read with Vision's text recognition.
// Rich outputs use the page-picture route when a text bridge would discard pictures, drawings or visible text it can't
// read, while retaining the available text.

import Foundation

/// Extracts the text of PDF files.
final class PdfTextConverter: Converter {
    let id = "pdf-text"
    let displayName = "PDF text (built-in)"
    let maxParallelism = 0

    let edges = [ConversionEdge("pdf", "txt", isTextExtraction: true)]

    func status() -> EngineStatus {
        .available(detail: "PDF → TXT", version: "\(EngineVersions.builtIn) · \(EngineVersions.system("PDFKit")) · Vision")
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        progress?(0.1)
        // An output that keeps pages re-plans through their pictures instead, so it does not wait for recognition.
        let (document, pagesWithoutText, needsPictures, textPages) = try await PdfDocumentReader.readText(
            step.inputPath, recognize: !step.keepsPages, progress: progress.map { report in { report(0.1 + 0.85 * $0) } })
        let text = PdfDocumentReader.plainText(document)
        try Task.checkCancellation()
        if text.isEmpty { throw NoTextError("The PDF contains no text, and none was recognised in its pages.") }
        if step.keepsPages, try needsPictures || PdfDocumentReader.showsAnything(step.inputPath, pagesWithoutText)
            || PdfDocumentReader.showsAnything(step.inputPath, textPages: textPages) {
            throw NoTextError("The PDF contains page content that text extraction would leave out.")
        }
        guard let output = try step.output.allocate("txt") else { return [] }
        // UTF-8 with BOM, so Notepad and Excel-era tools pick the right encoding for Korean and Chinese text.
        try FileManager.default.writeFile(output, Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8))
        progress?(1)
        return [output]
    }
}
