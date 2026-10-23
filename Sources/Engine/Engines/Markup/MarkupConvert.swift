// .NET number conversions the Markup readers rely on, so lengths and sizes come out as in Filee.

import Foundation

enum MarkupConvert {
    /// `(int)value` in .NET: truncates toward zero and saturates to the Int32 range (NaN → 0).
    static func int32(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= 2_147_483_647 { return 2_147_483_647 }
        if value <= -2_147_483_648 { return -2_147_483_648 }
        return Int(value)
    }

    /// `int.TryParse(text, out var n)` with the default style: optional surrounding white space (tab, line feeds,
    /// space) and sign, ASCII digits, within the Int32 range.
    static func tryParseInt(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int32(text.trimmingCharacters(in: whiteSpace)).map(Int.init)
    }

    private static let whiteSpace = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r ")

    /// `string.Equals(a, b, StringComparison.OrdinalIgnoreCase)`: UTF-16 units compared after simple upper-casing.
    static func equalsOrdinalIgnoreCase(_ a: String, _ b: String) -> Bool {
        let left = Markdown.chars(a), right = Markdown.chars(b)
        return left.count == right.count && zip(left, right).allSatisfy { $0 == $1 || $0.upperInvariant == $1.upperInvariant }
    }

    /// `WebUtility.HtmlEncode`: `< > " ' &` as entities, U+00A0–U+00FF and characters outside the BMP as decimal
    /// references.
    static func htmlEncode(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "&": result += "&amp;"
            default:
                if (0xA0...0xFF).contains(scalar.value) || scalar.value >= 0x10000 {
                    result += "&#\(scalar.value);"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// `Uri.UnescapeDataString`: %XX sequences that form UTF-8 are decoded, others stay escaped.
    static func unescapeDataString(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let units = Array(text.utf16)
        var output = ""
        var i = 0
        func hex(_ unit: UInt16) -> UInt8? {
            switch unit {
            case 0x30...0x39: UInt8(unit - 0x30)
            case 0x41...0x46: UInt8(unit - 0x37)
            case 0x61...0x66: UInt8(unit - 0x57)
            default: nil
            }
        }
        while i < units.count {
            var bytes: [UInt8] = []
            var escapes: [String] = []
            while i + 2 < units.count, units[i] == 0x25, let high = hex(units[i + 1]), let low = hex(units[i + 2]) {
                bytes.append(high << 4 | low)
                escapes.append(String(decoding: units[i..<i + 3], as: UTF16.self))
                i += 3
            }
            if !bytes.isEmpty {
                var parser = Unicode.UTF8.ForwardParser()
                var iterator = bytes.makeIterator()
                var consumed = 0
                loop: while true {
                    switch parser.parseScalar(from: &iterator) {
                    case .valid(let encoded):
                        output.unicodeScalars.append(Unicode.UTF8.decode(encoded))
                        consumed += encoded.count
                    case .error(let length):
                        output += escapes[consumed..<consumed + length].joined()
                        consumed += length
                    case .emptyInput:
                        break loop
                    }
                }
                continue
            }
            output += String(decoding: [units[i]], as: UTF16.self)
            i += 1
        }
        return output
    }
}
