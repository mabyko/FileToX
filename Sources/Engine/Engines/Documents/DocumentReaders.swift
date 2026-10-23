// Port of DocumentReaders.cs. Format arrays preserve Filee dictionary insertion order.
import Foundation

enum DocumentReaders {
    static let builtInFormats = [
        "docx", "docm", "dotx", "dotm", "txt", "md", "xlsx", "xlsm", "xltx", "csv", "tsv", "xls", "ods", "pptx", "pptm",
        "potx", "ppsx", "pdf", "hwpx", "html", "epub", "mobi", "azw3", "azw", "prc", "fb2", "htmlz", "txtz",
    ]
    static let throughPandoc = [("odt", "odt"), ("rtf", "rtf"), ("html", "html"), ("rst", "rst"), ("tex", "latex")]
    static let pdfPenalty = 6
    static var pandocFormats: [String] { throughPandoc.map(\.0).filter { !builtInFormats.contains($0) } }
    static func formats(_ pandoc: Bool) -> [String] { builtInFormats + (pandoc ? pandocFormats : []) }
    static func needsPandoc(_ format: String) -> Bool {
        !builtInFormats.contains(format.lowercased()) && throughPandoc.contains { $0.0 == format.lowercased() }
    }
    static func readAsync(_ path: String, _ format: String, _ workDirectory: String) async throws -> HDocument {
        try Task.checkCancellation()
        let media = FilePath.combine(workDirectory, "media-" + DocumentXML.guid())
        let f = format.lowercased()
        switch f {
        case "docx", "docm", "dotx", "dotm": return try DocxReader.read(path, media)
        case "txt": return try textDocument(Data(contentsOf: URL(fileURLWithPath: path)))
        case "md":
            return try MarkdownReader.read(
                TextEncodings.decodeText(Data(contentsOf: URL(fileURLWithPath: path))),
                FilePath.directoryName(FilePath.fullPath(path))!)
        case "xlsx", "xlsm", "xltx": return try SheetDocument.build(XlsxReader.read(path))
        case "csv": return try SheetDocument.build(CsvFormat.read(path))
        case "tsv", "xls", "ods": return try SheetDocument.build(SpreadsheetConverter.read(path, f))
        case "pptx", "pptm", "potx", "ppsx": return try PptxReader.read(path, media)
        case "pdf": return try PdfDocumentReader.read(path, media)
        case "hwpx": return try HwpxReader.read(path, media)
        case "html": return try HtmlReader.read(path, media)
        case "epub": return try EpubReader.read(path, media)
        case "mobi", "azw3", "azw", "prc": return try MobiReader.read(path, media)
        case "fb2": return try Fb2Reader.read(path, media)
        case "htmlz": return try ZippedText.readHtmlz(path, media)
        case "txtz": return try ZippedText.readTxtz(path, media)
        default:
            guard let reader = throughPandoc.first(where: { $0.0 == f })?.1 else {
                throw ConversionError("There is no document reader for \(format.uppercased()) files.")
            }
            guard let pandoc = PandocConverter.locate() else { throw ConversionError("Pandoc was not found.") }
            let json = FilePath.combine(workDirectory, "ast-" + DocumentXML.guid() + ".json")
            let inputFolder = FilePath.directoryName(FilePath.fullPath(path))!
            let result = try await ProcessRunner.run(
                pandoc, [path, "-f", reader, "-t", "json", "--extract-media=" + media, "-o", json], timeout: 120,
                workingDirectory: inputFolder)
            if !FileManager.default.fileExists(json) {
                throw ConversionError(
                    "Pandoc failed (exit \(result.exitCode)). \(DocumentXML.trim(result.standardError))")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: json))
            let ast = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            if ast is NSNull { throw ConversionError("Pandoc produced an empty document.") }
            return try PandocAstReader.read(ast) { target in
                if DocumentXML.trim(target).isEmpty || target.contains("://") { return nil }
                let p = target.removingPercentEncoding ?? target
                for candidate in [p, FilePath.combine(inputFolder, p)] where FileManager.default.fileExists(candidate) {
                    return FilePath.fullPath(candidate)
                }
                return nil
            }
        }
    }
    static func decodeText(_ bytes: Data) -> String { TextEncodings.decodeText(bytes) }
    static func textDocument(_ bytes: Data) -> HDocument {
        let doc = HDocument()
        let section = HSection()
        for line in TextEncodings.decodeText(bytes).replacingOccurrences(of: "\r\n", with: "\n").components(
            separatedBy: "\n")
        {
            let p = HParagraph()
            if !line.isEmpty { p.inlines.append(HText(line)) }
            section.blocks.append(p)
        }
        doc.sections.append(section)
        return doc
    }
}
