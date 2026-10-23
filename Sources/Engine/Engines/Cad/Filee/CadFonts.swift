// Port of Filee.Engines/Cad/CadFonts.cs: fonts for CAD text. Drawings name SHX fonts (txt.shx, romans.shx, Korean
// big fonts) that are not shipped, so text is drawn with a sans-serif typeface; a TrueType style font (arial.ttf,
// malgun.ttf ...) is used when available. Characters the chosen typeface lacks (Hangul, Hanzi ...) fall back per
// character to a CJK font. CoreText replaces SkiaSharp; lookups follow Skia's macOS font manager (SkFontMgr_mac_ct)
// so the same typefaces, metrics and advances come out.

import CoreText
import Foundation

/// A typeface (Skia's `SKTypeface` on CoreText): one face, shared, so runs can be compared by identity.
final class CadTypeface {
    /// The face at CoreText's default size (12), like Skia's typeface font.
    let font: CTFont
    let familyName: String
    /// CSS weight (100 … 1000), width (1 … 9) and slant computed from the CoreText traits like Skia.
    let weight: Int
    let width: Int
    let isItalic: Bool
    let glyphCount: Int
    /// What Skia's SVG canvas writes as `font-family`: every family name of the 'name' table.
    let svgFamilyNames: String

    private let lock = NSLock()
    private var sizedFonts: [Float: CTFont] = [:]
    private var reverseCmap: [UInt32]?

    fileprivate init(_ font: CTFont) {
        self.font = font
        familyName = CTFontCopyFamilyName(font) as String
        let traits = CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(font), kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
        let ctWeight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let ctWidth = (traits[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0
        let ctSlant = (traits[kCTFontSlantTrait] as? NSNumber)?.doubleValue ?? 0
        weight = CadFonts.cssWeight(ctWeight)
        width = CadFonts.cssWidth(ctWidth)
        isItalic = ctSlant != 0
        glyphCount = CTFontGetGlyphCount(font)
        svgFamilyNames = CadFonts.nameTableFamilies(font)
    }

    /// The face at `size` points (cached; Skia's scaler contexts use a copy at the text size).
    func font(size: Float) -> CTFont {
        lock.lock()
        defer { lock.unlock() }
        if let font = sizedFonts[size] { return font }
        let sized = CTFontCreateCopyWithAttributes(font, CGFloat(size), nil, nil)
        if sizedFonts.count > 64 { sizedFonts.removeAll() }
        sizedFonts[size] = sized
        return sized
    }

    /// `SKTypeface.ContainsGlyph`: the code point maps to a glyph other than .notdef.
    func containsGlyph(_ codePoint: UInt32) -> Bool { glyph(codePoint) != 0 }

    func glyph(_ codePoint: UInt32) -> CGGlyph {
        guard let scalar = Unicode.Scalar(codePoint) else { return 0 }
        var units = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return 0 }
        return glyphs[0]
    }

    /// Glyphs of a UTF-16 string, one per code point (surrogate pairs give one glyph), like Skia's `textToGlyphs`.
    func glyphs(_ units: [UInt16]) -> [CGGlyph] {
        guard !units.isEmpty else { return [] }
        var source = units
        var raw = [CGGlyph](repeating: 0, count: units.count)
        _ = CTFontGetGlyphsForCharacters(font, &source, &raw, units.count)
        var result: [CGGlyph] = []
        result.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            result.append(raw[i])
            i += UTF16.isLeadSurrogate(units[i]) && i + 1 < units.count && UTF16.isTrailSurrogate(units[i + 1]) ? 2 : 1
        }
        return result
    }

    /// Horizontal advances at `size` as Skia stores them (floats from CoreText).
    func advances(_ glyphs: [CGGlyph], size: Float) -> [Float] {
        guard !glyphs.isEmpty else { return [] }
        let sized = font(size: size)
        var source = glyphs
        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(sized, .horizontal, &source, &sizes, glyphs.count)
        return sizes.map { Float($0.width) }
    }

