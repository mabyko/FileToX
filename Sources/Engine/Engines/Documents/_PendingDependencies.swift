// Temporary cross-group APIs. The integrator removes this file after merging their implementations.
import Foundation

enum PdfDocumentReader {
    static func read(_ path: String, _ mediaFolder: String) throws -> HDocument {
        throw ConversionError("not ported yet")
    }
    static func readText(_ path: String) throws -> HDocument { throw ConversionError("not ported yet") }
    static func plainText(_ document: HDocument) throws -> String { throw ConversionError("not ported yet") }
}
