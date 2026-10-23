// The CAD document model: a Swift port of the parts of ACadSharp (MIT, 3.8.0) that Filee uses to read DWG / DXF,
// write DXF / DWG and draw drawings. ACadSharp's namespaces become this `ACad` namespace; type and member names
// follow ACadSharp (members in lowerCamel). This file holds the value types: vectors, colours, line weights,
// transparency, versions and code pages.

import Foundation

/// Namespace of the CAD document model (ACadSharp port).
enum ACad {}

extension ACad {
    /// CSMath `XYZ`.
    struct XYZ: Hashable {
        var x: Double
        var y: Double
        var z: Double

        init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        init(_ value: Double) { self.init(value, value, value) }

        static let zero = XYZ(0, 0, 0)
        static let axisX = XYZ(1, 0, 0)
        static let axisY = XYZ(0, 1, 0)
        static let axisZ = XYZ(0, 0, 1)
        static let nan = XYZ(.nan, .nan, .nan)

        subscript(index: Int) -> Double {
            get { index == 0 ? x : index == 1 ? y : z }
            set {
                switch index {
                case 0: x = newValue
                case 1: y = newValue
                default: z = newValue
                }
            }
        }

        var length: Double { (x * x + y * y + z * z).squareRoot() }
        var isZero: Bool { x == 0 && y == 0 && z == 0 }
        var xy: XY { XY(x, y) }

        /// CSMath `Normalize`: a zero vector stays NaN-free (returns itself).
        func normalized() -> XYZ {
            let l = length
            return l == 0 ? self : XYZ(x / l, y / l, z / l)
        }

        static func cross(_ a: XYZ, _ b: XYZ) -> XYZ {
            XYZ(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }

        static func dot(_ a: XYZ, _ b: XYZ) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

        static func + (a: XYZ, b: XYZ) -> XYZ { XYZ(a.x + b.x, a.y + b.y, a.z + b.z) }
        static func - (a: XYZ, b: XYZ) -> XYZ { XYZ(a.x - b.x, a.y - b.y, a.z - b.z) }
        static prefix func - (a: XYZ) -> XYZ { XYZ(-a.x, -a.y, -a.z) }
        static func * (a: XYZ, k: Double) -> XYZ { XYZ(a.x * k, a.y * k, a.z * k) }
        static func * (k: Double, a: XYZ) -> XYZ { XYZ(a.x * k, a.y * k, a.z * k) }
        static func / (a: XYZ, k: Double) -> XYZ { XYZ(a.x / k, a.y / k, a.z / k) }

        static func distance(_ a: XYZ, _ b: XYZ) -> Double { (a - b).length }

        /// CSMath `IsEqual` with the default tolerance (MathHelper.Epsilon = 1e-12).
        func isEqual(_ other: XYZ, _ tolerance: Double = 1e-12) -> Bool {
            abs(x - other.x) < tolerance && abs(y - other.y) < tolerance && abs(z - other.z) < tolerance
        }
    }

    /// CSMath `XY`.
    struct XY: Hashable {
        var x: Double
        var y: Double

        init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }

        static let zero = XY(0, 0)
        static let axisX = XY(1, 0)
        static let axisY = XY(0, 1)

        subscript(index: Int) -> Double {
            get { index == 0 ? x : y }
            set { if index == 0 { x = newValue } else { y = newValue } }
        }

        var length: Double { (x * x + y * y).squareRoot() }
        var xyz: XYZ { XYZ(x, y, 0) }

        func normalized() -> XY {
            let l = length
            return l == 0 ? self : XY(x / l, y / l)
        }

        static func + (a: XY, b: XY) -> XY { XY(a.x + b.x, a.y + b.y) }
        static func - (a: XY, b: XY) -> XY { XY(a.x - b.x, a.y - b.y) }
        static func * (a: XY, k: Double) -> XY { XY(a.x * k, a.y * k) }
        static func dot(_ a: XY, _ b: XY) -> Double { a.x * b.x + a.y * b.y }

        /// CSMath `GetAngle`: angle of the vector from the X axis.
        var angle: Double { atan2(y, x) }
    }

