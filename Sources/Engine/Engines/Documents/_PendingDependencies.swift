// Temporary cross-group APIs. The integrator removes this file after merging their implementations.
import Foundation

enum PdfDocumentReader {
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
    static func readText(_ path: String) throws -> HDocument { throw ConversionError("not ported yet") }
    static func plainText(_ document: HDocument) throws -> String { throw ConversionError("not ported yet") }
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
