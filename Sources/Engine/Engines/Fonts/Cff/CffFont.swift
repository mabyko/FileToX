// Port of Filee.Engines/Fonts/Cff/CffFont.cs.
import Foundation

struct CffPrivate { var subrs: [Data] = [] }
final class CffFont {
    var charStrings: [Data] = [], globalSubrs: [Data] = [], privates: [CffPrivate] = [], fontMatrices: [[Double]] = []
    var isCid = false, charset: [Int]?, strings: [String] = []
    private var fdSelect: [Int] = [], glyphBySidCache: [Int: Int]?
    var glyphCount: Int { charStrings.count }
    func fontDictIndex(_ glyph: Int) -> Int { glyph < fdSelect.count ? fdSelect[glyph] : 0 }
    func glyphName(_ glyph: Int) -> String? {
        guard !isCid, let charset = charset, glyph < charset.count else { return nil }
        let sid = charset[glyph], n = CffStandardData.standardStrings.count
        return sid < n ? CffStandardData.standardStrings[sid] : sid - n < strings.count ? strings[sid - n] : nil
    }
    func glyphBySid(_ sid: Int) -> Int {
        guard let charset = charset, !isCid else { return -1 }
        if glyphBySidCache == nil {
            glyphBySidCache = [:]
            for (gid, s) in charset.enumerated() where glyphBySidCache![s] == nil { glyphBySidCache![s] = gid }
        }
        return glyphBySidCache![sid] ?? -1
    }
    static func parse(_ data: Data) throws -> CffFont {
        if data.count < 4 { throw ConversionError("The CFF table is damaged.") }
        if data[0] != 1 { throw ConversionError("CFF version \(data[0]) outlines can't be converted.") }
        var position = Int(data[2]); _ = try readIndex(data, &position)
        let topDicts = try readIndex(data, &position), strings = try readIndex(data, &position), globalSubrs = try readIndex(data, &position)
        if topDicts.isEmpty { throw ConversionError("The CFF table has no font.") }
        let top = try parseDict(topDicts[0])
        if number(top, 1206, 2) != 2 { throw ConversionError("The CFF font uses Type 1 charstrings, which aren't supported.") }
        guard let csOffset = top[17], !csOffset.isEmpty else { throw ConversionError("The CFF font has no glyphs.") }
        var at = try offset(csOffset[0], data)
        let charStrings = try readIndex(data, &at), topMatrix = top[1207].flatMap { $0.count == 6 ? $0 : nil } ?? [0.001, 0, 0, 0.001, 0, 0], isCid = top[1230] != nil
        let font = CffFont()
        if isCid {
            guard let fdOffset = top[1236], !fdOffset.isEmpty else { throw ConversionError("The CID-keyed CFF font has no font dictionaries.") }
            var fdAt = try offset(fdOffset[0], data)
            let fontDicts = try readIndex(data, &fdAt).map(parseDict)
            font.privates = try fontDicts.map { try readPrivate(data, $0) }
            font.fontMatrices = fontDicts.map { fd in fd[1207].flatMap { $0.count == 6 ? multiply($0, topMatrix) : nil } ?? topMatrix }
            if let fdSelectOffset = top[1237]?.first { font.fdSelect = try readFdSelect(data, offset(fdSelectOffset, data), charStrings.count, font.privates.count) }
        } else { font.privates = [try readPrivate(data, top)]; font.fontMatrices = [topMatrix] }
        // Filee expects at least one dictionary; surface damaged input as an error instead of indexing an empty array.
        guard !font.privates.isEmpty else { throw ConversionError("The CID-keyed CFF font has no font dictionaries.") }
        font.charStrings = charStrings; font.globalSubrs = globalSubrs; font.isCid = isCid
        font.charset = try readCharset(data, Int(number(top, 15, 0)), charStrings.count)
        font.strings = strings.map { String(decoding: $0.map(UInt16.init), as: UTF16.self) }; return font
    }
    private static func multiply(_ f: [Double], _ t: [Double]) -> [Double] {
        [t[0] * f[0] + t[2] * f[1], t[1] * f[0] + t[3] * f[1], t[0] * f[2] + t[2] * f[3], t[1] * f[2] + t[3] * f[3], t[0] * f[4] + t[2] * f[5] + t[4], t[1] * f[4] + t[3] * f[5] + t[5]]
    }
    private static func readPrivate(_ data: Data, _ dict: [Int: [Double]]) throws -> CffPrivate {
        guard let entry = dict[18], entry.count >= 2 else { return CffPrivate() }
        let size = Int(entry[0]), off = try offset(entry[1], data)
        if size < 0 || size > data.count - off { throw ConversionError("The CFF private dictionary lies outside the table.") }
        let priv = try parseDict(data.subdata(in: off..<off + size))
        if let subrsOffset = priv[19]?.first { var at = try offset(Double(off) + subrsOffset, data); return CffPrivate(subrs: try readIndex(data, &at)) }
        return CffPrivate()
    }
    private static func readCharset(_ data: Data, _ off: Int, _ glyphCount: Int) throws -> [Int]? {
        if off == 0 { return Array(0..<glyphCount) }
        if off == 1 || off == 2 { return nil }
        var charset = [Int](repeating: 0, count: glyphCount), glyph = 1
        let r = try FontBigEndianReader(data, offset(Double(off), data)), format = try r.u8()
        while glyph < glyphCount {
            switch format {
            case 0: charset[glyph] = try r.u16(); glyph += 1
            case 1, 2:
                let first = try r.u16(), left = try format == 1 ? r.u8() : r.u16()
                for i in 0...left where glyph < glyphCount { charset[glyph] = Int(UInt16(truncatingIfNeeded: first + i)); glyph += 1 }
            default: throw ConversionError("Unknown CFF charset format \(format).")
            }
        }
        return charset
    }
    private static func readFdSelect(_ data: Data, _ off: Int, _ glyphCount: Int, _ fdCount: Int) throws -> [Int] {
        var fds = [Int](repeating: 0, count: glyphCount)
        let r = FontBigEndianReader(data, off), format = try r.u8()
        if format == 0 { for i in 0..<glyphCount { fds[i] = try r.u8() } }
        else if format == 3 {
            let ranges = try r.u16(); var first = try r.u16()
            for _ in 0..<ranges {
                let fd = try r.u8(), next = try r.u16()
                if first < min(next, glyphCount) { for g in first..<min(next, glyphCount) { fds[g] = fd } }
                first = next
            }
        } else { throw ConversionError("Unknown CFF FDSelect format \(format).") }
        if fds.contains(where: { $0 >= fdCount }) { throw ConversionError("The CFF FDSelect refers to a missing font dictionary.") }
        return fds
    }
    static func readIndex(_ data: Data, _ position: inout Int) throws -> [Data] {
        let r = FontBigEndianReader(data, position), count = try r.u16()
        if count == 0 { position = r.position; return [] }
        let offSize = try r.u8()
        if offSize < 1 || offSize > 4 { throw ConversionError("The CFF table is damaged (invalid INDEX).") }
        var offsets: [Int] = []
        for _ in 0...count { var value = 0; for _ in 0..<offSize { value = try value << 8 | r.u8() }; offsets.append(value) }
        let dataStart = r.position - 1
        var items: [Data] = []
        for i in 0..<count {
            let start = dataStart + offsets[i], end = dataStart + offsets[i + 1]
            if start < r.position || end < start || end > data.count { throw ConversionError("The CFF table is damaged (INDEX data outside the table).") }
            items.append(data.subdata(in: start..<end))
        }
        position = dataStart + offsets[count]; return items
    }
    static func parseDict(_ data: Data) throws -> [Int: [Double]] {
        var dict: [Int: [Double]] = [:], operands: [Double] = []
        let r = FontBigEndianReader(data)
        while r.remaining > 0 {
            let b0 = try r.u8()
            if b0 <= 21 { let op = b0 == 12 ? try 1200 + r.u8() : b0; dict[op] = operands; operands.removeAll(keepingCapacity: true) }
            else if b0 == 28 { operands.append(Double(try r.i16())) }
            else if b0 == 29 { operands.append(Double(try r.i32())) }
            else if b0 == 30 { operands.append(try readReal(r)) }
            else if b0 >= 32 && b0 <= 246 { operands.append(Double(b0 - 139)) }
            else if b0 >= 247 && b0 <= 250 { operands.append(Double(try (b0 - 247) * 256 + r.u8() + 108)) }
            else if b0 >= 251 && b0 <= 254 { operands.append(Double(try -(b0 - 251) * 256 - r.u8() - 108)) }
            else { throw ConversionError("The CFF table is damaged (invalid DICT data).") }
        }
        return dict
    }
    private static func readReal(_ r: FontBigEndianReader) throws -> Double {
        var text = ""
        while true {
            let b = try r.u8()
            for nibble in [b >> 4, b & 15] {
                switch nibble {
                case 0...9: text += String(nibble)
                case 10: text += "."
                case 11: text += "E"
                case 12: text += "E-"
                case 14: text += "-"
                case 15: return Double(text) ?? 0
                default: break
                }
            }
        }
    }
    private static func number(_ dict: [Int: [Double]], _ op: Int, _ fallback: Double) -> Double { dict[op]?.first ?? fallback }
    private static func offset(_ value: Double, _ data: Data) throws -> Int {
        if !value.isFinite || value < 0 || value >= Double(data.count) { throw ConversionError("The CFF table is damaged (offset outside the table).") }
        return Int(value)
    }
}
