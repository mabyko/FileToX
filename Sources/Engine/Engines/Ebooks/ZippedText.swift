// Port of Filee.Engines/Ebooks/ZippedText.cs.
import Foundation

enum ZippedText {
    static func readHtmlz(_ path: String, _ workFolder: String) throws -> HDocument { try readHtmlzBook(path, workFolder).document }
    static func readTxtz(_ path: String, _ workFolder: String) throws -> HDocument { try readTxtzBook(path, workFolder).document }
    static func readHtmlzBook(_ path: String, _ workFolder: String) throws -> Book {
        let folder = try extract(path, workFolder, "htmlz")
        guard let page = mainFile(folder, "index.html", [".html", ".htm", ".xhtml"]) else { throw ConversionError("The HTMLZ file contains no HTML page.") }
        let document = try ChapterReader.read([page], FilePath.combine(folder, "~media")), metadata = try self.metadata(folder)
        document.title = metadata.title ?? document.title; return Book(document, metadata)
    }
    static func readTxtzBook(_ path: String, _ workFolder: String) throws -> Book {
        let folder = try extract(path, workFolder, "txtz")
        guard let text = mainFile(folder, "index.txt", [".txt", ".md", ".markdown", ".text"]) else { throw ConversionError("The TXTZ file contains no text file.") }
        let document = try MarkdownReader.read(TextEncodings.decodeText(Data(contentsOf: URL(fileURLWithPath: text))), FilePath.directoryName(text)!)
        let metadata = try self.metadata(folder); document.title = metadata.title ?? document.title; return Book(document, metadata)
    }
    static func writeHtmlz(_ book: Book, _ outputPath: String, _ sourcePath: String, _ workFolder: String) throws {
        let title = book.displayTitle(sourcePath), language = book.displayLanguage(), images = ImageSet(try EbookFiles.newFolder(workFolder, "htmlz-images"))
        let pages = XhtmlWriter.write(book.document, XhtmlOptions(imageSource: images.add))
        guard pages.count == 1, let page = pages.first else { throw ConversionError("Sequence contains more than one element") }
        try save(outputPath, [("index.html", XhtmlWriter.page(title, page.body, language, "style.css", false)), ("style.css", XhtmlWriter.css), ("metadata.opf", try OpfPackage.metadataOnly(book.metadata, title, language))], images)
    }
    static func writeTxtz(_ book: Book, _ outputPath: String, _ sourcePath: String, _ workFolder: String) throws {
        let title = book.displayTitle(sourcePath), images = ImageSet(try EbookFiles.newFolder(workFolder, "txtz-images"))
        let text = MarkdownWriter.write(book.document, images.add)
        try save(outputPath, [("index.txt", text), ("metadata.opf", try OpfPackage.metadataOnly(book.metadata, title, book.displayLanguage()))], images)
    }
    private static func extract(_ path: String, _ workFolder: String, _ prefix: String) throws -> String {
        let folder = try EbookFiles.newFolder(workFolder, prefix)
        do { try EbookFiles.extract(ZipReader(path: path), folder) }
        catch is ZipError { throw ConversionError("This is not a valid \(prefix.uppercased()) file (it is not a ZIP archive).") }
        return folder
    }
    private static func mainFile(_ folder: String, _ preferred: String, _ extensions: [String]) -> String? {
        let top = FilePath.combine(folder, preferred)
        if FileManager.default.fileExists(top) { return top }
        return EbookFiles.files(folder).filter { extensions.contains(FilePath.extension($0).lowercased()) }.sorted {
            let a = $0.filter { $0 == "/" }.count, b = $1.filter { $0 == "/" }.count
            return a == b ? $0.lowercased() < $1.lowercased() : a < b
        }.first
    }
    private static func metadata(_ folder: String) throws -> BookMetadata {
        guard let opf = EbookFiles.files(folder).first(where: { FilePath.extension($0) == ".opf" }) else { return BookMetadata() }
        do { return try OpfPackage.load(opf).metadata } catch is XmlError { return BookMetadata() }
    }
    private static func save(_ outputPath: String, _ texts: [(String, String)], _ images: ImageSet) throws {
        let temp = outputPath + ".tmp", zip = try ZipWriter(path: temp)
        for (name, text) in texts { try zip.add(name, text: text) }
        for (name, file) in images.files { try zip.add(name, contentsOf: file, level: .noCompression) }
        try zip.close(); try EbookFiles.replace(temp, outputPath)
    }
    private final class ImageSet {
        let convertFolder: String
        private var names: [String: String] = [:]
        private(set) var files: [(name: String, file: String)] = []
        init(_ convertFolder: String) { self.convertFolder = convertFolder }
        func add(_ path: String) -> String? {
            if let known = names[path.lowercased()] { return known }
            guard let (file, _) = EbookFiles.commonImage(path, convertFolder, true) else { return nil }
            let name = String(format: "images/img%04d%@", files.count + 1, FilePath.extension(file).lowercased())
            files.append((name, file)); names[path.lowercased()] = name; return name
        }
    }
}
