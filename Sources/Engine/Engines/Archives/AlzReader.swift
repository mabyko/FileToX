// Port of Filee.Engines/Archives/AlzReader.cs: reads ALZ archives, the format of the Korean ALZip (ESTsoft), which
// 7-Zip does not support. Layout as documented by unalz (zlib licence) and the "unalz" Rust crate (MIT); Filee's reader
// is its own:
//
//   "ALZ\x01" + 4 bytes                         archive header
//   "BLZ\x01" + local file header + name + data  one per entry
//   "CLZ\x01" + 12 bytes                         central directory marker
//   "CLZ\x02" (+ 12 bytes of end info)           end of archive; "ELZ\x01" is a comment section
//
// Local file header (little endian): name length u16, attributes u8 (0x10 = folder), DOS time u32, descriptor u8
// (bit 0 = encrypted, bits 4-7 = width of the size fields: 0x10/0x20/0x40/0x80 = 1/2/4/8 bytes), unknown u8; then,
// when the width is not 0: method u8 (0 store, 1 ALZ bzip2, 2 deflate), unknown u8, CRC-32 u32, packed size,
// unpacked size. Names are CP949 (Korean Windows) unless they are valid UTF-8.

import Foundation

/// Unpacks ALZ archives (store, deflate and ALZip's bzip2 variant).
enum AlzReader {
    private static let archiveSignature: UInt32 = 0x015A4C41 // "ALZ\x01"
    private static let entrySignature: UInt32 = 0x015A4C42 // "BLZ\x01"
    private static let directorySignature: UInt32 = 0x015A4C43 // "CLZ\x01"
    private static let endSignature: UInt32 = 0x025A4C43 // "CLZ\x02"
    private static let splitMarker: UInt32 = 0x035A4C43 // "CLZ\x03"
    private static let commentSignature: UInt32 = 0x015A4C45 // "ELZ\x01"
    private static let splitSignature: UInt32 = 0x015A4C53 // "SLZ\x01"

    /// One entry of the archive.
    private struct Entry {
        let name: String
        let isFolder: Bool
        let modified: Date?
        let method: Int
        let crc: UInt32
        let packedSize: Int64
        let size: Int64
        let dataOffset: Int64
    }

    /// Unpacks every entry of `archive` into `targetDirectory`.
    static func extract(_ archive: String, _ targetDirectory: String) throws {
        let archiveName = FilePath.fileName(archive)
        let stream = try ArchiveFiles.map(archive)
        let entries = try readEntries(stream, archiveName)
        try ArchiveSafety.ensureRoom(entries.filter { !$0.isFolder }.reduce(0) { $0 + $1.size }, targetDirectory, archiveName)

        var folders: [(path: String, modified: Date?)] = []
        for entry in entries {
            try Task.checkCancellation()
            var path = try ArchiveSafety.resolveEntryPath(targetDirectory, entry.name, archiveName)
            if entry.isFolder {
                try FileManager.default.createDirectoryIfNeeded(path)
                folders.append((path, entry.modified))
                continue
            }

            try FileManager.default.createDirectoryIfNeeded(FilePath.directoryName(path) ?? targetDirectory)
            path = ArchiveFiles.uniquePath(path)
            var crc = ArchiveCrc32()
            let output = try ArchiveFiles.createNew(path)
            do {
                defer { try? output.close() }
                let sink: (Data) throws -> Void = { chunk in
                    crc.append(chunk)
                    try output.write(contentsOf: chunk)
                }
                let packed = stream[Int(entry.dataOffset)..<Int(entry.dataOffset + entry.packedSize)]
                switch entry.method {
                case 0:
                    try ArchiveFiles.copyLimited(ArchiveFiles.chunks(packed), to: sink, maxBytes: entry.size)
                case 1:
                    try Bzip2Decoder.decompress(packed, sink, alzFraming: true, maxOutput: entry.size)
                case 2:
                    try inflate(packed, sink, entry.size, archiveName, entry.name)
                default:
                    throw ConversionError("\(archiveName) uses an unknown ALZ compression method (\(entry.method)).")
                }
            }

            if ArchiveFiles.fileLength(path) != entry.size || crc.value != entry.crc {
                throw ArchiveSafety.damaged(archiveName, "checksum error in \(entry.name)")
            }
            if let modified = entry.modified { try ArchiveFiles.setModificationDate(path, modified) }
        }

        // Folder times last: writing files into a folder changes its time.
        for folder in folders {
            if let time = folder.modified { try ArchiveFiles.setModificationDate(folder.path, time) }
        }
    }

    /// Raw deflate (DeflateStream) into `sink`, capped at `size`. Broken data is reported as a checksum error, the
    /// same message a short or wrong result gets.
    static func inflate(_ packed: Data, _ sink: (Data) throws -> Void, _ size: Int64, _ archiveName: String, _ entryName: String) throws {
        do {
            try ArchiveFiles.copyLimited({ try Deflate.inflate(packed, $0) }, to: sink, maxBytes: size)
        } catch is ZipError {
            throw ArchiveSafety.damaged(archiveName, "checksum error in \(entryName)")
        }
    }

