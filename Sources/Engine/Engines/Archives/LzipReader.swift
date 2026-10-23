// Port of Filee.Engines/Archives/LzipReader.cs: reads lzip files (.lz, .tar.lz), which 7-Zip does not open. An lzip
// member is a 6-byte header ("LZIP", version 1, coded dictionary size), a raw LZMA stream (lc=3, lp=0, pb=2, always
// ended by an end marker) and a 20-byte trailer (CRC-32 u32, data size u64, member size u64). Each member is rewritten
// as a classic .lzma file, which the bundled 7-Zip decodes; the result is checked against the trailer.

import Foundation

/// Decompresses lzip files with the help of 7-Zip's LZMA decoder.
enum LzipReader {
    private static let headerSize = 6
    private static let trailerSize = 20

    /// One lzip member.
    private struct Member {
        let start: Int
        let size: Int
        let crc: UInt32
        let dataSize: Int64
    }

    /// Decompresses `lzipFile` into `outputFile`.
    static func decompress(_ lzipFile: String, _ outputFile: String, _ sevenZip: SevenZip, _ workDirectory: String) async throws {
        let name = FilePath.fileName(lzipFile)
        let input = try ArchiveFiles.map(lzipFile)
        let members = try findMembers(input, name)
        try ArchiveSafety.ensureRoom(try ArchiveFiles.sum(members.map(\.dataSize)),
                                     FilePath.directoryName(FilePath.fullPath(outputFile)) ?? "/", name)

        let folder = FilePath.combine(workDirectory, "lzip-\(ArchiveFiles.guid().prefix(8))")
        try FileManager.default.createDirectoryIfNeeded(folder)
        defer { ArchiveFiles.tryDeleteFolder(folder) }
        do {
            let output = try ArchiveFiles.createNew(outputFile)
            defer { try? output.close() }
            for member in members {
                try Task.checkCancellation()
                let lzma = FilePath.combine(folder, "member.lzma")
                guard FileManager.default.createFile(atPath: lzma, contents: nil), let file = FileHandle(forWritingAtPath: lzma) else {
                    throw ArchiveFiles.accessDenied(lzma)
                }
                do {
                    defer { try? file.close() }
                    // .lzma header: properties (lc=3, lp=0, pb=2), dictionary size, unknown size (-1: until the end marker).
                    var header = Data([0x5D])
                    header.append(littleEndian(UInt64(dictionarySize(Int(input[member.start + 5])))).prefix(4))
                    header.append(littleEndian(UInt64.max))
                    try file.write(contentsOf: header)
                    let packed = input[(member.start + headerSize)..<(member.start + member.size - trailerSize)]
                    try ArchiveFiles.copyLimited(ArchiveFiles.chunks(packed), to: { try file.write(contentsOf: $0) }, maxBytes: .max)
                }

                let unpacked = FilePath.combine(folder, "out")
                ArchiveFiles.tryDeleteFolder(unpacked)
                try await sevenZip.extract(lzma, unpacked, [], folder)
                let result = FilePath.combine(unpacked, "member")
                guard FileManager.default.fileExists(result) else { throw ArchiveSafety.damaged(name, "LZMA data could not be decoded") }

                var crc = ArchiveCrc32()
                let copied = try ArchiveFiles.copyLimited(ArchiveFiles.chunks(ofFile: result), to: { chunk in
                    crc.append(chunk)
                    try output.write(contentsOf: chunk)
                }, maxBytes: member.dataSize)
                if copied != member.dataSize { throw ArchiveSafety.damaged(name, "wrong data size") }
                if crc.value != member.crc { throw ArchiveSafety.damaged(name, "checksum error") }
            }
        } catch {
            ArchiveFiles.tryDeleteFile(outputFile)
            throw error
        }
        if let time = ArchiveFiles.modificationDate(lzipFile) { try ArchiveFiles.setModificationDate(outputFile, time) }
    }

    /// Finds the members from the end of the file backwards (every trailer ends with its member's size), as lzip does.
    private static func findMembers(_ input: Data, _ name: String) throws -> [Member] {
        var members: [Member] = []
        var end = input.count
        while end > 0 {
            if end < headerSize + trailerSize { throw invalidLzip(name) }
            let crc = BinaryPrimitives.readUInt32LittleEndian(input, end - trailerSize)
            let dataSize = BinaryPrimitives.readInt64LittleEndian(input, end - trailerSize + 4)
            let size = BinaryPrimitives.readInt64LittleEndian(input, end - trailerSize + 12)
            if size < Int64(headerSize + trailerSize) || size > Int64(end) || dataSize < 0 { throw invalidLzip(name) }

            let start = end - Int(size)
            if input[start..<start + 5] != Data("LZIP".utf8) + Data([1]) { throw invalidLzip(name) }
            members.insert(Member(start: start, size: Int(size), crc: crc, dataSize: dataSize), at: 0)
            end = start
        }
        if members.isEmpty { throw invalidLzip(name) }
        return members
    }

    /// The coded dictionary size of the header: bits 0-4 are the base-2 logarithm, bits 5-7 subtract that many
    /// sixteenths.
    static func dictionarySize(_ coded: Int) -> UInt32 {
        let size: UInt32 = 1 << UInt32(coded & 0x1F)
        return size - (size / 16) * UInt32((coded >> 5) & 7)
    }

    private static func invalidLzip(_ name: String) -> ConversionError {
        ConversionError("\(name) is not a valid lzip file, or it is damaged.")
    }

    private static func littleEndian(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
