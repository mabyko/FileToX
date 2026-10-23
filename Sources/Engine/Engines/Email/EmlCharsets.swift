// Charsets of e-mail text the way MimeKit resolves them on .NET (MimeKit CharsetUtils + System.Text code pages).
// Names map to code pages through MimeKit's aliases and rules; decoding follows .NET's default fallbacks: invalid
// bytes become "?" (U+FFFD for UTF-8 / UTF-16). The Korean code pages (CP949, EUC-KR 51949, ISO-2022-KR 50225) and
// the single-byte tables are decoded byte for byte like .NET's tables (CoreFoundation plus the measured differences);
// other multi-byte charsets go through CoreFoundation.

import CoreFoundation
import Foundation

enum EmlCharsets {
    // MARK: Names → code pages

    /// MimeKit `CharsetUtils.GetCodePage`: the code page of a charset name, -1 when it is not supported.
    static func codePage(_ charset: String) -> Int {
        if let alias = aliases[charset.lowercased()] { return alias }
        let parsed = parseCodePage(charset)
        if parsed != -1 { return isSupported(parsed) ? parsed : -1 }
        return codePage(named: charset)
    }

    /// MimeKit's aliases (euc-kr and ks_c_5601-1987 are "upgraded" to 51949, as MimeKit does).
    private static let aliases: [String: Int] = {
        var table: [String: Int] = [:]
        func add(_ codePage: Int, _ names: String...) { for name in names { table[name] = codePage } }
        add(65001, "utf-8", "utf8", "unicode")
        add(20127, "ansi_x3.4-1968")
        add(28591, "ansi_x3.110-1983", "latin1")
        add(10000, "macintosh")
        add(10079, "x-mac-icelandic")
        add(51949, "ks_c_5601-1987", "ksc-5601-1987", "ksc-5601_1987", "ksc-5601", "5601", "ks_c_5861-1992", "ksc-5861-1992",
            "ksc-5861_1992", "euckr-0", "euc-kr")
        add(950, "big5", "big5-0", "big5-hkscs", "big5.eten-0", "big5hkscs-0")
        add(936, "gb2312", "gb-2312", "gb2312-0", "gb2312-80", "gb2312.1980-0")
        add(51936, "euc-cn", "gbk-0", "x-gbk", "gbk")
        add(52936, "hz-gb-2312", "hz-gb2312")
        add(54936, "gb18030-0", "gb18030")
        add(51932, "eucjp-0", "euc-jp", "ujis-0", "ujis")
        add(932, "shift_jis", "jisx0208.1983-0", "jisx0212.1990-0", "pck")
        add(50220, "iso-2022-jp")
        return table
    }()

