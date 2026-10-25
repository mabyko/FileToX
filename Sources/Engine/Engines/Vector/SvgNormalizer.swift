// Prepares an SVG for AppKit's SVG renderer (CoreSVG), which draws shapes, gradients, patterns, clips, masks and filters
// but not what Svg.Skia (Filee's renderer) does with text and CSS:
//
// • CSS: <style> rules (type, class and id selectors, descendant and child combinators) and style attributes become
//   presentation attributes, with the cascade's order (attributes < rules by specificity < style attribute, !important
//   last) and the `font` shorthand expanded. CoreSVG ignores the shorthand and keyword weights.
// • Text: every <text> is laid out with Core Text — tspans with their own fill, size, weight and style, x/y/dx/dy,
//   text-anchor per chunk, letter-spacing, baseline-shift, underline/overline/line-through, xml:space — and replaced by
//   its glyph outlines, the way Filee's OutlinedTextPlayback drew text for PDF output. Real bold and italic faces are
//   used where the family has them (CoreSVG ignores font-style), synthesized (stroke, slant) where it has not, and
//   missing characters fall back to other fonts like Skia's font manager. Vertical text uses mixed upright/sideways glyphs.
//   Text on a path stays text.
// • Files: images next to the drawing are embedded; network references are dropped (converting must not fetch anything).
//
// Anything that can't be parsed leaves the file as it was.

import AppKit
import CoreText
import Foundation

enum SvgNormalizer {
    private static let svg = XNamespace("http://www.w3.org/2000/svg")
    private static let xlink = XNamespace("http://www.w3.org/1999/xlink")

    /// The SVG ready for CoreSVG; `data` unchanged when it can't be parsed.
    static func normalize(_ data: Data, baseDirectory: String?) -> Data {
        guard let document = try? XDocument.load(data: data, preserveWhitespace: true), document.root.name.localName == "svg" else { return data }
        let root = document.root
        applyStyles(root)
        canonicalizeReferences(root)
        resolveReferences(root, baseDirectory: baseDirectory)
        outlineText(root, inherited: TextStyle())
        return (try? document.data(indent: false)) ?? data
    }

    // ───────────────────────── CSS ─────────────────────────

    /// SVG 1.1 presentation attributes (plus paint-order and vector-effect): CSS properties written back as attributes.
    private static let presentationAttributes: Set<String> = [
        "alignment-baseline", "baseline-shift", "clip", "clip-path", "clip-rule", "color", "color-interpolation", "color-interpolation-filters",
        "color-profile", "color-rendering", "cursor", "direction", "display", "dominant-baseline", "enable-background", "fill", "fill-opacity",
        "fill-rule", "filter", "flood-color", "flood-opacity", "font-family", "font-size", "font-size-adjust", "font-stretch", "font-style",
        "font-variant", "font-weight", "glyph-orientation-horizontal", "glyph-orientation-vertical", "image-rendering", "kerning",
        "letter-spacing", "lighting-color", "marker-end", "marker-mid", "marker-start", "mask", "opacity", "overflow", "pointer-events",
        "shape-rendering", "stop-color", "stop-opacity", "stroke", "stroke-dasharray", "stroke-dashoffset", "stroke-linecap",
        "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width", "text-anchor", "text-decoration", "text-orientation", "text-rendering",
        "unicode-bidi", "visibility", "word-spacing", "writing-mode", "paint-order", "vector-effect",
    ]

    private struct Rule {
        let selector: [(combinator: Character, compound: Compound)]
        let specificity: Int
        let declarations: [(property: String, value: String, important: Bool)]
        let order: Int
    }

    private struct Compound {
        var element: String?
        var id: String?
        var classes: [String] = []

