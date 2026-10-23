// The ACadSharp entry points Filee's CadFile calls (DxfWriter.Write here; the DWG reader and writer in their files).

import Foundation

enum CadFileIO {
    /// `DxfWriter.Write(path, document, binary: false, new DxfWriterConfiguration(), notify)`.
    static func writeDxf(_ document: ACad.Document, to path: String, warning: ((String) -> Void)?) throws {
        let notifications = try ACad.DxfWriter.write(document, to: URL(fileURLWithPath: path))
        if let warning { notifications.forEach(warning) }
    }
}
