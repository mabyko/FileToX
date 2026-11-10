// Port of Filee.Engines/Fonts/TrueTypeGlyph.cs.
import Foundation

struct GlyphPoint: Equatable { var x: Int; var y: Int; var onCurve: Bool }
final class TrueTypeGlyph {
    static let argsAreWords = 0x0001, hasScale = 0x0008, moreComponents = 0x0020, hasXYScale = 0x0040, hasTwoByTwo = 0x0080, hasInstructions = 0x0100
    var numberOfContours = 0, xMin = 0, yMin = 0, xMax = 0, yMax = 0
    var endPoints: [Int] = [], points: [GlyphPoint] = []
    var instructions = Data(), components = Data()
    var overlapSimple = false, hasCubicPoints = false
    var isComposite: Bool { numberOfContours < 0 }
    static func parse(_ glyf: Data, _ offset: Int, _ length: Int) throws -> TrueTypeGlyph? {
        if length == 0 { return nil }
        let r = FontBigEndianReader(glyf, offset, offset + length), glyph = TrueTypeGlyph()
        glyph.numberOfContours = try r.i16(); glyph.xMin = try r.i16(); glyph.yMin = try r.i16(); glyph.xMax = try r.i16(); glyph.yMax = try r.i16()
        if glyph.numberOfContours >= 0 { try glyph.parseSimple(r) }
        else if glyph.numberOfContours == -1 { try glyph.parseComposite(r) }
        else { throw ConversionError("Invalid TrueType glyph (negative contour count).") }
        return glyph
    }
    private func parseSimple(_ r: FontBigEndianReader) throws {
        for i in 0..<numberOfContours {
            endPoints.append(try r.u16())
            if i > 0 && endPoints[i] <= endPoints[i - 1] { throw ConversionError("Invalid TrueType glyph (contour end points out of order).") }
        }
        instructions = try r.bytes(r.u16())
        let count = numberOfContours == 0 ? 0 : endPoints.last! + 1
        var flags = [Int](repeating: 0, count: count), i = 0
        while i < count {
            let flag = try r.u8(); flags[i] = flag
            if flag & 8 != 0 {
                let repeats = try r.u8()
                for _ in 0..<repeats {
                    i += 1
                    if i >= count { throw ConversionError("Invalid TrueType glyph (too many point flags).") }
                    flags[i] = flag
                }
            }
            i += 1
        }
        let xs = try Self.readCoordinates(r, flags, 2, 16), ys = try Self.readCoordinates(r, flags, 4, 32)
        for i in 0..<count {
            points.append(GlyphPoint(x: xs[i], y: ys[i], onCurve: flags[i] & 1 != 0)); hasCubicPoints = hasCubicPoints || flags[i] & 128 != 0
        }
        overlapSimple = count > 0 && flags[0] & 64 != 0
    }
    private static func readCoordinates(_ r: FontBigEndianReader, _ flags: [Int], _ short: Int, _ same: Int) throws -> [Int] {
        var values: [Int] = [], value = 0
        for flag in flags {
            if flag & short != 0 { let delta = try r.u8(); value += flag & same != 0 ? delta : -delta }
            else if flag & same == 0 { value += try r.i16() }
            values.append(value)
        }
        return values
    }
    private func parseComposite(_ r: FontBigEndianReader) throws {
        let start = r.position, hasInstructions = try Self.skipComponents(r)
        components = r.data.subdata(in: start..<r.position)
        if hasInstructions { instructions = try r.bytes(r.u16()) }
    }
    static func skipComponents(_ r: FontBigEndianReader) throws -> Bool {
        var instructions = false, flags: Int
        repeat {
            flags = try r.u16(); try r.skip(2); try r.skip(flags & argsAreWords != 0 ? 4 : 2)
            if flags & hasScale != 0 { try r.skip(2) }
            else if flags & hasXYScale != 0 { try r.skip(4) }
            else if flags & hasTwoByTwo != 0 { try r.skip(8) }
            instructions = instructions || flags & hasInstructions != 0
        } while flags & moreComponents != 0
        return instructions
    }
    func computeBounds() -> (Int, Int, Int, Int) {
        guard !points.isEmpty else { return (0, 0, 0, 0) }
        return (Int(Int16(truncatingIfNeeded: points.map(\.x).min()!)), Int(Int16(truncatingIfNeeded: points.map(\.y).min()!)), Int(Int16(truncatingIfNeeded: points.map(\.x).max()!)), Int(Int16(truncatingIfNeeded: points.map(\.y).max()!)))
    }
    func serialize() throws -> Data {
        let w = FontBigEndianWriter()
        w.i16(numberOfContours); w.i16(xMin); w.i16(yMin); w.i16(xMax); w.i16(yMax)
        if isComposite {
            w.bytes(components)
            if try componentsHaveInstructions() { w.u16(instructions.count); w.bytes(instructions) }
            return w.written
        }
        for end in endPoints { w.u16(end) }
        w.u16(instructions.count); w.bytes(instructions)
        let flags = FontBigEndianWriter(), xs = FontBigEndianWriter(), ys = FontBigEndianWriter()
        var lastX = 0, lastY = 0, lastFlag = -1, repeated = 0
        for (i, p) in points.enumerated() {
            var flag = p.onCurve ? 1 : 0
            if i == 0 && overlapSimple { flag |= 64 }
            flag |= Self.delta(xs, p.x - lastX, 2, 16); flag |= Self.delta(ys, p.y - lastY, 4, 32)
            lastX = p.x; lastY = p.y
            if flag == lastFlag && repeated < 255 {
                if repeated == 0 { flags.written[flags.length - 1] |= 8 }
                repeated += 1
            } else { if repeated > 0 { flags.u8(repeated) }; flags.u8(flag); repeated = 0 }
            lastFlag = flag
        }
        if repeated > 0 { flags.u8(repeated) }
        w.bytes(flags.written); w.bytes(xs.written); w.bytes(ys.written); return w.written
    }
    private static func delta(_ coordinates: FontBigEndianWriter, _ delta: Int, _ short: Int, _ same: Int) -> Int {
        if delta == 0 { return same }
        if delta > -256 && delta < 256 { coordinates.u8(abs(delta)); return short | (delta > 0 ? same : 0) }
        coordinates.i16(delta); return 0
    }
    func componentsHaveInstructions() throws -> Bool { try !components.isEmpty && Self.skipComponents(FontBigEndianReader(components)) }
}

