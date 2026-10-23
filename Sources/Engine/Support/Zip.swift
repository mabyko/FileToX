// ZIP reading and writing (System.IO.Compression.ZipArchive replacement) for OOXML, ODF, EPUB, HWPX, CBZ and the
// archive engine. Store and Deflate (zlib, levels like .NET's CompressionLevel), ZIP64, UTF-8 names, CRC checks.
// The writer puts real sizes in every local header (no data descriptors), like .NET on a seekable stream, which
// strict readers (EPUB's stored "mimetype" first entry, Hancom Office) expect.

import Foundation
import zlib

public enum ZipError: LocalizedError, Sendable {
    case notAZip(String)
    case corrupt(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip(let detail): "Not a ZIP archive: \(detail)"
        case .corrupt(let detail): "The ZIP archive is damaged: \(detail)"
        case .unsupported(let detail): "Unsupported ZIP feature: \(detail)"
        }
    }
}

/// Compression level of a written entry (System.IO.Compression.CompressionLevel).
public enum ZipCompressionLevel: Sendable {
    case noCompression, fastest, optimal, smallestSize

    var zlibLevel: Int32? {
        switch self {
        case .noCompression: nil
        case .fastest: 1
        case .optimal: 6
        case .smallestSize: 9
        }
    }
}

public final class ZipReader {
    public struct Entry: Sendable {
        /// Full name inside the archive ("word/document.xml", "folder/").
        public let name: String
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let crc32: UInt32
        public let method: UInt16
        public let flags: UInt16
        public let modificationDate: Date
        public let externalAttributes: UInt32
        public let versionMadeBy: UInt16
        let localHeaderOffset: UInt64

        public var isDirectory: Bool { name.hasSuffix("/") }
        public var isEncrypted: Bool { flags & 1 != 0 }
        /// Unix permission/type bits when the archive was made on a Unix system.
        public var unixMode: UInt16? { versionMadeBy >> 8 == 3 ? UInt16(truncatingIfNeeded: externalAttributes >> 16) : nil }
        public var isSymbolicLink: Bool { unixMode.map { $0 & 0o170000 == 0o120000 } ?? false }
    }

    public let entries: [Entry]
    private let bytes: Data