    /// Skia's glyph-to-unicode map (`getGlyphToUnicodeMap`): the lowest code point of the font's character set
    /// that maps to each glyph; 0 for glyphs no character maps to.
    func unicode(of glyph: CGGlyph) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        if reverseCmap == nil { reverseCmap = CadFonts.glyphToUnicode(font, glyphCount) }
        let map = reverseCmap!
        return Int(glyph) < map.count ? map[Int(glyph)] : 0xFFFD
    }
}

/// A piece of one text line drawn with one typeface. `advance` is the advance width in em (font size 1).
struct CadGlyphRun {
    let text: String
    let typeface: CadTypeface
    let advance: Double
}

/// Typeface lookup and text measurement shared by the scene builder and the renderer.
enum CadFonts {
    /// Font size used for measuring; advances are divided by it (small sizes suffer from rounding).
    private static let measureSize: Float = 64

    /// Families tried for Latin text, in order.
    private static let sansFamilies = ["Noto Sans", "Arial", "Helvetica", "Liberation Sans", "DejaVu Sans", "Segoe UI"]

    /// Families tried for characters the main typeface lacks: Korean first (Filee's main audience), then Chinese
    /// and Japanese. Only installed fonts are used; without any, CoreText's own fallback decides.
    private static let cjkFamilies = [
        "Noto Sans KR", "Noto Sans CJK KR", "Malgun Gothic", "Apple SD Gothic Neo", "NanumGothic",
        "Noto Sans SC", "Noto Sans CJK SC", "Microsoft YaHei", "PingFang SC", "Yu Gothic", "MS Gothic",
    ]

    /// Common Windows font files named by text styles, mapped to their family names (keys compared without case).
    private static let fileFamilies: [String: String] = [
        "arial": "Arial",
        "arialn": "Arial Narrow",
        "times": "Times New Roman",
        "cour": "Courier New",
        "calibri": "Calibri",
        "tahoma": "Tahoma",
        "verdana": "Verdana",
        "isocpeur": "ISOCPEUR",
        "malgun": "Malgun Gothic",
        "gulim": "Gulim",
        "batang": "Batang",
        "dotum": "Dotum",
        "gungsuh": "Gungsuh",
        "simsun": "SimSun",
        "simhei": "SimHei",
        "msyh": "Microsoft YaHei",
        "msgothic": "MS Gothic",
        "msmincho": "MS Mincho",
    ]

    private struct FamilyKey: Hashable {
        let family: String
        let bold: Bool
        let italic: Bool
    }

    private struct FallbackKey: Hashable {
        let codePoint: UInt32
        let primary: ObjectIdentifier
    }

    private struct StyleKey: Hashable {
        let bold: Bool
        let italic: Bool
    }

    private static let lock = NSRecursiveLock()
    private static var typefaces: [String: CadTypeface] = [:]
    private static var families: [FamilyKey: CadTypeface?] = [:]
    private static var fallbacks: [FallbackKey: CadTypeface?] = [:]
    private static var defaults: [StyleKey: CadTypeface] = [:]
    private static var fontMetrics: [ObjectIdentifier: (capHeight: Double, descent: Double)] = [:]

    /// The typeface for a text style: its TrueType family if installed (family name or font file), else the
    /// default sans-serif typeface. Never nil.
    static func resolve(_ familyOrFile: String?, _ bold: Bool, _ italic: Bool) -> CadTypeface {
        if let family = familyOf(familyOrFile), let typeface = find(family, bold, italic) { return typeface }
        lock.lock()
        defer { lock.unlock() }
        let key = StyleKey(bold: bold, italic: italic)
        if let typeface = defaults[key] { return typeface }
        let typeface = sansFamilies.lazy.compactMap { find($0, bold, italic) }.first
            ?? matchStyle(family: nil, bold: bold, italic: italic)
        defaults[key] = typeface
        return typeface
    }

