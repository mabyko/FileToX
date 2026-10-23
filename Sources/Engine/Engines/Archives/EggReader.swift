// Port of Filee.Engines/Archives/EggReader.cs: reads EGG archives, ALZip's newer format, which 7-Zip does not support.
// Layout as documented by EggDotNet (MIT) and unegg (MIT); Filee's reader is its own. All numbers are little endian.
//
//   "EGGA" version u16, header id u32, reserved u32, extra fields…, END      archive header
//   FILE (0x0A8590E3) file id u32, size u64, extra fields…, END              one per entry, followed by
//   BLOCK (0x02B50C13) method u8, hint u8, size u32, packed u32, CRC-32 u32, END, data   one or more blocks
//   END (0x08E28222)                                                         end of archive
//
// An extra field is magic u32, flags u8, size u16 (u32 when flags bit 0 is set) and data. The file name field has a
// locale u16 before the name when flags & 0x08 (else the name is UTF-8) and a parent id u32 when flags & 0x10.
// Methods: 0 store, 1 deflate, 2 bzip2, 3 AZO (ESTsoft's own, not supported), 4 LZMA (ZIP-style: 4-byte version and
// size header, 5 property bytes, raw data; decoded by 7-Zip). Solid, split and encrypted archives are refused.

import Foundation

/// Unpacks EGG archives (store, deflate, bzip2 and LZMA blocks).
enum EggReader {
    private static let archiveMagic: UInt32 = 0x41474745 // "EGGA"
    private static let endMagic: UInt32 = 0x08E28222
    private static let fileMagic: UInt32 = 0x0A8590E3
    private static let blockMagic: UInt32 = 0x02B50C13
    private static let fileNameMagic: UInt32 = 0x0A8591AC
    private static let windowsInfoMagic: UInt32 = 0x2C86950B
    private static let posixInfoMagic: UInt32 = 0x1EE922E5
    private static let encryptMagic: UInt32 = 0x08D1470F
    private static let splitMagic: UInt32 = 0x24F5A262
    private static let solidMagic: UInt32 = 0x24E5A060

    /// One compressed block of an entry's data.
    private struct Block {
        let method: Int
        let size: Int64
        let packedSize: Int64
        let crc: UInt32
        let dataOffset: Int
    }

    /// One entry of the archive.
    private final class Entry {
        var name = ""
        var size: Int64 = 0
        var isFolder = false
        var modified: Date?
        var blocks: [Block] = []
    }

    /// Unpacks every entry of `archive` into `targetDirectory`. `sevenZip` decodes LZMA blocks; nil when 7-Zip is
    /// missing (LZMA entries then fail).
    static func extract(_ archive: String, _ targetDirectory: String, _ sevenZip: SevenZip?, _ workDirectory: String) async throws {
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
            let output = try ArchiveFiles.createNew(path)
            do {
                defer { try? output.close() }
                for block in entry.blocks {
                    var crc = ArchiveCrc32()
                    var length: Int64 = 0
                    try await decodeBlock(stream, block, { chunk in
                        crc.append(chunk)
                        length += Int64(chunk.count)
                        try output.write(contentsOf: chunk)
                    }, sevenZip, workDirectory, archiveName, entry.name)
                    if length != block.size || crc.value != block.crc {
                        throw ArchiveSafety.damaged(archiveName, "checksum error in \(entry.name)")
                    }
                }
            }
            if ArchiveFiles.fileLength(path) != entry.size { throw ArchiveSafety.damaged(archiveName, "wrong size of \(entry.name)") }
            if let modified = entry.modified { try ArchiveFiles.setModificationDate(path, modified) }
        }

