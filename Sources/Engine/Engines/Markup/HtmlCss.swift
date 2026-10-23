// Port of Filee.Engines/Hwp/Hwpx/HtmlCss.cs: the small part of CSS the HTML reader understands — inline style=""
// declarations, simple stylesheet rules (tag, .class, tag.class), colours and lengths. Enough for the formatting
// e-books and saved web pages rely on (bold and italic classes, centred text, page breaks, first-line indents)
// without a full CSS engine.

import Foundation

/// Property → value pairs of one declaration block; property names compare case-insensitively.
struct CssDeclarations {
    private var values: [String: String] = [:]

    init() {}

    /// Parses "color: red; font-weight: bold" (later declarations win, !important is ignored).
    static func parse(_ text: String?) -> CssDeclarations {
        var result = CssDeclarations()
        guard let text, !text.allSatisfy(\.isWhitespace) else { return result }
        for declaration in text.components(separatedBy: ";") {
            guard let colon = declaration.firstIndex(of: ":"), colon != declaration.startIndex else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = declaration[declaration.index(after: colon)...]
                .replacingOccurrences(of: "!important", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !value.isEmpty { result[name] = value }
        }
        return result
    }

    subscript(name: String) -> String? {
        get { values[name.lowercased()] }
        set { values[name.lowercased()] = newValue }
    }

    func get(_ name: String) -> String? { self[name] }

    var count: Int { values.count }

    /// Lower-cased property names.
    var names: [String] { Array(values.keys) }

    /// Copies every declaration of `other` over this one.
    mutating func merge(_ other: CssDeclarations) {
        values.merge(other.values) { _, new in new }
    }
}

/// Rules of the document's style sheets that the reader can match without a full selector engine.
final class CssStyleSheet {
    /// Properties taken from style sheets. Colours and sizes are not: whole-book rules (body colour, base font size)
    /// would otherwise be copied onto every run.
    private static let sheetProperties: Set<String> = [
        "font-weight", "font-style", "text-decoration", "text-decoration-line", "vertical-align", "text-align",
        "display", "page-break-before", "page-break-after", "break-before", "break-after", "white-space",
        "text-indent", "list-style", "list-style-type", "font-variant",
    ]

    /// `tag` nil for any element; all `classes` required; classes count more than the tag name in `specificity`.
    private struct Rule {
        var tag: String?
        var classes: [String]
        var specificity: Int
        var order: Int
        var declarations: CssDeclarations
    }

    private var rules: [Rule] = []

    var isEmpty: Bool { rules.isEmpty }

    /// Adds the rules of a style sheet. @media, @font-face and other at-rules are skipped.
    func add(_ text: String) {
        let css = Array(Self.comment.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "").utf16)
        let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
        func string(_ range: Range<Int>) -> String { String(decoding: css[range], as: UTF16.self) }
        var position = 0
        while position < css.count {
            guard let openIndex = css[position...].firstIndex(of: open) else { break }
            let selectors = string(position..<openIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            // MatchingBrace: the index of the brace closing the block that starts at `openIndex`, or -1.
            var closeIndex = -1
            var depth = 0
            for index in openIndex..<css.count {
                if css[index] == open { depth += 1 } else if css[index] == close { depth -= 1; if depth == 0 { closeIndex = index; break } }
            }
            let body = string((openIndex + 1)..<max(openIndex + 1, closeIndex))
            position = closeIndex < 0 ? css.count : closeIndex + 1
            if selectors.hasPrefix("@") || body.contains("{") { continue } // at-rules (nested blocks): not applied

            var declarations = CssDeclarations.parse(body)
            for name in declarations.names where !Self.sheetProperties.contains(name) { declarations[name] = nil }
            if declarations.count == 0 { continue }
            for selector in selectors.components(separatedBy: ",") {
                if var rule = Self.parseSelector(selector.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    rule.order = rules.count
                    rule.declarations = declarations
                    rules.append(rule)
                }
            }
        }
    }

    /// Declarations that apply to an element, in cascade order (the last one wins).
    func match(_ tag: String, _ classes: [String]) -> CssDeclarations {
        var result = CssDeclarations()
        if rules.isEmpty { return result }
        let matching = rules.filter { ($0.tag == nil || $0.tag == tag) && $0.classes.allSatisfy(classes.contains) }
            .sorted { ($0.specificity, $0.order) < ($1.specificity, $1.order) }
        for rule in matching { result.merge(rule.declarations) }
        return result
    }

    /// "p", ".note", "span.bold", "p.a.b"; anything else (descendants, ids, pseudo classes) is skipped.
    private static func parseSelector(_ selector: String) -> Rule? {
        guard simpleSelector.firstMatch(in: selector, range: NSRange(selector.startIndex..., in: selector)) != nil else { return nil }
        let parts = selector.components(separatedBy: ".")
        let tag = parts[0].isEmpty || parts[0] == "*" ? nil : parts[0].lowercased()
        let classes = Array(parts.dropFirst())
        return Rule(tag: tag, classes: classes, specificity: classes.count * 10 + (tag == nil ? 0 : 1), order: 0, declarations: CssDeclarations())
    }