    /// Splits a line into runs by typeface coverage and measures each run in em.
    static func layout(_ text: String, _ primary: CadTypeface) -> [CadGlyphRun] {
        var runs: [CadGlyphRun] = []
        let units = Array(text.utf16)
        if units.isEmpty { return runs }

        var start = 0
        var current: CadTypeface?
        var i = 0
        while i < units.count {
            let pair = UTF16.isLeadSurrogate(units[i]) && i + 1 < units.count && UTF16.isTrailSurrogate(units[i + 1])
            let width = pair ? 2 : 1
            let codePoint = pair ? 0x10000 + ((UInt32(units[i]) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00) : UInt32(units[i])
            // Spaces stay in the current run, so a Korean phrase is one run in one typeface.
            let face: CadTypeface = isWhiteSpace(units[i]) ? current ?? primary
                : primary.containsGlyph(codePoint) ? primary
                : fallback(codePoint, primary)
            if let current, face !== current {
                runs.append(measure(Array(units[start..<i]), current))
                start = i
            }
            current = face
            i += width
        }
        runs.append(measure(Array(units[start...]), current!))
        return runs
    }

    /// Cap height and descent of a typeface as fractions of the em size.
    static func metrics(_ typeface: CadTypeface) -> (capHeight: Double, descent: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let metrics = fontMetrics[ObjectIdentifier(typeface)] { return metrics }
        let font = typeface.font(size: measureSize)
        var capHeight = Float(CTFontGetCapHeight(font))
        // Skia prefers the OS/2 table's sCapHeight (offset 88) when it is sane.
        if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 90 {
            let upem = Double(CTFontGetUnitsPerEm(font))
            let value = Double(UInt16(table[table.startIndex + 88]) << 8 | UInt16(table[table.startIndex + 89]))
            if value > 0 && value < upem * 2 { capHeight = Float(value * Double(measureSize) / upem) }
        }
        let descent = Float(CTFontGetDescent(font))
        let cap = capHeight / measureSize
        let down = descent / measureSize
        // Some fonts report no cap height; 0.7 em is typical for sans-serif faces.
        let metrics = (capHeight: cap > 0.3 && cap < 1.2 ? Double(cap) : 0.7, descent: down > 0 && down < 1 ? Double(down) : 0.21)
        fontMetrics[ObjectIdentifier(typeface)] = metrics
        return metrics
    }

    private static func measure(_ units: [UInt16], _ typeface: CadTypeface) -> CadGlyphRun {
        let text = String(decoding: units, as: UTF16.self)
        // SkFont.measureText: the float advances at the measuring size, summed in float.
        var sum: Float = 0
        for advance in typeface.advances(typeface.glyphs(units), size: measureSize) { sum += advance }
        var advance = Double(sum / measureSize)
        if advance <= 0 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            advance = 0.6 * Double(units.count) // a typeface without glyphs: keep a plausible width
        }
        return CadGlyphRun(text: text, typeface: typeface, advance: advance)
    }

    private static func fallback(_ codePoint: UInt32, _ primary: CadTypeface) -> CadTypeface {
        lock.lock()
        defer { lock.unlock() }
        let key = FallbackKey(codePoint: codePoint, primary: ObjectIdentifier(primary))
        if let cached = fallbacks[key] { return cached ?? primary }
        let bold = primary.weight >= 600
        var result: CadTypeface?
        for family in cjkFamilies {
            if let face = find(family, bold, false), face.containsGlyph(codePoint) {
                result = face
                break
            }
        }
        if result == nil { result = matchCharacter(codePoint, bold: bold) }
        fallbacks[key] = .some(result)
        return result ?? primary
    }

