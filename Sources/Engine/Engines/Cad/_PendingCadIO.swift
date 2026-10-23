// Stand-ins for the ACadSharp DWG reader and the DXF / DWG writers, which are being ported separately. Replaced by the
// real implementations (same signatures) when they are merged.

import Foundation

enum CadFileIO {
    static func readDwg(_ data: Data, warning: ((String) -> Void)?) throws -> ACad.Document {
        throw ConversionError("not ported yet")
    }

    static func writeDxf(_ document: ACad.Document, to path: String, warning: ((String) -> Void)?) throws {
        throw ConversionError("not ported yet")
    }

    static func writeDwg(_ document: ACad.Document, to path: String, warning: ((String) -> Void)?) throws {
        throw ConversionError("not ported yet")
    }
}
