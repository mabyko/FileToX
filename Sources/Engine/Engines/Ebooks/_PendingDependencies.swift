// Temporary cross-group APIs, named by docs/design/swift-engine-port.md. Delete on integration.
import Foundation

struct XhtmlHeading { var level: Int; var text: String; var target: String }
struct XhtmlChapter { var fileName: String; var title: String?; var body: String; var plainStart: String; var headings: [XhtmlHeading] }
struct XhtmlOptions {
    var splitChapters = false
    var chapterFile: (Int) -> String = { String(format: "ch%03d.xhtml", $0 + 1) }
    var imageSource: (String) -> String?
    var epub = false
}
enum XhtmlWriter {
    static func write(_ document: HDocument, _ options: XhtmlOptions) throws -> [XhtmlChapter] { throw ConversionError("not ported yet") }
    static func page(_ title: String,_ body: String,_ language: String,_ styleSheet: String?,_ epub: Bool,_ head: String = "") -> String {
        (epub ? "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" : "")+"<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\""+(epub ? " xmlns:epub=\"http://www.idpf.org/2007/ops\"" : "")+" lang=\"\(escape(language))\" xml:lang=\"\(escape(language))\">\n<head>\n<meta charset=\"utf-8\"/>\n<title>\(escape(title))</title>\n"+head+(styleSheet.map { "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escape($0))\"/>\n" } ?? "<style>\n\(css)</style>\n")+"</head>\n<body>\n"+body+"</body>\n</html>\n"
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static let css = ""
}
enum MarkdownWriter {
    static func write(_ document: HDocument, _ imageTarget: @escaping (String) -> String?) throws -> String { throw ConversionError("not ported yet") }
}
enum PlainTextWriter {
    static func write(_ document: HDocument) throws -> String { throw ConversionError("not ported yet") }
}
enum HwpxWriter {
    static func write(_ document: HDocument, _ outputPath: String, _ template: Data? = nil) throws { throw ConversionError("not ported yet") }
}
enum DocxReader {
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument { throw ConversionError("not ported yet") }
}
enum DocumentReaders {
    static func textDocument(_ bytes: Data) -> HDocument {
        let document = HDocument(), section = HSection(); document.sections.append(section)
        for line in TextEncodings.decodeText(bytes).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let paragraph = HParagraph(); paragraph.inlines.append(HText(line)); section.blocks.append(paragraph)
        }
        return document
    }
}
struct HtmlReadOptions {
    var baseFolder: String
    var mediaFolder: String
    var mapLink: ((String) -> String?)?
    var mapId: ((String) -> String?)?
}
struct HtmlContent { var blocks: [HBlock]; var title: String?; var language: String? }
enum HtmlReader {
    static let codeShade = "#F1F0F5"
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument { throw ConversionError("not ported yet") }
    static func readFile(_ path: String, _ options: HtmlReadOptions) throws -> HtmlContent { throw ConversionError("not ported yet") }
    static func mergeRuns(_ inlines: inout [HInline]) {
        var result: [HInline] = []
        for inline in inlines {
            if let text = inline as? HText, let previous = result.last as? HText, text.format == previous.format { result[result.count - 1] = HText(previous.text + text.text, text.format) }
            else { result.append(inline) }
        }
        inlines = result
    }
    static func pruneBookmarks(_ document: HDocument) {}
}
enum MarkdownReader {
    static func read(_ markdown: String, _ baseFolder: String) throws -> HDocument { throw ConversionError("not ported yet") }
}
enum HDocumentWalker {
    static func inlines(_ blocks: [HBlock]) -> [HInline] {
        var result: [HInline] = []
        func walk(_ blocks: [HBlock]) {
            for block in blocks {
                if let paragraph = block as? HParagraph { walk(paragraph.inlines) }
                else if let table = block as? HTable { walk(table.caption); for row in table.rows { for cell in row.cells { walk(cell.blocks) } } }
            }
        }
        func walk(_ inlines: [HInline]) {
            result += inlines
            for inline in inlines {
                if let link = inline as? HLink { walk(link.content) }
                else if let note = inline as? HNote { walk(note.blocks) }
                else if let box = inline as? HTextBox { walk(box.blocks) }
            }
        }
        walk(blocks); return result
    }
    static func inlinesOf(_ inlines: [HInline]) -> [HInline] { inlines.flatMap { [$0] + (($0 as? HLink).map { inlinesOf($0.content) } ?? []) } }
    static func images(_ document: HDocument) -> [HImage] { document.sections.flatMap { inlines($0.blocks) }.compactMap { $0 as? HImage } }
    static func text(_ inlines: [HInline]) -> String {
        inlinesOf(inlines).map { ($0 as? HText)?.text ?? ($0 is HLineBreak || $0 is HTab ? " " : "") }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
final class ListNumbers {
    private var counters: [ObjectIdentifier: [Int]] = [:]
    func next(_ item: HListRef) -> String {
        if item.numbering.levels.isEmpty { return "•" }
        let level = min(item.level, item.numbering.levels.count - 1), definition = item.numbering.levels[min(item.level, item.numbering.levels.count - 1)]
        if definition.bullet { return definition.text.isEmpty ? "•" : definition.text }
        let key = ObjectIdentifier(item.numbering)
        var values = counters[key] ?? [Int](repeating: 0, count: max(10, item.numbering.levels.count))
        values[level] = values[level] == 0 ? definition.start : values[level] + 1
        for deeper in level + 1..<values.count { values[deeper] = 0 }
        counters[key] = values
        var text = definition.text
        for l in (1...min(9, item.numbering.levels.count)).reversed() {
            let value = values[l - 1] == 0 ? item.numbering.levels[l - 1].start : values[l - 1]
            text = text.replacingOccurrences(of: "^\(l)", with: Self.format(value, item.numbering.levels[l - 1].format))
        }
        return text
    }
    static func format(_ value: Int, _ format: String) -> String {
        switch format {
        case "LATIN_SMALL", "LATIN_CAPITAL":
            if value < 1 { return String(value) }
            var value = value, output = ""
            while value > 0 { output = String(UnicodeScalar((format == "LATIN_SMALL" ? 97 : 65) + (value - 1) % 26)!) + output; value = (value - 1) / 26 }
            return output
        case "ROMAN_SMALL", "ROMAN_CAPITAL":
            if value < 1 || value > 3999 { return String(value) }
            var value = value, output = ""
            for (number, text) in [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")] { while value >= number { output += text; value -= number } }
            return format == "ROMAN_SMALL" ? output.lowercased() : output
        case "HANGUL_SYLLABLE" where (1...14).contains(value): return String(Array("가나다라마바사아자차카타파하")[value - 1])
        case "CIRCLED_DIGIT" where (1...20).contains(value): return String(UnicodeScalar(0x2460 + value - 1)!)
        default: return String(value)
        }
    }
}