    /// CSMath `MathHelper` constants and helpers used by the ported code.
    enum MathHelper {
        static let epsilon = 1e-12
        static let twoPI = 2 * Double.pi
        static let halfPI = Double.pi / 2
        static func radToDeg(_ value: Double) -> Double { value * 180 / .pi }
        static func degToRad(_ value: Double) -> Double { value * .pi / 180 }
        static func isZero(_ value: Double) -> Bool { abs(value) < epsilon }
    }

    /// ACadSharp `Color`: an ACI index (0 = ByBlock, 256 = ByLayer, 257 = ByEntity) or a 24-bit true colour.
    struct Color: Hashable, CustomStringConvertible {
        /// Index or `r | g << 8 | b << 16 | 1 << 30` for true colours, as ACadSharp stores it.
        let raw: UInt32

        private static let trueColorFlag: UInt32 = 1 << 30

        init(index: Int16) {
            raw = UInt32(max(0, min(257, Int(index))))
        }

        init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            raw = UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | Color.trueColorFlag
        }

        /// `Color.FromTrueColor`: `value` in ACadSharp's layout (red in the low byte).
        static func fromTrueColor(_ value: UInt32) -> Color { Color(raw: (value & 0xFF_FFFF) | trueColorFlag) }

        /// Group code 420 / DWG RGB value 0x00RRGGBB.
        static func fromRgb24(_ value: Int32) -> Color {
            let v = UInt32(bitPattern: value)
            return Color(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }

        private init(raw: UInt32) { self.raw = raw }

        static let byBlock = Color(index: 0)
        static let byLayer = Color(index: 256)
        static let byEntity = Color(index: 257)
        static let red = Color(index: 1)
        static let yellow = Color(index: 2)
        static let green = Color(index: 3)
        static let cyan = Color(index: 4)
        static let blue = Color(index: 5)
        static let magenta = Color(index: 6)
        static let `default` = Color(index: 7)
        static let darkGray = Color(index: 8)
        static let lightGray = Color(index: 9)
        static let black = Color(index: 250)

        var isTrueColor: Bool { raw > 257 }
        /// -1 for true colours.
        var index: Int16 { isTrueColor ? -1 : Int16(raw) }
        var isByBlock: Bool { index == 0 }
        var isByLayer: Bool { index == 256 }
        /// `r | g << 8 | b << 16`, or -1 for indexed colours.
        var trueColor: Int32 { isTrueColor ? Int32(bitPattern: raw ^ Color.trueColorFlag) : -1 }

        /// `GetRgb()`: true colour components, or the ACI table entry (the index is truncated to a byte like ACadSharp).
        var rgb: (r: UInt8, g: UInt8, b: UInt8) {
            if isTrueColor { return (UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF)) }
            return Color.indexRgb[Int(raw & 0xFF)]
        }

        var r: UInt8 { rgb.r }
        var g: UInt8 { rgb.g }
        var b: UInt8 { rgb.b }

        /// 0x00RRGGBB for group code 420 and DWG CMC colours.
        var rgb24: Int32 { let c = rgb; return Int32(c.r) << 16 | Int32(c.g) << 8 | Int32(c.b) }

        /// `GetApproxIndex()`.
        func approxIndex() -> Int16 {
            isTrueColor ? Int16(Color.approxIndex(r, g, b)) : index
        }

        /// `Color.ApproxIndex` exactly as ACadSharp implements it.
        static func approxIndex(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
            var prevDist = -1
            for i in 0..<indexRgb.count {
                let c = indexRgb[i]
                let dist = (Int(r) - Int(c.r)) + (Int(g) - Int(c.g)) + (Int(b) - Int(c.b))
                if dist == 0 { return UInt8(i) }
                if dist < prevDist {
                    prevDist = dist
                    return UInt8(i)
                }
            }
            return 0
        }

        var description: String {
            if raw == 0 { return "ByBlock" }
            if raw == 256 { return "ByLayer" }
            if isTrueColor { let c = rgb; return "True Color RGB:\(c.r),\(c.g),\(c.b)" }
            return "Indexed Color:\(index)"
        }