enum GlyfTable {
    static let maxShortLocaSize = 0xFFFF * 2
    static func readLoca(_ loca: Data, _ glyphCount: Int, _ longFormat: Bool, _ glyfLength: Int) throws -> [(offset: Int, length: Int)] {
        let r = FontBigEndianReader(loca)
        let offsets = try (0...glyphCount).map { _ in longFormat ? Int(try r.u32()) : try r.u16() * 2 }
        return (0..<glyphCount).map { i in let start = min(offsets[i], glyfLength), end = min(offsets[i + 1], glyfLength); return (start, max(0, end - start)) }
    }
    static func readAll(_ font: SfntFont) throws -> [TrueTypeGlyph?] {
        let glyf = try font.require("glyf"), longLoca = try FontTables.indexToLocFormat(font.require("head")) != 0
        return try readLoca(font.require("loca"), font.glyphCount, longLoca, glyf.count).map { try TrueTypeGlyph.parse(glyf, $0.offset, $0.length) }
    }
    static func build(_ glyphs: [Data], _ longFormat: Bool, _ alignment: Int = 4) throws -> (glyf: Data, loca: Data, longFormat: Bool) {
        func align(_ n: Int) -> Int { (n + alignment - 1) / alignment * alignment }
        let total = glyphs.reduce(0) { $0 + align($1.count) }, longFormat = longFormat || total > maxShortLocaSize
        if total > Int32.max { throw ConversionError("The glyph outlines are too large for a TrueType font.") }
        let glyf = FontBigEndianWriter(total), loca = FontBigEndianWriter()
        func entry() { if longFormat { loca.u32(UInt32(glyf.length)) } else { loca.u16(glyf.length / 2) } }
        for glyph in glyphs { entry(); glyf.bytes(glyph); glyf.zeros(align(glyph.count) - glyph.count) }
        entry(); return (glyf.written, loca.written, longFormat)
    }
}

enum FontTables {
    static func unitsPerEm(_ head: Data) throws -> Int { try FontBigEndianReader(head, 18).u16() }
    static func indexToLocFormat(_ head: Data) throws -> Int { try FontBigEndianReader(head, 50).i16() }
    static func withIndexToLocFormat(_ head: Data, _ longFormat: Bool) throws -> Data {
        _ = try FontBigEndianReader(head, 50).u16()
        var copy = head; BinaryPrimitives.writeUInt16BigEndian(&copy, 50, longFormat ? 1 : 0); return copy
    }
    static func numberOfMetrics(_ hhea: Data) throws -> Int { try FontBigEndianReader(hhea, 34).u16() }
}