    /// `int.TryParse(..., NumberStyles.None)`: ASCII digits only.
    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int32(text).map(Int.init)
    }

    /// MimeKit `CharsetUtils.ParseCodePage`: windows-1252, windows-cp1252, ibm-437, iso-8859-1, iso-2022-kr, cp949, latin1.
    static func parseCodePage(_ charset: String) -> Int {
        let lower = charset.lowercased()
        func rest(after prefix: Int, allowCp: Bool) -> Substring? {
            var index = charset.index(charset.startIndex, offsetBy: prefix)
            if index == charset.endIndex { return nil }
            if charset[index] == "-" || charset[index] == "_" {
                if allowCp, charset.index(after: index) == charset.endIndex { return nil }
                index = charset.index(after: index)
            }
            return charset[index...]
        }
        if lower.hasPrefix("windows") {
            guard var tail = rest(after: 7, allowCp: true) else { return -1 }
            if tail.count > 2, tail.hasPrefix("cp") { tail = tail.dropFirst(2) }
            return digits(tail) ?? -1
        }
        if lower.hasPrefix("ibm") {
            guard let tail = rest(after: 3, allowCp: false) else { return -1 }
            return digits(tail) ?? -1
        }
        if lower.hasPrefix("iso") {
            guard let tail = rest(after: 3, allowCp: false) else { return -1 }
            return parseIsoCodePage(tail)
        }
        if lower.hasPrefix("cp") {
            guard let tail = rest(after: 2, allowCp: false) else { return -1 }
            return digits(tail) ?? -1
        }
        return lower == "latin1" ? 28591 : -1
    }

    private static func parseIsoCodePage(_ text: Substring) -> Int {
        guard text.count >= 5 else { return -1 }
        let dash = text.firstIndex { $0 == "-" || $0 == "_" } ?? text.endIndex
        guard let iso = digits(text[..<dash]) else { return -1 }
        if iso == 10646 { return 1201 }
        guard dash != text.endIndex, text.index(after: dash) != text.endIndex else { return -1 }
        let tail = text[text.index(after: dash)...]
        switch iso {
        case 8859:
            guard let page = digits(tail), page > 0, !(page > 9 && page < 13), page <= 15 else { return -1 }
            return 28590 + page
        case 2022:
            switch tail.lowercased() {
            case "jp": return 50220
            case "kr": return 50225
            default: return -1
            }
        default:
            return -1
        }
    }

    /// `Encoding.GetEncoding(name).CodePage`, through CoreFoundation's IANA names; -1 when unknown.
    private static func codePage(named name: String) -> Int {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return -1 }
        let windows = CFStringConvertEncodingToWindowsCodepage(cf)
        // Encodings without a Windows code page are kept by their CoreFoundation id.
        return windows == kCFStringEncodingInvalidId ? Int(cfBase) + Int(cf) : Int(windows)
    }

    private static let cfBase: UInt32 = 0x100000

    /// `Encoding.GetEncoding(codePage)` succeeds.
    static func isSupported(_ codePage: Int) -> Bool {
        switch codePage {
        case 65001, 1200, 1201, 12000, 12001, 20127, 28591, 949, 51949, 50225: return true
        default: return cfEncoding(codePage) != nil
        }
    }

    private static func cfEncoding(_ codePage: Int) -> CFStringEncoding? {
        guard codePage > 0 else { return nil }
        if codePage >= Int(cfBase) { return CFStringEncoding(UInt32(codePage) - cfBase) }
        if codePage == 38598 { return CFStringConvertWindowsCodepageToEncoding(28598) } // iso-8859-8-i: same table
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
        return cf == kCFStringEncodingInvalidId ? nil : cf
    }

    // MARK: Decoding

    /// `Encoding.GetEncoding(codePage).GetString(bytes)` with .NET's default replacement fallback.
    static func decode(_ bytes: ArraySlice<UInt8>, codePage: Int) -> String {
        decode(bytes, codePage: codePage, strict: false) ?? latin1(bytes)
    }

    /// Like `decode`, but nil instead of a replacement when `strict` and a byte sequence is invalid (.NET's exception and
    /// counting fallbacks). Unsupported code pages also give nil.
    static func decode(_ bytes: ArraySlice<UInt8>, codePage: Int, strict: Bool) -> String? {
        switch codePage {
        case 65001:
            return strict ? String(validating: bytes, as: UTF8.self) : String(decoding: bytes, as: UTF8.self)
        case 28591:
            return latin1(bytes)
        case 20127:
            if strict && bytes.contains(where: { $0 >= 0x80 }) { return nil }
            return String(decoding: bytes.map { $0 >= 0x80 ? 0x3F : $0 }, as: UTF8.self)
        case 1200, 1201:
            return utf16(bytes, bigEndian: codePage == 1201, strict: strict)
        case 949:
            return KoreanDbcs.cp949.decode(bytes, strict: strict)
        case 51949:
            return KoreanDbcs.eucKr.decode(bytes, strict: strict)
        case 50225:
            return iso2022Kr(bytes, strict: strict)
        default:
            guard let cf = cfEncoding(codePage) else { return nil }
            if singleByte.contains(codePage) || CFStringGetMaximumSizeForEncoding(1, cf) == 1 {
                return SingleByteTable.table(codePage: codePage, cf).decode(bytes, strict: strict)
            }
            return multiByte(bytes, cf, strict: strict)
        }
    }

    /// Single-byte code pages CoreFoundation does not report as such.
    private static let singleByte = Set([
        874, 1250, 1251, 1252, 1253, 1254, 1255, 1256, 1257, 1258, 20866, 21866, 38598, 437, 737, 775, 850, 852, 855, 857, 858,
        860, 861, 862, 863, 864, 865, 866, 869, 10000, 10004, 10005, 10006, 10007, 10010, 10017, 10021, 10029, 10079, 10081, 10082,
    ] + Array(28591...28606))

    static func latin1(_ bytes: ArraySlice<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
        return String(scalars)
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool, strict: Bool) -> String? {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            units.append(bigEndian ? a << 8 | b : b << 8 | a)
            index += 2
        }
        let odd = index < bytes.endIndex
        if strict {
            if odd { return nil }
            var units = units.makeIterator()
            var decoder = UTF16()
            loop: while true {
                switch decoder.decode(&units) {
                case .scalarValue: continue
                case .emptyInput: break loop
                case .error: return nil
                }
            }
        }
        return String(decoding: units, as: UTF16.self) + (odd ? "\u{FFFD}" : "")
    }

    /// Other multi-byte charsets through CoreFoundation; invalid sequences become "?" one byte at a time.
    private static func multiByte(_ bytes: ArraySlice<UInt8>, _ cf: CFStringEncoding, strict: Bool) -> String? {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        if let text = String(bytes: bytes, encoding: encoding) { return text }
        if strict { return nil }
        var result = ""
        var index = bytes.startIndex
        outer: while index < bytes.endIndex {
            for length in 1...4 where index + length <= bytes.endIndex {
                if let piece = String(bytes: bytes[index..<index + length], encoding: encoding), !piece.isEmpty {
                    result += piece
                    index += length
                    continue outer
                }
            }
            result += "?"
            index += 1
        }
        return result
    }

    // MARK: MimeKit's fallbacks

    /// MimeKit `CharsetUtils.ConvertToUnicode(options, ...)` with Filee's ParserOptions.CharsetEncoding = CP949: the
    /// first of UTF-8, CP949 and ISO-8859-1 that decodes without errors.
    static func convertToUnicode(_ bytes: ArraySlice<UInt8>) -> String {
        if let text = String(validating: bytes, as: UTF8.self) { return text }
        if let text = decode(bytes, codePage: 949, strict: true) { return text }
        return latin1(bytes)
    }

    /// MimeKit `CharsetUtils.ConvertToUnicode(options, codepage, ...)`: the code page's decoder, or the fallback above
    /// when it is unknown.
    static func convertToUnicode(_ bytes: ArraySlice<UInt8>, codePage: Int) -> String {
        guard codePage != -1, isSupported(codePage) else { return convertToUnicode(bytes) }
        return decode(bytes, codePage: codePage)
    }

    // MARK: .NET's Korean decoders

    /// .NET's double-byte decoders for CP949 and EUC-KR (51949): a lead byte always takes the next byte, an unmapped
    /// pair (or a lead byte at the end) becomes one "?", and some non-lead bytes decode to C1 controls or private use.
    private struct KoreanDbcs {
        let isLead: (UInt8) -> Bool
        /// Decoding of a non-lead byte ≥ 0x80; nil for "?".
        let single: (UInt8) -> UInt16?
        /// Pair → UTF-16 unit, 0 when unmapped: index (lead - 0x80) * 256 + trail.
        let pairs: [UInt16]

        static let cp949 = KoreanDbcs(
            isLead: { $0 >= 0x81 && $0 <= 0xFE },
            single: { $0 == 0x80 ? 0x0080 : $0 == 0xFF ? 0xF8F7 : nil },
            pairs: table(CFStringConvertWindowsCodepageToEncoding(949), leads: 0x81...0xFE) { lead, trail, cf in
                if lead == 0xA2 && trail == 0xE6 { return 0x20AC }
                if lead == 0xA2 && trail == 0xE7 { return 0x00AE }
                // The user-defined row: .NET maps it 0x0F00 lower in the private use area.
                if lead == 0xFE, trail >= 0xA1, trail <= 0xFE, cf != 0 { return cf - 0x0F00 }
                return cf
            })

        static let eucKr = KoreanDbcs(
            isLead: { ($0 >= 0xA1 && $0 <= 0xAC) || ($0 >= 0xB0 && $0 <= 0xC8) || ($0 >= 0xCA && $0 <= 0xFD) },
            single: { byte in
                switch byte {
                case 0x80...0x9F: UInt16(byte)
                case 0xA0: 0xF8E6
                case 0xAD: 0xF8E7
                case 0xAE: 0xF8E8
                case 0xAF: 0xF8E9
                case 0xFE: 0xF8EA
                case 0xFF: 0xF8EB
                default: nil
                }
            },
            pairs: table(CFStringConvertWindowsCodepageToEncoding(51949), leads: 0xA1...0xFD) { lead, trail, cf in
                if lead == 0xA2 && trail == 0xE6 { return 0x20AC }
                if lead == 0xA2 && trail == 0xE7 { return 0x00AE }
                if lead == 0xB4 && trail == 0xD3 { return 0xB2D6 }
                return cf
            })

        private static func table(_ cf: CFStringEncoding, leads: ClosedRange<UInt8>,
                                  adjust: (UInt8, UInt8, UInt16) -> UInt16) -> [UInt16] {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            var pairs = [UInt16](repeating: 0, count: 128 * 256)
            for lead in leads {
                for trail in UInt8(0)...UInt8(0xFF) {
                    var unit: UInt16 = 0
                    if let text = String(bytes: [lead, trail], encoding: encoding) {
                        let units = Array(text.utf16)
                        if units.count == 1 { unit = units[0] }
                    }
                    pairs[Int(lead - 0x80) * 256 + Int(trail)] = adjust(lead, trail, unit)
                }
            }
            return pairs
        }

        func pair(_ lead: UInt8, _ trail: UInt8) -> UInt16? {
            let unit = pairs[Int(lead - 0x80) * 256 + Int(trail)]
            return unit == 0 ? nil : unit
        }

        func decode(_ bytes: ArraySlice<UInt8>, strict: Bool) -> String? {
            var units: [UInt16] = []
            units.reserveCapacity(bytes.count)
            var index = bytes.startIndex
            while index < bytes.endIndex {
                let byte = bytes[index]
                index += 1
                if byte < 0x80 { units.append(UInt16(byte)); continue }
                if isLead(byte) {
                    guard index < bytes.endIndex else {
                        if strict { return nil }
                        units.append(0x3F)
                        break
                    }
                    let trail = bytes[index]
                    index += 1
                    if let unit = pair(byte, trail) { units.append(unit) } else if strict { return nil } else { units.append(0x3F) }
                    continue
                }
                if let unit = single(byte) { units.append(unit) } else if strict { return nil } else { units.append(0x3F) }
            }
            return String(decoding: units, as: UTF16.self)
        }
    }

    /// .NET's ISO-2022-KR (50225) decoder: ESC $ ) C is skipped, SO / SI switch between ASCII and KS X 1001 (two
    /// 7-bit bytes, CP949's table), space / tab / line feed pass through in KS X 1001 mode, everything else is "?".
    private static func iso2022Kr(_ bytes: ArraySlice<UInt8>, strict: Bool) -> String? {
        var units: [UInt16] = []
        var korean = false
        var escape: [UInt8] = []
        var index = bytes.startIndex
        var invalid = false
        func map(_ code: UInt16) -> UInt16? {
            if code < 0x80 { return code }
            if code < 0x100 { return nil }
            let lead = UInt8(code >> 8), trail = UInt8(code & 0xFF)
            guard (0x21...0x7E).contains(lead), (0x21...0x7E).contains(trail) else { return nil }
            return KoreanDbcs.cp949.pair(lead | 0x80, trail | 0x80)
        }
        while index < bytes.endIndex || !escape.isEmpty {
            var byte: UInt8
            if !escape.isEmpty {
                if escape[0] == 0x1B, index < bytes.endIndex {
                    escape.append(bytes[index])
                    index += 1
                    if escape.count < 4 { continue }
                    if escape[1] == 0x24 && escape[2] == 0x29 && escape[3] == 0x43 { escape.removeAll(); continue }
                }
                byte = escape.removeFirst()
            } else {
                byte = bytes[index]
                index += 1
                if byte == 0x1B { escape = [byte]; continue }
            }
            if byte == 0x0E { korean = true; continue }
            if byte == 0x0F { korean = false; continue }
            var code = UInt16(byte)
            if korean && byte != 0x20 && byte != 0x09 && byte != 0x0A {
                if !escape.isEmpty {
                    if escape[0] != 0x1B { code = code << 8 | UInt16(escape.removeFirst()) }
                } else if index < bytes.endIndex {
                    code = code << 8 | UInt16(bytes[index])
                    index += 1
                } else {
                    invalid = true
                    units.append(0x3F)
                    break
                }
            }
            if let unit = map(code) { units.append(unit) } else { invalid = true; units.append(0x3F) }
        }
        return strict && invalid ? nil : String(decoding: units, as: UTF16.self)
    }

    // MARK: Single-byte tables

    /// 256-entry decoding tables: CoreFoundation's, corrected where .NET's tables differ (measured with .NET 10).
    private final class SingleByteTable: @unchecked Sendable {
        let units: [UInt16?]

        init(units: [UInt16?]) { self.units = units }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var cache: [Int: SingleByteTable] = [:]

        static func table(codePage: Int, _ cf: CFStringEncoding) -> SingleByteTable {
            if let cached = lock.withLock({ cache[codePage] }) { return cached }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            var units = [UInt16?](repeating: nil, count: 256)
            for byte in 0...255 {
                if let text = String(bytes: [UInt8(byte)], encoding: encoding) {
                    let decoded = Array(text.utf16)
                    if decoded.count == 1 { units[byte] = decoded[0] }
                }
            }
            for (byte, unit) in dotNetDifferences[codePage == 38598 ? 28598 : codePage] ?? [:] { units[byte] = unit }
            let table = SingleByteTable(units: units)
            lock.withLock { cache[codePage] = table }
            return table
        }

        func decode(_ bytes: ArraySlice<UInt8>, strict: Bool) -> String? {
            var result: [UInt16] = []
            result.reserveCapacity(bytes.count)
            for byte in bytes {
                if let unit = units[Int(byte)] { result.append(unit) } else if strict { return nil } else { result.append(0x3F) }
            }
            return String(decoding: result, as: UTF16.self)
        }
    }

    /// Bytes where .NET's single-byte code page tables differ from CoreFoundation's (probe: decode every byte alone).
    private static let dotNetDifferences: [Int: [Int: UInt16]] = [
        874: [0x81: 0x0081, 0x82: 0x0082, 0x83: 0x0083, 0x84: 0x0084, 0x86: 0x0086, 0x87: 0x0087, 0x88: 0x0088, 0x89: 0x0089,
              0x8A: 0x008A, 0x8B: 0x008B, 0x8C: 0x008C, 0x8D: 0x008D, 0x8E: 0x008E, 0x8F: 0x008F, 0x90: 0x0090, 0x98: 0x0098,
              0x99: 0x0099, 0x9A: 0x009A, 0x9B: 0x009B, 0x9C: 0x009C, 0x9D: 0x009D, 0x9E: 0x009E, 0x9F: 0x009F, 0xDB: 0xF8C1,
              0xDC: 0xF8C2, 0xDD: 0xF8C3, 0xDE: 0xF8C4, 0xFC: 0xF8C5, 0xFD: 0xF8C6, 0xFE: 0xF8C7, 0xFF: 0xF8C8],
        1250: [0x81: 0x0081, 0x83: 0x0083, 0x88: 0x0088, 0x90: 0x0090, 0x98: 0x0098],
        1251: [0x98: 0x0098],
        1252: [0x81: 0x0081, 0x8D: 0x008D, 0x8F: 0x008F, 0x90: 0x0090, 0x9D: 0x009D],
        1253: [0x81: 0x0081, 0x88: 0x0088, 0x8A: 0x008A, 0x8C: 0x008C, 0x8D: 0x008D, 0x8E: 0x008E, 0x8F: 0x008F, 0x90: 0x0090,
               0x98: 0x0098, 0x9A: 0x009A, 0x9C: 0x009C, 0x9D: 0x009D, 0x9E: 0x009E, 0x9F: 0x009F, 0xAA: 0xF8F9, 0xD2: 0xF8FA,
               0xFF: 0xF8FB],
        1254: [0x81: 0x0081, 0x8D: 0x008D, 0x8E: 0x008E, 0x8F: 0x008F, 0x90: 0x0090, 0x9D: 0x009D, 0x9E: 0x009E],
        1255: [0x81: 0x0081, 0x8A: 0x008A, 0x8C: 0x008C, 0x8D: 0x008D, 0x8E: 0x008E, 0x8F: 0x008F, 0x90: 0x0090, 0x9A: 0x009A,
               0x9C: 0x009C, 0x9D: 0x009D, 0x9E: 0x009E, 0x9F: 0x009F, 0xCA: 0x05BA, 0xD9: 0xF88D, 0xDA: 0xF88E, 0xDB: 0xF88F,
               0xDC: 0xF890, 0xDD: 0xF891, 0xDE: 0xF892, 0xDF: 0xF893, 0xFB: 0xF894, 0xFC: 0xF895, 0xFF: 0xF896],
        1256: [0x8A: 0x0679, 0x8F: 0x0688, 0x98: 0x06A9, 0x9A: 0x0691, 0x9F: 0x06BA, 0xAA: 0x06BE, 0xC0: 0x06C1, 0xFF: 0x06D2],
        1257: [0xA1: 0xF8FC, 0xA5: 0xF8FD],
        1258: [0x81: 0x0081, 0x8A: 0x008A, 0x8D: 0x008D, 0x8E: 0x008E, 0x8F: 0x008F, 0x90: 0x0090, 0x9A: 0x009A, 0x9D: 0x009D,
               0x9E: 0x009E],
        28593: [0xA5: 0xF7F5, 0xAE: 0xF7F6, 0xBE: 0xF7F7, 0xC3: 0xF7F8, 0xD0: 0xF7F9, 0xE3: 0xF7FA, 0xF0: 0xF7FB],
        28596: Dictionary(uniqueKeysWithValues: zip([0xA1, 0xA2, 0xA3, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAE, 0xAF, 0xB0,
                                                    0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBC, 0xBD, 0xBE,
                                                    0xC0, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9,
                                                    0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF], UInt16(0xF7C8)...)),
        28597: [0xA1: 0x02BD, 0xA2: 0x02BC, 0xA4: 0xF7C2, 0xA5: 0xF7C3, 0xAA: 0xF7C4, 0xAE: 0xF7C5, 0xD2: 0xF7C6, 0xFF: 0xF7C7],
        28598: Dictionary(uniqueKeysWithValues: zip([0xA1] + Array(0xBF...0xDE) + [0xFB, 0xFC, 0xFD, 0xFE, 0xFF], UInt16(0xF79C)...)),
        28603: [0xFF: 0x2019],
        20866: [0x95: 0x2219],
        21866: [0xAE: 0x045E, 0xBE: 0x040E],
        857: [0xD5: 0xF8BB, 0xE7: 0xF8BC, 0xF2: 0xF8BD],
        860: [0xE6: 0x00B5],
        861: [0x80: 0x00C7, 0x83: 0x00E2, 0x85: 0x00E0, 0x87: 0x00E7, 0x88: 0x00EA, 0x89: 0x00EB, 0x8A: 0x00E8, 0x8B: 0x00D0,
              0x8C: 0x00F0, 0x8D: 0x00DE, 0x93: 0x00F4, 0x95: 0x00FE, 0x96: 0x00FB, 0x97: 0x00DD, 0x98: 0x00FD, 0x9E: 0x20A7,
              0x9F: 0x0192, 0xA0: 0x00E1, 0xA1: 0x00ED, 0xA3: 0x00FA, 0xA4: 0x00C1, 0xA5: 0x00CD, 0xA6: 0x00D3, 0xA7: 0x00DA,
              0xA8: 0x00BF, 0xA9: 0x2310, 0xAD: 0x00A1, 0xB5: 0x2561, 0xB6: 0x2562, 0xB7: 0x2556, 0xB8: 0x2555, 0xBD: 0x255C,
              0xBE: 0x255B, 0xC6: 0x255E, 0xC7: 0x255F, 0xCF: 0x2567, 0xD0: 0x2568, 0xD1: 0x2564, 0xD2: 0x2565, 0xD3: 0x2559,
              0xD4: 0x2558, 0xD5: 0x2552, 0xD6: 0x2553, 0xD7: 0x256B, 0xD8: 0x256A, 0xE0: 0x03B1, 0xE2: 0x0393, 0xE3: 0x03C0,
              0xE4: 0x03A3, 0xE5: 0x03C3, 0xE7: 0x03C4, 0xE8: 0x03A6, 0xE9: 0x0398, 0xEA: 0x03A9, 0xEB: 0x03B4, 0xEC: 0x221E,
              0xED: 0x03C6, 0xEE: 0x03B5, 0xEF: 0x2229, 0xF0: 0x2261, 0xF2: 0x2265, 0xF3: 0x2264, 0xF4: 0x2320, 0xF5: 0x2321,
              0xF7: 0x2248, 0xFB: 0x221A, 0xFC: 0x207F],
        862: [0xE6: 0x00B5],
        863: [0xE6: 0x00B5],
        864: [0x9B: 0x009B, 0x9C: 0x009C, 0x9F: 0x009F, 0xA6: 0xF8BE, 0xA7: 0xF8BF, 0xD7: 0xFEC1, 0xD8: 0xFEC5, 0xF1: 0x0651,
              0xFF: 0xF8C0],
        865: [0xE6: 0x00B5],
        869: [0x80: 0x0080, 0x81: 0x0081, 0x82: 0x0082, 0x83: 0x0083, 0x84: 0x0084, 0x85: 0x0085, 0x87: 0x0087, 0x88: 0x00B7,
              0x93: 0x0093, 0x94: 0x0094, 0xEF: 0x0384],
        10000: [0xBD: 0x2126],
        10006: [0x9C: 0x00AD, 0xAF: 0x0387, 0xFF: 0xF8A0],
        10007: [0xA2: 0x00A2, 0xB6: 0x2202, 0xFF: 0x00A4],
        10079: [0xBD: 0x2126, 0xDB: 0x00A4],
        10081: [0xBD: 0x2126],
    ]
}
