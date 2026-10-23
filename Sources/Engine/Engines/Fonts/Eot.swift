// Port of Filee.Engines/Fonts/Eot.cs.
import Foundation

enum Eot {
    static func isEot(_ data: Data) -> Bool {
        data.count >= 82 && BinaryPrimitives.readUInt16LittleEndian(data, 34) == 0x504C && [0x00010000, 0x00020001, 0x00020002].contains(BinaryPrimitives.readUInt32LittleEndian(data, 8))
    }
    static func encode(_ font: SfntFont) throws -> Data {
        let sfnt = font.write(), written = try SfntFont.read(sfnt), os2 = written["OS/2"] ?? Data(), head = try written.require("head"), names = FontNameTable.read(written["name"])
        func u16(_ data: Data, _ offset: Int) -> UInt16 { data.count >= offset + 2 ? BinaryPrimitives.readUInt16BigEndian(data, offset) : 0 }
        func u32(_ data: Data, _ offset: Int) -> UInt32 { data.count >= offset + 4 ? BinaryPrimitives.readUInt32BigEndian(data, offset) : 0 }
        let w = BinaryWriter()
        w.write(UInt32(0)); w.write(UInt32(sfnt.count)); w.write(UInt32(0x00020001)); w.write(UInt32(0))
        w.write(os2.count >= 42 ? os2.subdata(in: 32..<42) : Data(repeating: 0, count: 10))
        w.write(UInt8(1)); w.write(UInt8(u16(os2, 62) & 1)); w.write(UInt32(u16(os2, 4))); w.write(u16(os2, 8)); w.write(UInt16(0x504C))
        for i in 0..<4 { w.write(u32(os2, 42 + 4 * i)) }
        for i in 0..<2 { w.write(u32(os2, 78 + 4 * i)) }
        w.write(u32(head, 8))
        for _ in 0..<4 { w.write(UInt32(0)) }
        w.write(UInt16(0))
        for id in [1, 2, 5, 4] {
            let bytes = names.get(id).data(using: .utf16LittleEndian)!
            w.write(UInt16(truncatingIfNeeded: bytes.count)); w.write(bytes); w.write(UInt16(0))
        }
        w.write(UInt16(0)); w.write(sfnt)
        var eot = w.data; BinaryPrimitives.writeUInt32LittleEndian(&eot, 0, UInt32(eot.count)); return eot
    }
    static func decode(_ data: Data) throws -> SfntFont {
        guard isEot(data) else { throw ConversionError("This is not an EOT file.") }
        let size = Int(BinaryPrimitives.readUInt32LittleEndian(data)), fontSize = Int(BinaryPrimitives.readUInt32LittleEndian(data, 4)), flags = BinaryPrimitives.readUInt32LittleEndian(data, 12)
        if flags & 4 != 0 { throw ConversionError("This EOT file is compressed with MicroType Express, which Filee can't unpack. Only uncompressed EOT files can be converted.") }
        guard size <= data.count, size >= 82, fontSize <= size - 82 else { throw ConversionError("The EOT file is truncated or damaged.") }
        var font = data.subdata(in: size - fontSize..<size)
        if flags & 0x10000000 != 0 { for i in font.indices { font[i] ^= 0x50 } }
        return try SfntFont.read(font)
    }
}

final class FontNameTable {
    private var records: [(platform: Int, encoding: Int, language: Int, nameId: Int, value: String)] = []
    static func read(_ name: Data?) -> FontNameTable {
        let table = FontNameTable()
        guard let name = name, name.count >= 6 else { return table }
        do {
            let r = FontBigEndianReader(name); _ = try r.u16()
            let count = try r.u16(), stringOffset = try r.u16()
            for _ in 0..<count {
                let platform = try r.u16(), encoding = try r.u16(), language = try r.u16(), nameId = try r.u16(), length = try r.u16(), offset = try r.u16()
                if stringOffset + offset + length > name.count { continue }
                let bytes = name.subdata(in: stringOffset + offset..<stringOffset + offset + length)
                let value: String?
                if platform == 0 || platform == 3 {
                    var units: [UInt16] = []; var i = 0
                    while i + 1 < bytes.count { units.append(BinaryPrimitives.readUInt16BigEndian(bytes, i)); i += 2 }
                    if i < bytes.count { units.append(0xFFFD) }
                    value = String(decoding: units, as: UTF16.self)
                } else if platform == 1 && encoding == 0 { value = String(decoding: bytes.map(UInt16.init), as: UTF16.self) }
                else { value = nil }
                if let value = value { table.records.append((platform, encoding, language, nameId, value)) }
            }
        } catch { /* A damaged name table only costs the names. */ }
        return table
    }
    func get(_ nameId: Int) -> String {
        let candidates = records.filter { $0.nameId == nameId }
        return candidates.first { $0.platform == 3 && $0.language == 0x409 }?.value ?? candidates.first { $0.platform == 3 }?.value ?? candidates.first { $0.platform == 0 }?.value ?? candidates.first?.value ?? ""
    }
}
