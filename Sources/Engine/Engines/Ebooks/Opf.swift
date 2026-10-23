// Port of Filee.Engines/Ebooks/Opf.cs. Manifest order is explicit (C# Dictionary preserves insertion order).
import Foundation

struct OpfItem {
    let id: String, path: String, mediaType: String, properties: String
}

final class OpfPackage {
    let metadata = BookMetadata()
    private(set) var manifest: [String: OpfItem] = [:]
    private(set) var manifestItems: [OpfItem] = []
    private(set) var spine: [OpfItem] = []

    static func load(_ opfPath: String) throws -> OpfPackage {
        let package = OpfPackage()
        let root = try loadXml(opfPath).root
        let folder = FilePath.directoryName(FilePath.fullPath(opfPath))!
        for item in root.elements().filter({ $0.name.localName == "manifest" }).flatMap({ $0.elements().filter { $0.name.localName == "item" } }) {
            guard let id = item.attributeValue("id"), let href = item.attributeValue("href") else { continue }
            let relative = String(href.split(separator: "#", omittingEmptySubsequences: false)[0])
            if let path = EbookFiles.safePath(folder, relative.removingPercentEncoding ?? relative), package.manifest[id] == nil {
                let value = OpfItem(id: id, path: path, mediaType: (item.attributeValue("media-type") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), properties: item.attributeValue("properties") ?? "")
                package.manifest[id] = value; package.manifestItems.append(value)
            }
        }
        for item in root.elements().filter({ $0.name.localName == "spine" }).flatMap({ $0.elements().filter { $0.name.localName == "itemref" } }) {
            if let id = item.attributeValue("idref"), let entry = package.manifest[id] { package.spine.append(entry) }
        }
        if let metadata = root.elements().first(where: { $0.name.localName == "metadata" }) { readMetadata(metadata, package) }
        return package
    }

    private static func readMetadata(_ metadata: XElement, _ package: OpfPackage) {
        func first(_ name: String) -> String? {
            metadata.descendants().first { $0.name.localName == name && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let meta = package.metadata
        meta.title = first("title"); meta.language = first("language"); meta.description = first("description"); meta.publisher = first("publisher")
        for creator in metadata.descendants().filter({ $0.name.localName == "creator" }) {
            let name = creator.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let role = creator.attributes.first { $0.name.localName == "role" }?.value
            if !name.isEmpty && (role == nil || role == "aut") && !meta.authors.contains(name) { meta.authors.append(name) }
        }
        var cover = package.manifestItems.first { $0.properties.components(separatedBy: " ").contains("cover-image") }
        if cover == nil, let coverMeta = metadata.descendants().first(where: { $0.name.localName == "meta" && $0.attributeValue("name") == "cover" }), let id = coverMeta.attributeValue("content") { cover = package.manifest[id] }
        if let cover, cover.mediaType.hasPrefix("image/"), FileManager.default.fileExists(cover.path) { meta.coverImage = cover.path }
    }

    static func rootFile(_ bookFolder: String) throws -> String {
        let container = FilePath.combine(bookFolder, "META-INF", "container.xml")
        if FileManager.default.fileExists(container) {
            let rootFile = try loadXml(container).root.descendantsAndSelf().first { $0.name.localName == "rootfile" && ($0.attributeValue("media-type") ?? "application/oebps-package+xml") == "application/oebps-package+xml" }
            if let fullPath = rootFile?.attributeValue("full-path"), let path = EbookFiles.safePath(bookFolder, fullPath.removingPercentEncoding ?? fullPath), FileManager.default.fileExists(path) { return path }
        }
        guard let path = EbookFiles.files(bookFolder).first(where: { FilePath.extension($0) == ".opf" }) else {
            throw ConversionError("This is not a valid EPUB file: it has no package document (content.opf).")
        }
        return path
    }

    static func loadXml(_ path: String) throws -> XDocument { try XDocument.load(path) }

    static func metadataOnly(_ metadata: BookMetadata, _ title: String, _ language: String) throws -> String {
        let opf = XNamespace("http://www.idpf.org/2007/opf"), dc = XNamespace("http://purl.org/dc/elements/1.1/")
        let meta = XElement(opf + "metadata", XAttribute(XNamespace.xmlns + "dc", dc.namespaceName),
            XElement(dc + "title", title), XElement(dc + "language", language),
            XElement(dc + "identifier", XAttribute("id", "uuid_id"), "urn:uuid:\(UUID().uuidString.lowercased())"))
        for author in metadata.authors { meta.add(XElement(dc + "creator", XAttribute(opf + "role", "aut"), author)) }
        if let publisher = metadata.publisher { meta.add(XElement(dc + "publisher", publisher)) }
        if let description = metadata.description { meta.add(XElement(dc + "description", description)) }
        let package = XElement(opf + "package", XAttribute("version", "2.0"), XAttribute("unique-identifier", "uuid_id"), meta)
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + (try package.toString())
    }
}