    private static func readEntries(_ stream: Data, _ archiveName: String) throws -> [Entry] {
        let reader = BinaryReader(stream)
        var entries: [Entry] = []
        do {
            if try stream.count < 8 || reader.readUInt32() != archiveSignature {
                throw ConversionError("\(archiveName) is not an ALZ archive.")
            }
            _ = try reader.readUInt32() // version / unknown

            while reader.position + 4 <= reader.length {
                switch try reader.readUInt32() {
                case entrySignature:
                    if entries.count >= ArchiveSafety.maxEntries {
                        throw ConversionError("\(archiveName) has more than \(ArchiveSafety.maxEntriesText) entries; Filee does not unpack it.")
                    }
                    entries.append(try readEntry(reader, archiveName))
                case directorySignature:
                    reader.position += 12
                case splitMarker:
                    break
                case commentSignature:
                    try skipComment(reader)
                case endSignature:
                    return entries
                case splitSignature:
                    throw ConversionError("\(archiveName) is part of a split ALZ archive (.alz + .a00 …); Filee cannot unpack split archives.")
                default:
                    throw ArchiveSafety.damaged(archiveName, "unknown ALZ header")
                }
            }
            return entries // no end record: keep what was found, the data checks catch damage
        } catch is EndOfStreamError {
            throw ArchiveSafety.damaged(archiveName, "the archive ends too early")
        }
    }

    private static func readEntry(_ reader: BinaryReader, _ archiveName: String) throws -> Entry {
        let nameLength = Int(try reader.readUInt16())
        let attributes = try reader.readByte()
        let dosTime = try reader.readUInt32()
        let descriptor = try reader.readByte()
        _ = try reader.readByte() // unknown

        if descriptor & 0x01 != 0 { throw ArchiveSafety.encrypted(archiveName) }

        let width: Int
        switch descriptor & 0xF0 {
        case 0x00: width = 0
        case 0x10: width = 1
        case 0x20: width = 2
        case 0x40: width = 4
        case 0x80: width = 8
        default: throw ArchiveSafety.damaged(archiveName, "invalid ALZ size field")
        }
        var method = 0
        var crc: UInt32 = 0
        var packedSize: Int64 = 0, size: Int64 = 0
        if width > 0 {
            method = Int(try reader.readByte())
            _ = try reader.readByte() // unknown
            crc = try reader.readUInt32()
            packedSize = try readSize(reader, width)
            size = try readSize(reader, width)
        }
        if nameLength == 0 || packedSize < 0 || size < 0 { throw ArchiveSafety.damaged(archiveName, "invalid ALZ entry") }

        let name = decodeName(try reader.readBytes(nameLength))
        let offset = Int64(reader.position)
        if offset + packedSize > Int64(reader.length) { throw ArchiveSafety.damaged(archiveName, "the archive ends too early") }
        reader.position += Int(packedSize)

        let isFolder = attributes & 0x10 != 0
        return Entry(name: name, isFolder: isFolder, modified: fromDosTime(dosTime), method: method, crc: crc,
                     packedSize: packedSize, size: size, dataOffset: offset)
    }

    private static func readSize(_ reader: BinaryReader, _ width: Int) throws -> Int64 {
        var value: UInt64 = 0
        for (index, byte) in try reader.readBytes(width).enumerated() { value |= UInt64(byte) << (8 * UInt64(index)) }
        return Int64(bitPattern: value)
    }

    /// Skips an "ELZ\x01" comment section; its size is in the 12 bytes after the end record.
    private static func skipComment(_ reader: BinaryReader) throws {
        let position = reader.position
        try reader.seek(reader.length - 12)
        let size = Int64(try reader.readUInt32()) // includes the 4-byte signature already read
        reader.position = position + Int(max(0, size - 4))
    }

    /// CP949 names as written by Korean Windows, UTF-8 when the bytes are valid UTF-8.
    static func decodeName(_ bytes: Data) -> String {
        String(data: bytes, encoding: .utf8) ?? TextEncodings.decode(bytes, codePage: 949)
    }

    /// DOS date and time (local time, 2-second steps), or nil when invalid.
    static func fromDosTime(_ value: UInt32) -> Date? {
        let second = Int(value & 0x1F) * 2, minute = Int(value >> 5) & 0x3F, hour = Int(value >> 11) & 0x1F
        let day = Int(value >> 16) & 0x1F, month = Int(value >> 21) & 0x0F, year = 1980 + Int(value >> 25)
        let calendar = ZipReader.dosCalendar
        guard (1...12).contains(month), hour <= 23, minute <= 59, second <= 59,
              let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: monthStart), day >= 1, day <= days.count else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }
}
