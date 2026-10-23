// Port of Filee.Engines/Cad/CadFile.cs: reads DWG / DXF files and writes DXF / DWG. Output is always AutoCAD 2018
// (AC1032): the current DWG format (AutoCAD 2018–2026, DWG TrueView, BricsCAD, LibreCAD ...), and for DXF the
// first-choice version whose text is UTF-8, so Korean and Chinese text survive without code page guessing.

import Foundation

/// A drawing that cannot be used, with a readable message (Filee's `InvalidDataException` from CadFile).
struct CadInvalidDataError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

/// DWG and DXF input and output.
enum CadFile {
    /// Version of every written DWG and DXF.
    static let outputVersion = ACad.Version.ac1032

    /// Reads a drawing. Binary and ASCII DXF are detected automatically. Throws `CadInvalidDataError` with a readable
    /// message for files that are not drawings, are damaged, or use an unsupported version.
    static func read(_ path: String, _ format: String, warning: ((String) -> Void)? = nil) throws -> ACad.Document {
        let kind = format == "dwg" ? "DWG" : "DXF"
        do {
            if format == "dwg" {
                try requireDwgSignature(path)
                return try CadFileIO.readDwg(try Data(contentsOf: URL(fileURLWithPath: path)), warning: warning)
            }
            // CreateDefaults adds missing tables (layer 0, standard styles, model space) so that files from simple DXF
            // writers can be rendered and saved as DWG.
            let reader = ACad.DxfReader(data: try openDxf(path), createDefaults: true)
            let document = try reader.read()
            if let warning { reader.notifications.forEach(warning) }
            return document
        } catch let error as ACad.CadNotSupportedError {
            throw CadInvalidDataError("This \(kind) version is not supported (\(error.description)).")
        } catch let error as CadInvalidDataError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where isFileSystemError(error) {
            // File system errors (locked, missing) keep their own message; a truncated file is damage.
            throw error
        } catch {
            throw CadInvalidDataError("The file is not a valid \(kind) drawing or is damaged: \(message(error))")
        }
    }

    /// Writes the drawing as an AutoCAD 2018 DXF (ASCII) or DWG.
    static func write(_ document: ACad.Document, _ path: String, _ format: String, warning: ((String) -> Void)? = nil) throws {
        document.header.version = outputVersion
        do {
            dropStraySequenceEnds(document)
            if format == "dwg" {
                dropUnwritableDimensions(document, warning)
                try CadFileIO.writeDwg(document, to: path, warning: warning)
            } else {
                try CadFileIO.writeDxf(document, to: path, warning: warning)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where isFileSystemError(error) {
            throw error
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw CadInvalidDataError("The drawing could not be written as \(format.uppercased()): \(message(error))")
        }
    }

    /// R12 DXF files can leave SEQEND markers behind as loose entities; the writers reject them (DWG) or would write
    /// them as garbage (DXF). They carry no geometry.
    private static func dropStraySequenceEnds(_ document: ACad.Document) {
        for record in document.blockRecords {
            for marker in record.entities.filter({ $0 is ACad.Seqend }) {
                _ = record.entities.remove(marker)
            }
        }
    }

    /// DWG stores each dimension's measured value, which cannot be computed for degenerate definition points (e.g. an
    /// angular dimension with coincident points, seen in old R12 files). Those dimensions are left out instead of
    /// failing the whole file.
    private static func dropUnwritableDimensions(_ document: ACad.Document, _ warning: ((String) -> Void)?) {
        for record in document.blockRecords {
            var broken: [ACad.Dimension] = []
            for case let dimension as ACad.Dimension in record.entities {
                do {
                    _ = try dimension.measurement()
                } catch {
                    broken.append(dimension)
                }
            }
            for dimension in broken { _ = record.entities.remove(dimension) }
            if !broken.isEmpty { warning?("\(broken.count) degenerate dimension(s) in \(record.name) were left out of the DWG.") }
        }
    }

    /// DWG files start with "AC10xx"; anything else fails early with a clear message.
    private static func requireDwgSignature(_ path: String) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            _ = try Data(contentsOf: URL(fileURLWithPath: path)) // the file system's own error
            throw CadInvalidDataError("The file is not a DWG drawing (it does not start with an AutoCAD version tag).")
        }
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 6) ?? Data())
        if head.count < 6 || head[0] != UInt8(ascii: "A") || head[1] != UInt8(ascii: "C") || !(0x30...0x39).contains(head[2]) {
            throw CadInvalidDataError("The file is not a DWG drawing (it does not start with an AutoCAD version tag).")
        }
    }

    /// Reads a DXF. Korean AutoCAD saves pre-2007 DXF with `$DWGCODEPAGE ANSI_949`, a name ACadSharp 3.8 does not map
    /// (it would decode the text as UTF-8); such headers are rewritten to the equivalent name it knows, in memory.
    private static func openDxf(_ path: String) throws -> Data {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let head = [UInt8](bytes.prefix(64 * 1024))
        guard let key = find(Array("$DWGCODEPAGE".utf8), in: head, from: 0, count: head.count, ignoreCase: false),
              let value = find(Array("ANSI_949".utf8), in: head, from: key, count: min(64, head.count - key), ignoreCase: true) else {
            return bytes
        }
        var patched = Data(bytes.prefix(value))
        patched.append(contentsOf: Array("KCS5601".utf8))
        patched.append(bytes.dropFirst(value + 8))
        return patched
    }

    /// `string.IndexOf(value, start, count)` over ASCII bytes: the first match lying wholly inside the range.
    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int, count: Int, ignoreCase: Bool) -> Int? {
        func fold(_ b: UInt8) -> UInt8 { ignoreCase && b >= 0x61 && b <= 0x7A ? b - 0x20 : b }
        let end = start + count
        guard needle.count <= count else { return nil }
        var i = start
        while i + needle.count <= end {
            if (0..<needle.count).allSatisfy({ fold(haystack[i + $0]) == fold(needle[$0]) }) { return i }
            i += 1
        }
        return nil
    }

    /// Errors of the file system (missing, locked, unreadable), which keep their own message.
    private static func isFileSystemError(_ error: Error) -> Bool {
        error is CocoaError || error is POSIXError || (error as NSError).domain == NSPOSIXErrorDomain
    }

    /// The message of an error, as .NET's `Exception.Message`.
    static func message(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return String(describing: error)
    }
}
