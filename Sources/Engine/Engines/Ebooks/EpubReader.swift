// Port of Filee.Engines/Ebooks/EpubReader.cs.
import Foundation

enum EpubReader {
    private static let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
    static func read(_ path: String, _ workFolder: String) throws -> HDocument { try readBook(path, workFolder).document }
    static func readBook(_ path: String, _ workFolder: String) throws -> Book {
        let folder = try EbookFiles.newFolder(workFolder, "epub")
        let zip: ZipReader
        do { zip = try ZipReader(path: path) } catch is ZipError { throw ConversionError("This is not a valid EPUB file (it is not a ZIP package).") }
        try checkDrm(zip); try EbookFiles.extract(zip, folder)
        let package = try OpfPackage.load(OpfPackage.rootFile(folder))
        var chapters: [String] = []
        for item in package.spine {
            if ["application/xhtml+xml", "text/html", "application/xml"].contains(item.mediaType) || item.mediaType.isEmpty && item.path.lowercased().hasSuffix("html") { chapters.append(item.path) }
            else if item.mediaType.hasPrefix("image/") { chapters.append(try imagePage(item.path)) }
        }
        if chapters.isEmpty { throw ConversionError("The EPUB has no readable chapters.") }
        let document = try ChapterReader.read(chapters, FilePath.combine(folder, "~media"))
        document.title = package.metadata.title ?? document.title
        return Book(document, package.metadata)
    }
    static func checkDrm(_ zip: ZipReader) throws {
        if zip.entry(named: "META-INF/sinf.xml") != nil { throw ConversionError(EbookFiles.drmMessage) }
        guard let entry = zip.entry(named: "META-INF/encryption.xml") else { return }
        let encryption: XDocument
        do { encryption = try XDocument.load(data: zip.data(for: entry)) } catch is XmlError { return }
        let algorithms = encryption.root.descendantsAndSelf().filter { $0.name.localName == "EncryptionMethod" }.map { $0.attributeValue("Algorithm") ?? "" }
        if algorithms.contains(where: { !fontObfuscation.contains($0) }) { throw ConversionError(EbookFiles.drmMessage) }
    }
    private static func imagePage(_ image: String) throws -> String {
        let page = FilePath.combine(FilePath.directoryName(image)!, "~\(FilePath.fileNameWithoutExtension(image))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).xhtml")
        try Data("<html><body><p style=\"text-align:center\"><img src=\"\(EbookFiles.uriEscape(FilePath.fileName(image)))\"/></p></body></html>".utf8).write(to: URL(fileURLWithPath: page))
        return page
    }
}
