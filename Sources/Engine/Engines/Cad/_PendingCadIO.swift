// Stand-in for the ACadSharp DWG writer, which is being ported separately. Replaced by the real
// implementation (same signature) when they are merged.

import Foundation

extension CadFileIO {
    static func writeDwg(_ document: ACad.Document, to path: String, warning: ((String) -> Void)?) throws {
        throw ConversionError("not ported yet")
    }
}
