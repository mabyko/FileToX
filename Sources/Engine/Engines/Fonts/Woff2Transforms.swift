// Port of Filee.Engines/Fonts/Woff2Transforms.cs.
import Foundation

enum Woff2Transforms {
    struct TransformedGlyf { let data: Data; let glyfLength: Int; let locaLength: Int; let longLoca: Bool; let xMins: [Int] }
    static func tryTransformGlyf(_ font: SfntFont) throws -> TransformedGlyf? {
        let glyphs: [TrueTypeGlyph?]
        do { glyphs = try GlyfTable.readAll(font) } catch is ConversionError { return nil }
        if glyphs.contains(where: { $0?.hasCubicPoints == true }) { return nil }
        let count = glyphs.count, nContours = FontBigEndianWriter(), nPoints = FontBigEndianWriter(), flags = FontBigEndianWriter(), glyphStream = FontBigEndianWriter(), composites = FontBigEndianWriter(), bboxes = FontBigEndianWriter(), instructions = FontBigEndianWriter()
        var bboxBitmap = Data(repeating: 0, count: 4 * ((count + 31) / 32)), overlap = Data(repeating: 0, count: (count + 7) / 8), hasOverlap = false, xMins = [Int](repeating: 0, count: count), glyfLength = 0
        for i in 0..<count {
            try Task.checkCancellation()
            guard let glyph = glyphs[i], glyph.numberOfContours != 0 else { nContours.i16(0); continue }
            xMins[i] = glyph.xMin; glyfLength += (try glyph.serialize().count + 3) & ~3
            if glyph.isComposite {
                nContours.i16(-1); composites.bytes(glyph.components)
                if try glyph.componentsHaveInstructions() { glyphStream.write255UInt16(glyph.instructions.count); instructions.bytes(glyph.instructions) }
                writeBbox(glyph, i, &bboxBitmap, bboxes); continue
            }
            nContours.i16(glyph.numberOfContours)
            var previous = -1
            for end in glyph.endPoints { nPoints.write255UInt16(end - previous); previous = end }
            var lastX = 0, lastY = 0
            for p in glyph.points { writeTriplet(flags, glyphStream, p.onCurve, p.x - lastX, p.y - lastY); lastX = p.x; lastY = p.y }
            glyphStream.write255UInt16(glyph.instructions.count); instructions.bytes(glyph.instructions)
            if glyph.computeBounds() != (glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax) { writeBbox(glyph, i, &bboxBitmap, bboxes) }
            if glyph.overlapSimple { overlap[i >> 3] |= UInt8(0x80 >> (i & 7)); hasOverlap = true }
        }
        let longLoca = try FontTables.indexToLocFormat(font.require("head")) != 0 || glyfLength > GlyfTable.maxShortLocaSize, w = FontBigEndianWriter()
        w.u16(0); w.u16(hasOverlap ? 1 : 0); w.u16(count); w.u16(longLoca ? 1 : 0)
        for size in [nContours.length, nPoints.length, flags.length, glyphStream.length, composites.length, bboxBitmap.count + bboxes.length, instructions.length] { w.u32(UInt32(size)) }
        for data in [nContours.written, nPoints.written, flags.written, glyphStream.written, composites.written, bboxBitmap, bboxes.written, instructions.written] { w.bytes(data) }
        if hasOverlap { w.bytes(overlap) }
        return TransformedGlyf(data: w.written, glyfLength: glyfLength, locaLength: (count + 1) * (longLoca ? 4 : 2), longLoca: longLoca, xMins: xMins)
    }
    private static func writeBbox(_ glyph: TrueTypeGlyph, _ index: Int, _ bitmap: inout Data, _ bboxes: FontBigEndianWriter) {
        bitmap[index >> 3] |= UInt8(0x80 >> (index & 7)); bboxes.i16(glyph.xMin); bboxes.i16(glyph.yMin); bboxes.i16(glyph.xMax); bboxes.i16(glyph.yMax)
    }
    private static func writeTriplet(_ flags: FontBigEndianWriter, _ data: FontBigEndianWriter, _ onCurve: Bool, _ dx: Int, _ dy: Int) {
        let absX = abs(dx), absY = abs(dy), onCurveBit = onCurve ? 0 : 128, xSign = dx < 0 ? 0 : 1, ySign = dy < 0 ? 0 : 1, signs = xSign + 2 * ySign
        if dx == 0 && absY < 1280 { flags.u8(onCurveBit + ((absY & 0xF00) >> 7) + ySign); data.u8(absY & 255) }
        else if dy == 0 && absX < 1280 { flags.u8(onCurveBit + 10 + ((absX & 0xF00) >> 7) + xSign); data.u8(absX & 255) }
        else if absX < 65 && absY < 65 { flags.u8(onCurveBit + 20 + ((absX - 1) & 0x30) + (((absY - 1) & 0x30) >> 2) + signs); data.u8((((absX - 1) & 15) << 4) | ((absY - 1) & 15)) }
        else if absX < 769 && absY < 769 { flags.u8(onCurveBit + 84 + 12 * (((absX - 1) & 0x300) >> 8) + (((absY - 1) & 0x300) >> 6) + signs); data.u8((absX - 1) & 255); data.u8((absY - 1) & 255) }
        else if absX < 4096 && absY < 4096 { flags.u8(onCurveBit + 120 + signs); data.u8(absX >> 4); data.u8(((absX & 15) << 4) | (absY >> 8)); data.u8(absY & 255) }
        else { flags.u8(onCurveBit + 124 + signs); data.u16(absX); data.u16(absY) }
    }
    static func reconstructGlyf(_ data: Data, _ offset: Int, _ length: Int) throws -> (Data, Data, Bool, [Int]) {
        let end = offset + length, header = FontBigEndianReader(data, offset, end)
        _ = try header.u16(); let options = try header.u16(), count = try header.u16(), longLoca = try header.u16() != 0, sizes = try (0..<7).map { _ in Int(try header.u32()) }
        var position = header.position
        func nextStream(_ size: Int) throws -> FontBigEndianReader {
            if size > end - position { throw ConversionError("The WOFF2 glyph data is damaged.") }
            defer { position += size }; return FontBigEndianReader(data, position, position + size)
        }
        let nContours = try nextStream(sizes[0]), nPoints = try nextStream(sizes[1]), flagStream = try nextStream(sizes[2]), glyphStream = try nextStream(sizes[3]), composites = try nextStream(sizes[4]), bboxStream = try nextStream(sizes[5]), instructions = try nextStream(sizes[6])
        let bboxBitmap = try bboxStream.bytes(4 * ((count + 31) / 32)), overlap = options & 1 != 0 ? try nextStream((count + 7) / 8).bytes((count + 7) / 8) : nil
        var glyphs = [Data](repeating: Data(), count: count), xMins = [Int](repeating: 0, count: count)
        for i in 0..<count {
            try Task.checkCancellation()
            let contours = try nContours.i16(), hasBbox = bboxBitmap[i >> 3] & UInt8(0x80 >> (i & 7)) != 0, glyph = TrueTypeGlyph()
            if contours == 0 {
                if hasBbox { throw ConversionError("The WOFF2 glyph data is damaged (bounding box on an empty glyph).") }
                continue
            }
            if contours == -1 {
                if !hasBbox { throw ConversionError("The WOFF2 glyph data is damaged (composite glyph without bounding box).") }
                let start = composites.position, hasInstructions = try TrueTypeGlyph.skipComponents(composites)
                glyph.numberOfContours = -1; glyph.components = data.subdata(in: start..<composites.position)
                if hasInstructions { glyph.instructions = try instructions.bytes(glyphStream.read255UInt16()) }
            } else if contours > 0 {
                glyph.numberOfContours = contours
                var total = 0
                for _ in 0..<contours {
                    total += try nPoints.read255UInt16()
                    if total > 65535 { throw ConversionError("The WOFF2 glyph data is damaged (too many points).") }
                    glyph.endPoints.append(Int(UInt16(truncatingIfNeeded: total - 1)))
                }
                glyph.points = try readPoints(flagStream, glyphStream, total); glyph.instructions = try instructions.bytes(glyphStream.read255UInt16())
                glyph.overlapSimple = overlap.map { $0[i >> 3] & UInt8(0x80 >> (i & 7)) != 0 } ?? false
            } else { throw ConversionError("The WOFF2 glyph data is damaged (invalid contour count).") }
            if hasBbox { glyph.xMin = try bboxStream.i16(); glyph.yMin = try bboxStream.i16(); glyph.xMax = try bboxStream.i16(); glyph.yMax = try bboxStream.i16() }
            else { (glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax) = glyph.computeBounds() }
            xMins[i] = glyph.xMin; glyphs[i] = try glyph.serialize()
        }
        let built = try GlyfTable.build(glyphs, longLoca); return (built.glyf, built.loca, built.longFormat, xMins)
    }
    private static func readPoints(_ flags: FontBigEndianReader, _ data: FontBigEndianReader, _ count: Int) throws -> [GlyphPoint] {
        func withSign(_ flag: Int, _ value: Int) -> Int { flag & 1 != 0 ? value : -value }
        var points: [GlyphPoint] = [], x = 0, y = 0
        for _ in 0..<count {
            var flag = try flags.u8(); let onCurve = flag & 128 == 0; flag &= 127
            let dx: Int, dy: Int
            if flag < 10 { dx = 0; dy = try withSign(flag, ((flag & 14) << 7) + data.u8()) }
            else if flag < 20 { dx = try withSign(flag, (((flag - 10) & 14) << 7) + data.u8()); dy = 0 }
            else if flag < 84 { let b0 = flag - 20, b1 = try data.u8(); dx = withSign(flag, 1 + (b0 & 0x30) + (b1 >> 4)); dy = withSign(flag >> 1, 1 + ((b0 & 12) << 2) + (b1 & 15)) }
            else if flag < 120 { let b0 = flag - 84, b1 = try data.u8(), b2 = try data.u8(); dx = withSign(flag, 1 + ((b0 / 12) << 8) + b1); dy = withSign(flag >> 1, 1 + (((b0 % 12) >> 2) << 8) + b2) }
            else if flag < 124 { let b1 = try data.u8(), b2 = try data.u8(), b3 = try data.u8(); dx = withSign(flag, (b1 << 4) + (b2 >> 4)); dy = withSign(flag >> 1, ((b2 & 15) << 8) + b3) }
            else { dx = try withSign(flag, data.u16()); dy = try withSign(flag >> 1, data.u16()) }
            x += dx; y += dy; points.append(GlyphPoint(x: x, y: y, onCurve: onCurve))
        }
        return points
    }
    static func tryTransformHmtx(_ hmtx: Data, _ glyphCount: Int, _ metricsCount: Int, _ xMins: [Int]) throws -> Data? {
        if metricsCount < 1 || metricsCount > glyphCount || hmtx.count != 4 * metricsCount + 2 * (glyphCount - metricsCount) { return nil }
        let r = FontBigEndianReader(hmtx)
        var advances = [Int](repeating: 0, count: metricsCount), lsbs = [Int](repeating: 0, count: glyphCount)
        for i in 0..<metricsCount { advances[i] = try r.u16(); lsbs[i] = try r.i16() }
        for i in metricsCount..<glyphCount { lsbs[i] = try r.i16() }
        let proportional = (0..<metricsCount).allSatisfy { lsbs[$0] == xMins[$0] }, monospaced = (metricsCount..<glyphCount).allSatisfy { lsbs[$0] == xMins[$0] }
        if !proportional && !monospaced { return nil }
        let w = FontBigEndianWriter(); w.u8((proportional ? 1 : 0) | (monospaced ? 2 : 0))
        for advance in advances { w.u16(advance) }
        if !proportional { for i in 0..<metricsCount { w.i16(lsbs[i]) } }
        if !monospaced { for i in metricsCount..<glyphCount { w.i16(lsbs[i]) } }
        return w.written
    }
    static func reconstructHmtx(_ data: Data, _ offset: Int, _ length: Int, _ glyphCount: Int, _ metricsCount: Int, _ xMins: [Int]) throws -> Data {
        if metricsCount < 1 || metricsCount > glyphCount || xMins.count < glyphCount { throw ConversionError("The WOFF2 metrics are damaged.") }
        let r = FontBigEndianReader(data, offset, offset + length), flags = try r.u8()
        if flags & 0xFC != 0 { throw ConversionError("The WOFF2 metrics use unknown flags.") }
        let advances = try (0..<metricsCount).map { _ in try r.u16() }; var lsbs = Array(xMins.prefix(glyphCount))
        if flags & 1 == 0 { for i in 0..<metricsCount { lsbs[i] = try r.i16() } }
        if flags & 2 == 0 { for i in metricsCount..<glyphCount { lsbs[i] = try r.i16() } }
        let w = FontBigEndianWriter()
        for i in 0..<glyphCount { if i < metricsCount { w.u16(advances[i]) }; w.i16(lsbs[i]) }
        return w.written
    }
}
