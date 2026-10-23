// Port of Filee.Engines/Ebooks/EbookConverter.cs.
import Foundation

public final class EbookConverter: Converter {
    static let bookReaders = ["epub", "mobi", "azw3", "azw", "prc", "fb2", "htmlz", "txtz"]
    static let bookWriters = ["epub", "hwpx", "txt", "html", "md", "fb2", "htmlz", "txtz"]
    static let documentReaders = ["html", "md", "txt", "docx"]
    static let ebookWriters = ["epub", "fb2", "htmlz", "txtz"]
    static let comics = ["cbz", "cbr", "cb7", "cbt", "cbc"]
    public let id = "ebook"
    public let displayName = "E-books (built-in)"
    public let maxParallelism = 0
    public let edges: [ConversionEdge] = {
        var edges = bookReaders.flatMap { from in bookWriters.filter { $0 != from }.map { ConversionEdge(from, $0, $0 == "md" ? 12 : 10) } }
        edges += documentReaders.flatMap { from in ebookWriters.map { ConversionEdge(from, $0) } }
        edges += [ConversionEdge("html", "txt"), ConversionEdge("html", "md", 14)]
        edges += comics.flatMap { [ConversionEdge($0, "pdf"), ConversionEdge($0, "epub")] }
        edges += comics.filter { $0 != "cbz" }.map { ConversionEdge($0, "cbz") }
        return edges + [ConversionEdge("pdf", "cbz", 15), ConversionEdge("azw4", "pdf")]
    }()
    public init() {}
    public func status() -> EngineStatus { .available(detail: "EPUB, MOBI / AZW3, FB2, HTMLZ, TXTZ, CBZ / CBR / CB7 / CBT / CBC, AZW4", version: EngineVersions.builtIn + " · libxml2") }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        try Task.checkCancellation()
        progress?(0.05)
        let work = try EbookFiles.newFolder(step.workDirectory, "ebook")
        if Self.comics.contains(step.from) || step.from == "pdf" { return try await Self.comic(step, work, progress) }
        if step.from == "azw4" {
            let pdf = try MobiReader.printReplicaPdf(step.inputPath)
            guard let target = try step.output.allocate("pdf") else { return [] }
            try pdf.write(to: URL(fileURLWithPath: target)); progress?(1); return [target]
        }
        let book = try Self.read(step, work)
        progress?(0.5); try Task.checkCancellation()
        guard let output = try step.output.allocate(step.to) else { return [] }
        try Self.write(book, step, output, work); progress?(1); return [output]
    }
    private static func read(_ step: ConversionStep, _ work: String) throws -> Book {
        let input = step.inputPath, media = FilePath.combine(work, "media")
        switch step.from {
        case "epub": return try EpubReader.readBook(input, work)
        case "mobi", "azw3", "azw", "prc": return try MobiReader.readBook(input, work)
        case "fb2": return try Fb2Reader.readBook(input, work)
        case "htmlz": return try ZippedText.readHtmlzBook(input, work)
        case "txtz": return try ZippedText.readTxtzBook(input, work)
        case "txt": return Book(PlainText.toDocument(TextEncodings.decodeText(try Data(contentsOf: URL(fileURLWithPath: input)))), BookMetadata())
        case "html", "md", "docx":
            let document: HDocument
            if step.from == "html" { document = try HtmlReader.read(input, media) }
            else if step.from == "md" { document = try MarkdownReader.read(TextEncodings.decodeText(Data(contentsOf: URL(fileURLWithPath: input))), FilePath.directoryName(FilePath.fullPath(input))!) }
            else { document = try DocxReader.read(input, media) }
            let metadata = BookMetadata(); metadata.title = document.title; return Book(document, metadata)
        default: throw ConversionError("\(step.from) → \(step.to)")
        }
    }
    private static func write(_ book: Book, _ step: ConversionStep, _ output: String, _ work: String) throws {
        switch step.to {
        case "epub": try EpubWriter.write(book, output, step.inputPath, work)
        case "hwpx": book.document.title = book.displayTitle(step.inputPath); try HwpxWriter.write(book.document, output)
        case "txt": try (Data([0xEF, 0xBB, 0xBF]) + Data(PlainTextWriter.write(book.document).utf8)).write(to: URL(fileURLWithPath: output))
        case "html":
            let images = try EbookFiles.newFolder(work, "html-images"), failure = EbookFiles.ImageFailure()
            let pages = XhtmlWriter.write(book.document, XhtmlOptions(imageSource: { path in
                do { return try EbookFiles.dataUri(path, images) } catch { failure.error = error; return nil }
            }))
            if let error = failure.error { throw error }
            guard pages.count == 1, let page = pages.first else { throw ConversionError("Sequence contains more than one element") }
            try Data(XhtmlWriter.page(book.displayTitle(step.inputPath), page.body, book.displayLanguage(), nil, false).utf8).write(to: URL(fileURLWithPath: output))
        case "md":
            let failure = EbookFiles.ImageFailure()
            let markdown = try MarkdownWriter.write(book.document, EbookFiles.markdownImages(output, work, failure))
            if let error = failure.error { throw error }
            try Data(markdown.utf8).write(to: URL(fileURLWithPath: output))
        case "fb2": try Fb2Writer.write(book, output, step.inputPath, work)
        case "htmlz": try ZippedText.writeHtmlz(book, output, step.inputPath, work)
        case "txtz": try ZippedText.writeTxtz(book, output, step.inputPath, work)
        default: throw ConversionError("\(step.from) → \(step.to)")
        }
    }
    private static func comic(_ step: ConversionStep, _ work: String, _ progress: ProgressHandler?) async throws -> [String] {
        let pages: [String]
        if step.from == "pdf" { pages = try ComicBook.renderPdf(step.inputPath, step, work, progress) }
        else { pages = try await ComicBook.extractPages(step.inputPath, step.from, work) }
        progress?(0.4)
        guard let output = try step.output.allocate(step.to) else { return [] }
        switch step.to {
        case "pdf": try ComicBook.toPdf(pages, output, work, progress)
        case "epub": try EpubWriter.writeFixedLayout(FormatRegistry.nameWithoutExtension(step.inputPath), pages, output, work)
        case "cbz": try ComicBook.toCbz(pages, output)
        default: throw ConversionError("\(step.from) → \(step.to)")
        }
        progress?(1); return [output]
    }
}

