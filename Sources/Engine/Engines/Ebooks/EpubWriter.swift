// Port of Filee.Engines/Ebooks/EpubWriter.cs.
import Foundation

enum EpubWriter {
    static func write(_ book: Book, _ outputPath: String, _ sourcePath: String, _ workFolder: String) throws {
        let title = book.displayTitle(sourcePath), language = book.displayLanguage()
        let package = EpubPackage(title, language, book.metadata), imageFolder = try EbookFiles.newFolder(workFolder, "epub-images")
        let chapters = XhtmlWriter.write(book.document, XhtmlOptions(splitChapters: true, chapterFile: { String(format: "ch%03d.xhtml", $0 + 1) }, imageSource: { package.addImage($0, imageFolder) }, epub: true))
        var cover: String?
        if let file = book.metadata.coverImage, FileManager.default.fileExists(file) { cover = package.addImage(file, imageFolder, true) }
        if let cover, !HDocumentWalker.images(book.document).contains(where: { $0.path.lowercased() == book.metadata.coverImage?.lowercased() }) {
            let body = "<div style=\"text-align:center\"><img src=\"\(XhtmlWriter.escape(cover))\" alt=\"\(XhtmlWriter.escape(title))\" style=\"max-height:100%\"/></div>\n"
            package.addPage("cover.xhtml", XhtmlWriter.page(title, body, language, "style.css", true))
        }
        for chapter in chapters { package.addPage(chapter.fileName, XhtmlWriter.page(chapter.title ?? title, chapter.body, language, "style.css", true)) }
        package.toc += tableOfContents(chapters, title)
        try package.save(outputPath, XhtmlWriter.css, false)
    }
    static func writeFixedLayout(_ title: String, _ pages: [String], _ outputPath: String, _ workFolder: String) throws {
        let package = EpubPackage(title, "en", BookMetadata()), imageFolder = try EbookFiles.newFolder(workFolder, "epub-images")
        var count = 0
        for picture in pages {
            try Task.checkCancellation()
            guard let source = package.addImage(picture, imageFolder, count == 0) else { continue }
            guard let info = EbookFiles.imageInfo(picture) else { throw ConversionError("The comic contains no readable pictures.") }
            count += 1
            let page = String(format: "p%04d.xhtml", count)
            let head = "<meta name=\"viewport\" content=\"width=\(info.width), height=\(info.height)\"/>\n"
            let body = "<div class=\"page\"><img src=\"\(XhtmlWriter.escape(source))\" alt=\"\" width=\"\(info.width)\" height=\"\(info.height)\"/></div>\n"
            package.addPage(page, XhtmlWriter.page(title, body, "en", "style.css", true, head))
        }
        if count == 0 { throw ConversionError("The comic contains no readable pictures.") }
        try package.save(outputPath, "body{margin:0;padding:0;}\n.page{margin:0;padding:0;}\nimg{display:block;margin:0;padding:0;}\n", true)
    }
    private static func tableOfContents(_ chapters: [XhtmlChapter], _ title: String) -> [XhtmlHeading] {
        let headings = chapters.flatMap(\.headings).filter { !$0.text.isEmpty }
        if let top = headings.map(\.level).min() { return headings.filter { $0.level <= top + 1 }.map { XhtmlHeading(level: $0.level - top + 1, text: $0.text, target: $0.target) } }
        return chapters.enumerated().map { i, c in XhtmlHeading(level: 1, text: i == 0 ? title : !c.plainStart.isEmpty ? c.plainStart + "…" : "\(i + 1)", target: c.fileName) }
    }
}

