// The ACadSharp entry points Filee's CadFile calls (DxfWriter.Write, DwgReader.Read; the DWG writer in its file).

import Foundation

enum CadFileIO {
    /// `DxfWriter.Write(path, document, binary: false, new DxfWriterConfiguration(), notify)`.
    static func writeDxf(_ document: ACad.Document, to path: String, warning: ((String) -> Void)?) throws {
        let notifications = try ACad.DxfWriter.write(document, to: URL(fileURLWithPath: path))
        if let warning { notifications.forEach(warning) }
    }

    /// `DwgReader.Read(path, new DwgReaderConfiguration { Failsafe = true }, notify)`.
    static func readDwg(_ data: Data, warning: ((String) -> Void)?) throws -> ACad.Document {
        let reader = ACad.DwgReader(data: data)
        defer { if let warning { reader.notifications.forEach(warning) } }
        return try reader.read()
    }
}
