// Port of Filee.Engines/Fonts/Woff.cs.
import Foundation

enum Woff {
    static let signature: UInt32 = 0x774F4646
    static func encode(_ font: SfntFont) throws -> Data {
        let sfnt = try SfntFont.read(font.write()), tags = sfnt.tables.keys.sorted()
        var compressed: [Data] = [], sfntSize = 12 + 16 * tags.count
        for tag in tags {
            try Task.checkCancellation()
            let data = sfnt.tables[tag]!, packed = try Deflate.deflate(data, level: 9, windowBits: 15)
            compressed.append(packed.count < data.count ? packed : data)
            sfntSize += (data.count + 3) & ~3
        }
        let w = FontBigEndianWriter()
        w.u32(signature); w.u32(sfnt.flavor); w.u32(0); w.u16(tags.count); w.u16(0); w.u32(UInt32(sfntSize))
        let (major, minor) = fontVersion(sfnt); w.u16(major); w.u16(minor); w.zeros(20)
        var offset = 44 + 20 * tags.count
        for i in tags.indices {
            let data = sfnt.tables[tags[i]]!
            w.u32(SfntFont.tagValue(tags[i])); w.u32(UInt32(offset)); w.u32(UInt32(compressed[i].count)); w.u32(UInt32(data.count)); w.u32(SfntFont.tableChecksum(tags[i], data))
            offset += (compressed[i].count + 3) & ~3
        }
        for data in compressed { w.bytes(data); w.pad4() }
        w.setU32(8, UInt32(w.length)); return w.written
    }
    static func decode(_ data: Data) throws -> SfntFont {
        let r = FontBigEndianReader(data)
        if try r.u32() != signature { throw ConversionError("This is not a WOFF file.") }
        let font = SfntFont(try r.u32())
        guard [SfntFont.trueTypeFlavor, SfntFont.cffFlavor, SfntFont.appleTrueTypeFlavor].contains(font.flavor) else { throw ConversionError("The WOFF file contains an unknown kind of font.") }
        if font.flavor == SfntFont.appleTrueTypeFlavor { font.flavor = SfntFont.trueTypeFlavor }
        try r.skip(4); let count = try r.u16(); r.position = 44
        for _ in 0..<count {
            let tag = SfntFont.tagName(try r.u32()), offset = Int(try r.u32()), compLength = Int(try r.u32()), origLength = Int(try r.u32())
            try r.skip(4)
            guard offset <= data.count, compLength <= data.count - offset, compLength <= origLength else { throw ConversionError("The WOFF table '\(tag.trimmingCharacters(in: .whitespaces))' is damaged.") }
            let stored = data.subdata(in: offset..<offset + compLength)
            if compLength == origLength { font.tables[tag] = stored }
            else {
                do {
                    let decoded = try Deflate.inflate(stored, windowBits: 15)
                    guard decoded.count >= origLength else { throw EndOfStreamError() }
                    font.tables[tag] = Data(decoded.prefix(origLength))
                } catch { throw ConversionError("The WOFF table '\(tag.trimmingCharacters(in: .whitespaces))' can't be decompressed.") }
            }
        }
        return font
    }
    static func fontVersion(_ font: SfntFont) -> (Int, Int) {
        guard let head = font["head"], head.count >= 8 else { return (0, 0) }
        let revision = Double(BinaryPrimitives.readInt32BigEndian(head, 4)) / 65536, major = Int(floor(revision))
        return (min(65535, max(0, major)), min(65535, max(0, Int(((revision - Double(major)) * 1000).rounded(.toNearestOrEven)))))
    }
}
