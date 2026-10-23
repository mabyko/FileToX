// ACadSharp 3.8.0 `DwgWriter` with the default `DwgWriterConfiguration`, as Filee's CadFile.Write calls it: the
// sections in ACadSharp's order, laid out by the R2004+ file header writer.
// shortcut: only AC1024–AC1032 output (Filee writes AC1032); AC1014–AC1018 need the AC15 header writer and the
// older stream writer overrides.

import Foundation

extension ACad {
    final class DwgWriter {
        let document: Document
        /// `OnNotification` messages, for the log.
        private(set) var notifications: [String] = []
        private var handlesMap: [UInt64: Int64] = [:]

        /// Test hook: the values ACadSharp takes from the clock or the assembly, made fixed for byte comparisons.
        static var appInfoVersion: String {
            get { DwgAppInfoWriter.assemblyVersion }
            set { DwgAppInfoWriter.assemblyVersion = newValue }
        }

        init(document: Document) {
            self.document = document
        }

        var version: Version { document.header.version }

        /// `DwgWriter.Write`: the bytes of the file.
        func write() throws -> Data {
            // CadWriterBase.Write
            document.updateImageReactors()
            document.updateDxfClasses(reset: false)
            // `getListedEncoding(CodePage)`: `GetCodePage(null)` is a null reference.
            guard document.header.codePage != nil else { throw DxfWriteError.nullReference }

            switch version {
            case .ac1024, .ac1027, .ac1032: break
            default: throw CadNotSupportedError(version: version)
            }

            let stream = DwgMemoryStream()
            let fileHeaderWriter = DwgFileHeaderWriter(stream, document)

            // Header
            var section = DwgMemoryStream()
            try DwgHeaderWriter(section, document).write()
            try fileHeaderWriter.addSection(DwgSectionDefinition.header, section, true)
            // Classes
            section = DwgMemoryStream()
            try DwgClassesWriter(section, document).write()
            try fileHeaderWriter.addSection(DwgSectionDefinition.classes, section, true)
            // Summary info
            section = DwgMemoryStream()
            try writeSummaryInfo(section)
            try fileHeaderWriter.addSection(DwgSectionDefinition.summaryInfo, section, false, 0x100)
            // Preview
            section = DwgMemoryStream()
            DwgPreviewWriter.write(section)
            try fileHeaderWriter.addSection(DwgSectionDefinition.preview, section, false, 0x400)
            // App info
            section = DwgMemoryStream()
            try DwgAppInfoWriter.write(section)
            try fileHeaderWriter.addSection(DwgSectionDefinition.appInfo, section, false, 0x80)
            // File dependencies: feature count, file count
            section = DwgMemoryStream()
            section.write(DwgLE.bytes(UInt32(0)) + DwgLE.bytes(UInt32(0)))
            try fileHeaderWriter.addSection(DwgSectionDefinition.fileDepList, section, false, 0x80)
            // Revision history
            section = DwgMemoryStream()
            section.write(DwgLE.bytes(UInt32(0)) + DwgLE.bytes(UInt32(0)) + DwgLE.bytes(UInt32(0)))
            try fileHeaderWriter.addSection(DwgSectionDefinition.revHistory, section, true)
            // Aux header
            section = DwgMemoryStream()
            DwgAuxHeaderWriter(section, document.header).write()
            try fileHeaderWriter.addSection(DwgSectionDefinition.auxHeader, section, true)
            // Objects
            section = DwgMemoryStream()
            let objectWriter = DwgObjectWriter(section, document)
            defer { notifications += objectWriter.messages }
            try objectWriter.write()
            handlesMap = objectWriter.map
            try fileHeaderWriter.addSection(DwgSectionDefinition.acDbObjects, section, true)
            // Free space
            section = DwgMemoryStream()
            writeObjFreeSpace(section)
            try fileHeaderWriter.addSection(DwgSectionDefinition.objFreeSpace, section, true)
            // Template: description length, MEASUREMENT
            section = DwgMemoryStream()
            section.write(DwgLE.bytes(Int16(0)) + DwgLE.bytes(UInt16(bitPattern: document.header.measurementUnits)))
            try fileHeaderWriter.addSection(DwgSectionDefinition.template, section, true)
            // Handles, last to avoid conflicts with versions < AC1018
            section = DwgMemoryStream()
            try DwgHandleWriter(version, section, handlesMap).write(fileHeaderWriter.handleSectionOffset)
            try fileHeaderWriter.addSection(DwgSectionDefinition.handles, section, true)

            try fileHeaderWriter.writeFile()
            return Data(stream.bytes)
        }

        /// Writes a document to a file path.
        static func write(_ document: Document, to url: URL) throws -> [String] {
            let writer = DwgWriter(document: document)
            let data = try writer.write()
            try data.write(to: url)
            return writer.notifications
        }

        private func writeSummaryInfo(_ stream: DwgMemoryStream) throws {
            guard let info = document.summaryInfo else { throw DxfWriteError.nullReference }
            let w = DwgStreamWriter(stream)
            try w.writeTextUnicode(info.title)
            try w.writeTextUnicode(info.subject)
            try w.writeTextUnicode(info.author)
            try w.writeTextUnicode(info.keywords)
            try w.writeTextUnicode(info.comments)
            try w.writeTextUnicode(info.lastSavedBy)
            try w.writeTextUnicode(info.revisionNumber)
            try w.writeTextUnicode(info.hyperlinkBase)
            // Total editing time (ODA writes two zero Int32's)
            w.writeInt(0)
            w.writeInt(0)
            w.write8BitJulianDate(info.createdDate)
            w.write8BitJulianDate(info.modifiedDate)
            w.writeRawUShort(UInt16(truncatingIfNeeded: info.properties.count))
            for (key, value) in info.properties {
                try w.writeTextUnicode(key)
                try w.writeTextUnicode(value)
            }
            w.writeInt(0)
            w.writeInt(0)
        }

        private func writeObjFreeSpace(_ stream: DwgMemoryStream) {
            var out: [UInt8] = DwgLE.bytes(Int32(0))
            // Approximate number of objects in the drawing (number of handles).
            out += DwgLE.bytes(UInt32(truncatingIfNeeded: handlesMap.count))
            // R2000+: TDUUPDATE
            let j = document.header.universalUpdateDateTime.dwgJulian
            out += DwgLE.bytes(j.jdate)
            out += DwgLE.bytes(j.milliseconds)
            // Offset of the objects section in the stream.
            out += DwgLE.bytes(UInt32(0))
            // Number of 64-bit values that follow (ODA writes 4), and their ODA values.
            out.append(4)
            for v: UInt32 in [0x32, 0, 0x64, 0, 0x200, 0, 0xFFFF_FFFF, 0] { out += DwgLE.bytes(v) }
            stream.write(out)
        }
    }
}

extension CadFileIO {
    /// `DwgWriter.Write(path, document, new DwgWriterConfiguration(), notify)`.
    static func writeDwg(_ document: ACad.Document, to path: String, warning: ((String) -> Void)?) throws {
        let writer = ACad.DwgWriter(document: document)
        defer { if let warning { writer.notifications.forEach(warning) } }
        try writer.write().write(to: URL(fileURLWithPath: path))
    }
}
