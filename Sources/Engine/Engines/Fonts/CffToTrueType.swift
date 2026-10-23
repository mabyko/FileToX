// Port of Filee.Engines/Fonts/CffToTrueType.cs.
import Foundation

enum CffToTrueType {
    static func convert(_ source: SfntFont, _ progress: ProgressHandler? = nil) throws -> SfntFont {
        if source["CFF2"] != nil { throw ConversionError("This is a variable font with CFF2 outlines. Converting CFF2 to TrueType isn't supported; WOFF, WOFF2 and OTF work.") }
        let cff = try CffFont.parse(source.require("CFF ")), glyphCount = try source.glyphCount
        if cff.glyphCount != glyphCount { throw ConversionError("The font's CFF outlines and glyph count don't match.") }
        let head = try source.require("head"), upem = try FontTables.unitsPerEm(head), tolerance = Double(max(upem, 16)) * 0.001
        let matrices: [[Double]?] = cff.fontMatrices.map { matrix in
            let m = matrix.map { $0 * Double(upem) }, identity: [Double] = [1, 0, 0, 1, 0, 0]
            return zip(m, identity).allSatisfy { abs($0 - $1) < 1e-9 } ? nil : m
        }
        let interpreter = Type2Interpreter(cff)
        var glyphs: [TrueTypeGlyph?] = []
        for gid in 0..<glyphCount {
            if gid % 64 == 0 { try Task.checkCancellation(); progress?(Double(gid) / Double(glyphCount)) }
            var contours = try interpreter.run(gid)
            if let matrix = matrices[min(cff.fontDictIndex(gid), matrices.count - 1)] { contours = contours.map { transform($0, matrix) } }
            glyphs.append(try buildGlyph(contours, tolerance))
        }
        let font = source.clone()
        for tag in ["CFF ", "VORG", "DSIG"] { font.tables.removeValue(forKey: tag) }; font.flavor = SfntFont.trueTypeFlavor
        let built = try GlyfTable.build(glyphs.map { try $0?.serialize() ?? Data() }, false, 2)
        font.tables["glyf"] = built.glyf; font.tables["loca"] = built.loca
        font.tables["head"] = try updateHead(head, glyphs, built.longFormat); font.tables["maxp"] = buildMaxp(glyphs)
        font.tables["post"] = buildPost(source["post"], (0..<glyphCount).map(cff.glyphName))
        if let hhea = font["hhea"], hhea.count >= 36, let hmtx = font["hmtx"] {
            let (header, metrics) = try updateHorizontalMetrics(hhea, hmtx, glyphs); font.tables["hhea"] = header; font.tables["hmtx"] = metrics
        }
        if let vorg = source["VORG"], let vhea = font["vhea"], vhea.count >= 36, let vmtx = font["vmtx"] {
            let (header, metrics) = try updateVerticalMetrics(vhea, vmtx, vorg, glyphs); font.tables["vhea"] = header; font.tables["vmtx"] = metrics
        }
        if font["gasp"] == nil && font["prep"] == nil {
            font.tables["gasp"] = Data([0, 1, 0, 1, 0xFF, 0xFF, 0, 0x0F]); font.tables["prep"] = Data([0xB8, 0x01, 0xFF, 0x85, 0xB0, 0x04, 0x8D])
        }
        progress?(1); return font
    }
    private static func transform(_ contour: FontPathContour, _ m: [Double]) -> FontPathContour {
        func apply(_ p: FontVec2) -> FontVec2 { FontVec2(m[0] * p.x + m[2] * p.y + m[4], m[1] * p.x + m[3] * p.y + m[5]) }
        let result = FontPathContour(apply(contour.start))
        result.segments = contour.segments.map { FontPathSegment(isCurve: $0.isCurve, c1: apply($0.c1), c2: apply($0.c2), end: apply($0.end)) }; return result
    }
    private static func buildGlyph(_ contours: [FontPathContour], _ tolerance: Double) throws -> TrueTypeGlyph? {
        var endPoints: [Int] = [], points: [GlyphPoint] = []
        for contour in contours {
            var raw: [(FontVec2, Bool)] = [(contour.start, true)], current = contour.start
            for segment in contour.segments {
                if segment.isCurve { for control in CubicToQuadratic.convert(current, segment.c1, segment.c2, segment.end, tolerance) { raw.append((control, false)) } }
                raw.append((segment.end, true)); current = segment.end
            }
            let rounded = clean(raw.map { GlyphPoint(x: Int(floor($0.0.x + 0.5)), y: Int(floor($0.0.y + 0.5)), onCurve: $0.1) })
            if rounded.count < 3 { continue }
            points.append(rounded[0]); points.append(contentsOf: rounded.dropFirst().reversed())
            if points.count > 65535 { throw ConversionError("A glyph has more points than TrueType allows.") }
            endPoints.append(points.count - 1)
        }
        if endPoints.isEmpty { return nil }
        let glyph = TrueTypeGlyph(); glyph.numberOfContours = Int(Int16(truncatingIfNeeded: endPoints.count)); glyph.endPoints = endPoints; glyph.points = points
        (glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax) = glyph.computeBounds(); return glyph
    }
    private static func clean(_ points: [GlyphPoint]) -> [GlyphPoint] {
        var result: [GlyphPoint] = []
        for p in points {
            if let last = result.last, p.onCurve && last.onCurve && last.x == p.x && last.y == p.y { continue }; result.append(p)
        }
        while result.count > 1 && result.last!.onCurve && result.last!.x == result[0].x && result.last!.y == result[0].y { result.removeLast() }
        return result
    }
    private static func set16(_ data: inout Data, _ offset: Int, _ value: Int) { BinaryPrimitives.writeUInt16BigEndian(&data, offset, UInt16(truncatingIfNeeded: value)) }
    private static func updateHead(_ head: Data, _ glyphs: [TrueTypeGlyph?], _ longLoca: Bool) throws -> Data {
        var result = try FontTables.withIndexToLocFormat(head, longLoca)
        _ = try FontBigEndianReader(result, 52).u16()
        let outlines = glyphs.compactMap { $0 }
        if !outlines.isEmpty {
            set16(&result, 36, outlines.map(\.xMin).min()!); set16(&result, 38, outlines.map(\.yMin).min()!); set16(&result, 40, outlines.map(\.xMax).max()!); set16(&result, 42, outlines.map(\.yMax).max()!)
        }
        set16(&result, 52, 0); return result
    }
    private static func buildMaxp(_ glyphs: [TrueTypeGlyph?]) -> Data {
        let w = FontBigEndianWriter(); w.u32(0x00010000); w.u16(glyphs.count)
        w.u16(glyphs.map { $0?.points.count ?? 0 }.max() ?? 0); w.u16(glyphs.map { $0?.numberOfContours ?? 0 }.max() ?? 0)
        for value in [0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0] { w.u16(value) }; return w.written
    }
    static func buildPost(_ old: Data?, _ names: [String?]) -> Data {
        let w = FontBigEndianWriter(); var header = Data(repeating: 0, count: 32)
        if let old = old { header.replaceSubrange(0..<min(32, old.count), with: old.prefix(32)) }
        let usable = names.allSatisfy { name in guard let name = name else { return false }; return name.utf16.count > 0 && name.utf16.count < 256 && name.utf16.allSatisfy { $0 > 32 && $0 < 127 } }
        BinaryPrimitives.writeUInt32BigEndian(&header, 0, usable ? 0x00020000 : 0x00030000); w.bytes(header)
        if !usable { return w.written }
        let standard = Dictionary(uniqueKeysWithValues: CffStandardData.macGlyphNames.enumerated().map { ($0.element, $0.offset) })
        var custom: [String: Int] = [:], extra: [String] = []
        w.u16(names.count)
        for name in names {
            let name = name!
            if let index = standard[name] { w.u16(index); continue }
            if custom[name] == nil { custom[name] = standard.count + extra.count; extra.append(name) }
            w.u16(custom[name]!)
        }
        for name in extra { w.u8(name.utf16.count); w.bytes(Data(name.utf8)) }; return w.written
    }
    private static func updateHorizontalMetrics(_ hhea: Data, _ hmtx: Data, _ glyphs: [TrueTypeGlyph?]) throws -> (Data, Data) {
        let metrics = try FontTables.numberOfMetrics(hhea), (advances, _) = try readMetrics(hmtx, metrics, glyphs.count), lsbs = glyphs.map { $0?.xMin ?? 0 }, result = writeMetrics(advances, lsbs, metrics)
        var header = hhea; let withOutlines = glyphs.indices.filter { glyphs[$0] != nil }
        set16(&header, 10, advances.max() ?? 0)
        if !withOutlines.isEmpty {
            set16(&header, 12, withOutlines.map { glyphs[$0]!.xMin }.min()!); set16(&header, 14, withOutlines.map { advances[$0] - glyphs[$0]!.xMax }.min()!); set16(&header, 16, withOutlines.map { glyphs[$0]!.xMax }.max()!)
        }
        return (header, result)
    }
    private static func updateVerticalMetrics(_ vhea: Data, _ vmtx: Data, _ vorg: Data, _ glyphs: [TrueTypeGlyph?]) throws -> (Data, Data) {
        let metrics = try FontTables.numberOfMetrics(vhea); var (heights, tsbs) = try readMetrics(vmtx, metrics, glyphs.count)
        let r = FontBigEndianReader(vorg); try r.skip(4); let defaultOrigin = try r.i16(), count = try r.u16()
        var origins: [Int: Int] = [:]
        for _ in 0..<count { let gid = try r.u16(); origins[gid] = try r.i16() }
        for i in glyphs.indices { if let glyph = glyphs[i] { tsbs[i] = (origins[i] ?? defaultOrigin) - glyph.yMax } }
        let result = writeMetrics(heights, tsbs, metrics); var header = vhea
        let withOutlines = glyphs.indices.filter { glyphs[$0] != nil }
        if !withOutlines.isEmpty {
            func extent(_ i: Int) -> Int { tsbs[i] + glyphs[i]!.yMax - glyphs[i]!.yMin }
            set16(&header, 12, withOutlines.map { tsbs[$0] }.min()!); set16(&header, 14, withOutlines.map { heights[$0] - extent($0) }.min()!); set16(&header, 16, withOutlines.map(extent).max()!)
        }
        return (header, result)
    }
    private static func readMetrics(_ table: Data, _ metrics: Int, _ glyphCount: Int) throws -> ([Int], [Int]) {
        let r = FontBigEndianReader(table); var advances: [Int] = [], bearings: [Int] = [], last = 0
        for i in 0..<glyphCount { if i < metrics { last = try r.u16() }; advances.append(last); bearings.append(r.remaining >= 2 ? try r.i16() : 0) }
        return (advances, bearings)
    }
    private static func writeMetrics(_ advances: [Int], _ bearings: [Int], _ metrics: Int) -> Data {
        let w = FontBigEndianWriter(); for i in advances.indices { if i < metrics { w.u16(advances[i]) }; w.i16(bearings[i]) }; return w.written
    }
}
