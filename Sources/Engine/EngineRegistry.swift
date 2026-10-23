// Port of Filee.Engines/EngineRegistry.cs: THE place where conversion engines are registered.
// Order is Filee's (built-in engines first, optional tools last); it only breaks ties when no priority is set.

import Foundation

public enum EngineRegistry {
    /// Every converter, with the same ids and order as Filee's `EngineRegistry.CreateAll`.
    public static func createAll(_ environment: EngineEnvironment) -> [Converter] {
        var converters: [Converter] = []
        // Engines are appended here as they are ported, in Filee's order:
        // magick, pdfsharp, pdfium, rhwp, unhwp, markdown, spreadsheet, ooxml, hwpx-writer, archive, vector, icns,
        // font, docx-writer, pdf-text, email, ffmpeg, cad, ebook, pandoc, ghostscript, calibre, libreoffice.
        _ = environment
        converters.append(ArchiveConverter())
        return converters
    }

    public static func findPdfMerger(_ converters: [Converter]) -> PdfMerger? { converters.lazy.compactMap { $0 as? PdfMerger }.first }
    public static func findTiffMerger(_ converters: [Converter]) -> TiffMerger? { converters.lazy.compactMap { $0 as? TiffMerger }.first }
    public static func findFileCombiner(_ converters: [Converter]) -> FileCombiner? { converters.lazy.compactMap { $0 as? FileCombiner }.first }
}
