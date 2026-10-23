// Port of Filee.Engines/Fonts/SfntFont.cs.
import Foundation

final class SfntFont {
    static let trueTypeFlavor: UInt32 = 0x00010000
    static let cffFlavor: UInt32 = 0x4F54544F
    static let appleTrueTypeFlavor: UInt32 = 0x74727565
    static let collectionTag: UInt32 = 0x74746366
    private static let trueTypeOrder = ["head", "hhea", "maxp", "OS/2", "hmtx", "LTSH", "VDMX", "hdmx", "cmap", "fpgm", "prep", "cvt ", "loca", "glyf", "kern", "name", "post", "gasp", "PCLT"]
    private static let cffOrder = ["head", "hhea", "maxp", "OS/2", "name", "cmap", "post", "CFF "]
    var flavor: UInt32
    var tables: [String: Data] = [:]
    init(_ flavor: UInt32) { self.flavor = flavor }
    subscript(_ tag: String) -> Data? { tables[tag] }
    var hasCffOutlines: Bool { tables["CFF "] != nil && tables["glyf"] == nil }
    func require(_ tag: String) throws -> Data {
        guard let data = tables[tag] else { throw ConversionError("The font has no '\(tag.trimmingCharacters(in: .whitespaces))' table.") }
        return data
    }
    var glyphCount: Int { get throws { try FontBigEndianReader(require("maxp"), 4).u16() } }
    static func tagValue(_ tag: String) -> UInt32 { tag.utf16.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    static func tagName(_ tag: UInt32) -> String { String(decoding: (0..<4).map { UInt16((tag >> (24 - 8 * $0)) & 255) }, as: UTF16.self) }
    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0, word: UInt32 = 0
        for (i, b) in data.enumerated() {
            word |= UInt32(b) << (24 - (i & 3) * 8)
            if i & 3 == 3 { sum &+= word; word = 0 }
        }
        return sum &+ word
    }
    static func tableChecksum(_ tag: String, _ data: Data) -> UInt32 {
        if tag != "head" || data.count < 12 { return checksum(data) }
        var copy = data; copy.replaceSubrange(8..<12, with: [0, 0, 0, 0]); return checksum(copy)
    }
    static func isSfnt(_ data: Data) -> Bool {
        data.count >= 12 && [trueTypeFlavor, cffFlavor, appleTrueTypeFlavor, collectionTag].contains(BinaryPrimitives.readUInt32BigEndian(data))
    }
    static func read(_ data: Data, _ offset: Int = 0) throws -> SfntFont {
        let r = FontBigEndianReader(data, offset), flavor = try r.u32()
        if flavor == collectionTag {
            if offset != 0 { throw ConversionError("Nested font collection.") }
            try r.skip(4)
            if try r.u32() == 0 { throw ConversionError("The font collection is empty.") }
            return try read(data, Int(r.u32()))
        }
        guard [trueTypeFlavor, cffFlavor, appleTrueTypeFlavor].contains(flavor) else { throw ConversionError("This is not a TrueType or OpenType font.") }
        let font = SfntFont(flavor == appleTrueTypeFlavor ? trueTypeFlavor : flavor), count = try r.u16()
        try r.skip(6)
        for _ in 0..<count {
            let tag = tagName(try r.u32()); try r.skip(4)
            let tableOffset = Int(try r.u32()), length = Int(try r.u32())
            guard tableOffset <= data.count, length <= data.count - tableOffset else { throw ConversionError("The font's '\(tag.trimmingCharacters(in: .whitespaces))' table lies outside the file.") }
            font.tables[tag] = data.subdata(in: tableOffset..<tableOffset + length)
        }
        return font
    }
    func write() -> Data {
        let tags = tables.keys.sorted(), order = flavor == Self.cffFlavor ? Self.cffOrder : Self.trueTypeOrder
        func rank(_ tag: String) -> Int { tag == "DSIG" ? Int.max : order.firstIndex(of: tag) ?? order.count }
        let dataOrder = tags.sorted { rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1) }
        var offsets: [String: Int] = [:], position = 12 + 16 * tags.count
        for tag in dataOrder { offsets[tag] = position; position += (tables[tag]!.count + 3) & ~3 }
        var output = Data(repeating: 0, count: position)
        let w = FontBigEndianWriter(), selector = tags.isEmpty ? 0 : Int.bitWidth - 1 - tags.count.leadingZeroBitCount
        let searchRange = (1 << selector) * 16
        w.u32(flavor); w.u16(tags.count); w.u16(searchRange); w.u16(selector); w.u16(tags.count * 16 - searchRange)
        for tag in tags {
            let data = tables[tag]!, offset = offsets[tag]!
            w.u32(Self.tagValue(tag)); w.u32(Self.tableChecksum(tag, data)); w.u32(UInt32(offset)); w.u32(UInt32(data.count))
            output.replaceSubrange(offset..<offset + data.count, with: data)
        }
        output.replaceSubrange(0..<w.length, with: w.written)
        if let head = offsets["head"], tables["head"]!.count >= 12 {
            output.replaceSubrange(head + 8..<head + 12, with: [0, 0, 0, 0])
            BinaryPrimitives.writeUInt32BigEndian(&output, head + 8, 0xB1B0AFBA &- Self.checksum(output))
        }
        return output
    }
    func clone() -> SfntFont { let copy = SfntFont(flavor); copy.tables = tables; return copy }
}