        func matches(_ e: XElement) -> Bool {
            if let element, element != "*", e.name.localName != element { return false }
            if let id, e.attributeValue("id") != id { return false }
            if !classes.isEmpty {
                let own = Set((e.attributeValue("class") ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
                if !classes.allSatisfy(own.contains) { return false }
            }
            return true
        }
    }

    private static func applyStyles(_ root: XElement) {
        var rules: [Rule] = []
        for style in root.descendantsAndSelf().filter({ $0.name.localName == "style" }) {
            let type = style.attributeValue("type") ?? "text/css"
            if type.isEmpty || type.lowercased() == "text/css" { rules += parseStyleSheet(style.value, startOrder: rules.count) }
            style.remove()
        }
        for element in root.descendantsAndSelf() {
            // property → (value, priority: important, origin, specificity, order)
            var cascade: [String: (value: String, rank: [Int])] = [:]
            func apply(_ property: String, _ value: String, _ rank: [Int]) {
                for (name, expanded) in expand(property, value) where cascade[name].map({ $0.rank.lexicographicallyPrecedes(rank) || $0.rank == rank }) ?? true {
                    cascade[name] = (expanded, rank)
                }
            }
            // The obsolete orientation attribute is a shorthand for the modern property, before inheritance.
            for name in ["glyph-orientation-vertical", "text-orientation"] {
                if let value = element.attributeValue(XName(name)) { apply(name, value, [0, 0, 0, 0]) }
            }
            for rule in rules where matches(rule.selector, element) {
                for declaration in rule.declarations { apply(declaration.property, declaration.value, [declaration.important ? 1 : 0, 1, rule.specificity, rule.order]) }
            }
            if let inline = element.attributeValue("style") {
                for declaration in parseDeclarations(inline) { apply(declaration.property, declaration.value, [declaration.important ? 1 : 0, 2, 0, 0]) }
                element.setAttributeValue("style", nil)
            }
            var leftover: [String] = []
            for (property, entry) in cascade.sorted(by: { $0.key < $1.key }) {
                if presentationAttributes.contains(property) {
                    element.setAttributeValue(XName(property), entry.value)
                } else {
                    leftover.append("\(property):\(entry.value)")
                }
            }
            if !leftover.isEmpty { element.setAttributeValue("style", leftover.joined(separator: ";")) }
            // Presentation attributes CoreSVG reads differently.
            if element.attributeValue("font") != nil {
                for (name, value) in expand("font", element.attributeValue("font")!) { element.setAttributeValue(XName(name), value) }
                element.setAttributeValue("font", nil)
            }
            if let weight = element.attributeValue("font-weight") {
                // Resolve relative weights after the cascade, against the parent's computed weight.
                var parent = element.parent
                while let ancestor = parent, ancestor.attributeValue("font-weight") == nil { parent = ancestor.parent }
                let inherited = parent?.attributeValue("font-weight").flatMap(Int.init) ?? 400
                element.setAttributeValue("font-weight", String(numericWeight(weight, parent: inherited)))
            }
        }
    }

    private static func matches(_ selector: [(combinator: Character, compound: Compound)], _ element: XElement) -> Bool {
        guard let last = selector.last, last.compound.matches(element) else { return false }
        var current: XElement? = element
        var index = selector.count - 1
        while index > 0 {
            let combinator = selector[index].combinator
            let wanted = selector[index - 1].compound
            if combinator == ">" {
                guard let parent = current?.parent, wanted.matches(parent) else { return false }
                current = parent
            } else {
                var ancestor = current?.parent
                while let candidate = ancestor, !wanted.matches(candidate) { ancestor = candidate.parent }
                guard let found = ancestor else { return false }
                current = found
            }
            index -= 1
        }
        return true
    }

    private static func parseStyleSheet(_ css: String, startOrder: Int) -> [Rule] {
        let text = stripComments(css)
        var rules: [Rule] = []
        var index = text.startIndex
        func skipBlock() {
            var depth = 0
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 } else if text[index] == "}" { depth -= 1; if depth <= 0 { index = text.index(after: index); return } }
                index = text.index(after: index)
            }
        }
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            if text[index] == "@" {
                // @media, @font-face, @import …: not applied.
                while index < text.endIndex, text[index] != "{", text[index] != ";" { index = text.index(after: index) }
                if index < text.endIndex, text[index] == "{" { skipBlock() } else if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            guard let open = text[index...].firstIndex(of: "{") else { break }
            let selectorText = String(text[index..<open])
            guard let close = text[open...].firstIndex(of: "}") else { break }
            let declarations = parseDeclarations(String(text[text.index(after: open)..<close]))
            index = text.index(after: close)
            for part in selectorText.split(separator: ",") {
                guard let (selector, specificity) = parseSelector(String(part)) else { continue }
                rules.append(Rule(selector: selector, specificity: specificity, declarations: declarations, order: startOrder + rules.count))
            }
        }
        return rules
    }

