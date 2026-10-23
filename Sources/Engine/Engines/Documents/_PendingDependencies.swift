// Temporary cross-group APIs. The integrator removes this file after merging their implementations.
import Foundation

enum HtmlReader {
    static let codeShade = "#F1F0F5", markShade = "#FFF3A3"
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
    static func readFile(_ path: String, _ options: HtmlReadOptions) throws -> HtmlContent {
        throw ConversionError("not ported yet")
    }
    static func mergeRuns(_ inlines: inout [HInline]) throws { throw ConversionError("not ported yet") }
    static func pruneBookmarks(_ document: HDocument) throws { throw ConversionError("not ported yet") }
}
enum MarkdownReader {
    static func read(_ markdown: String, _ baseFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
    static func resolveImage(_ target: String?, _ baseFolder: String) throws -> String? {
        throw ConversionError("not ported yet")
    }
}
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
enum EpubReader {
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
}
enum MobiReader {
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
}
enum Fb2Reader {
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
}
enum ZippedText {
    static func readHtmlz(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
    static func readTxtz(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
}

struct HtmlReadOptions {
    var baseFolder: String
    var mediaFolder: String
    var mapLink: ((String) -> String?)?
    var mapId: ((String) -> String?)?
}
struct HtmlContent {
    var blocks: [HBlock]
    var title: String?
    var language: String?
}
