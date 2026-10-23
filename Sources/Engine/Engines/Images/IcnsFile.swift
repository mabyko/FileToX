// Port of Filee.Engines/Icns/IcnsFile.cs: reads and writes Apple icon files (.icns): a list of typed entries, each
// holding one icon size as PNG, JPEG 2000 or (in old files) run-length encoded RGB plus a separate 8-bit mask.

import Foundation

/// One entry of an .icns file: four-character type code (e.g. "ic08") and payload (without the 8-byte entry header).
struct IcnsEntry {
    let type: String
    let data: [UInt8]
}

/// A decoded icon: straight (non-premultiplied) RGBA pixels, row by row.
struct IcnsBitmap {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

/// ICNS container parsing, writing and the legacy RLE codec.
enum IcnsFile {
    /// Entry types written for a new icon, smallest first, with their pixel size (iconutil's set).
    static let writtenTypes: [(type: String, size: Int)] = [
        ("icp4", 16),
        ("ic11", 32), // 16 pt @2x
        ("icp5", 32),
        ("ic12", 64), // 32 pt @2x
        ("ic07", 128),
        ("ic13", 256), // 128 pt @2x
        ("ic08", 256),
        ("ic14", 512), // 256 pt @2x
        ("ic09", 512),
        ("ic10", 1024), // 512 pt @2x
    ]

    /// Pixel size of the image types that carry PNG or JPEG 2000 data (or ARGB for ic04/ic05).
    private static let imageTypes: [String: Int] = [
        "icp4": 16, "icp5": 32, "icp6": 64, "ic07": 128, "ic08": 256, "ic09": 512, "ic10": 1024, "ic11": 32, "ic12": 64, "ic13": 256,
        "ic14": 512, "ic04": 16, "ic05": 32, "icsb": 18, "icsB": 36, "sb24": 24, "SB24": 48,
    ]

    /// Legacy RLE RGB types, their size and the type of their 8-bit mask.
    private static let legacyTypes: [String: (size: Int, mask: String)] = [
        "is32": (16, "s8mk"), "il32": (32, "l8mk"), "ih32": (48, "h8mk"), "it32": (128, "t8mk"),
    ]

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let jp2Signature: [UInt8] = [0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20]
    private static let j2kSignature: [UInt8] = [0xFF, 0x4F, 0xFF, 0x51]

    // ───────────────────────── Container ─────────────────────────

    /// Parses the top-level entries of an .icns file.
    static func parse(_ file: [UInt8]) throws -> [IcnsEntry] {
        guard file.count >= 8, Array(file[0..<4]) == Array("icns".utf8) else {
            throw ConversionError("Not an ICNS file (the 'icns' signature is missing).")
        }
        let end = min(u32(file, 4), file.count)
        var entries: [IcnsEntry] = []
        var offset = 8
        while offset + 8 <= end {
            let type = String(bytes: file[offset..<offset + 4], encoding: .isoLatin1) ?? ""
            let length = u32(file, offset + 4)
            if length < 8 || offset + length > end { break } // truncated or corrupt: keep what was readable
            entries.append(IcnsEntry(type: type, data: Array(file[offset + 8..<offset + length])))
            offset += length
        }
        return entries
    }

    /// Writes entries, preceded by a table of contents like iconutil does.
    static func write(_ entries: [IcnsEntry]) -> [UInt8] {
        let tocLength = 8 + 8 * entries.count
        let total = 8 + tocLength + entries.reduce(0) { $0 + 8 + $1.data.count }
        var buffer: [UInt8] = Array("icns".utf8) + be32(total)
        buffer += Array("TOC ".utf8) + be32(tocLength)
        for entry in entries { buffer += Array(entry.type.utf8.prefix(4)) + be32(8 + entry.data.count) }
        for entry in entries { buffer += Array(entry.type.utf8.prefix(4)) + be32(8 + entry.data.count) + entry.data }
        return buffer
    }

    // ───────────────────────── Choosing an image ─────────────────────────

    /// An icon image found in the file, not decoded yet: PNG or JPEG 2000 bytes (`encoded`, decoded by ImageIO) or a
    /// decoder for legacy/ARGB data.
    struct Candidate {
        let type: String
        /// Nominal pixel size from the entry type.
        let size: Int
        let encoded: [UInt8]?
        let decode: (() -> IcnsBitmap)?
    }

