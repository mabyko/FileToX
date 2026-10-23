// Port of Filee.Engines/Ebooks/ChapterReader.cs.
import Foundation

enum ChapterReader {
    static func read(_ chapters: [String], _ mediaFolder: String) throws -> HDocument {
        var index: [String: Int] = [:]
        for i in chapters.indices { let path = FilePath.fullPath(chapters[i]).lowercased(); if index[path] == nil { index[path] = i } }
        let section = HSection(), document = HDocument(); document.sections.append(section)
        for i in chapters.indices {
            try Task.checkCancellation()
            let chapter = FilePath.fullPath(chapters[i])
            if !FileManager.default.fileExists(chapter) { continue }
            var content = try HtmlReader.readFile(chapter, HtmlReadOptions(baseFolder: FilePath.directoryName(chapter)!, mediaFolder: mediaFolder,
                mapLink: { link($0, chapter, i, index) }, mapId: { anchor(i, $0) }))
            if document.title == nil { document.title = content.title }
            if !content.blocks.contains(where: hasContent) { continue }
            let first: HParagraph
            if let paragraph = content.blocks.first as? HParagraph { first = paragraph }
            else { first = HParagraph(); content.blocks.insert(first, at: 0) }
            first.pageBreakBefore = !section.blocks.isEmpty
            first.inlines.insert(HBookmark(anchor(i, nil)), at: 0)
            section.blocks += content.blocks
        }
        HtmlReader.pruneBookmarks(document)
        return document
    }
    private static func hasContent(_ block: HBlock) -> Bool {
        block is HTable || HDocumentWalker.inlines([block]).contains { $0 is HImage || ($0 as? HText).map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true }
    }
    private static func anchor(_ chapter: Int, _ id: String?) -> String {
        guard let id else { return "c\(chapter + 1)" }
        let clean = id.utf16.map { c -> UInt16 in ((65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 45 || c == 95) ? c : 95 }
        return "c\(chapter + 1)-" + String(decoding: clean, as: UTF16.self)
    }
    private static func link(_ href: String, _ chapter: String, _ number: Int, _ index: [String: Int]) -> String? {
        if href.hasPrefix("#") { let fragment = String(href.dropFirst()); return fragment.isEmpty ? nil : "#" + anchor(number, EbookFiles.uriUnescape(fragment)) }
        if let colon = href.firstIndex(of: ":"), href[..<colon].utf16.count > 1, href[..<colon].utf16.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) { return href.lowercased().hasPrefix("javascript:") ? nil : href }
        let pieces = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var file = pieces[0]
        let fragment = pieces.count > 1 ? EbookFiles.uriUnescape(pieces[1]) : nil
        file = file.components(separatedBy: "?")[0]
        let relative = EbookFiles.uriUnescape(file)
        if relative.utf8.contains(0) { return nil }
        let target = FilePath.fullPath(FilePath.combine(FilePath.directoryName(chapter)!, relative))
        guard let chapterIndex = index[target.lowercased()] else { return nil }
        return "#" + anchor(chapterIndex, fragment?.isEmpty == false ? fragment : nil)
    }
}
