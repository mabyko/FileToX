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
//   Horizontal text on a path follows the path (SvgTextPath.swift); vertical or rotated text on a path stays text.
//   The glyphs of plainly visible horizontal text are also kept (TextLayer) for PDF output to draw invisibly over the
//   outlines, so the PDF can be searched and its text selected.
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
    static func normalize(_ data: Data, baseDirectory: String?) -> Data { prepare(data, baseDirectory: baseDirectory).data }

    /// The SVG ready for CoreSVG (`data` unchanged when it can't be parsed) and the glyphs of its plainly visible text,
    /// nil when the viewport isn't plain enough to place them.
    static func prepare(_ data: Data, baseDirectory: String?) -> (data: Data, text: TextLayer?) {
        guard let document = try? XDocument.load(data: data, preserveWhitespace: true), document.root.name.localName == "svg" else { return (data, nil) }
        let root = document.root
        applyStyles(root)
        canonicalizeReferences(root)
        resolveReferences(root, baseDirectory: baseDirectory)
        var text = TextLayer(root)
        outlineText(root, inherited: TextStyle(), targets: textPathTargets(root), layer: &text)
        text?.removeCovered(root)
        guard let normalized = try? document.data(indent: false) else { return (data, nil) }
        return (normalized, text)
    }

    // ───────────────────────── Searchable text ─────────────────────────

    /// Glyphs drawn at `positions` (glyph-run space, y up) through `transform`.
    struct GlyphRun {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let transform: CGAffineTransform
    }

    /// The glyphs of plainly visible text in viewport pixels (y down): each character as the font's own glyph for it,
    /// which is what PDF text extraction maps back to the character.
    struct TextLayer {
        /// The viewport the glyphs assume: the drawing has to be this size for them to lie on the outlines.
        let viewport: CGSize
        /// Root user space to viewport pixels.
        let viewBox: CGAffineTransform
        var runs: [GlyphRun] = []
        /// Each text's outlines in the tree, its runs and the area its glyphs cover in viewport pixels.
        private var texts: [(outlines: XElement, runs: Range<Int>, area: CGRect)] = []

        /// Nil unless the viewport is plain: an absolute width and height (or a viewBox's), and a viewBox, if any, of the
        /// same aspect ratio, which every preserveAspectRatio maps alike.
        init?(_ root: XElement) {
            let tokens = (root.attributeValue("viewBox") ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace })
            let box = tokens.compactMap { Double($0) }
            guard box.count == tokens.count, box.allSatisfy(\.isFinite), box.isEmpty || (box.count == 4 && box[2] > 0 && box[3] > 0) else { return nil }
            func size(_ name: String, _ index: Int) -> Double? {
                guard let text = root.attributeValue(XName(name)) else { return box.isEmpty ? nil : box[index] }
                return SvgNormalizer.length(text, fontSize: 16, percentOf: 0)
            }
            guard let width = size("width", 2), let height = size("height", 3), width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
            viewport = CGSize(width: width, height: height)
            guard !box.isEmpty else { viewBox = .identity; return }
            guard abs(width * box[3] - height * box[2]) <= 1e-6 * width * box[3] else { return nil }
            viewBox = CGAffineTransform(translationX: -box[0], y: -box[1]).concatenating(CGAffineTransform(scaleX: width / box[2], y: height / box[3]))
        }

        /// Adds a text's glyphs, given its user space in the root's and the outlines that draw it. Clipped glyphs and text
        /// under a pixel tall keep their outlines alone; an invisible glyph must not reveal the part the page cuts away.
        mutating func add(_ glyphs: [GlyphRun], _ toRoot: CGAffineTransform, outlines: XElement) {
            let canvas = CGRect(origin: .zero, size: viewport)
            let first = runs.count
            var area = CGRect.null
            for run in glyphs {
                let transform = run.transform.concatenating(toRoot).concatenating(viewBox)
                guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite),
                      transform.a * transform.d - transform.b * transform.c != 0,
                      CTFontGetSize(run.font) * min(hypot(transform.a, transform.b), hypot(transform.c, transform.d)) >= 1 else { continue }
                var advances = [CGSize](repeating: .zero, count: run.glyphs.count)
                CTFontGetAdvancesForGlyphs(run.font, .horizontal, run.glyphs, &advances, run.glyphs.count)
                var bounds = [CGRect](repeating: .zero, count: run.glyphs.count)
                CTFontGetBoundingRectsForGlyphs(run.font, .horizontal, run.glyphs, &bounds, run.glyphs.count)
                let boxes = run.glyphs.indices.map { i -> CGRect in
                    let box = bounds[i].isEmpty
                        ? CGRect(x: 0, y: -CTFontGetDescent(run.font), width: advances[i].width, height: CTFontGetAscent(run.font) + CTFontGetDescent(run.font))
                        : bounds[i]
                    return box.isEmpty ? .null : box.offsetBy(dx: run.positions[i].x, dy: run.positions[i].y).applying(transform)
                }
                let kept = run.glyphs.indices.filter { !boxes[$0].isNull && canvas.contains(boxes[$0]) }
                for i in kept { area = area.union(boxes[i]) }
                if !kept.isEmpty { runs.append(GlyphRun(font: run.font, glyphs: kept.map { run.glyphs[$0] }, positions: kept.map { run.positions[$0] }, transform: transform)) }
            }
            if runs.count > first { texts.append((outlines, first..<runs.count, area)) }
        }

        /// Leaves out each text that anything drawn after it may cover, wholly or in part, even see-through: an invisible
        /// glyph must not reveal what the page may hide. Paint whose area isn't measured covers everything.
        mutating func removeCovered(_ root: XElement) {
            guard !texts.isEmpty else { return }
            var areas: [CGRect?] = [], ends: [ObjectIdentifier: Int] = [:], work = 1_000_000
            SvgNormalizer.paintedAreas(root, viewBox, Stroke(root), Set(texts.map { ObjectIdentifier($0.outlines) }), &areas, &ends, &work)
            var covered = IndexSet()
            for text in texts {
                let area = text.area.insetBy(dx: -1, dy: -1)
                let end = ends[ObjectIdentifier(text.outlines)]
                if end.map({ areas[$0...].contains { $0?.intersects(area) ?? true } }) ?? true { covered.insert(integersIn: text.runs) }
            }
            runs = runs.indices.filter { !covered.contains($0) }.map { runs[$0] }
        }
    }

    /// A shape's inherited stroke: whether it is painted, its width in user units (nil when not measured here), and
    /// whether markers, a miter limit or a vector effect may take it further than twice its width from the geometry.
    private struct Stroke {
        var painted = false
        var width: Double? = 1
        var unmeasured = false

        init(_ element: XElement, inheriting inherited: Stroke? = nil) {
            if let inherited { self = inherited }
            if let paint = keyword(element.attributeValue("stroke")) { painted = paint != "none" }
            if let value = keyword(element.attributeValue("stroke-width")) {
                width = ["em", "ex", "%"].contains(where: value.hasSuffix) ? nil : length(value, fontSize: 0, percentOf: 0).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
            if ["marker-start", "marker-mid", "marker-end", "stroke-miterlimit", "vector-effect"].contains(where: { ![nil, "none"].contains(keyword(element.attributeValue(XName($0)))) }) {
                unmeasured = true
            }
        }
    }

    /// Elements that draw nothing where they are (definitions, resources, metadata, animation).
    private static let undrawn: Set<String> = [
        "defs", "clipPath", "mask", "pattern", "marker", "symbol", "linearGradient", "radialGradient", "filter", "style", "title",
        "desc", "metadata", "script", "font", "font-face", "color-profile", "cursor", "view", "animate", "animateMotion",
        "animateTransform", "animateColor", "set",
    ]

    /// The area (viewport pixels) each element drawn inside `parent` covers, in painting order; nil for paint whose area
    /// isn't measured here (references, text CoreSVG lays out, nested viewports, filters, markers, ...). `ends` gets, for
    /// each of `marked`, how many areas were painted when it was done.
    private static func paintedAreas(_ parent: XElement, _ transform: CGAffineTransform?, _ inherited: Stroke, _ marked: Set<ObjectIdentifier>,
                                     _ areas: inout [CGRect?], _ ends: inout [ObjectIdentifier: Int], _ work: inout Int) {
        for element in parent.elements() where element.name.namespaceName == svg.namespaceName && !undrawn.contains(element.name.localName)
            && keyword(element.attributeValue("display")) != "none" {
            let stroke = Stroke(element, inheriting: inherited)
            var placed = transform
            if let value = element.attributeValue("transform") { placed = parsedTransform(value).flatMap { matrix in transform.map(matrix.concatenating) } }
            if (element.attributeValue("style") ?? "").lowercased().contains("transform") || ![nil, "none"].contains(keyword(element.attributeValue("filter"))) {
                placed = nil
            }
            func number(_ name: String) -> Double? {
                guard let value = keyword(element.attributeValue(XName(name))), !["em", "ex", "%"].contains(where: value.hasSuffix) else { return nil }
                return length(value, fontSize: 0, percentOf: 0).flatMap { $0.isFinite ? $0 : nil }
            }
            switch element.name.localName {
            case "g", "a":
                if placed == nil { areas.append(nil) } else { paintedAreas(element, placed, stroke, marked, &areas, &ends, &work) }
            case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                guard let placed, !stroke.unmeasured, let width = stroke.width else { areas.append(nil); break }
                let path = equivalentPath(element, work: &work)
                if case .invalid = path { break } // draws nothing
                guard case .segments(let segments) = path else { areas.append(nil); break }
                var box = CGRect.null
                for segment in segments {
                    switch segment {
                    case .move(let p), .line(let p): box = box.union(CGRect(origin: p, size: .zero))
                    case .quad(let c, let p): box = box.union(CGRect(origin: c, size: .zero)).union(CGRect(origin: p, size: .zero))
                    case .cubic(let c1, let c2, let p):
                        box = box.union(CGRect(origin: c1, size: .zero)).union(CGRect(origin: c2, size: .zero)).union(CGRect(origin: p, size: .zero))
                    case .close: break
                    }
                }
                // A stroke reaches half its width out, a miter join (limit 4) twice its width; a pixel for antialiasing.
                let outset = stroke.painted ? 2 * width : 0
                areas.append(box.insetBy(dx: -outset, dy: -outset).applying(placed).insetBy(dx: -1, dy: -1))
            case "image":
                let styledGeometry = (element.attributeValue("style") ?? "").split(separator: ";").contains {
                    ["x", "y", "width", "height"].contains(keyword($0.split(separator: ":", maxSplits: 1).first.map(String.init)) ?? "")
                }
                guard let placed, let width = number("width"), let height = number("height"),
                      let x = element.attributeValue("x") == nil ? 0 : number("x"),
                      let y = element.attributeValue("y") == nil ? 0 : number("y"), !styledGeometry,
                      [nil, "hidden", "scroll"].contains(keyword(element.attributeValue("overflow"))) else { areas.append(nil); break }
                areas.append(CGRect(x: x, y: y, width: width, height: height).standardized.applying(placed).insetBy(dx: -1, dy: -1))
            default:
                areas.append(nil)
            }
            if marked.contains(ObjectIdentifier(element)) { ends[ObjectIdentifier(element)] = areas.count }
        }
    }

    /// An attribute keyword as compared: trimmed, lowercase.
    private static func keyword(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// A text's user space in the root's (its own and its groups' transforms), or nil unless CoreSVG draws its outlines
    /// where they were laid out: only plain groups up to the root, nothing hiding (display, visibility, opacity),
    /// clipping, masking or filtering them, no conditional processing, no CSS the outlines don't follow, no `initial`
    /// (CoreSVG may not read it as the layout did), and transforms that parse.
    private static func layerTransform(_ text: XElement) -> CGAffineTransform? {
        func plain(_ element: XElement) -> Bool {
            !element.attributes.contains { TextStyle.inherited.contains($0.name.localName) && keyword($0.value) == "initial" }
                && keyword(element.attributeValue("display")) != "none" && [nil, "visible"].contains(keyword(element.attributeValue("visibility")))
                && (keyword(element.attributeValue("opacity")).map { Double($0) == 1 } ?? true)
                && ["clip-path", "mask", "filter"].allSatisfy { [nil, "none"].contains(keyword(element.attributeValue(XName($0)))) }
                && ["systemLanguage", "requiredFeatures", "requiredExtensions"].allSatisfy { element.attributeValue(XName($0)) == nil }
                && (element.attributeValue("style") ?? "").split(separator: ";").allSatisfy(typographic)
        }
        guard text.descendants().allSatisfy({ $0.name == svg + "tspan" && $0.attributeValue("transform") == nil && plain($0) }) else { return nil }
        var transform = CGAffineTransform.identity
        for element in [text] + text.ancestors() {
            let root = element.parent == nil
            guard element.name.namespaceName == svg.namespaceName, element === text || element.name.localName == (root ? "svg" : "g"), plain(element) else { return nil }
            if let value = element.attributeValue("transform") {
                guard !root, let matrix = parsedTransform(value) else { return nil }
                transform = transform.concatenating(matrix)
            }
        }
        return transform
    }

    /// Leftover CSS (no presentation attribute) that neither moves nor hides text: fonts, line height, white space,
    /// alignment and wrapping (the tspans' own positions place the text), sizes (the viewport must match CoreSVG's),
    /// Inkscape's properties and the background.
    private static func typographic(_ declaration: Substring) -> Bool {
        let name = keyword(declaration.split(separator: ":", maxSplits: 1).first.map(String.init)) ?? ""
        return name.isEmpty || ["font-", "-inkscape-", "background", "max-", "min-"].contains(where: name.hasPrefix)
            || ["line-height", "white-space", "text-align", "shape-inside", "shape-padding", "inline-size", "width", "height"].contains(name)
    }

    /// Filled with an opaque colour: none given (black), a 3- or 6-digit hex colour or a colour keyword; `currentColor`
    /// is the nearest `color` of the text or its ancestors, as CoreSVG reads it for the outlines.
    private static func opaqueFill(_ style: TextStyle, _ text: XElement) -> Bool {
        var fill = keyword(style.values["fill"])
        if fill == "currentcolor" {
            fill = ([text] + text.ancestors()).compactMap { keyword($0.attributeValue("color")) }.first { !["inherit", "currentcolor"].contains($0) }
        }
        guard keyword(style.values["fill-opacity"]).map({ Double($0) == 1 }) ?? true else { return false }
        guard let fill else { return true }
        if fill.hasPrefix("#") { return [4, 7].contains(fill.count) && fill.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit } }
        return fill.allSatisfy { $0.isASCII && $0.isLetter } && CssValues.color(fill) != nil
    }

    /// A glyph run's characters as the font's own glyph for each, spread over the advance of the glyph that shows them
    /// (a ligature shows several; its deleted 0xFFFF glyphs show none); nil when they can't stand for the run exactly:
    /// right-to-left or reordered, a character shown by several glyphs or with no glyph of its own in the font, colour
    /// glyphs, or the placeholder glyphs of the LastResort font (one glyph for many characters).
    private static func characterGlyphs(_ glyphRun: CTRun, _ font: CTFont, _ glyphs: [CGGlyph], _ positions: [CGPoint], _ run: TextLayout.Run) -> GlyphRun? {
        let count = glyphs.count, range = CTRunGetStringRange(glyphRun), text = Array(run.text.utf16)
        guard !CTRunGetStatus(glyphRun).contains(.rightToLeft), !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs),
              CTFontCopyPostScriptName(font) as String != "LastResort" else { return nil }
        var indices = [CFIndex](repeating: 0, count: count), advances = [CGSize](repeating: .zero, count: count)
        CTRunGetStringIndices(glyphRun, CFRange(location: 0, length: count), &indices)
        CTRunGetAdvances(glyphRun, CFRange(location: 0, length: count), &advances)
        let shown = (0..<count).filter { glyphs[$0] != 0xFFFF }
        guard shown.first == 0, indices.first == range.location, zip(indices, indices.dropFirst()).allSatisfy({ $0 < $1 }),
              range.location + range.length <= text.count else { return nil }
        var ids: [CGGlyph] = [], points: [CGPoint] = []
        for (n, i) in shown.enumerated() {
            let end = n + 1 < shown.count ? indices[shown[n + 1]] : range.location + range.length
            guard indices[i] < end else { return nil }
            let characters = Array(text[indices[i]..<end])
            var mapped = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(font, characters, &mapped, characters.count), !mapped.contains(0) else { return nil }
            for (k, glyph) in mapped.enumerated() {
                ids.append(glyph)
                points.append(CGPoint(x: positions[i].x + advances[i].width * CGFloat(k) / CGFloat(mapped.count), y: positions[i].y))
            }
        }
        let slant: CGFloat = run.style.italic && !CTFontGetSymbolicTraits(font).contains(.traitItalic) ? 0.21 : 0
        return GlyphRun(font: font, glyphs: ids, positions: points, transform: CGAffineTransform(a: 1, b: 0, c: slant, d: -1, tx: CGFloat(run.x), ty: CGFloat(run.y)))
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
                } else if ["writing-mode", "text-orientation", "direction"].contains(name) {
                    style.values[name] = keyword
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

    /// Elements by id (the first in document order) for text on a path; none when the drawing has no textPath.
    private static func textPathTargets(_ root: XElement) -> TextPathTargets {
        let elements = root.descendantsAndSelf()
        guard elements.contains(where: { $0.name.localName == "textPath" }) else { return TextPathTargets([:]) }
        var ids: [String: XElement] = [:]
        for element in elements { if let id = element.attributeValue("id"), ids[id] == nil { ids[id] = element } }
        return TextPathTargets(ids)
    }

    /// Walks the tree and replaces every <text> by its outlines, adding the glyphs of plainly visible text to `layer`.
    private static func outlineText(_ element: XElement, inherited: TextStyle, targets: TextPathTargets, layer: inout TextLayer?) {
        let style = inherited.adding(element)
        if element.name.localName == "text" {
            let layout = TextLayout(element, style, targets)
            guard let outlined = layout.outlined() else { return }
            if let glyphs = layout.searchable, let transform = layerTransform(element) { layer?.add(glyphs, transform, outlines: outlined) }
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
        for child in element.elements() { outlineText(child, inherited: style, targets: targets, layer: &layer) }
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
            /// On a path, `x` is the distance along the path and `y` the offset across it.
            var path: TextPathShape?
        }

        let element: XElement
        let style: TextStyle
        let targets: TextPathTargets
        var runs: [Run] = []
        var penX = 0.0, penY = 0.0
        var baselineShift = 0.0
        var pendingX: [Double] = [], pendingY: [Double] = [], pendingDX: [Double] = [], pendingDY: [Double] = []
        var lastWasSpace = true
        var unsupported = false
        /// The textPath being collected, whether its first run is still to come, and where text after it continues.
        var currentPath: TextPathShape?
        var pathStarts = false
        var resume: CGPoint?
        /// Inside a textPath that draws nothing: its characters still take part in white space and positions.
        var suppressed = 0
        /// The suppressed characters ended with a space; it disappears with them instead of collapsing the next one.
        var suppressedTrailingSpace = false
        /// The ancestors' position lists where the outermost suppressed subtree began, and how many characters it has
        /// hidden since, counted in Unicode scalars as SVG addresses characters.
        var hiddenPositions: (x: [Double], y: [Double], dx: [Double], dy: [Double])?
        var hiddenScalars = 0
        /// The glyphs of the drawn runs for a searchable PDF (text-element space); nil when one of them can't be placed.
        var searchable: [GlyphRun]? = []

        init(_ element: XElement, _ style: TextStyle, _ targets: TextPathTargets) {
            self.element = element
            self.style = style
            self.targets = targets
        }

        /// The outlines in a group carrying the text's own attributes, or nil to leave the text to CoreSVG.
        func outlined() -> XElement? {
            collect(element, style, isRoot: true)
            if unsupported { return nil }
            if style.values["xml:space"] != "preserve", let last = runs.indices.last {
                runs[last].text = String(runs[last].text.reversed().drop { $0 == " " }.reversed())
            }
            // shortcut: styled vertical or on-path bidi chunks, and right-to-left text on a path, stay with CoreSVG until
            // shaping spans the whole anchored chunk.
            var chunkRuns = 0, bidirectional = false
            for run in runs where !run.text.isEmpty && (run.vertical || run.path != nil) {
                if run.path != nil && run.style.values["direction"]?.lowercased() == "rtl" { return nil }
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
            // shortcut: unicode-bidi embedding, overrides and isolation aren't applied to outlines, so text declaring any
            // of them stays with CoreSVG.
            if let bidi = node.attributeValue("unicode-bidi"), bidi.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "normal" { unsupported = true }
            let size = style.fontSize
            var shape: TextPathShape?
            var suppress = false
            if node.name.localName == "textPath" {
                // A textPath belongs directly in its text; nested ones and missing or invalid references draw nothing.
                if node.parent !== element || suppressed > 0 {
                    suppress = true
                } else {
                    switch SvgNormalizer.textPathReference(node, targets: targets, fontSize: size) {
                    case .shape(let path): shape = path
                    case .invalid: suppress = true
                    case .unsupported: unsupported = true; return
                    }
                }
                // shortcut: vertical text on a path stays with CoreSVG until glyph orientation along a path is implemented.
                if shape != nil && self.style.vertical { unsupported = true; return }
            } else {
                // Positions of the element apply to its first characters; a textPath has none of its own.
                let x = SvgNormalizer.lengths(node.attributeValue("x"), fontSize: size), y = SvgNormalizer.lengths(node.attributeValue("y"), fontSize: size)
                if !x.isEmpty { pendingX = x }
                if !y.isEmpty { pendingY = y }
                pendingDX += SvgNormalizer.lengths(node.attributeValue("dx"), fontSize: size)
                pendingDY += SvgNormalizer.lengths(node.attributeValue("dy"), fontSize: size)
            }
            if node.attributeValue("rotate") != nil { unsupported = true }
            var shift = 0.0
            switch node.attributeValue("baseline-shift")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "super": shift = size * 0.33
            case "sub": shift = -size * 0.2
            case let value?: shift = SvgNormalizer.length(value, fontSize: size, percentOf: size) ?? 0
            case nil: break
            }
            let inheritedShift = baselineShift
            baselineShift += shift
            defer { baselineShift = inheritedShift }
            if let shape {
                // The path's characters start a chunk at its start, offset across it from zero.
                currentPath = shape; pathStarts = true; penY = 0; resume = nil
            }
            if suppress {
                if suppressed == 0 {
                    suppressedTrailingSpace = false
                    hiddenPositions = (pendingX, pendingY, pendingDX, pendingDY)
                    hiddenScalars = 0
                }
                suppressed += 1
            }
            defer {
                if let shape { currentPath = nil; pathStarts = false; resume = shape.continuation }
                if suppress {
                    suppressed -= 1
                    if suppressed == 0 {
                        if suppressedTrailingSpace { lastWasSpace = false }
                        // The hidden characters use up the ancestors' positions for them; lists given inside the hidden
                        // subtree apply only there.
                        if let ancestors = hiddenPositions {
                            pendingX = Array(ancestors.x.dropFirst(hiddenScalars))
                            pendingY = Array(ancestors.y.dropFirst(hiddenScalars))
                            pendingDX = Array(ancestors.dx.dropFirst(hiddenScalars))
                            pendingDY = Array(ancestors.dy.dropFirst(hiddenScalars))
                        }
                        hiddenPositions = nil
                    }
                }
            }
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
            if suppressed > 0 {
                // Characters that draw nothing still use up positions, one per Unicode scalar (collect settles them).
                if let last = text.last { suppressedTrailingSpace = last == " " && !preserve }
                hiddenScalars += text.unicodeScalars.count
                return
            }
            for character in text {
                let positioned = !pendingX.isEmpty || !pendingY.isEmpty || !pendingDX.isEmpty || !pendingDY.isEmpty
                // Upright cursive scripts use isolated forms, so each grapheme is shaped separately.
                if positioned || (self.style.vertical && style.verticalOrientation == "upright") || runs.isEmpty || runs[runs.count - 1].style.values != style.values || runs[runs.count - 1].opacity != opacity || runs[runs.count - 1].baselineShift != baselineShift
                    || runs[runs.count - 1].path !== currentPath || pathStarts || resume != nil {
                    var run = Run(text: "", style: style, font: SvgNormalizer.font(style), opacity: opacity)
                    run.vertical = self.style.vertical
                    run.baselineShift = baselineShift
                    if run.vertical {
                        if let x = pendingX.first { penX = x; run.startsChunk = true; pendingX.removeFirst() }
                        if let y = pendingY.first { run.y = y; run.startsChunk = true; pendingY.removeFirst() } else { run.y = .nan }
                        if let dx = pendingDX.first { penX += dx; pendingDX.removeFirst() }
                        if let dy = pendingDY.first { run.width = dy; pendingDY.removeFirst() }
                        run.x = penX + baselineShift
                    } else if let path = currentPath {
                        // On a path x moves along it (y doesn't apply), dx too, and dy moves across it.
                        run.path = path
                        run.x = pathStarts ? 0 : .nan
                        run.startsChunk = pathStarts
                        pathStarts = false
                        if let x = pendingX.first { run.x = x; run.startsChunk = true; pendingX.removeFirst() }
                        if !pendingY.isEmpty { pendingY.removeFirst() }
                        if let dx = pendingDX.first { run.width = dx; pendingDX.removeFirst() }
                        if let dy = pendingDY.first { penY += dy; pendingDY.removeFirst() }
                        run.y = penY - baselineShift
                    } else {
                        // Text after a textPath continues from the end of the path.
                        if let end = resume { run.x = Double(end.x); penY = Double(end.y); run.startsChunk = true; resume = nil } else { run.x = .nan }
                        if let x = pendingX.first { run.x = x; run.startsChunk = true; pendingX.removeFirst() }
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

        private func build() -> XElement? {
            let group = XElement(SvgNormalizer.svg + "g")
            // The text's own (not inherited) attributes stay on the group: id, transform, clip-path, mask, filter, opacity …
            let textAttributes: Set<String> = ["x", "y", "dx", "dy", "rotate", "textLength", "lengthAdjust", "font-family", "font-size", "font-weight",
                                               "font-style", "font-stretch", "font-variant", "letter-spacing", "word-spacing", "text-anchor",
                                               "text-decoration", "baseline-shift", "dominant-baseline", "alignment-baseline", "kerning"]
            for attribute in element.attributes where !textAttributes.contains(attribute.name.localName) && attribute.name.namespaceName != XNamespace.xml.namespaceName {
                group.setAttributeValue(attribute.name, attribute.value)
            }
            for run in runs where !run.text.isEmpty && run.style.values["visibility"] != "hidden" {
                // shortcut: the searchable layer takes plainly visible, opaquely filled horizontal text only; vertical text
                // and text on a path stay outlines alone until their glyph orientation is placed in it.
                if run.vertical || run.path != nil || ![nil, "visible"].contains(SvgNormalizer.keyword(run.style.values["visibility"]))
                    || !(SvgNormalizer.keyword(run.opacity).map { Double($0) == 1 } ?? true) || !SvgNormalizer.opaqueFill(run.style, element) {
                    searchable = nil
                }
                guard let nodes = SvgNormalizer.outline(run, &searchable) else { return nil }
                for node in nodes { group.add(node) }
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
    /// stay text. Nil when text on a path can't be placed, which keeps the whole text with CoreSVG. Unless `searchable`
    /// is nil, the run's characters are added to it as glyphs, or it becomes nil when they can't be.
    private static func outline(_ run: TextLayout.Run, _ searchable: inout [GlyphRun]?) -> [XElement]? {
        let ctLine = line(run.text, run.font, run.style, vertical: run.vertical)
        let path = CGMutablePath()
        var leftovers: [XElement] = []
        let wantsItalic = run.style.italic
        if let shape = run.path, !placeOnPath(ctLine, run, shape, path, &leftovers) { return nil }
        for glyphRun in run.path == nil ? (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] : [] {
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
            if searchable != nil {
                if let characters = characterGlyphs(glyphRun, font, glyphs, positions, run) { searchable!.append(characters) } else { searchable = nil }
            }
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
        if run.vertical || run.path != nil {
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

    /// Text on a path. Each typographic cluster (a grapheme joined with every character a glyph covers, such as a
    /// ligature, across the font runs it is shaped in) keeps its shaped layout and moves rigidly: the midpoint of its
    /// advance cell goes to that distance along the path, turned with the tangent and offset across it (SVG 2 "Position
    /// on path"). Clusters past an open path's ends aren't drawn; decorations are drawn per cluster so they follow the
    /// path. False when a cluster's advance cell can't be recovered from the shaped line.
    private static func placeOnPath(_ ctLine: CTLine, _ run: TextLayout.Run, _ shape: TextPathShape, _ path: CGMutablePath, _ leftovers: inout [XElement]) -> Bool {
        let source = run.text as NSString
        let count = source.length
        var parent = Array(0..<count)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        func join(_ a: Int, _ b: Int) {
            let x = root(a), y = root(b)
            if x != y { parent[max(x, y)] = min(x, y) }
        }
        var location = 0
        while location < count {
            let grapheme = source.rangeOfComposedCharacterSequence(at: location)
            for index in grapheme.location..<NSMaxRange(grapheme) { join(grapheme.location, index) }
            location = max(NSMaxRange(grapheme), location + 1)
        }
        struct Glyph {
            let font: CTFont, glyph: CGGlyph, position: CGPoint, index: Int
            /// The pen positions before and after the glyph's advance, apart from any offset of the glyph itself.
            let cell: (low: CGFloat, high: CGFloat)
        }
        var glyphs: [Glyph] = []
        for glyphRun in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
            let glyphCount = CTRunGetGlyphCount(glyphRun)
            guard glyphCount > 0, let attributes = CTRunGetAttributes(glyphRun) as? [String: Any],
                  let value = attributes[kCTFontAttributeName as String] else { continue }
            let font = value as! CTFont
            var ids = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var indices = [CFIndex](repeating: 0, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var origins = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(glyphRun, CFRange(location: 0, length: glyphCount), &ids)
            CTRunGetPositions(glyphRun, CFRange(location: 0, length: glyphCount), &positions)
            CTRunGetStringIndices(glyphRun, CFRange(location: 0, length: glyphCount), &indices)
            CTRunGetBaseAdvancesAndOrigins(glyphRun, CFRange(location: 0, length: glyphCount), &advances, &origins)
            // A glyph covers the characters from its index up to the run's next glyph index.
            let range = CTRunGetStringRange(glyphRun)
            let starts = Set(indices).sorted()
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? starts[k + 1] : range.location + range.length
                guard start >= 0, start < end, end <= count else { return false }
                for index in start..<end { join(start, index) }
            }
            for i in 0..<glyphCount {
                let pen = positions[i].x - origins[i].x, next = pen + advances[i].width
                glyphs.append(Glyph(font: font, glyph: ids[i], position: positions[i], index: indices[i], cell: (min(pen, next), max(pen, next))))
            }
        }
        let clusters = (0..<count).map(root)
        // A cluster's advance cell spans its glyphs' cells, so offsets (marks, enclosing marks, glyphs another font
        // shaped) stay where shaping put them inside it.
        var low: [Int: CGFloat] = [:], high: [Int: CGFloat] = [:]
        for glyph in glyphs {
            let cluster = clusters[glyph.index]
            low[cluster] = min(low[cluster] ?? glyph.cell.low, glyph.cell.low)
            high[cluster] = max(high[cluster] ?? glyph.cell.high, glyph.cell.high)
        }
        // Letter spacing ends a character's advance cell; the character centres on its own advance.
        var spacing: CGFloat = 0
        if let value = run.style.values["letter-spacing"], value != "normal" {
            spacing = CGFloat(length(value, fontSize: run.style.fontSize, percentOf: run.style.fontSize) ?? 0)
        }
        var frames: [Int: (frame: CGAffineTransform, middle: CGFloat)] = [:], order: [Int] = [], hidden = Set<Int>()
        for glyph in glyphs {
            let cluster = clusters[glyph.index]
            guard frames[cluster] == nil, !hidden.contains(cluster) else { continue }
            guard let cellLow = low[cluster], let cellHigh = high[cluster], cellLow.isFinite, cellHigh.isFinite, cellLow <= cellHigh else { return false }
            let middle = (cellLow + cellHigh - min(spacing, cellHigh - cellLow)) / 2
            guard let placement = shape.place(run.x + Double(middle) + shape.offset, anchor: run.anchor) else { hidden.insert(cluster); continue }
            frames[cluster] = (CGAffineTransform(rotationAngle: placement.angle).concatenating(CGAffineTransform(translationX: placement.point.x, y: placement.point.y)), middle)
            order.append(cluster)
        }
        var characters: [Int: NSRange] = [:]
        for index in 0..<count { characters[clusters[index]] = characters[clusters[index]].map { NSUnionRange($0, NSRange(location: index, length: 1)) } ?? NSRange(location: index, length: 1) }
        var emitted = Set<Int>()
        for glyph in glyphs {
            let cluster = clusters[glyph.index]
            guard let placed = frames[cluster] else { continue }
            let (frame, middle) = placed
            // A family without an italic face gets the slant Skia gives it.
            let slant: CGFloat = run.style.italic && !CTFontGetSymbolicTraits(glyph.font).contains(.traitItalic) ? 0.21 : 0
            let x = glyph.position.x - middle, y = CGFloat(run.y) - glyph.position.y
            var transform = CGAffineTransform(a: 1, b: 0, c: slant, d: -1, tx: x, ty: y).concatenating(frame)
            if let outline = CTFontCreatePathForGlyph(glyph.font, glyph.glyph, &transform) {
                path.addPath(outline)
            } else if CTFontGetSymbolicTraits(glyph.font).contains(.traitColorGlyphs), emitted.insert(cluster).inserted, let range = characters[cluster] {
                let place = CGAffineTransform(translationX: x, y: y).concatenating(frame)
                let text = XElement(svg + "text", XAttribute("x", 0), XAttribute("y", 0),
                                    XAttribute("font-family", CTFontCopyFamilyName(glyph.font) as String), XAttribute("font-size", run.style.fontSize),
                                    XAttribute("text-anchor", "start"), XAttribute("direction", "ltr"),
                                    XAttribute("transform", "matrix(\(place.a) \(place.b) \(place.c) \(place.d) \(place.tx) \(place.ty))"))
                text.add(source.substring(with: range))
                leftovers.append(text)
            }
        }
        for cluster in order {
            guard let placed = frames[cluster], let cellLow = low[cluster], let cellHigh = high[cluster] else { continue }
            decorateLine(run, path, left: cellLow - placed.middle, width: cellHigh - cellLow, transform: placed.frame)
        }
        return true
    }

    /// Underline, overline and line-through as rectangles of the font's underline thickness.
    private static func decorate(_ run: TextLayout.Run, _ path: CGMutablePath) {
        let decoration = (run.style.values["text-decoration"] ?? "").lowercased()
        guard run.path == nil, decoration.contains("underline") || decoration.contains("overline") || decoration.contains("line-through") else { return }
        let thickness = max(CTFontGetUnderlineThickness(run.font), CGFloat(run.style.fontSize) / 20)
        if run.vertical {
            let half = (CTFontGetAscent(run.font) + CTFontGetDescent(run.font)) / 2
            let x = CGFloat(run.x), y = CGFloat(run.y), height = CGFloat(run.width)
            if decoration.contains("underline") { path.addRect(CGRect(x: x - half - thickness, y: y, width: thickness, height: height)) }
            if decoration.contains("overline") { path.addRect(CGRect(x: x + half, y: y, width: thickness, height: height)) }
            if decoration.contains("line-through") { path.addRect(CGRect(x: x - thickness / 2, y: y, width: thickness, height: height)) }
            return
        }
        decorateLine(run, path, left: CGFloat(run.x), width: CGFloat(run.width), transform: .identity)
    }

    /// Horizontal decoration lines from `left`, `width` long on the run's baseline, in the space `transform` maps.
    private static func decorateLine(_ run: TextLayout.Run, _ path: CGMutablePath, left: CGFloat, width: CGFloat, transform: CGAffineTransform) {
        let decoration = (run.style.values["text-decoration"] ?? "").lowercased()
        let thickness = max(CTFontGetUnderlineThickness(run.font), CGFloat(run.style.fontSize) / 20), baseline = CGFloat(run.y)
        if decoration.contains("underline") {
            path.addRect(CGRect(x: left, y: baseline - CTFontGetUnderlinePosition(run.font) - thickness / 2, width: width, height: thickness), transform: transform)
        }
        if decoration.contains("overline") {
            path.addRect(CGRect(x: left, y: baseline - CTFontGetAscent(run.font) - thickness / 2, width: width, height: thickness), transform: transform)
        }
        if decoration.contains("line-through") {
            path.addRect(CGRect(x: left, y: baseline - CTFontGetXHeight(run.font) / 2 - thickness / 2, width: width, height: thickness), transform: transform)
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