    /// All images of the file, largest first (PNG / JPEG 2000 before legacy data of the same size).
    static func candidates(_ entries: [IcnsEntry]) -> [Candidate] {
        var byType: [String: IcnsEntry] = [:]
        for entry in entries where byType[entry.type] == nil { byType[entry.type] = entry }
        var result: [Candidate] = []
        for entry in entries {
            if let size = imageTypes[entry.type] {
                if isEncodedImage(entry.data) {
                    result.append(Candidate(type: entry.type, size: size, encoded: entry.data, decode: nil))
                } else if entry.data.starts(with: Array("ARGB".utf8)) {
                    result.append(Candidate(type: entry.type, size: size, encoded: nil, decode: { decodeArgb(entry.data, size) }))
                }
            } else if let legacy = legacyTypes[entry.type] {
                let mask = byType[legacy.mask]?.data
                result.append(Candidate(type: entry.type, size: legacy.size, encoded: nil,
                                        decode: { decodeLegacy(entry.type, entry.data, mask, legacy.size) }))
            }
        }
        // OrderByDescending(Size).ThenBy(encoded first); Swift's sort is stable like LINQ's.
        return result.sorted { a, b in a.size != b.size ? a.size > b.size : (a.encoded != nil && b.encoded == nil) }
    }

    /// True for PNG and JPEG 2000 (JP2 container or raw codestream) data.
    static func isEncodedImage(_ data: [UInt8]) -> Bool {
        data.starts(with: pngSignature) || data.starts(with: jp2Signature) || data.starts(with: j2kSignature)
    }

    // ───────────────────────── Legacy codecs ─────────────────────────

    /// Decodes is32/il32/ih32/it32: RGB stored channel after channel (all red, then green, then blue), each run-length
    /// encoded, plus an optional 8-bit mask entry as alpha. it32 data starts with four zero bytes. Data exactly
    /// 4 × size² bytes long is uncompressed ARGB, which some writers use for is32/il32.
    static func decodeLegacy(_ type: String, _ data: [UInt8], _ mask: [UInt8]?, _ size: Int) -> IcnsBitmap {
        let pixels = size * size
        var rgba = [UInt8](repeating: 0, count: pixels * 4)
        if data.count == pixels * 4 {
            for i in 0..<pixels {
                rgba[i * 4] = data[i * 4 + 1]
                rgba[i * 4 + 1] = data[i * 4 + 2]
                rgba[i * 4 + 2] = data[i * 4 + 3]
            }
        } else {
            let planes = unpackBits(Array(data.dropFirst(type == "it32" ? 4 : 0)), pixels * 3)
            for i in 0..<pixels {
                rgba[i * 4] = planes[i]
                rgba[i * 4 + 1] = planes[pixels + i]
                rgba[i * 4 + 2] = planes[2 * pixels + i]
            }
        }
        for i in 0..<pixels { rgba[i * 4 + 3] = mask != nil && mask!.count >= pixels ? mask![i] : 255 }
        return IcnsBitmap(width: size, height: size, rgba: rgba)
    }

    /// Decodes ic04/ic05 "ARGB" entries: the tag, then A, R, G and B planes run-length encoded.
    static func decodeArgb(_ data: [UInt8], _ size: Int) -> IcnsBitmap {
        let pixels = size * size
        let planes = unpackBits(Array(data.dropFirst(4)), pixels * 4)
        var rgba = [UInt8](repeating: 0, count: pixels * 4)
        for i in 0..<pixels {
            rgba[i * 4] = planes[pixels + i]
            rgba[i * 4 + 1] = planes[2 * pixels + i]
            rgba[i * 4 + 2] = planes[3 * pixels + i]
            rgba[i * 4 + 3] = planes[i]
        }
        return IcnsBitmap(width: size, height: size, rgba: rgba)
    }

    /// Apple's icon RLE: a control byte below 0x80 copies the next (n + 1) bytes, a control byte of 0x80 or more
    /// repeats the next byte (n − 125) times. Missing data (truncated files) stays zero.
    static func unpackBits(_ source: [UInt8], _ length: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: length)
        var written = 0
        var i = 0
        while written < length && i < source.count {
            let control = Int(source[i])
            i += 1
            if control < 0x80 {
                let count = min(control + 1, min(length - written, source.count - i))
                output.replaceSubrange(written..<written + count, with: source[i..<i + count])
                i += control + 1
                written += count
            } else {
                if i >= source.count { break }
                let value = source[i]
                i += 1
                let count = min(control - 125, length - written)
                for k in written..<written + count { output[k] = value }
                written += count
            }
        }
        return output
    }

    // ───────────────────────── Bytes ─────────────────────────

    private static func u32(_ data: [UInt8], _ at: Int) -> Int {
        Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
    }

    private static func be32(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