    private static func stripComments(_ css: String) -> String {
        var result = css
        while let start = result.range(of: "/*") {
            guard let end = result.range(of: "*/", range: start.upperBound..<result.endIndex) else { result.removeSubrange(start.lowerBound...); break }
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    /// "g > text.title #a" → compounds with combinators; nil for selectors with attributes, pseudo-classes or siblings.
    private static func parseSelector(_ text: String) -> ([(combinator: Character, compound: Compound)], Int)? {
        var result: [(combinator: Character, compound: Compound)] = []
        var specificity = 0
        var combinator: Character = " "
        let tokens = text.replacingOccurrences(of: ">", with: " > ").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        for token in tokens {
            if token == ">" { combinator = ">"; continue }
            if token.contains(where: { "[]:+~(".contains($0) }) { return nil }
            var compound = Compound()
            var current = ""
            var kind: Character = "e"
            func flush() {
                guard !current.isEmpty else { return }
                switch kind {
                case "#": compound.id = current; specificity += 100
                case ".": compound.classes.append(current); specificity += 10
                default: compound.element = current; if current != "*" { specificity += 1 }
                }
                current = ""
            }
            for character in token {
                if character == "#" || character == "." { flush(); kind = character } else { current.append(character) }
            }
            flush()
            result.append((combinator, compound))
            combinator = " "
        }
        return result.isEmpty ? nil : (result, specificity)
    }

    private static func parseDeclarations(_ text: String) -> [(property: String, value: String, important: Bool)] {
        var result: [(property: String, value: String, important: Bool)] = []
        var depth = 0, quote: Character?
        var current = ""
        func flush() {
            defer { current = "" }
            guard let colon = current.firstIndex(of: ":") else { return }
            let property = current[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = current[current.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let bang = value.range(of: "!important", options: [.caseInsensitive, .backwards]) {
                important = true
                value = value[..<bang.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !property.isEmpty && !value.isEmpty { result.append((property, value, important)) }
        }
        for character in stripComments(text) {
            if let open = quote { if character == open { quote = nil } } else if character == "\"" || character == "'" { quote = character }
            if quote == nil {
                if character == "(" { depth += 1 } else if character == ")" { depth -= 1 } else if character == ";" && depth == 0 { flush(); continue }
            }
            current.append(character)
        }
        flush()
        return result
    }

    /// Declarations as SVG properties, with the `font` shorthand expanded.
    private static func expand(_ property: String, _ value: String) -> [(String, String)] {
        switch property {
        case "font":
            return expandFont(value)
        case "glyph-orientation-vertical":
            let keyword = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let orientation = ["auto": "mixed", "0": "upright", "0deg": "upright", "90": "sideways", "90deg": "sideways",
                                     "inherit": "inherit", "initial": "initial", "unset": "unset"][keyword] else { return [] }
            return [("text-orientation", orientation)]
        default:
            return [(property, value)]
        }
    }

    /// The CSS `font` shorthand: [style] [variant] [weight] [stretch] size[/line-height] family. The weight stays as
    /// written; `applyStyles` resolves bolder and lighter against the parent's computed weight after the cascade.
    private static func expandFont(_ value: String) -> [(String, String)] {
        var style = "normal", variant = "normal", weight = "400", stretch = "normal"
        var rest = value.trimmingCharacters(in: .whitespaces)
        while let space = rest.firstIndex(where: \.isWhitespace) {
            let token = String(rest[..<space]).lowercased()
            if ["italic", "oblique"].contains(token) { style = token }
            else if token == "small-caps" { variant = token }
            else if ["bold", "bolder", "lighter"].contains(token) || (Int(token).map { (1...1000).contains($0) } ?? false) { weight = token }
            else if token.hasSuffix("condensed") || token.hasSuffix("expanded") { stretch = token }
            else if token != "normal" { break }
            rest = rest[space...].trimmingCharacters(in: .whitespaces)
        }
        // Size (and line height), then the family list.
        guard let end = rest.firstIndex(where: \.isWhitespace) else { return [] }
        let size = String(rest[..<end]).split(separator: "/").first.map(String.init) ?? ""
        var family = rest[end...].trimmingCharacters(in: .whitespaces)
        if family.hasPrefix("/"), let next = family.dropFirst().firstIndex(where: \.isWhitespace) { family = family[next...].trimmingCharacters(in: .whitespaces) }
        guard !size.isEmpty, !family.isEmpty else { return [] }
        return [("font-style", style), ("font-variant", variant), ("font-weight", weight), ("font-stretch", stretch), ("font-size", size), ("font-family", family)]
    }

    private static func numericWeight(_ value: String, parent: Int) -> Int {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "normal", "initial": 400
        case "bold": 700
        case "bolder": parent < 350 ? 400 : parent < 550 ? 700 : max(parent, 900)
        case "lighter": parent < 100 ? parent : parent < 550 ? 100 : parent < 750 ? 400 : 700
        case let number: Int(number).map { min(max($0, 1), 1000) } ?? parent
        }
    }

    // ───────────────────────── Files ─────────────────────────

    /// SVG2 href wins even when empty or blocked; SkSVGDOM also requires the literal xlink prefix.
    private static func canonicalizeReferences(_ root: XElement) {
        let elements = root.descendantsAndSelf()
        guard elements.contains(where: { element in
            element.name.namespaceName == svg.namespaceName &&
                (element.attributeValue("href") != nil || element.attributeValue(xlink + "href") != nil)
        }) else { return }
        for element in elements {
            for attribute in element.attributes where attribute.isNamespaceDeclaration &&
                (attribute.value == xlink.namespaceName || attribute.name.localName == "xlink") {
                element.setAttributeValue(attribute.name, nil)
            }
            if element.name.namespaceName == svg.namespaceName, let href = element.attributeValue("href") {
                element.setAttributeValue(xlink + "href", href)
                element.setAttributeValue("href", nil)
            }
        }
        root.setAttributeValue(XNamespace.xmlns + "xlink", xlink.namespaceName)
    }

    /// Embeds images next to the drawing (Svg.Skia read local files) and drops references to anything else.
    private static func resolveReferences(_ root: XElement, baseDirectory: String?) {
        for element in root.descendantsAndSelf() {
            for name in [xlink + "href", XName("href")] {
                guard let href = element.attributeValue(name)?.trimmingCharacters(in: .whitespaces), !href.hasPrefix("#"), !href.lowercased().hasPrefix("data:") else { continue }
                var replacement: String?
                if element.name.localName == "image", let path = localPath(href, baseDirectory), let data = FileManager.default.contents(atPath: path),
                   let type = imageType(data) {
                    replacement = "data:\(type);base64," + data.base64EncodedString()
                }
                element.setAttributeValue(name, replacement)
            }
        }
    }

    private static func localPath(_ href: String, _ baseDirectory: String?) -> String? {
        if href.lowercased().hasPrefix("file://") { return URL(string: href)?.path }
        if href.contains("://") || href.hasPrefix("//") { return nil }
        let decoded = href.removingPercentEncoding ?? href
        if decoded.hasPrefix("/") { return decoded }
        return baseDirectory.map { FilePath.fullPath(FilePath.combine($0, decoded)) }
    }

    private static func imageType(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if head.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if head.count >= 12, Array(head[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if String(decoding: data.prefix(1024), as: UTF8.self).lowercased().contains("<svg") { return "image/svg+xml" }
        return nil
    }

    // ───────────────────────── Text ─────────────────────────

    /// Inherited text properties (attribute values).
    private struct TextStyle {
        var values: [String: String] = [:]

        static let inherited: Set<String> = [
            "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin",
            "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "paint-order", "visibility", "color", "font-family", "font-size",
            "font-weight", "font-style", "font-stretch", "font-variant", "letter-spacing", "word-spacing", "text-anchor", "text-decoration",
            "direction", "writing-mode", "text-orientation", "xml:space",
        ]

        func adding(_ element: XElement) -> TextStyle {
            var style = self
            for attribute in element.attributes {
                let name = attribute.name.namespaceName == XNamespace.xml.namespaceName ? "xml:" + attribute.name.localName : attribute.name.localName
                let keyword = attribute.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard TextStyle.inherited.contains(name), !["inherit", "unset"].contains(keyword) else { continue }
                if keyword == "initial" { style.values[name] = nil; continue }
                if name == "font-size" {
                    style.values[name] = String(SvgNormalizer.length(attribute.value, fontSize: style.fontSize, percentOf: style.fontSize) ?? style.fontSize)
                } else if name == "font-weight" {
                    style.values[name] = String(SvgNormalizer.numericWeight(attribute.value, parent: style.weight))
                } else {
                    style.values[name] = attribute.value
                }
            }
            return style
        }

        var vertical: Bool { ["tb", "tb-rl", "vertical-rl", "vertical-lr"].contains((values["writing-mode"] ?? "").lowercased()) }

        var verticalOrientation: String { values["text-orientation"]?.lowercased() ?? "mixed" }

        var fontSize: Double { values["font-size"].flatMap(Double.init) ?? 16 }
        var weight: Int { values["font-weight"].flatMap(Int.init) ?? 400 }
        var italic: Bool { ["italic", "oblique"].contains(values["font-style"]?.lowercased() ?? "") }
    }

    /// Walks the tree and replaces every <text> by its outlines.
    private static func outlineText(_ element: XElement, inherited: TextStyle) {
        let style = inherited.adding(element)
        if element.name.localName == "text" {
            guard let outlined = TextLayout(element, style).outlined() else { return }
            if element.parent?.name.localName == "clipPath" {
                // Clip paths take shapes, not groups: the outlines with the text's transform and clip.
                let paths = outlined.elements()
                for path in paths {
                    for name in ["transform", "clip-path", "clip-rule"] where outlined.attributeValue(XName(name)) != nil {
                        path.setAttributeValue(XName(name), outlined.attributeValue(XName(name)))
                    }
                }
                for path in paths.reversed() { element.addAfterSelf(XElement(copying: path)) }
                element.remove()
            } else {
                element.replaceWith(outlined)
            }
            return
        }
        for child in element.elements() { outlineText(child, inherited: style) }
    }

    /// A length in user units: px, pt, pc, mm, cm, in, em, ex, %.
    static func length(_ text: String, fontSize: Double, percentOf base: Double) -> Double? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("px", 1), ("pt", 4.0 / 3), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54), ("in", 96), ("em", fontSize), ("ex", fontSize / 2), ("%", base / 100)]
        for (unit, factor) in units where value.hasSuffix(unit) {
            return Double(value.dropLast(unit.count)).map { $0 * factor }
        }
        if let named = ["xx-small": 9.0, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32][value] { return named }
        if value == "larger" { return fontSize * 1.2 }
        if value == "smaller" { return fontSize / 1.2 }
        return Double(value)
    }

    private static func lengths(_ text: String?, fontSize: Double) -> [Double] {
        guard let text else { return [] }
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { length(String($0), fontSize: fontSize, percentOf: 0) }
    }

    /// One <text> element laid out as runs of equally styled characters.
    private final class TextLayout {
        struct Run {
            var text: String
            var style: TextStyle
            var font: CTFont
            var x = 0.0, y = 0.0
            var width = 0.0
            var startsChunk = false
            var anchor = "start"
            var opacity: String?
            var vertical = false
            var baselineShift = 0.0
        }

        let element: XElement
        let style: TextStyle
        var runs: [Run] = []
        var penX = 0.0, penY = 0.0
        var baselineShift = 0.0
        var pendingX: [Double] = [], pendingY: [Double] = [], pendingDX: [Double] = [], pendingDY: [Double] = []
        var lastWasSpace = true
        var unsupported = false

        init(_ element: XElement, _ style: TextStyle) {
            self.element = element
            self.style = style
        }

        /// The outlines in a group carrying the text's own attributes, or nil to leave the text to CoreSVG.
        func outlined() -> XElement? {
            if element.descendants().contains(where: { $0.name.localName == "textPath" }) { return nil }
            collect(element, style, isRoot: true)
            if unsupported { return nil }
            if style.values["xml:space"] != "preserve", let last = runs.indices.last {
                runs[last].text = String(runs[last].text.reversed().drop { $0 == " " }.reversed())
            }
            // shortcut: styled vertical bidi chunks stay with CoreSVG until shaping spans the whole anchored chunk.
            var chunkRuns = 0, bidirectional = false
            for run in runs where !run.text.isEmpty && run.vertical {
                if run.startsChunk { chunkRuns = 0; bidirectional = false }
                chunkRuns += 1
                if run.style.verticalOrientation != "upright" {
                    bidirectional = bidirectional || run.style.values["direction"]?.lowercased() == "rtl"
                        || SvgNormalizer.bidirectionalCharacters.firstMatch(in: run.text, range: NSRange(location: 0, length: (run.text as NSString).length)) != nil
                }
                if chunkRuns > 1 && bidirectional { return nil }
            }
            measure()
            anchorChunks()
            return build()
        }

        private func collect(_ node: XElement, _ inherited: TextStyle, isRoot: Bool) {
            let style = isRoot ? inherited : inherited.adding(node)
            if !isRoot && node.attributeValue("display") == "none" { return }
            // shortcut: mixed vertical/horizontal inlines stay with CoreSVG until orthogonal inline layout is implemented.
            if self.style.vertical && !style.vertical { unsupported = true }
            if self.style.vertical, let bidi = node.attributeValue("unicode-bidi"), bidi.lowercased() != "normal" { unsupported = true }
            let size = style.fontSize
            // Positions of the element apply to its first characters.
            let x = SvgNormalizer.lengths(node.attributeValue("x"), fontSize: size), y = SvgNormalizer.lengths(node.attributeValue("y"), fontSize: size)
            if !x.isEmpty { pendingX = x }
            if !y.isEmpty { pendingY = y }
            pendingDX += SvgNormalizer.lengths(node.attributeValue("dx"), fontSize: size)
            pendingDY += SvgNormalizer.lengths(node.attributeValue("dy"), fontSize: size)
            if node.attributeValue("rotate") != nil { unsupported = true }
            var shift = 0.0
            switch node.attributeValue("baseline-shift") {
            case "super": shift = size * 0.33
            case "sub": shift = -size * 0.2
            case let value?: shift = SvgNormalizer.length(value, fontSize: size, percentOf: size) ?? 0
            case nil: break
            }
            let inheritedShift = baselineShift
            baselineShift += shift
            defer { baselineShift = inheritedShift }
            for child in node.nodes {
                switch child {
                case .element(let element) where ["tspan", "a", "textPath"].contains(element.name.localName):
                    collect(element, style, isRoot: false)
                case .text(let text), .cdata(let text):
                    add(text, style, opacity: isRoot ? nil : node.attributeValue("opacity"))
                default:
                    break
                }
            }
        }

        /// Adds characters with SVG's white-space handling; characters with their own x/y/dx/dy start runs of their own.
        private func add(_ raw: String, _ inherited: TextStyle, opacity: String?) {
            var style = inherited
            if !self.style.vertical {
                style.values.removeValue(forKey: "text-orientation")
                style.values.removeValue(forKey: "glyph-orientation-vertical")
            }
            let preserve = style.values["xml:space"] == "preserve"
            var text = ""
            for character in raw {
                var c = character
                if c == "\n" || c == "\r" || c == "\r\n" { if preserve { c = " " } else { continue } }
                if c == "\t" { c = " " }
                if c == " " && !preserve {
                    if lastWasSpace { continue }
                    lastWasSpace = true
                } else {
                    lastWasSpace = c == " "
                }
                text.append(c)
            }
            for character in text {
                let positioned = !pendingX.isEmpty || !pendingY.isEmpty || !pendingDX.isEmpty || !pendingDY.isEmpty
                // Upright cursive scripts use isolated forms, so each grapheme is shaped separately.
                if positioned || (self.style.vertical && style.verticalOrientation == "upright") || runs.isEmpty || runs[runs.count - 1].style.values != style.values || runs[runs.count - 1].opacity != opacity || runs[runs.count - 1].baselineShift != baselineShift {
                    var run = Run(text: "", style: style, font: SvgNormalizer.font(style), opacity: opacity)
                    run.vertical = self.style.vertical
                    run.baselineShift = baselineShift
                    if run.vertical {
                        if let x = pendingX.first { penX = x; run.startsChunk = true; pendingX.removeFirst() }
                        if let y = pendingY.first { run.y = y; run.startsChunk = true; pendingY.removeFirst() } else { run.y = .nan }
                        if let dx = pendingDX.first { penX += dx; pendingDX.removeFirst() }
                        if let dy = pendingDY.first { run.width = dy; pendingDY.removeFirst() }
                        run.x = penX + baselineShift
                    } else {
                        if let x = pendingX.first { run.x = x; run.startsChunk = true; pendingX.removeFirst() } else { run.x = .nan }
                        if let y = pendingY.first { penY = y; pendingY.removeFirst() }
                        if let dx = pendingDX.first { run.width = dx; pendingDX.removeFirst() }
                        if let dy = pendingDY.first { penY += dy; pendingDY.removeFirst() }
                        run.y = penY - baselineShift
                    }
                    run.anchor = style.values["text-anchor"] ?? "start"
                    if run.vertical && style.verticalOrientation != "upright" && style.values["direction"]?.lowercased() == "rtl" {
                        if run.anchor == "start" { run.anchor = "end" } else if run.anchor == "end" { run.anchor = "start" }
                    }
                    runs.append(run)
                }
                runs[runs.count - 1].text.append(character)
            }
        }

        /// Pen positions and advances. A run's `width` holds its inline-axis offset until measured.
        private func measure() {
            penX = 0
            penY = 0
            for i in runs.indices {
                if runs[i].vertical {
                    if !runs[i].y.isNaN { penY = runs[i].y }
                    penY += runs[i].width
                    runs[i].y = penY
                    runs[i].width = SvgNormalizer.advance(runs[i].text, runs[i].font, runs[i].style, vertical: true)
                    penY += runs[i].width
                    continue
                }
                let dx = runs[i].width
                if !runs[i].x.isNaN { penX = runs[i].x }
                penX += dx
                runs[i].x = penX
                runs[i].width = SvgNormalizer.advance(runs[i].text, runs[i].font, runs[i].style)
                penX += runs[i].width
            }
            if let first = runs.indices.first { runs[first].startsChunk = true }
        }

        /// text-anchor middle / end moves every run of a chunk along its inline axis.
        private func anchorChunks() {
            var start = 0
            while start < runs.count {
                var end = start + 1
                while end < runs.count && !runs[end].startsChunk { end += 1 }
                let vertical = runs[start].vertical
                let left = vertical ? runs[start].y : runs[start].x
                let right = (vertical ? runs[end - 1].y : runs[end - 1].x) + runs[end - 1].width
                let shift: Double = switch runs[start].anchor { case "middle": -(right - left) / 2; case "end": -(right - left); default: 0 }
                for i in start..<end { if vertical { runs[i].y += shift } else { runs[i].x += shift } }
                start = end
            }
        }

        private func build() -> XElement {
            let group = XElement(SvgNormalizer.svg + "g")
            // The text's own (not inherited) attributes stay on the group: id, transform, clip-path, mask, filter, opacity …
            let textAttributes: Set<String> = ["x", "y", "dx", "dy", "rotate", "textLength", "lengthAdjust", "font-family", "font-size", "font-weight",
                                               "font-style", "font-stretch", "font-variant", "letter-spacing", "word-spacing", "text-anchor",
                                               "text-decoration", "baseline-shift", "dominant-baseline", "alignment-baseline", "kerning"]
            for attribute in element.attributes where !textAttributes.contains(attribute.name.localName) && attribute.name.namespaceName != XNamespace.xml.namespaceName {
                group.setAttributeValue(attribute.name, attribute.value)
            }
            for run in runs where !run.text.isEmpty && run.style.values["visibility"] != "hidden" {
                for node in SvgNormalizer.outline(run) { group.add(node) }
            }
            return group
        }
    }

    /// The font of a text style: the first installed family of the list (generic names mapped), the weight and slant asked for.
    private static func font(_ style: TextStyle) -> CTFont {
        let families = (style.values["font-family"] ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
        let generic: [String: String] = ["serif": "Times New Roman", "sans-serif": "Helvetica", "monospace": "Courier", "cursive": "Apple Chancery",
                                         "fantasy": "Papyrus", "system-ui": "Helvetica Neue"]
        let size = CGFloat(style.fontSize)
        var traits: [CFString: Any] = [kCTFontWeightTrait: cssWeight(style.weight)]
        if style.italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        for family in families + ["Helvetica"] {
            let name = generic[family.lowercased()] ?? family
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name, kCTFontTraitsAttribute: traits] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            if (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(name) == .orderedSame { return font }
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func cssWeight(_ weight: Int) -> CGFloat {
        let table: [(Int, CGFloat)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        return table.min { abs($0.0 - weight) < abs($1.0 - weight) }!.1
    }

    private static let uprightCharacters = try! NSRegularExpression(pattern: "^[\\p{vo=U}\\p{vo=Tu}\\p{vo=Tr}]")
    private static let bidirectionalCharacters = try! NSRegularExpression(pattern: "[\\p{bc=R}\\p{bc=AL}\\p{Bidi_Control}]")

    private static func line(_ text: String, _ font: CTFont, _ style: TextStyle, vertical: Bool) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font]
        if let spacing = style.values["letter-spacing"], spacing != "normal",
           let value = length(spacing, fontSize: style.fontSize, percentOf: style.fontSize) {
            attributes[.init(kCTKernAttributeName as String)] = value
        }
        guard vertical else { return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)) }
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        if style.verticalOrientation != "upright" {
            var direction: CTWritingDirection = style.values["direction"]?.lowercased() == "rtl" ? .rightToLeft : .leftToRight
            let paragraph = withUnsafePointer(to: &direction) { value in
                var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: value)
                return CTParagraphStyleCreate(&setting, 1)
            }
            attributed.addAttribute(.init(kCTParagraphStyleAttributeName as String), value: paragraph, range: NSRange(location: 0, length: (text as NSString).length))
        }
        let orientation = style.verticalOrientation
        if orientation == "upright" {
            attributed.addAttribute(.init(kCTVerticalFormsAttributeName as String), value: true, range: NSRange(location: 0, length: (text as NSString).length))
        } else if orientation != "sideways" {
            var offset = 0, ranges: [NSRange] = []
            for value in text {
                let character = String(value)
                let count = (character as NSString).length
                if uprightCharacters.firstMatch(in: character, range: NSRange(location: 0, length: count)) != nil {
                    if let last = ranges.indices.last, NSMaxRange(ranges[last]) == offset { ranges[last].length += count }
                    else { ranges.append(NSRange(location: offset, length: count)) }
                }
                offset += count
            }
            for range in ranges { attributed.addAttribute(.init(kCTVerticalFormsAttributeName as String), value: true, range: range) }
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func advance(_ text: String, _ font: CTFont, _ style: TextStyle, vertical: Bool = false) -> Double {
        CTLineGetTypographicBounds(line(text, font, style, vertical: vertical), nil, nil, nil)
    }

    /// The run as paths (glyph outlines and decoration lines) with its paint; glyphs without outlines (colour emoji)
    /// stay text.
    private static func outline(_ run: TextLayout.Run) -> [XElement] {
        let ctLine = line(run.text, run.font, run.style, vertical: run.vertical)
        let path = CGMutablePath()
        var leftovers: [XElement] = []
        let wantsItalic = run.style.italic
        for glyphRun in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(glyphRun)
            guard count > 0, let attributes = CTRunGetAttributes(glyphRun) as? [String: Any],
                  let value = attributes[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices: [CFIndex] = []
            var renderedClusters = Set<Int>()
            if run.vertical && CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
                indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(glyphRun, CFRange(location: 0, length: count), &indices)
            }
            CTRunGetGlyphs(glyphRun, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(glyphRun, CFRange(location: 0, length: count), &positions)
            // A family without an italic face gets the slant Skia gives it.
            let slant: CGFloat = wantsItalic && !CTFontGetSymbolicTraits(font).contains(.traitItalic) ? 0.21 : 0
            for i in 0..<count {
                var transform = CGAffineTransform(a: 1, b: 0, c: slant, d: -1, tx: CGFloat(run.x) + positions[i].x, ty: CGFloat(run.y) - positions[i].y)
                if run.vertical {
                    let matrix = CTRunGetTextMatrix(glyphRun)
                    let position = positions[i].applying(matrix)
                    let center = matrix == .identity ? (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2 : 0
                    // Core Text's run matrix precedes the clockwise inline axis and SVG's downward y axis.
                    transform = CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0).concatenating(matrix).concatenating(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: CGFloat(run.x) + position.y - center, ty: CGFloat(run.y) + position.x))
                }
                if let glyph = CTFontCreatePathForGlyph(font, glyphs[i], &transform) {
                    path.addPath(glyph)
                } else if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
                    if run.vertical {
                        let source = run.text as NSString
                        let range = source.rangeOfComposedCharacterSequence(at: indices[i])
                        guard renderedClusters.insert(range.location).inserted else { continue }
                        let text = XElement(svg + "text", XAttribute("x", 0), XAttribute("y", 0),
                                            XAttribute("font-family", CTFontCopyFamilyName(font) as String), XAttribute("font-size", run.style.fontSize),
                                            XAttribute("writing-mode", "horizontal-tb"), XAttribute("text-anchor", "start"), XAttribute("direction", "ltr"),
                                            XAttribute("transform", "matrix(\(transform.a) \(transform.b) \(-transform.c) \(-transform.d) \(transform.tx) \(transform.ty))"))
                        text.add(source.substring(with: range))
                        leftovers.append(text)
                        continue
                    }
                    let range = CTRunGetStringRange(glyphRun)
                    let characters = (run.text as NSString).substring(with: NSRange(location: range.location, length: range.length))
                    let text = XElement(svg + "text", XAttribute("x", Double(run.x) + Double(positions[0].x)), XAttribute("y", run.y),
                                        XAttribute("font-family", CTFontCopyFamilyName(font) as String), XAttribute("font-size", run.style.fontSize))
                    text.add(characters)
                    leftovers.append(text)
                    break
                }
            }
        }
        decorate(run, path)
        let paint = ["fill", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
                     "stroke-dasharray", "stroke-dashoffset", "paint-order"]
        if run.vertical {
            for text in leftovers {
                for name in paint { if let value = run.style.values[name] { text.setAttributeValue(XName(name), value) } }
                if let opacity = run.opacity { text.setAttributeValue("opacity", opacity) }
            }
        }
        guard !path.isEmpty else { return leftovers }
        let element = XElement(svg + "path", XAttribute("d", pathData(path)))
        for name in paint { if let value = run.style.values[name] { element.setAttributeValue(XName(name), value) } }
        if let opacity = run.opacity { element.setAttributeValue("opacity", opacity) }
        // A family without a bold face gets Skia's fake bold: a thin outline in the fill colour.
        let traits = CTFontCopyTraits(run.font) as? [CFString: Any]
        let fontWeight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        if run.style.weight >= 600 && fontWeight < 0.23 && run.style.values["stroke"] == nil {
            element.setAttributeValue("stroke", run.style.values["fill"] ?? "black")
            element.setAttributeValue("stroke-width", XmlConvert.string(run.style.fontSize / 30))
        }
        return [element] + leftovers
    }

    /// Underline, overline and line-through as rectangles of the font's underline thickness.
    private static func decorate(_ run: TextLayout.Run, _ path: CGMutablePath) {
        let decoration = (run.style.values["text-decoration"] ?? "").lowercased()
        guard decoration.contains("underline") || decoration.contains("overline") || decoration.contains("line-through") else { return }
        let thickness = max(CTFontGetUnderlineThickness(run.font), CGFloat(run.style.fontSize) / 20)
        if run.vertical {
            let half = (CTFontGetAscent(run.font) + CTFontGetDescent(run.font)) / 2
            let x = CGFloat(run.x), y = CGFloat(run.y), height = CGFloat(run.width)
            if decoration.contains("underline") { path.addRect(CGRect(x: x - half - thickness, y: y, width: thickness, height: height)) }
            if decoration.contains("overline") { path.addRect(CGRect(x: x + half, y: y, width: thickness, height: height)) }
            if decoration.contains("line-through") { path.addRect(CGRect(x: x - thickness / 2, y: y, width: thickness, height: height)) }
            return
        }
        let left = CGFloat(run.x), width = CGFloat(run.width), baseline = CGFloat(run.y)
        if decoration.contains("underline") {
            path.addRect(CGRect(x: left, y: baseline - CTFontGetUnderlinePosition(run.font) - thickness / 2, width: width, height: thickness))
        }
        if decoration.contains("overline") {
            path.addRect(CGRect(x: left, y: baseline - CTFontGetAscent(run.font) - thickness / 2, width: width, height: thickness))
        }
        if decoration.contains("line-through") {
            path.addRect(CGRect(x: left, y: baseline - CTFontGetXHeight(run.font) / 2 - thickness / 2, width: width, height: thickness))
        }
    }

    /// SVG path data of a Core Graphics path, two decimals.
    private static func pathData(_ path: CGPath) -> String {
        var data = ""
        func number(_ value: CGFloat) -> String {
            let text = String(format: "%.2f", Double(value))
            var trimmed = text
            while trimmed.contains(".") && (trimmed.hasSuffix("0") || trimmed.hasSuffix(".")) { trimmed.removeLast() }
            return trimmed == "-0" ? "0" : trimmed
        }
        func point(_ p: CGPoint) -> String { number(p.x) + " " + number(p.y) }
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: data += "M" + point(points[0])
            case .addLineToPoint: data += "L" + point(points[0])
            case .addQuadCurveToPoint: data += "Q" + point(points[0]) + " " + point(points[1])
            case .addCurveToPoint: data += "C" + point(points[0]) + " " + point(points[1]) + " " + point(points[2])
            case .closeSubpath: data += "Z"
            @unknown default: break
            }
        }
        return data
    }
}
