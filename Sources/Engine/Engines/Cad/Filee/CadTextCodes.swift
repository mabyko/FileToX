// Port of Filee.Engines/Cad/CadTextCodes.cs: decodes the control codes inside CAD text — %%d / %%c / %%p specials and
// \U+ / \M+ escapes in TEXT, and the MTEXT formatting language (\P paragraphs, \H height, \C colour, \f font,
// \S stacked fractions, {} groups ...). Works on UTF-16 code units like the C# string code.

import Foundation

/// Formatting state of an MTEXT run. Values not set by codes come from the entity.
struct CadMTextFormat: Equatable {
    var height: Double
    var colorIndex: Int16?
    var trueColor: Int32?
    var fontFamily: String?
    var bold: Bool
    var italic: Bool
    var widthFactor: Double
    var obliqueDegrees: Double
}

/// A piece of MTEXT with one format.
struct CadMTextRun: Equatable {
    var text: String
    var format: CadMTextFormat
}

/// Parsers for text control codes.
enum CadTextCodes {
    /// Multi-byte code pages of `\M+n` escapes (AutoCAD's numbering).
    private static let multiByteCodePages = [0, 932, 950, 949, 1361, 936]

    /// Decodes a single-line TEXT / ATTRIB value: `%%d` → °, `%%c` → Ø, `%%p` → ±, `%%nnn` → character nnn,
    /// underline / overline toggles removed, `\U+XXXX` and `\M+nXXXX` escapes decoded.
    static func decodeText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let units = Array(value.utf16)
        var sb: [UInt16] = []
        sb.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            if tryEscape(units, &i, &sb) || trySpecial(units, &i, &sb) {
                i += 1
                continue
            }
            sb.append(units[i] == 0x09 ? 0x20 : units[i])
            i += 1
        }
        return String(utf16: sb)
    }

    /// Parses an MTEXT value into paragraphs of formatted runs. Paragraph, line and column breaks start a new
    /// paragraph; stacked text becomes an inline fraction ("1/2"); codes that only affect layout details (tracking,
    /// paragraph indents, underline) are dropped.
    static func parseMText(_ value: String?, _ initial: CadMTextFormat) -> [[CadMTextRun]] {
        var paragraphs: [[CadMTextRun]] = [[]]
        guard let value, !value.isEmpty else { return paragraphs }
        let units = Array(value.utf16)

        var state = initial
        var stack: [CadMTextFormat] = []
        var text: [UInt16] = []

        func flush() {
            if text.isEmpty { return }
            paragraphs[paragraphs.count - 1].append(CadMTextRun(text: String(utf16: text), format: state))
            text.removeAll()
        }

        func newParagraph() {
            flush()
            paragraphs.append([])
        }

        var i = 0
        while i < units.count {
            defer { i += 1 }
            let ch = units[i]
            if ch == 0x7B { // {
                flush()
                stack.append(state)
                continue
            }
            if ch == 0x7D { // }
                flush()
                if let popped = stack.popLast() { state = popped }
                continue
            }
            if ch == 0x0A || ch == 0x0D {
                if ch == 0x0D && i + 1 < units.count && units[i + 1] == 0x0A { i += 1 }
                newParagraph()
                continue
            }
            if ch != 0x5C || i + 1 >= units.count {
                if !trySpecial(units, &i, &text) {
                    if ch == 0x09 { text.append(contentsOf: [0x20, 0x20, 0x20, 0x20]) } else { text.append(ch) }
                }
                continue
            }

            let code = units[i + 1]
            switch code {
            case 0x5C, 0x7B, 0x7D: // \\ \{ \}
                text.append(code)
                i += 1
            case 0x50, 0x4E, 0x58: // P N X
                i += 1
                newParagraph()
            case 0x7E: // ~ : non-breaking space
                text.append(0xA0)
                i += 1
            case 0x55, 0x4D: // U M
                if !tryEscape(units, &i, &text) { i += 1 }
            case 0x48, 0x57, 0x51: // H W Q
                let argument = readArgument(units, &i)
                flush()
                state = applyNumeric(state, code, argument)
            case 0x43, 0x63: // C c
                let argument = readArgument(units, &i)
                flush()
                if let number = parseInteger(argument) {
                    if code == 0x43 {
                        state.colorIndex = Int16(min(max(number, 0), 256))
                        state.trueColor = nil
                    } else {
                        state.trueColor = Int32(truncatingIfNeeded: number) & 0xFFFFFF
                        state.colorIndex = nil
                    }
                }
            case 0x66, 0x46: // f F
                let argument = readArgument(units, &i)
                flush()
                state = applyFont(state, argument)
            case 0x53: // S
                let argument = readArgument(units, &i)
                text.append(contentsOf: Array(stacked(argument).utf16))
            case 0x41, 0x54, 0x70, 0x71: // A T p q: alignment, tracking, paragraph properties: layout details
                _ = readArgument(units, &i)
            default:
                // \L \l \O \o \K \k (underline, overline, strike-through) and unknown codes: drop the code.
                i += 1
            }
        }
        flush()
        return paragraphs
    }

    /// Reads the argument of a code like `\H2.5;`, leaving `i` on the ';'.
    private static func readArgument(_ value: [UInt16], _ i: inout Int) -> [UInt16] {
        let start = i + 2
        var end = start
        while end < value.count && value[end] != 0x3B {
            // Inside \S, "\;" is an escaped semicolon.
            if value[end] == 0x5C && end + 1 < value.count { end += 1 }
            end += 1
        }
        i = min(end, value.count - 1)
        return start < value.count ? Array(value[start..<min(end, value.count)]) : []
    }

    private static func applyNumeric(_ state: CadMTextFormat, _ code: UInt16, _ argument: [UInt16]) -> CadMTextFormat {
        let relative = argument.last == 0x78 || argument.last == 0x58 // x X
        guard let number = parseFloat(relative ? Array(argument.dropLast()) : argument), number.isFinite else { return state }
        var state = state
        switch code {
        case 0x48 where number > 0: state.height = relative ? state.height * number : number
        case 0x57 where number > 0: state.widthFactor = relative ? state.widthFactor * number : number
        case 0x51: state.obliqueDegrees = min(max(number, -85), 85)
        default: break
        }
        return state
    }

    /// `\fArial|b1|i0|c0|p34;` (TrueType) or `\Ftxt.shx;` (SHX: rendered with the default font).
    private static func applyFont(_ state: CadMTextFormat, _ argument: [UInt16]) -> CadMTextFormat {
        let parts = String(utf16: argument).components(separatedBy: "|")
        var family = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var bold = false
        var italic = false
        for part in parts.dropFirst() {
            let u = Array(part.utf16)
            if u.count >= 2 && u[0] == 0x62 { // b
                bold = u[1] == 0x31
            } else if u.count >= 2 && u[0] == 0x69 { // i
                italic = u[1] == 0x31
            }
        }
        if family.lowercased().hasSuffix(".shx") { family = "" }
        var state = state
        state.fontFamily = family.isEmpty ? nil : family
        state.bold = bold
        state.italic = italic
        return state
    }

    /// Stacked text `1/2`, `1#2` (diagonal) or `+0.1^-0.2` (tolerance) shown inline as "1/2".
    private static func stacked(_ argument: [UInt16]) -> String {
        let unescaped = Array(String(utf16: argument).replacingOccurrences(of: "\\;", with: ";").utf16)
        guard let split = unescaped.firstIndex(where: { $0 == 0x2F || $0 == 0x23 || $0 == 0x5E }) else {
            return decodeText(String(utf16: unescaped))
        }
        let top = decodeText(String(utf16: Array(unescaped[..<split]))).trimmingCharacters(in: .whitespacesAndNewlines)
        let bottom = decodeText(String(utf16: Array(unescaped[(split + 1)...]))).trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? bottom : bottom.isEmpty ? top : "\(top)/\(bottom)"
    }

    /// Decodes `\U+XXXX` (Unicode) and `\M+nXXXX` (a double-byte character in an Asian code page).
    private static func tryEscape(_ value: [UInt16], _ i: inout Int, _ sb: inout [UInt16]) -> Bool {
        if value[i] != 0x5C || i + 2 >= value.count || value[i + 2] != 0x2B { return false }
        let letter = value[i + 1]
        if (letter == 0x55 || letter == 0x75) && i + 7 <= value.count, let code = parseHex(Array(value[(i + 3)..<(i + 7)])) {
            sb.append(UInt16(truncatingIfNeeded: code))
            i += 6
            return true
        }
        if (letter == 0x4D || letter == 0x6D) && i + 8 <= value.count, value[i + 3] >= 0x31 && value[i + 3] <= 0x35,
           let bytes = parseHex(Array(value[(i + 4)..<(i + 8)])) {
            guard let encoding = TextEncodings.encoding(codePage: multiByteCodePages[Int(value[i + 3] - 0x30)]) else { return false }
            let decoded = TextEncodings.decode(Data([UInt8(truncatingIfNeeded: bytes >> 8), UInt8(truncatingIfNeeded: bytes)]), encoding: encoding)
            sb.append(contentsOf: Array(decoded.utf16))
            i += 7
            return true
        }
        return false
    }

    /// The `%%` specials of AutoCAD text.
    private static func trySpecial(_ value: [UInt16], _ i: inout Int, _ sb: inout [UInt16]) -> Bool {
        if value[i] != 0x25 || i + 2 >= value.count || value[i + 1] != 0x25 { return false }
        let code = lowerInvariant(value[i + 2])
        switch code {
        case 0x64: sb.append(0xB0) // d → °
        case 0x63: sb.append(0xD8) // c → Ø
        case 0x70: sb.append(0xB1) // p → ±
        case 0x25: sb.append(0x25)
        case 0x75, 0x6F, 0x6B: break // underline / overline / strike-through toggles
        case 0x30...0x39:
            var end = i + 2
            while end < value.count && end < i + 5 && value[end] >= 0x30 && value[end] <= 0x39 { end += 1 }
            var number = 0
            for unit in value[(i + 2)..<end] { number = number * 10 + Int(unit - 0x30) }
            sb.append(UInt16(truncatingIfNeeded: number))
            i = end - 1
            return true
        default:
            return false
        }
        i += 2
        return true
    }

    // ───────────────────────── .NET parsing rules ─────────────────────────

    /// `char.ToLowerInvariant` for one UTF-16 unit.
    private static func lowerInvariant(_ unit: UInt16) -> UInt16 {
        guard let scalar = Unicode.Scalar(unit) else { return unit }
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        guard lower.count == 1, let first = lower.first, first.value <= 0xFFFF else { return unit }
        return UInt16(first.value)
    }

    /// White space accepted around numbers by `NumberStyles` (tab … carriage return and space).
    private static func trimNumberWhite(_ units: [UInt16]) -> [UInt16] {
        func isWhite(_ u: UInt16) -> Bool { u == 0x20 || (u >= 0x09 && u <= 0x0D) }
        var start = 0
        var end = units.count
        while start < end && isWhite(units[start]) { start += 1 }
        while end > start && isWhite(units[end - 1]) { end -= 1 }
        return Array(units[start..<end])
    }

    /// `int.TryParse(s, NumberStyles.HexNumber)`.
    private static func parseHex(_ units: [UInt16]) -> Int? {
        let digits = trimNumberWhite(units)
        guard !digits.isEmpty else { return nil }
        var value = 0
        for unit in digits {
            guard let scalar = Unicode.Scalar(unit), let digit = Int(String(Character(scalar)), radix: 16) else { return nil }
            value = value * 16 + digit
        }
        return value
    }

    /// `int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture)`.
    private static func parseInteger(_ units: [UInt16]) -> Int? {
        let s = String(utf16: trimNumberWhite(units))
        guard let first = s.utf8.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") || (first >= 0x30 && first <= 0x39),
              s.utf8.dropFirst().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let value = Int32(s) else { return nil }
        return Int(value)
    }

    /// `double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture)`.
    private static func parseFloat(_ units: [UInt16]) -> Double? {
        let s = String(utf16: trimNumberWhite(units))
        switch s {
        case "Infinity", "+Infinity", "∞", "+∞": return .infinity
        case "-Infinity", "-∞": return -.infinity
        case "NaN": return .nan
        default: break
        }
        var bytes = Array(s.utf8)[...]
        if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        var digits = 0
        while let b = bytes.first, b >= 0x30 && b <= 0x39 { digits += 1; bytes = bytes.dropFirst() }
        if bytes.first == UInt8(ascii: ".") {
            bytes = bytes.dropFirst()
            while let b = bytes.first, b >= 0x30 && b <= 0x39 { digits += 1; bytes = bytes.dropFirst() }
        }
        guard digits > 0 else { return nil }
        if let e = bytes.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
            var exponentDigits = 0
            while let b = bytes.first, b >= 0x30 && b <= 0x39 { exponentDigits += 1; bytes = bytes.dropFirst() }
            guard exponentDigits > 0 else { return nil }
        }
        guard bytes.isEmpty else { return nil }
        return Double(s.hasPrefix(".") || s.hasPrefix("-.") || s.hasPrefix("+.") ? s.replacingOccurrences(of: ".", with: "0.", options: [], range: s.range(of: ".")) : s)
    }
}

fileprivate extension String {
    init(utf16 units: [UInt16]) {
        self = String(decoding: units, as: UTF16.self)
    }
}
