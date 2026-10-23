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
}
