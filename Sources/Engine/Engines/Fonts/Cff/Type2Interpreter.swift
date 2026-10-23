// Port of Filee.Engines/Fonts/Cff/Type2Interpreter.cs.
import Foundation

struct FontVec2: Equatable {
    var x: Double = 0, y: Double = 0
    init(_ x: Double = 0, _ y: Double = 0) { self.x = x; self.y = y }
    static func + (a: Self, b: Self) -> Self { Self(a.x + b.x, a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y) }
    static func * (a: Self, s: Double) -> Self { Self(a.x * s, a.y * s) }
    var length: Double { sqrt(x * x + y * y) }
    static func dot(_ a: Self, _ b: Self) -> Double { a.x * b.x + a.y * b.y }
}
struct FontPathSegment { let isCurve: Bool; let c1: FontVec2; let c2: FontVec2; let end: FontVec2 }
final class FontPathContour {
    var start: FontVec2, segments: [FontPathSegment] = []
    init(_ start: FontVec2) { self.start = start }
}
final class Type2Interpreter {
    private let font: CffFont, globalBias: Int
    private var stack = [Double](repeating: 0, count: 513), transient = [Double](repeating: 0, count: 32)
    private var contours: [FontPathContour] = [], current: FontPathContour?, priv = CffPrivate()
    private var localBias = 0, count = 0, stems = 0, widthParsed = false, ended = false, x: Double = 0, y: Double = 0
    private var seac: (adx: Double, ady: Double, base: Int, accent: Int)?
    init(_ font: CffFont) { self.font = font; globalBias = Self.bias(font.globalSubrs.count) }
    func run(_ glyph: Int, _ allowSeac: Bool = true) throws -> [FontPathContour] {
        if glyph < 0 || glyph >= font.glyphCount { throw ConversionError("A CFF accent refers to a missing glyph.") }
        contours = []; current = nil; priv = font.privates[min(font.fontDictIndex(glyph), font.privates.count - 1)]
        localBias = Self.bias(priv.subrs.count); count = 0; stems = 0; widthParsed = false; ended = false; x = 0; y = 0; seac = nil
        try execute(font.charStrings[glyph], 0); closePath()
        var result = contours
        if let seac = seac {
            if !allowSeac { throw ConversionError("A CFF accent is itself an accented glyph.") }
            let baseGlyph = font.glyphBySid(CffStandardData.standardEncoding[seac.base & 255]), accentGlyph = font.glyphBySid(CffStandardData.standardEncoding[seac.accent & 255])
            result += try run(baseGlyph, false)
            for contour in try run(accentGlyph, false) { result.append(Self.translate(contour, FontVec2(seac.adx, seac.ady))) }
        }
        return result
    }
    private static func translate(_ contour: FontPathContour, _ offset: FontVec2) -> FontPathContour {
        let moved = FontPathContour(contour.start + offset)
        moved.segments = contour.segments.map { FontPathSegment(isCurve: $0.isCurve, c1: $0.c1 + offset, c2: $0.c2 + offset, end: $0.end + offset) }; return moved
    }
    private static func bias(_ count: Int) -> Int { count < 1240 ? 107 : count < 33900 ? 1131 : 32768 }
    private func execute(_ code: Data, _ depth: Int) throws {
        if depth > 10 { throw ConversionError("CFF subroutines are nested too deeply.") }
        let r = FontBigEndianReader(code)
        while r.remaining > 0 && !ended {
            let b0 = try r.u8()
            if b0 >= 32 || b0 == 28 {
                let value: Double
                switch b0 {
                case 28: value = Double(try r.i16())
                case ...246: value = Double(b0 - 139)
                case ...250: value = Double(try (b0 - 247) * 256 + r.u8() + 108)
                case ...254: value = Double(try -(b0 - 251) * 256 - r.u8() - 108)
                default: value = Double(try r.i32()) / 65536
                }
                try push(value); continue
            }
            switch b0 {
            case 1, 3, 18, 23: parseStems()
            case 19, 20: parseStems(); try r.skip((stems + 7) / 8)
            case 21: parseWidth(2); moveTo(arg(0), arg(1))
            case 22: parseWidth(1); moveTo(arg(0), 0)
            case 4: parseWidth(1); moveTo(0, arg(0))
            case 5:
                var i = 0; while i + 1 < count { lineTo(stack[i], stack[i + 1]); i += 2 }; clear()
            case 6, 7:
                for i in 0..<count { if (i % 2 == 0) == (b0 == 6) { lineTo(stack[i], 0) } else { lineTo(0, stack[i]) } }; clear()
            case 8:
                var i = 0; while i + 5 < count { curveTo(i); i += 6 }; clear()
            case 24:
                var i = 0; while i + 7 < count { curveTo(i); i += 6 }
                if i + 1 < count { lineTo(stack[i], stack[i + 1]) }; clear()
            case 25:
                var i = 0; while i + 7 < count { lineTo(stack[i], stack[i + 1]); i += 2 }
                if i + 5 < count { curveTo(i) }; clear()
            case 26:
                var i = count % 2, dx1 = count % 2 == 1 ? stack[0] : 0
                while i + 3 < count { curveTo(dx1, stack[i], stack[i + 1], stack[i + 2], 0, stack[i + 3]); i += 4; dx1 = 0 }; clear()
            case 27:
                var i = count % 2, dy1 = count % 2 == 1 ? stack[0] : 0
                while i + 3 < count { curveTo(stack[i], dy1, stack[i + 1], stack[i + 2], stack[i + 3], 0); i += 4; dy1 = 0 }; clear()
            case 30, 31:
                var horizontal = b0 == 31, i = 0
                while i + 3 < count {
                    let last = count - i == 5 ? stack[i + 4] : 0
                    if horizontal { curveTo(stack[i], 0, stack[i + 1], stack[i + 2], last, stack[i + 3]) }
                    else { curveTo(0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], last) }
                    i += 4; horizontal.toggle()
                }; clear()
            case 10: try execute(subroutine(priv.subrs, localBias), depth + 1)
            case 29: try execute(subroutine(font.globalSubrs, globalBias), depth + 1)
            case 11: return
            case 14:
                if !widthParsed && (count == 1 || count == 5) { takeWidth() }; widthParsed = true
                if count >= 4 { seac = (stack[count - 4], stack[count - 3], Int(stack[count - 2]), Int(stack[count - 1])) }
                closePath(); ended = true; return
            case 12: try escape(r.u8())
            case 15, 16: throw ConversionError("The font uses CFF2 charstring operators (variable fonts), which aren't supported.")
            default: throw ConversionError("The CFF charstring uses an unknown operator (\(b0)).")
            }
        }
    }
    private func escape(_ op: Int) throws {
        switch op {
        case 0: clear()
        case 3: try binary { $0 != 0 && $1 != 0 ? 1 : 0 }
        case 4: try binary { $0 != 0 || $1 != 0 ? 1 : 0 }
        case 5: try push(pop() == 0 ? 1 : 0)
        case 9: try push(abs(pop()))
        case 10: try binary(+)
        case 11: try binary(-)
        case 12: try binary { $1 == 0 ? 0 : $0 / $1 }
        case 14: try push(-pop())
        case 15: try binary { $0 == $1 ? 1 : 0 }
        case 18: _ = try pop()
        case 20:
            let index = Int(try pop()), value = try pop(); if index >= 0 && index < 32 { transient[index] = value }
        case 21:
            let index = Int(try pop()); try push(index >= 0 && index < 32 ? transient[index] : 0)
        case 22:
            let v2 = try pop(), v1 = try pop(), s2 = try pop(), s1 = try pop(); try push(v1 <= v2 ? s1 : s2)
        case 23: try push(0.5)
        case 24: try binary(*)
        case 26: try push(sqrt(max(0, pop())))
        case 27: let value = try pop(); try push(value); try push(value)
        case 28: let b = try pop(), a = try pop(); try push(b); try push(a)
        case 29: let i = max(0, Int(try pop())); try push(i < count ? stack[count - 1 - i] : 0)
        case 30:
            var j = Int(try pop()); let n = Int(try pop())
            if n > 0 && n <= count {
                let items = Array(stack[count - n..<count]); j = ((j % n) + n) % n
                for i in 0..<n { stack[count - n + (i + j) % n] = items[i] }
            }
        case 34:
            try need(7); curveTo(stack[0], 0, stack[1], stack[2], stack[3], 0); curveTo(stack[4], 0, stack[5], -stack[2], stack[6], 0); clear()
        case 35: try need(12); curveTo(0); curveTo(6); clear()
        case 36:
            try need(9); curveTo(stack[0], stack[1], stack[2], stack[3], stack[4], 0); curveTo(stack[5], 0, stack[6], stack[7], stack[8], -(stack[1] + stack[3] + stack[7])); clear()
        case 37:
            try need(11)
            var dx: Double = 0, dy: Double = 0
            for i in stride(from: 0, to: 10, by: 2) { dx += stack[i]; dy += stack[i + 1] }
            let horizontal = abs(dx) > abs(dy)
            curveTo(0); curveTo(stack[6], stack[7], stack[8], stack[9], horizontal ? stack[10] : -dx, horizontal ? -dy : stack[10]); clear()
        default: throw ConversionError("The CFF charstring uses an unknown operator (12 \(op)).")
        }
    }
    private func subroutine(_ subrs: [Data], _ bias: Int) throws -> Data {
        let index = Int(try pop()) + bias
        if index < 0 || index >= subrs.count { throw ConversionError("A CFF charstring calls a missing subroutine.") }
        return subrs[index]
    }
    private func parseStems() { if !widthParsed && count % 2 == 1 { takeWidth() }; widthParsed = true; stems += count / 2; clear() }
    private func parseWidth(_ expected: Int) { if !widthParsed && count > expected { takeWidth() }; widthParsed = true }
    private func takeWidth() { if count > 1 { for i in 0..<count - 1 { stack[i] = stack[i + 1] } }; count -= 1 }
    private func moveTo(_ dx: Double, _ dy: Double) { closePath(); x += dx; y += dy; current = FontPathContour(FontVec2(x, y)); clear() }
    private func lineTo(_ dx: Double, _ dy: Double) {
        let contour = ensureContour(); x += dx; y += dy; contour.segments.append(FontPathSegment(isCurve: false, c1: FontVec2(), c2: FontVec2(), end: FontVec2(x, y)))
    }
    private func curveTo(_ i: Int) { curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]) }
    private func curveTo(_ dxa: Double, _ dya: Double, _ dxb: Double, _ dyb: Double, _ dxc: Double, _ dyc: Double) {
        let contour = ensureContour(), c1 = FontVec2(x + dxa, y + dya), c2 = FontVec2(c1.x + dxb, c1.y + dyb)
        x = c2.x + dxc; y = c2.y + dyc; contour.segments.append(FontPathSegment(isCurve: true, c1: c1, c2: c2, end: FontVec2(x, y)))
    }
    private func ensureContour() -> FontPathContour { if current == nil { current = FontPathContour(FontVec2(x, y)) }; return current! }
    private func closePath() { if let current = current, !current.segments.isEmpty { contours.append(current) }; current = nil }
    private func arg(_ i: Int) -> Double { i < count ? stack[i] : 0 }
    private func need(_ n: Int) throws { if count < n { throw ConversionError("A CFF charstring has too few arguments.") } }
    private func push(_ value: Double) throws {
        if count >= stack.count { throw ConversionError("A CFF charstring overflows the argument stack.") }; stack[count] = value; count += 1
    }
    private func pop() throws -> Double { try need(1); count -= 1; return stack[count] }
    private func binary(_ op: (Double, Double) -> Double) throws { let b = try pop(), a = try pop(); try push(op(a, b)) }
    private func clear() { count = 0 }
}