extension EbookFiles {
    final class ImageFailure { var error: Error? }
    static func dataUri(_ path: String, _ convertFolder: String) throws -> String? {
        guard let (file, mediaType) = EbookFiles.commonImage(path, convertFolder, true) else { return nil }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        return "data:\(mediaType);base64,\(bytes.base64EncodedString())"
    }
    static func markdownImages(_ output: String, _ work: String, _ failure: ImageFailure) throws -> (String) -> String? {
        let folderName = FilePath.fileNameWithoutExtension(output) + "_files", folder = FilePath.combine(FilePath.directoryName(output)!, folderName)
        let convert = try EbookFiles.newFolder(work, "md-images")
        var names: [String: String] = [:]
        return { path in
            if let known = names[path.lowercased()] { return known }
            guard let (file, _) = EbookFiles.commonImage(path, convert, true) else { return nil }
            do {
                try FileManager.default.createDirectoryIfNeeded(folder)
                let name = String(format: "img%04d%@", names.count + 1, FilePath.extension(file).lowercased()), target = FilePath.combine(folder, name)
                // Copy overwrite like File.Copy(..., overwrite: true).
                try FileManager.default.writeFile(target, Data(contentsOf: URL(fileURLWithPath: file)))
                let reference = EbookFiles.uriEscape(folderName) + "/" + name
                names[path.lowercased()] = reference; return reference
            } catch { failure.error = error; return nil }
        }
    }
}