final class EpubPackage {
    private let title: String, language: String, metadata: BookMetadata
    private var pages: [(href: String, content: String)] = []
    private var images: [(href: String, source: String, mediaType: String, cover: Bool)] = []
    private var imageBySource: [String: String] = [:]
    var toc: [XhtmlHeading] = []
    init(_ title: String, _ language: String, _ metadata: BookMetadata) { self.title = title; self.language = language; self.metadata = metadata }
    func addPage(_ href: String, _ content: String) { pages.append((href, content)) }
    func addImage(_ path: String, _ convertFolder: String, _ cover: Bool = false) -> String? {
        if let known = imageBySource[path.lowercased()] {
            if cover, let index = images.firstIndex(where: { $0.href == known }) { images[index].cover = true }
            return known
        }
        guard let (file, mediaType) = EbookFiles.commonImage(path, convertFolder, true) else { return nil }
        let ext = mediaType == "image/jpeg" ? "jpg" : mediaType == "image/png" ? "png" : mediaType == "image/gif" ? "gif" : "svg"
        let href = String(format: "images/img%04d.%@", images.count + 1, ext)
        images.append((href, file, mediaType, cover)); imageBySource[path.lowercased()] = href
        return href
    }
    func save(_ outputPath: String, _ css: String, _ fixedLayout: Bool) throws {
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())", temp = outputPath + ".tmp"
        let zip = try ZipWriter(path: temp)
        try zip.add("mimetype", text: "application/epub+zip", level: .noCompression)
        try zip.add("META-INF/container.xml", text: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n<rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles>\n</container>\n")
        try zip.add("OEBPS/content.opf", text: opf(identifier, fixedLayout))
        try zip.add("OEBPS/nav.xhtml", text: nav())
        try zip.add("OEBPS/toc.ncx", text: ncx(identifier))
        try zip.add("OEBPS/style.css", text: css)
        for (href, content) in pages { try zip.add("OEBPS/" + href, text: content) }
        for image in images { try zip.add("OEBPS/" + image.href, data: Data(contentsOf: URL(fileURLWithPath: image.source)), level: .noCompression) }
        try zip.close(); try EbookFiles.replace(temp, outputPath)
    }
    private func e(_ text: String) -> String { XhtmlWriter.escape(text) }
    private func opf(_ identifier: String, _ fixedLayout: Bool) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" xml:lang=\"\(e(language))\""
        if fixedLayout { s += " prefix=\"rendition: http://www.idpf.org/vocab/rendition/#\"" }
        s += ">\n<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n<dc:identifier id=\"book-id\">\(identifier)</dc:identifier>\n<dc:title>\(e(title))</dc:title>\n<dc:language>\(e(language))</dc:language>\n"
        for author in metadata.authors { s += "<dc:creator>\(e(author))</dc:creator>\n" }
        if let publisher = metadata.publisher { s += "<dc:publisher>\(e(publisher))</dc:publisher>\n" }
        if let description = metadata.description { s += "<dc:description>\(e(description))</dc:description>\n" }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        s += "<meta property=\"dcterms:modified\">\(date.string(from: Date()))</meta>\n"
        if let cover = images.firstIndex(where: \.cover) { s += "<meta name=\"cover\" content=\"img\(cover + 1)\"/>\n" }
        if fixedLayout { s += "<meta property=\"rendition:layout\">pre-paginated</meta>\n<meta property=\"rendition:spread\">auto</meta>\n" }
        s += "</metadata>\n<manifest>\n<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n"
        for (i, page) in pages.enumerated() { s += "<item id=\"page\(i + 1)\" href=\"\(e(page.href))\" media-type=\"application/xhtml+xml\"/>\n" }
        for (i, image) in images.enumerated() { s += "<item id=\"img\(i + 1)\" href=\"\(e(image.href))\" media-type=\"\(image.mediaType)\"\(image.cover ? " properties=\"cover-image\"" : "")/>\n" }
        s += "</manifest>\n<spine toc=\"ncx\">\n"
        for i in pages.indices { s += "<itemref idref=\"page\(i + 1)\"/>\n" }
        return s + "</spine>\n</package>\n"
    }
    private func nav() -> String {
        var s = "<nav epub:type=\"toc\" id=\"toc\">\n<h1>\(e(contentsLabel()))</h1>\n", depth = 0
        for entry in entries() {
            let level = min(entry.level, depth + 1)
            s += level > depth ? "<ol>\n" : "</li>\n"
            while depth > level { s += "</ol>\n</li>\n"; depth -= 1 }
            depth = level
            s += "<li><a href=\"\(e(entry.target))\">\(e(entry.text))</a>"
        }
        while depth > 0 { s += "</li>\n</ol>\n"; depth -= 1 }
        return XhtmlWriter.page(title, s + "</nav>\n", language, "style.css", true)
    }
    private func ncx(_ identifier: String) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\n<head>\n<meta name=\"dtb:uid\" content=\"\(identifier)\"/>\n<meta name=\"dtb:depth\" content=\"\(max(1, entries().map(\.level).max() ?? 0))\"/>\n<meta name=\"dtb:totalPageCount\" content=\"0\"/>\n<meta name=\"dtb:maxPageNumber\" content=\"0\"/>\n</head>\n<docTitle><text>\(e(title))</text></docTitle>\n<navMap>\n"
        var depth = 0
        for (i, entry) in entries().enumerated() {
            let level = min(entry.level, depth + 1)
            while depth >= level { s += "</navPoint>\n"; depth -= 1 }
            depth = level
            s += "<navPoint id=\"nav\(i + 1)\" playOrder=\"\(i + 1)\"><navLabel><text>\(e(entry.text))</text></navLabel><content src=\"\(e(entry.target))\"/>\n"
        }
        while depth > 0 { s += "</navPoint>\n"; depth -= 1 }
        return s + "</navMap>\n</ncx>\n"
    }
    private func entries() -> [XhtmlHeading] { toc.isEmpty ? [XhtmlHeading(level: 1, text: title, target: pages.first?.href ?? "nav.xhtml")] : toc }
    private func contentsLabel() -> String { ["ko": "목차", "zh": "目录", "ja": "目次"][language.components(separatedBy: "-")[0].lowercased()] ?? "Contents" }
}