    /// `SKFontManager.MatchFamily`: the face of an installed family closest to the style, nil for unknown families.
    private static func find(_ family: String, _ bold: Bool, _ italic: Bool) -> CadTypeface? {
        lock.lock()
        defer { lock.unlock() }
        let key = FamilyKey(family: family, bold: bold, italic: italic)
        if let cached = families[key] { return cached }
        var result: CadTypeface?
        let request = descriptor(family: family, bold: bold, italic: italic)
        let mandatory: Set<CFString> = [kCTFontFamilyNameAttribute]
        if let resolved = CTFontDescriptorCreateMatchingFontDescriptor(request, mandatory as CFSet) {
            let face = intern(CTFontCreateWithFontDescriptor(resolved, 0, nil))
            if face.glyphCount > 0 { result = face }
        }
        families[key] = .some(result)
        return result
    }

    /// `SKTypeface.FromFamilyName(null, style)`: CoreText's default face for the style.
    private static func matchStyle(family: String?, bold: Bool, italic: Bool) -> CadTypeface {
        intern(CTFontCreateWithFontDescriptor(descriptor(family: family, bold: bold, italic: italic), 0, nil))
    }

    /// `SKFontManager.MatchCharacter`: CoreText's fallback font for the character (Skia uses CTFontCreateForString).
    private static func matchCharacter(_ codePoint: UInt32, bold: Bool) -> CadTypeface? {
        guard let scalar = Unicode.Scalar(codePoint) else { return nil }
        let base = CTFontCreateWithFontDescriptor(descriptor(family: nil, bold: bold, italic: false), 0, nil)
        let string = String(Character(scalar)) as CFString
        let fallback = CTFontCreateForString(base, string, CFRange(location: 0, length: CFStringGetLength(string)))
        return intern(fallback)
    }

    /// Skia's `create_descriptor`: family name plus weight, width and slant traits.
    private static func descriptor(family: String?, bold: Bool, italic: Bool) -> CTFontDescriptor {
        let weight = bold ? 700 : 400
        let traits: [CFString: Any] = [
            kCTFontWeightTrait: ctWeight(weight),
            kCTFontWidthTrait: 0.0,
            kCTFontSlantTrait: italic ? 1.0 : 0.0,
        ]
        var attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        if let family { attributes[kCTFontFamilyNameAttribute] = family }
        return CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
    }

    private static func intern(_ font: CTFont) -> CadTypeface {
        lock.lock()
        defer { lock.unlock() }
        let name = CTFontCopyPostScriptName(font) as String
        if let typeface = typefaces[name] { return typeface }
        let typeface = CadTypeface(font)
        typefaces[name] = typeface
        return typeface
    }

    private static func familyOf(_ familyOrFile: String?) -> String? {
        guard let familyOrFile, !familyOrFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var name = familyOrFile.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = FilePath.extension(name)
        if ext.lowercased() == ".shx" { return nil }
        if !ext.isEmpty { name = FilePath.fileNameWithoutExtension(name) }
        return fileFamilies[name.lowercased()] ?? name
    }

