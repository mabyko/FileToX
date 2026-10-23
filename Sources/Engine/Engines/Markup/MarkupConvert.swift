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
}