        for folder in folders {
            if let time = folder.modified { try ArchiveFiles.setModificationDate(folder.path, time) }
        }
    }

    private static func decodeBlock(_ stream: Data, _ block: Block, _ output: (Data) throws -> Void, _ sevenZip: SevenZip?,
                                    _ workDirectory: String, _ archiveName: String, _ entryName: String) async throws {
        let packed = stream[block.dataOffset..<block.dataOffset + Int(block.packedSize)]
        switch block.method {
        case 0:
            try ArchiveFiles.copyLimited(ArchiveFiles.chunks(packed), to: output, maxBytes: block.size)
        case 1:
            try AlzReader.inflate(packed, output, block.size, archiveName, entryName)
        case 2:
            try Bzip2Decoder.decompress(packed, output, alzFraming: false, maxOutput: block.size)
        case 3:
            throw ConversionError("\(archiveName) is compressed with ALZip's own AZO method, which Filee cannot unpack. Save it again in ALZip as ZIP or 7Z, or as EGG with another method.")
        case 4:
            try await decodeLzma(packed, block, output, sevenZip, workDirectory, archiveName)
        default:
            throw ConversionError("\(archiveName) uses an unknown EGG compression method (\(block.method)).")
        }
    }

    /// LZMA blocks carry ZIP's LZMA header (version u16, property size u16, 5 property bytes). Rewritten as a .lzma file
    /// (properties, unpacked size u64, data) they can be decoded by 7-Zip.
    private static func decodeLzma(_ packed: Data, _ block: Block, _ output: (Data) throws -> Void, _ sevenZip: SevenZip?,
                                   _ workDirectory: String, _ archiveName: String) async throws {
        guard let sevenZip else { throw ConversionError("7-Zip was not found; it is needed for LZMA data.") }
        guard packed.count >= 9 else { throw EndOfStreamError() }
        let header = packed.prefix(9)
        let folder = FilePath.combine(workDirectory, "egg-\(ArchiveFiles.guid().prefix(8))")
        try FileManager.default.createDirectoryIfNeeded(folder)
        defer { ArchiveFiles.tryDeleteFolder(folder) }

        let lzma = FilePath.combine(folder, "block.lzma")
        let file = try ArchiveFiles.createNew(lzma)
        do {
            defer { try? file.close() }
            try file.write(contentsOf: header.suffix(5))
            try file.write(contentsOf: littleEndian(UInt64(bitPattern: block.size)))
            try ArchiveFiles.copyLimited(ArchiveFiles.chunks(packed.dropFirst(9)), to: { try file.write(contentsOf: $0) },
                                         maxBytes: block.packedSize)
        }
        let unpacked = FilePath.combine(folder, "out")
        try await sevenZip.extract(lzma, unpacked, [], folder)
        let result = FilePath.combine(unpacked, "block")
        guard FileManager.default.fileExists(result) else { throw ArchiveSafety.damaged(archiveName, "LZMA data could not be decoded") }
        try ArchiveFiles.copyLimited(ArchiveFiles.chunks(ofFile: result), to: output, maxBytes: block.size)
    }

    private static func readEntries(_ stream: Data, _ archiveName: String) throws -> [Entry] {
        let reader = BinaryReader(stream)
        var entries: [Entry] = []
        do {
            if try stream.count < 14 || reader.readUInt32() != archiveMagic {
                throw ConversionError("\(archiveName) is not an EGG archive.")
            }
            _ = try reader.readUInt16() // version
            _ = try reader.readUInt32() // header id
            _ = try reader.readUInt32() // reserved
            try readExtraFields(reader, archiveName, nil)

            var current: Entry?
            while reader.position + 4 <= reader.length {
                let magic = try reader.readUInt32()
                if magic == fileMagic {
                    if entries.count >= ArchiveSafety.maxEntries {
                        throw ConversionError("\(archiveName) has more than \(ArchiveSafety.maxEntriesText) entries; Filee does not unpack it.")
                    }
                    let entry = Entry()
                    _ = try reader.readUInt32() // file id
                    entry.size = try reader.readInt64()
                    try readExtraFields(reader, archiveName, entry)
                    entries.append(entry)
                    current = entry
                } else if magic == blockMagic, let current {
                    let method = Int(try reader.readByte())
                    _ = try reader.readByte() // hint
                    let size = try reader.readUInt32()
                    let packedSize = try reader.readUInt32()
                    let crc = try reader.readUInt32()
                    if try reader.readUInt32() != endMagic { throw ArchiveSafety.damaged(archiveName, "invalid EGG block header") }
                    if reader.position + Int(packedSize) > reader.length { throw ArchiveSafety.damaged(archiveName, "the archive ends too early") }
                    current.blocks.append(Block(method: method, size: Int64(size), packedSize: Int64(packedSize), crc: crc,
                                                dataOffset: reader.position))
                    reader.position += Int(packedSize)
                } else if magic == endMagic {
                    return try validate(entries, archiveName)
                } else {
                    // Comments and other extra fields between entries.
                    try skipExtraField(reader, archiveName)
                }
            }
            return try validate(entries, archiveName)
        } catch is EndOfStreamError {
            throw ArchiveSafety.damaged(archiveName, "the archive ends too early")
        }
    }

    private static func validate(_ entries: [Entry], _ archiveName: String) throws -> [Entry] {
        for entry in entries {
            if entry.name.isEmpty { throw ArchiveSafety.damaged(archiveName, "an entry has no name") }
            if entry.name.hasSuffix("/") || entry.name.hasSuffix("\\") { entry.isFolder = true }
            if !entry.isFolder && entry.blocks.reduce(0, { $0 + $1.size }) != entry.size {
                throw ArchiveSafety.damaged(archiveName, "the blocks of \(entry.name) do not add up")
            }
        }
        return entries
    }

    /// Reads extra fields up to the END marker, filling `entry` (nil: archive header).
    private static func readExtraFields(_ reader: BinaryReader, _ archiveName: String, _ entry: Entry?) throws {
        while true {
            let magic = try reader.readUInt32()
            if magic == endMagic { return }
            let flags = try reader.readByte()
            switch magic {
            case splitMagic:
                throw ConversionError("\(archiveName) is part of a split EGG archive; Filee cannot unpack split archives.")
            case solidMagic:
                throw ConversionError("\(archiveName) is a solid EGG archive, which Filee cannot unpack.")
            case encryptMagic:
                throw ArchiveSafety.encrypted(archiveName)
            case fileNameMagic where entry != nil:
                let nameLength = flags & 0x01 != 0 ? Int(try reader.readUInt32()) : Int(try reader.readUInt16())
                if flags & 0x04 != 0 { throw ArchiveSafety.encrypted(archiveName) }
                var encoding = String.Encoding.utf8
                if flags & 0x08 != 0 {
                    let codePage = Int(try reader.readUInt16())
                    encoding = TextEncodings.encoding(codePage: codePage) ?? TextEncodings.encoding(codePage: 949) ?? .utf8
                }
                if flags & 0x10 != 0 { _ = try reader.readUInt32() } // parent path id; names already hold the full path
                entry?.name = TextEncodings.decode(try reader.readBytes(nameLength), encoding: encoding)
            case windowsInfoMagic where entry != nil:
                let infoSize = try readFieldSize(reader, flags)
                let fileTime = try reader.readInt64()
                let attributes = try reader.readByte()
                try reader.seek(reader.position + Int(infoSize) - 9)
                // FILETIME: 100 ns steps since 1601 (UTC), up to DateTime.MaxValue.
                entry?.modified = fileTime > 0 && fileTime < 2_650_467_743_999_999_999
                    ? Date(timeIntervalSince1970: Double(fileTime - 116_444_736_000_000_000) / 10_000_000) : nil
                entry?.isFolder = (entry?.isFolder ?? false) || attributes & 0x10 != 0
            case posixInfoMagic where entry != nil:
                let posixSize = try readFieldSize(reader, flags)
                let mode = try reader.readUInt32()
                try reader.seek(reader.position + Int(posixSize) - 4)
                entry?.isFolder = (entry?.isFolder ?? false) || mode & 0xF000 == 0x4000
            default:
                try reader.seek(reader.position + Int(try readFieldSize(reader, flags)))
            }
        }
    }

    /// Skips an extra field whose magic has been read.
    private static func skipExtraField(_ reader: BinaryReader, _ archiveName: String) throws {
        let flags = try reader.readByte()
        let size = try readFieldSize(reader, flags)
        if reader.position + Int(size) > reader.length { throw ArchiveSafety.damaged(archiveName, "unknown EGG header") }
        reader.position += Int(size)
    }

    private static func readFieldSize(_ reader: BinaryReader, _ flags: UInt8) throws -> Int64 {
        flags & 0x01 != 0 ? Int64(try reader.readUInt32()) : Int64(try reader.readUInt16())
    }

    private static func littleEndian(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