    /// `char.IsWhiteSpace` for one UTF-16 unit.
    static func isWhiteSpace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }

    // ───────────────────────── Skia's CoreText conventions ─────────────────────────

    /// NSFontWeight values for CSS weights 0, 100 … 1000 (SkCTFontGetNSFontWeightMapping).
    private static let nsFontWeights: [Double] = [-1.00, -0.80, -0.60, -0.40, 0.00, 0.23, 0.30, 0.40, 0.56, 0.62, 1.00]

    /// SkCTFontCTWeightForCSSWeight.
    private static func ctWeight(_ css: Int) -> Double {
        let mappings = nsFontWeights.enumerated().map { (Double($0.offset * 100), $0.element) }
        return interpolate(Double(css), mappings)
    }

    /// ct_weight_to_fontstyle (system fonts): CoreText weight → CSS weight.
    fileprivate static func cssWeight(_ ct: Double) -> Int {
        let mappings = nsFontWeights.enumerated().map { ($0.element, Double($0.offset * 100)) }
        return Int(interpolate(ct, mappings) + 0.5)
    }

    /// ct_width_to_fontstyle: CoreText width → CSS width 0 … 10.
    fileprivate static func cssWidth(_ ct: Double) -> Int {
        Int(interpolate(ct, [(-0.5, 0), (0.5, 10)]) + 0.5)
    }

    /// Skia's LinearInterpolater.
    private static func interpolate(_ value: Double, _ mappings: [(Double, Double)]) -> Double {
        if value < mappings[0].0 { return mappings[0].1 }
        for i in 0..<(mappings.count - 1) where value < mappings[i + 1].0 {
            let (lowSrc, lowDst) = mappings[i]
            let (highSrc, highDst) = mappings[i + 1]
            return lowDst + (value - lowSrc) * (highDst - lowDst) / (highSrc - lowSrc)
        }
        return mappings[mappings.count - 1].1
    }

    /// Family names from the 'name' table (IDs 1, 16, 21 in record order, de-duplicated), joined like Skia's SVG
    /// device; CoreText's family name when the table is missing.
    fileprivate static func nameTableFamilies(_ font: CTFont) -> String {
        var names: [String] = []
        if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), []) as Data?, table.count >= 6 {
            let bytes = [UInt8](table)
            func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
            let count = u16(2)
            let stringOffset = u16(4)
            if stringOffset <= bytes.count {
                let recordCount = min(count, (bytes.count - 6) / 12)
                for type in [1, 16, 21] {
                    for index in 0..<recordCount {
                        let record = 6 + index * 12
                        guard u16(record + 6) == type else { continue }
                        let length = u16(record + 8)
                        let offset = u16(record + 10)
                        guard stringOffset + offset + length <= bytes.count else { break }
                        let data = Data(bytes[(stringOffset + offset)..<(stringOffset + offset + length)])
                        let platform = u16(record)
                        let encoding = u16(record + 2)
                        switch platform {
                        case 3 where [0, 1, 10].contains(encoding), 0, 2:
                            names.append(TextEncodings.decode(data, encoding: .utf16BigEndian))
                        case 1 where encoding == 0:
                            names.append(TextEncodings.decode(data, encoding: .macOSRoman))
                        default:
                            names.append("")
                        }
                    }
                }
            }
        } else {
            names.append(CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil) as String? ?? "")
        }
        var seen = Set<String>()
        var joined = ""
        for name in names where seen.insert(name).inserted {
            joined += joined.isEmpty ? name : ", \(name)"
        }
        return joined
    }

    /// populate_glyph_to_unicode: for each glyph, the first code point of the character set at or above U+0020
    /// (CoreText maps tab, LF and CR to the space glyph; Skia prefers the space).
    fileprivate static func glyphToUnicode(_ font: CTFont, _ glyphCount: Int) -> [UInt32] {
        var map = [UInt32](repeating: 0, count: glyphCount)
        let characters = CTFontCopyCharacterSet(font)
        let bitmap = CFCharacterSetCreateBitmapRepresentation(nil, characters) as Data
        let bits = [UInt8](bitmap)
        func add(_ codePoint: UInt32) {
            var units: [UInt16]
            if codePoint < 0x10000 {
                units = [UInt16(codePoint)]
            } else {
                guard let scalar = Unicode.Scalar(codePoint) else { return }
                units = Array(String(Character(scalar)).utf16)
            }
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return }
            let glyph = Int(glyphs[0])
            if glyph < glyphCount && map[glyph] < 0x20 { map[glyph] = codePoint }
        }
        // The BMP takes 8192 bytes; each further plane present adds its plane number byte and 8192 bytes.
        for byte in 0..<min(8192, bits.count) where bits[byte] != 0 {
            for bit in 0..<8 where bits[byte] & (1 << bit) != 0 { add(UInt32(byte * 8 + bit)) }
        }
        var offset = 8192
        while offset + 8193 <= bits.count {
            let plane = UInt32(bits[offset])
            for byte in 0..<8192 where bits[offset + 1 + byte] != 0 {
                for bit in 0..<8 where bits[offset + 1 + byte] & (1 << bit) != 0 {
                    add(plane << 16 | UInt32(byte * 8 + bit))
                }
            }
            offset += 8193
        }
        return map
    }
}