    /// Opens a ZIP file (memory-mapped).
    public convenience init(path: String) throws {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }
        catch { throw ZipError.notAZip("\(FilePath.fileName(path)): \(error.localizedDescription)") }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        bytes = data
        entries = try Self.readCentralDirectory(data)
    }

    /// The entry with exactly this name (ordinal, like ZipArchive.GetEntry), or nil.
    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// The uncompressed bytes of an entry. Fails on CRC mismatch, encryption and unknown methods.
    public func data(for entry: Entry) throws -> Data {
        var result = Data()
        result.reserveCapacity(Int(min(entry.uncompressedSize, 64 << 20)))
        try read(entry) { result.append($0) }
        return result
    }

    public func data(named name: String) throws -> Data? { try entry(named: name).map { try data(for: $0) } }

    /// The entry as UTF-8 text (a BOM is dropped).
    public func string(named name: String) throws -> String? {
        guard let data = try data(named: name) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Streams an entry into a new file at `path` (the caller checks the name is safe).
    public func extract(_ entry: Entry, to path: String) throws {
        let handle = try ZipWriter.create(path, O_WRONLY)
        defer { try? handle.close() }
        try read(entry) { try handle.write(contentsOf: $0) }
    }

    /// Feeds the uncompressed bytes of an entry to `sink` in chunks.
    public func read(_ entry: Entry, sink: (Data) throws -> Void) throws {
        guard !entry.isEncrypted else { throw ZipError.unsupported("encrypted entry \(entry.name)") }
        let start = try dataOffset(of: entry)
        guard start + entry.compressedSize <= UInt64(bytes.count) else { throw ZipError.corrupt("\(entry.name) is truncated") }
        let range = Int(start)..<Int(start + entry.compressedSize)
        var crc: uLong = zlib.crc32(0, nil, 0)
        var total: UInt64 = 0
        func emit(_ chunk: Data) throws {
            total += UInt64(chunk.count)
            guard total <= entry.uncompressedSize else { throw ZipError.corrupt("\(entry.name) is larger than recorded") }
            crc = chunk.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            try sink(chunk)
        }
        switch entry.method {
        case 0:
            var offset = range.lowerBound
            while offset < range.upperBound {
                let end = min(offset + (1 << 20), range.upperBound)
                try emit(bytes.subdata(in: offset..<end))
                offset = end
            }
        case 8:
            try Deflate.inflate(bytes[range], emit)
        default:
            throw ZipError.unsupported("compression method \(entry.method) in \(entry.name)")
        }
        guard total == entry.uncompressedSize else { throw ZipError.corrupt("\(entry.name) has the wrong size") }
        guard UInt32(truncatingIfNeeded: crc) == entry.crc32 else { throw ZipError.corrupt("\(entry.name) failed its CRC check") }
    }

    private func dataOffset(of entry: Entry) throws -> UInt64 {
        let offset = Int(entry.localHeaderOffset)
        guard offset + 30 <= bytes.count, bytes.le32(offset) == 0x04034b50 else { throw ZipError.corrupt("bad local header of \(entry.name)") }
        return UInt64(offset + 30 + Int(bytes.le16(offset + 26)) + Int(bytes.le16(offset + 28)))
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notAZip("too short") }
        var eocd = -1
        var position = data.count - 22
        let lowest = max(0, data.count - 22 - 65535)
        while position >= lowest {
            if data.le32(position) == 0x06054b50 { eocd = position; break }
            position -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip("no end of central directory") }
        var count = UInt64(data.le16(eocd + 10))
        var size = UInt64(data.le32(eocd + 12))
        var offset = UInt64(data.le32(eocd + 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF, eocd >= 20, data.le32(eocd - 20) == 0x07064b50 {
            let record = Int(data.le64(eocd - 20 + 8))
            guard record + 56 <= data.count, data.le32(record) == 0x06064b50 else { throw ZipError.corrupt("bad ZIP64 end record") }
            count = data.le64(record + 32)
            size = data.le64(record + 40)
            offset = data.le64(record + 48)
        }
        guard offset + size <= UInt64(data.count) else { throw ZipError.corrupt("central directory out of range") }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 1 << 20)))
        var p = Int(offset)
        for _ in 0..<count {
            guard p + 46 <= data.count, data.le32(p) == 0x02014b50 else { throw ZipError.corrupt("bad central directory entry") }
            let madeBy = data.le16(p + 4), flags = data.le16(p + 8), method = data.le16(p + 10)
            let time = data.le16(p + 12), date = data.le16(p + 14), crc = data.le32(p + 16)
            var compressed = UInt64(data.le32(p + 20)), uncompressed = UInt64(data.le32(p + 24))
            let nameLength = Int(data.le16(p + 28)), extraLength = Int(data.le16(p + 30)), commentLength = Int(data.le16(p + 32))
            let external = data.le32(p + 38)
            var local = UInt64(data.le32(p + 42))
            guard p + 46 + nameLength + extraLength + commentLength <= data.count else { throw ZipError.corrupt("entry name out of range") }
            let nameBytes = data.subdata(in: (p + 46)..<(p + 46 + nameLength))
            var extra = p + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let tag = data.le16(extra), length = Int(data.le16(extra + 2))
                if tag == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + length { uncompressed = data.le64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + length { compressed = data.le64(field); field += 8 }
                    if local == 0xFFFF_FFFF, field + 8 <= extra + 4 + length { local = data.le64(field) }
                }
                extra += 4 + length
            }
            entries.append(Entry(name: decodeName(nameBytes, utf8: flags & 0x800 != 0), compressedSize: compressed,
                                 uncompressedSize: uncompressed, crc32: crc, method: method, flags: flags,
                                 modificationDate: dosDate(date: date, time: time), externalAttributes: external,
                                 versionMadeBy: madeBy, localHeaderOffset: local))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func decodeName(_ bytes: Data, utf8: Bool) -> String {
        if utf8 || bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return TextEncodings.decode(bytes, codePage: 437)
    }

    /// DOS dates are Gregorian local time, whatever calendar the user's locale prefers (Buddhist, Japanese …).
    static var dosCalendar: Calendar { Calendar(identifier: .gregorian) }

    static func dosDate(date: UInt16, time: UInt16) -> Date {
        var components = DateComponents()
        components.year = Int(date >> 9) + 1980
        components.month = max(1, Int((date >> 5) & 0xF))
        components.day = max(1, Int(date & 0x1F))
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return dosCalendar.date(from: components) ?? Date(timeIntervalSince1970: 315_532_800)
    }
}