    private static let comment = try! NSRegularExpression(pattern: #"/\*.*?\*/"#, options: .dotMatchesLineSeparators)
    private static let simpleSelector = try! NSRegularExpression(pattern: #"^(\*|[A-Za-z][\w-]*)?(\.[\w-]+)*$"#)
}

/// CSS values: colours and lengths.
enum CssValues {
    private static let namedColors: [String: String] = [
        "black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#008000", "blue": "#0000FF",
        "yellow": "#FFFF00", "gray": "#808080", "grey": "#808080", "silver": "#C0C0C0", "maroon": "#800000",
        "purple": "#800080", "fuchsia": "#FF00FF", "magenta": "#FF00FF", "lime": "#00FF00", "olive": "#808000",
        "navy": "#000080", "teal": "#008080", "aqua": "#00FFFF", "cyan": "#00FFFF", "orange": "#FFA500",
        "brown": "#A52A2A", "pink": "#FFC0CB", "gold": "#FFD700", "darkred": "#8B0000", "darkblue": "#00008B",
        "darkgreen": "#006400", "darkgray": "#A9A9A9", "darkgrey": "#A9A9A9", "lightgray": "#D3D3D3",
        "lightgrey": "#D3D3D3", "dimgray": "#696969", "dimgrey": "#696969", "crimson": "#DC143C", "indigo": "#4B0082",
        "violet": "#EE82EE", "coral": "#FF7F50", "tomato": "#FF6347", "steelblue": "#4682B4", "royalblue": "#4169E1",
        "lightblue": "#ADD8E6", "lightyellow": "#FFFFE0", "lightgreen": "#90EE90", "whitesmoke": "#F5F5F5",
        "beige": "#F5F5DC", "ivory": "#FFFFF0",
    ]

    /// "#RRGGBB" for #rgb, #rrggbb, rgb()/rgba() and common colour names; nil for anything else (transparent,
    /// inherit, gradients, ...).
    static func color(_ value: String?) -> String? {
        guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let named = namedColors[text.lowercased()] { return named }
        if text.hasPrefix("#") {
            let hex = Array(text.unicodeScalars.dropFirst())
            guard hex.allSatisfy(\.properties.isASCIIHexDigit) else { return nil }
            if hex.count == 3 || hex.count == 4 { return "#" + hex.prefix(3).map { "\($0)\($0)" }.joined().uppercased() }
            if hex.count == 6 || hex.count == 8 { return "#" + String(String.UnicodeScalarView(hex.prefix(6))).uppercased() }
            return nil
        }
        if text.lowercased().hasPrefix("rgb"), let open = text.firstIndex(of: "("), open != text.startIndex,
           let close = text.firstIndex(of: ")"), close > open {
            let parts = text[text.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            guard parts.count >= 3 else { return nil }
            var channels: [Int] = []
            for part in parts.prefix(3) {
                let percent = part.hasSuffix("%")
                guard let number = tryParseDouble(String(part).trimmingTrailing("%")) else { return nil }
                channels.append(MarkupConvert.int32(clamp((percent ? number * 2.55 : number).rounded(.toNearestOrEven), 0, 255)))
            }
            return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
        }
        return nil
    }

    /// The first colour inside a shorthand such as "background: #eee url(x.png)".
    static func firstColor(_ value: String?) -> String? {
        if let direct = color(value) { return direct }
        for token in (value ?? "").split(separator: " ") {
            if let found = color(String(token)) { return found }
        }
        return nil
    }

    /// A length in HWPUNIT. `em` is the size of 1em (and the base of %) in HWPUNIT; nil when the value is not a
    /// length (auto, inherit, ...).
    static func length(_ value: String?, _ em: Double) -> Int? {
        guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
        let text = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars)
        var split = 0
        while split < text.count && (text[split].properties.generalCategory == .decimalNumber || text[split] == "." || text[split] == "-" || text[split] == "+") {
            split += 1
        }
        guard split > 0, let number = tryParseDouble(String(String.UnicodeScalarView(text[..<split]))) else { return nil }
        let result: Double? = switch String(String.UnicodeScalarView(text[split...])).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "em", "rem": number * em
        case "ex", "ch": number * em / 2
        case "%": number * em / 100
        case "pt": number * 100
        case "px", "": number * HwpxUnits.perPixel
        case "in": number * 7200
        case "cm": number * HwpxUnits.perMm * 10
        case "mm": number * HwpxUnits.perMm
        case "pc": number * 1200
        default: nil
        }
        return result.map { MarkupConvert.int32($0.rounded(.toNearestOrEven)) }
    }

    /// A font size in 1/100 pt, relative sizes based on `parent` (1/100 pt).
    static func fontSize(_ value: String?, _ parent: Int) -> Int? {
        guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
        let factor: Double? = switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xx-small": 0.6
        case "x-small": 0.75
        case "small": 0.89
        case "medium": 1.0
        case "large": 1.2
        case "x-large": 1.5
        case "xx-large": 2.0
        case "xxx-large": 3.0
        case "smaller": 0.83
        case "larger": 1.2
        default: nil
        }
        if let factor { return MarkupConvert.int32((Double(parent) * factor).rounded(.toNearestOrEven)) }
        // HWPUNIT and 1/100 pt are the same scale (1 pt = 100 HWPUNIT), so length() fits font sizes directly.
        guard let size = length(value, Double(parent)), size > 0 else { return nil }
        return min(max(size, 100), 20000)
    }

    /// `double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture)`: optional white space and sign,
    /// digits with an optional decimal point and exponent, or Infinity / NaN; no hexadecimal or "inf" forms.
    static func tryParseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r "))
        guard floatPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasSuffix("infinity") { return lowered.hasPrefix("-") ? -.infinity : .infinity }
        if lowered.hasSuffix("nan") { return .nan }
        return Double(trimmed)
    }

    private static let floatPattern = try! NSRegularExpression(
        pattern: #"^(?:[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[+-]?(?i:infinity)|(?i:nan))$"#)

    /// Math.Clamp: NaN passes through.
    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value < low ? low : value > high ? high : value
    }
}

private extension String {
    /// `TrimEnd(ch)`.
    func trimmingTrailing(_ character: Character) -> String {
        var result = self
        while result.last == character { result.removeLast() }
        return result
    }
}
