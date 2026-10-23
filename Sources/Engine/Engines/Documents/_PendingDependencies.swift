// Temporary cross-group APIs. The integrator removes this file after merging their implementations.
import Foundation

enum PandocAstReader {
    static func read(_ ast: Any, _ resolveImage: (String) -> String?) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
}
enum PandocConverter { static func locate() -> String? { nil } }
enum PdfDocumentReader {
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
    static func readText(_ path: String) throws -> HDocument { throw ConversionError("not ported yet") }
    static func plainText(_ document: HDocument) throws -> String { throw ConversionError("not ported yet") }
}
enum XlsxReader { static func read(_ path: String) throws -> Workbook { throw ConversionError("not ported yet") } }
enum CsvFormat {
    static func read(_ path: String) throws -> Workbook { throw ConversionError("not ported yet") }
    static func readTsv(_ path: String) throws -> Workbook { throw ConversionError("not ported yet") }
}
enum SpreadsheetConverter {
    static func read(_ path: String, _ format: String) throws -> Workbook { throw ConversionError("not ported yet") }
}

struct HtmlReadOptions {
    var baseFolder: String
    var mediaFolder: String
    var mapLink: ((String) -> String?)?
    var mapId: ((String) -> String?)?
}
struct HtmlContent { var blocks: [HBlock]; var title: String?; var language: String? }
enum HtmlReader {
    static let codeShade = "#F1F0F5", markShade = "#FFF3A3"
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
    static func resolveImage(_ target: String?, _ baseFolder: String) throws -> String? { throw ConversionError("not ported yet") }
    static func read(_ markdown: String, _ baseFolder: String) throws -> HDocument { throw ConversionError("not ported yet") }
}