public final class ZipWriter {
    private struct Written {
        let name: Data
        let utf8: Bool
        let method: UInt16
        let time: UInt16, date: UInt16
        let crc: UInt32
        let compressed: UInt64, uncompressed: UInt64
        let offset: UInt64
        let external: UInt32
    }

    private let handle: FileHandle
    private var written: [Written] = []
    private var position: UInt64 = 0
    private var closed = false

    /// Creates (or truncates) the archive at `path`.
    public init(path: String) throws {
        handle = try Self.create(path, O_RDWR)
    }

    /// Creates or truncates a file with open(2), which keeps the name as given (FileManager.createFile stores it NFD).
    static func create(_ path: String, _ access: Int32) throws -> FileHandle {
        let descriptor = open(path, access | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw FilePath.writeError(errno, path) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit { if !closed { try? handle.close() } }

    /// Adds an entry with the given bytes.
    public func add(_ name: String, data: Data, level: ZipCompressionLevel = .optimal, date: Date = Date(), unixMode: UInt16 = 0o644) throws {
        try addEntry(name, level: level, date: date, external: UInt32(0o100000 | unixMode) << 16, knownSize: UInt64(data.count)) { feed in
            try feed(data)
        }
    }

    public func add(_ name: String, text: String, level: ZipCompressionLevel = .optimal, date: Date = Date()) throws {
        try add(name, data: Data(text.utf8), level: level, date: date)
    }

    /// Adds a file from disk, streamed. Its modification date and permissions are kept unless given; `progress` gets the
    /// byte count of every chunk read.
    public func add(_ name: String, contentsOf path: String, level: ZipCompressionLevel = .optimal, date: Date? = nil,
                    unixMode: UInt16? = nil, progress: ((Int) -> Void)? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = unixMode ?? UInt16(truncatingIfNeeded: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
        guard let input = FileHandle(forReadingAtPath: path) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
        defer { try? input.close() }
        try addEntry(name, level: level, date: date ?? (attributes[.modificationDate] as? Date) ?? Date(),
                     external: UInt32(0o100000 | (mode & 0o7777)) << 16, knownSize: size) { feed in
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try feed(chunk)
                progress?(chunk.count)
            }
        }
    }

    /// Adds a folder entry ("name/").
    public func addDirectory(_ name: String, date: Date = Date()) throws {
        let folder = name.hasSuffix("/") ? name : name + "/"
        try addEntry(folder, level: .noCompression, date: date, external: (UInt32(0o040755) << 16) | 0x10, knownSize: 0) { _ in }
    }

    /// Writes the central directory and closes the file. Required; an unclosed archive is invalid.
    public func close() throws {
        guard !closed else { return }
        closed = true
        defer { try? handle.close() }
        let directoryStart = position
        var directory = Data()
        for entry in written {
            let zip64 = entry.compressed >= 0xFFFF_FFFF || entry.uncompressed >= 0xFFFF_FFFF || entry.offset >= 0xFFFF_FFFF
            var extra = Data()
            if zip64 {
                extra.appendLE16(0x0001); extra.appendLE16(24)
                extra.appendLE64(entry.uncompressed); extra.appendLE64(entry.compressed); extra.appendLE64(entry.offset)
            }
            directory.appendLE32(0x02014b50)
            directory.appendLE16(zip64 ? 0x032D : 0x0314)
            directory.appendLE16(zip64 ? 45 : 20)
            directory.appendLE16(entry.utf8 ? 0x800 : 0)
            directory.appendLE16(entry.method)
            directory.appendLE16(entry.time); directory.appendLE16(entry.date)
            directory.appendLE32(entry.crc)
            directory.appendLE32(zip64 ? 0xFFFF_FFFF : UInt32(entry.compressed))
            directory.appendLE32(zip64 ? 0xFFFF_FFFF : UInt32(entry.uncompressed))
            directory.appendLE16(UInt16(entry.name.count)); directory.appendLE16(UInt16(extra.count)); directory.appendLE16(0)
            directory.appendLE16(0); directory.appendLE16(0)
            directory.appendLE32(entry.external)
            directory.appendLE32(zip64 ? 0xFFFF_FFFF : UInt32(entry.offset))
            directory.append(entry.name); directory.append(extra)
        }
        try write(directory)
        let directorySize = UInt64(directory.count)
        var end = Data()
        let needs64 = written.count >= 0xFFFF || directoryStart >= 0xFFFF_FFFF || directorySize >= 0xFFFF_FFFF
        if needs64 {
            let record = position
            end.appendLE32(0x06064b50); end.appendLE64(44); end.appendLE16(45); end.appendLE16(45); end.appendLE32(0); end.appendLE32(0)
            end.appendLE64(UInt64(written.count)); end.appendLE64(UInt64(written.count)); end.appendLE64(directorySize); end.appendLE64(directoryStart)
            end.appendLE32(0x07064b50); end.appendLE32(0); end.appendLE64(record); end.appendLE32(1)
        }
        end.appendLE32(0x06054b50); end.appendLE16(0); end.appendLE16(0)
        end.appendLE16(needs64 ? 0xFFFF : UInt16(written.count)); end.appendLE16(needs64 ? 0xFFFF : UInt16(written.count))
        end.appendLE32(needs64 ? 0xFFFF_FFFF : UInt32(directorySize)); end.appendLE32(needs64 ? 0xFFFF_FFFF : UInt32(directoryStart))
        end.appendLE16(0)
        try write(end)
        try handle.synchronize()
    }

    private func addEntry(_ name: String, level: ZipCompressionLevel, date: Date, external: UInt32, knownSize: UInt64,
                          body: ((Data) throws -> Void) throws -> Void) throws {
        precondition(!closed, "ZipWriter is closed")
        let nameBytes = Data(name.utf8)
        let utf8 = nameBytes.contains { $0 >= 0x80 }
        let (time, dosDay) = Self.dosDateTime(date)
        let zlibLevel = name.hasSuffix("/") ? nil : level.zlibLevel
        let method: UInt16 = zlibLevel == nil ? 0 : 8
        let zip64 = knownSize >= 0xFFFF_FFFF - (knownSize / 1000 + 4096)
        let offset = position

        var header = Data()
        header.appendLE32(0x04034b50)
        header.appendLE16(zip64 ? 45 : 20)
        header.appendLE16(utf8 ? 0x800 : 0)
        header.appendLE16(method)
        header.appendLE16(time); header.appendLE16(dosDay)
        header.appendLE32(0); header.appendLE32(zip64 ? 0xFFFF_FFFF : 0); header.appendLE32(zip64 ? 0xFFFF_FFFF : 0)
        header.appendLE16(UInt16(nameBytes.count)); header.appendLE16(zip64 ? 20 : 0)
        header.append(nameBytes)
        if zip64 { header.appendLE16(0x0001); header.appendLE16(16); header.appendLE64(0); header.appendLE64(0) }
        try write(header)

        var crc: uLong = zlib.crc32(0, nil, 0)
        var uncompressed: UInt64 = 0
        let dataStart = position
        if let zlibLevel {
            let deflater = try Deflate.Compressor(level: zlibLevel)
            try body { chunk in
                crc = chunk.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                uncompressed += UInt64(chunk.count)
                try self.write(try deflater.compress(chunk, finish: false))
            }
            try write(try deflater.compress(Data(), finish: true))
        } else {
            try body { chunk in
                crc = chunk.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                uncompressed += UInt64(chunk.count)
                try self.write(chunk)
            }
        }
        let compressed = position - dataStart
        if !zip64, compressed >= 0xFFFF_FFFF || uncompressed >= 0xFFFF_FFFF {
            throw ZipError.unsupported("\(name) grew past 4 GB while being written")
        }

        // Patch CRC and sizes into the local header.
        var patch = Data()
        patch.appendLE32(UInt32(truncatingIfNeeded: crc))
        patch.appendLE32(zip64 ? 0xFFFF_FFFF : UInt32(compressed)); patch.appendLE32(zip64 ? 0xFFFF_FFFF : UInt32(uncompressed))
        try handle.seek(toOffset: offset + 14)
        try handle.write(contentsOf: patch)
        if zip64 {
            var sizes = Data()
            sizes.appendLE64(uncompressed); sizes.appendLE64(compressed)
            try handle.seek(toOffset: offset + 30 + UInt64(nameBytes.count) + 4)
            try handle.write(contentsOf: sizes)
        }
        try handle.seek(toOffset: position)
        written.append(Written(name: nameBytes, utf8: utf8, method: method, time: time, date: dosDay,
                               crc: UInt32(truncatingIfNeeded: crc), compressed: compressed, uncompressed: uncompressed,
                               offset: offset, external: external))
    }

    private func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        position += UInt64(data.count)
    }

    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = ZipReader.dosCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// Raw deflate / inflate with zlib (also used for gzip and zlib-wrapped streams by other engines).
public enum Deflate {
    /// Most input bytes given to zlib at once (its counters are 32-bit); tests lower it to exercise the slicing.
    nonisolated(unsafe) static var inputSlice = 1 << 30

    /// Inflates raw deflate data, handing out chunks of at most 1 MiB.
    public static func inflate(_ input: Data, windowBits: Int32 = -15, _ sink: (Data) throws -> Void) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZipError.corrupt("inflate init failed")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 1 << 20)
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: Bytef.self).baseAddress
            var offset = 0
            var status: Int32 = Z_OK
            repeat {
                // zlib counts input in 32 bits: larger inputs (ZIP64 entries) are handed out in slices.
                if stream.avail_in == 0, offset < raw.count, let base {
                    let count = min(raw.count - offset, inputSlice)
                    stream.next_in = UnsafeMutablePointer(mutating: base + offset)
                    stream.avail_in = uInt(count)
                    offset += count
                }
                let produced: Int = output.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return buffer.count - Int(stream.avail_out)
                }
                if status != Z_OK && status != Z_STREAM_END && !(status == Z_BUF_ERROR && produced > 0) {
                    throw ZipError.corrupt(stream.msg.map { String(cString: $0) } ?? String(cString: zError(status)))
                }
                if produced > 0 { try sink(Data(output[0..<produced])) }
                if status == Z_BUF_ERROR && produced == 0 { throw ZipError.corrupt("unexpected end of compressed data") }
            } while status != Z_STREAM_END
        }
    }

    /// Inflates everything into memory.
    public static func inflate(_ input: Data, windowBits: Int32 = -15) throws -> Data {
        var result = Data()
        try inflate(input, windowBits: windowBits) { result.append($0) }
        return result
    }

    /// Compresses in one go. windowBits -15 raw deflate, 15 zlib, 31 gzip.
    public static func deflate(_ input: Data, level: Int32 = 6, windowBits: Int32 = -15) throws -> Data {
        let compressor = try Compressor(level: level, windowBits: windowBits)
        return try compressor.compress(input, finish: true)
    }

    /// Streaming deflate.
    public final class Compressor {
        private var stream = z_stream()
        private var finished = false

        public init(level: Int32, windowBits: Int32 = -15) throws {
            guard deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZipError.corrupt("deflate init failed") }
        }

        deinit { deflateEnd(&stream) }

        public func compress(_ input: Data, finish: Bool) throws -> Data {
            precondition(!finished, "Compressor already finished")
            var result = Data()
            var output = [UInt8](repeating: 0, count: 256 * 1024)
            try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: Bytef.self).baseAddress
                var offset = 0
                repeat {
                    // zlib counts input in 32 bits: hand it out in slices; only the last one may finish the stream.
                    let count = min(raw.count - offset, Deflate.inputSlice)
                    stream.next_in = base.map { UnsafeMutablePointer(mutating: $0 + offset) }
                    stream.avail_in = uInt(count)
                    offset += count
                    let flush = finish && offset == raw.count ? Z_FINISH : Z_NO_FLUSH
                    var status: Int32 = Z_OK
                    repeat {
                        let produced: Int = output.withUnsafeMutableBytes { buffer in
                            stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                            stream.avail_out = uInt(buffer.count)
                            status = zlib.deflate(&stream, flush)
                            return buffer.count - Int(stream.avail_out)
                        }
                        guard status != Z_STREAM_ERROR else { throw ZipError.corrupt("deflate failed") }
                        result.append(contentsOf: output[0..<produced])
                    } while flush == Z_FINISH ? status != Z_STREAM_END : stream.avail_out == 0
                } while offset < raw.count
            }
            if finish { finished = true }
            return result
        }
    }
}

fileprivate extension Data {
    func le16(_ offset: Int) -> UInt16 { UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8 }
    func le32(_ offset: Int) -> UInt32 { UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16 }
    func le64(_ offset: Int) -> UInt64 { UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32 }
    mutating func appendLE16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func appendLE32(_ value: UInt32) { appendLE16(UInt16(value & 0xFFFF)); appendLE16(UInt16(value >> 16)) }
    mutating func appendLE64(_ value: UInt64) { appendLE32(UInt32(value & 0xFFFF_FFFF)); appendLE32(UInt32(value >> 32)) }
}