        static let indexRgb: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (0,0,0), (255,0,0), (255,255,0), (0,255,0), (0,255,255), (0,0,255), (255,0,255), (255,255,255),
            (128,128,128), (192,192,192), (255,0,0), (255,127,127), (165,0,0), (165,82,82), (127,0,0), (127,63,63),
            (76,0,0), (76,38,38), (38,0,0), (38,19,19), (255,63,0), (255,159,127), (165,41,0), (165,103,82),
            (127,31,0), (127,79,63), (76,19,0), (76,47,38), (38,9,0), (38,28,19), (255,127,0), (255,191,127),
            (165,82,0), (165,124,82), (127,63,0), (127,95,63), (76,38,0), (76,57,38), (38,19,0), (38,28,19),
            (255,191,0), (255,223,127), (165,124,0), (165,145,82), (127,95,0), (127,111,63), (76,57,0), (76,66,38),
            (38,28,0), (38,33,19), (255,255,0), (255,255,127), (165,165,0), (165,165,82), (127,127,0), (127,127,63),
            (76,76,0), (76,76,38), (38,38,0), (38,38,19), (191,255,0), (223,255,127), (124,165,0), (145,165,82),
            (95,127,0), (111,127,63), (57,76,0), (66,76,38), (28,38,0), (33,38,19), (127,255,0), (191,255,127),
            (82,165,0), (124,165,82), (63,127,0), (95,127,63), (38,76,0), (57,76,38), (19,38,0), (28,38,19),
            (63,255,0), (159,255,127), (41,165,0), (103,165,82), (31,127,0), (79,127,63), (19,76,0), (47,76,38),
            (9,38,0), (23,38,19), (0,255,0), (125,255,127), (0,165,0), (82,165,82), (0,127,0), (63,127,63),
            (0,76,0), (38,76,38), (0,38,0), (19,38,19), (0,255,63), (127,255,159), (0,165,41), (82,165,103),
            (0,127,31), (63,127,79), (0,76,19), (38,76,47), (0,38,9), (19,88,23), (0,255,127), (127,255,191),
            (0,165,82), (82,165,124), (0,127,63), (63,127,95), (0,76,38), (38,76,57), (0,38,19), (19,88,28),
            (0,255,191), (127,255,223), (0,165,124), (82,165,145), (0,127,95), (63,127,111), (0,76,57), (38,76,66),
            (0,38,28), (19,88,88), (0,255,255), (127,255,255), (0,165,165), (82,165,165), (0,127,127), (63,127,127),
            (0,76,76), (38,76,76), (0,38,38), (19,88,88), (0,191,255), (127,223,255), (0,124,165), (82,145,165),
            (0,95,127), (63,111,217), (0,57,76), (38,66,126), (0,28,38), (19,88,88), (0,127,255), (127,191,255),
            (0,82,165), (82,124,165), (0,63,127), (63,95,127), (0,38,76), (38,57,126), (0,19,38), (19,28,88),
            (0,63,255), (127,159,255), (0,41,165), (82,103,165), (0,31,127), (63,79,127), (0,19,76), (38,47,126),
            (0,9,38), (19,23,88), (0,0,255), (127,127,255), (0,0,165), (82,82,165), (0,0,127), (63,63,127),
            (0,0,76), (38,38,126), (0,0,38), (19,19,88), (63,0,255), (159,127,255), (41,0,165), (103,82,165),
            (31,0,127), (79,63,127), (19,0,76), (47,38,126), (9,0,38), (23,19,88), (127,0,255), (191,127,255),
            (165,0,82), (124,82,165), (63,0,127), (95,63,127), (38,0,76), (57,38,126), (19,0,38), (28,19,88),
            (191,0,255), (223,127,255), (124,0,165), (142,82,165), (95,0,127), (111,63,127), (57,0,76), (66,38,76),
            (28,0,38), (88,19,88), (255,0,255), (255,127,255), (165,0,165), (165,82,165), (127,0,127), (127,63,127),
            (76,0,76), (76,38,76), (38,0,38), (88,19,88), (255,0,191), (255,127,223), (165,0,124), (165,82,145),
            (127,0,95), (127,63,111), (76,0,57), (76,38,66), (38,0,28), (88,19,88), (255,0,127), (255,127,191),
            (165,0,82), (165,82,124), (127,0,63), (127,63,95), (76,0,38), (76,38,57), (38,0,19), (88,19,28),
            (255,0,63), (255,127,159), (165,0,41), (165,82,103), (127,0,31), (127,63,79), (76,0,19), (76,38,47),
            (38,0,9), (88,19,23), (0,0,0), (101,101,101), (102,102,102), (153,153,153), (204,204,204), (255,255,255),
        ]
    }

    /// ACadSharp `LineWeightType`: hundredths of a millimetre, or one of the negative "by" values.
    struct LineWeight: RawRepresentable, Hashable {
        var rawValue: Int16
        init(rawValue: Int16) { self.rawValue = rawValue }
        init(_ value: Int16) { rawValue = value }

        static let byDIPs = LineWeight(-4)
        static let `default` = LineWeight(-3)
        static let byBlock = LineWeight(-2)
        static let byLayer = LineWeight(-1)
        static let w0 = LineWeight(0)
        static let w211 = LineWeight(211)

        /// The 24 standard weights in DWG index order (`CadUtils._indexedValue`).
        static let indexed: [Int16] = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211]

        /// `CadUtils.ToValue`: DWG line weight index → value.
        static func fromIndex(_ b: UInt8) -> LineWeight {
            switch b {
            case 28, 29: return .byLayer
            case 30: return .byBlock
            case 31: return .default
            default: return Int(b) < indexed.count ? LineWeight(indexed[Int(b)]) : .default
            }
        }

        /// `CadUtils.ToIndex`: value → DWG line weight index.
        var dwgIndex: UInt8 {
            switch self {
            case .default: return 31
            case .byBlock: return 30
            case .byLayer: return 29
            default:
                // Array.IndexOf returns -1 for unknown values, cast to byte: 255 (ACadSharp's `result < 0` never fires).
                return LineWeight.indexed.firstIndex(of: rawValue).map { UInt8($0) } ?? 255
            }
        }
    }

    /// ACadSharp `Transparency`: -1 ByLayer, 100 ByBlock, else 0 (opaque) … 90 percent.
    struct Transparency: Hashable {
        private(set) var value: Int16

        init(_ value: Int16) {
            self.value = value == -1 || value == 100 ? value : max(0, min(90, value))
        }

        static let byLayer = Transparency(-1)
        static let byBlock = Transparency(100)
        static let opaque = Transparency(0)

        var isByLayer: Bool { value == -1 }
        var isByBlock: Bool { value == 100 }

        /// `FromAlphaValue`: group code 440 / DWG BL value.
        static func fromAlphaValue(_ raw: Int32) -> Transparency {
            let alphaByte = UInt8(truncatingIfNeeded: raw)
            let alpha = Int16(Double(100) - (Double(alphaByte) / 255.0) * 100)
            if alpha == -1 { return .byLayer }
            if alpha == 100 { return .byBlock }
            if alpha < 0 { return Transparency(0) }
            if alpha > 90 { return Transparency(90) }
            return Transparency(alpha)
        }

        /// `ToAlphaValue`.
        static func toAlphaValue(_ t: Transparency) -> Int32 {
            if t.isByBlock { return Int32(bitPattern: 0x0100_0000) }
            // .NET 9+ converts doubles to bytes with saturation (ByLayer's 257.55 becomes 255).
            let alpha = UInt8(max(0, min(255, (255 * Double(100 - Int(t.value)) / 100.0).rounded(.towardZero))))
            return Int32(bitPattern: UInt32(alpha) | 0x0200_0000)
        }
    }

    /// ACadSharp `ACadVersion`, with the same numeric values.
    enum Version: Int16, Comparable, CaseIterable {
        case unknown = -1
        case mc0_0 = 0, ac1_2, ac1_4, ac1_50, ac2_10, ac1002, ac1003, ac1004, ac1006, ac1009
        case ac1012 = 19, ac1014 = 21, ac1015 = 23, ac1018 = 25, ac1021 = 27, ac1024 = 29, ac1027 = 31, ac1032 = 33

        static func < (a: Version, b: Version) -> Bool { a.rawValue < b.rawValue }

        /// `CadUtils.GetNameFromVersion`: "AC1032", "MC0.0" …
        var name: String {
            switch self {
            case .unknown: return "Unknown"
            case .mc0_0: return "MC0.0"
            case .ac1_2: return "AC1.2"
            case .ac1_4: return "AC1.4"
            case .ac1_50: return "AC1.50"
            case .ac2_10: return "AC2.10"
            default: return String(describing: self).uppercased()
            }
        }

        /// `CadUtils.GetVersionFromName`.
        static func from(name: String) -> Version {
            let key = name.replacingOccurrences(of: ".", with: "_").uppercased()
            return allCases.first { String(describing: $0).uppercased() == key } ?? .unknown
        }
    }

    /// Text encodings of drawings (`CadUtils` code page tables and CSUtilities `CodePage`).
    enum CodePages {
        /// DXF `$DWGCODEPAGE` names → Windows code pages (`CadUtils._dxfEncodingMap`).
        static let dxfNames: [(String, Int)] = [
            ("gb2312", 936), ("kcs5601", 949), ("ascii", 20127), ("big5", 950), ("johab", 1361), ("mac-roman", 10010),
            ("dos437", 437), ("dos850", 850), ("dos852", 852), ("dos737", 737), ("dos866", 866), ("dos855", 855),
            ("dos857", 857), ("dos860", 860), ("dos861", 861), ("dos863", 863), ("dos864", 864), ("dos865", 865),
            ("dos869", 869), ("dos720", 720), ("dos775", 775), ("dos932", 932), ("dos950", 950), ("ansi_874", 874),
            ("ansi_932", 932), ("ansi_936", 936), ("ansi_950", 950), ("ansi_1250", 1250), ("ansi1250", 1250),
            ("ansi_1251", 1251), ("ansi1251", 1251), ("ansi_1252", 1252), ("ansi1252", 1252), ("ansi_1253", 1253),
            ("ansi1253", 1253), ("ansi_1254", 1254), ("ansi1254", 1254), ("ansi_1255", 1255), ("ansi1255", 1255),
            ("ansi_1256", 1256), ("ansi1256", 1256), ("ansi_1257", 1257), ("ansi1257", 1257), ("iso8859-1", 28591),
            ("iso88591", 28591), ("iso8859-2", 28592), ("iso88592", 28592), ("iso8859-3", 28593), ("iso88593", 28593),
            ("iso8859-4", 28594), ("iso88594", 28594), ("iso8859-5", 28595), ("iso88595", 28595), ("iso8859-6", 28596),
            ("iso88596", 28596), ("iso8859-7", 28597), ("iso88597", 28597), ("iso8859-8", 28598), ("iso88598", 28598),
            ("iso8859-9", 28599), ("iso88599", 28599), ("iso8859-10", 28600), ("iso885910", 28600),
            ("iso8859-13", 28603), ("iso885913", 28603), ("iso885915", 28605), ("iso8859-15", 28605),
        ]

        /// DWG header code page numbers → Windows code pages (`CadUtils._pageCodes`); 0 = unknown.
        static let dwgIndex: [Int] = [
            0, 20127, 28591, 28592, 28593, 28594, 28595, 28596, 28597, 28598, 28599, 437, 850, 852, 855, 857, 860, 861,
            863, 864, 865, 869, 932, 10000, 950, 949, 1361, 866, 1250, 1251, 1252, 936, 1253, 1254, 1255, 1256, 1257, 874,
            932, 936, 949, 950, 1361, 1200, 1258,
        ]

        /// `CadUtils.GetCodePage(string)`: 0 when the name is unknown.
        static func codePage(name: String) -> Int {
            let key = name.lowercased()
            return dxfNames.first { $0.0 == key }?.1 ?? 0
        }

        /// `CadUtils.GetCodePageName`: the first DXF name of a code page.
        static func name(codePage: Int) -> String? { dxfNames.first { $0.1 == codePage }?.0 }

        /// `CadUtils.GetCodePage(int)`.
        static func codePage(dwgIndex index: Int) -> Int { index >= 0 && index < dwgIndex.count ? dwgIndex[index] : 0 }

        /// `CadUtils.GetCodeIndex`.
        static func dwgIndex(codePage: Int) -> Int { dwgIndex.firstIndex(of: codePage) ?? -1 }

        /// `Encoding.GetEncoding(code)` as ACadSharp calls it: code page 0 is .NET's default (UTF-8); unknown pages
        /// fall back to Windows-1252.
        static func encoding(_ codePage: Int) -> String.Encoding {
            if codePage == 0 { return .utf8 }
            return TextEncodings.encoding(codePage: codePage) ?? TextEncodings.encoding(codePage: 1252) ?? .windowsCP1252
        }
    }
}
