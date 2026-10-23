// HTML (and, with HTML switched off, plain text) output of the Markdown tree, byte for byte like Markdig's
// HtmlRenderer: "\n" line endings, the same escaping and URL encoding, and the same renderer per object type.

import Foundation

extension Markdown {
    /// Writes one kind of object (`HtmlObjectRenderer<T>`); `accepts` mirrors `typeof(T).IsAssignableFrom`.
    class ObjectRenderer {
        /// Writers tried first; one returning true replaces the default output (`TryWriters`).
        var tryWriters: [(HtmlRenderer, MarkdownObject) -> Bool] = []

        func accepts(_ object: MarkdownObject) -> Bool { false }
        func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {}

        func render(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            for writer in tryWriters where writer(renderer, object) { return }
            write(renderer, object)
        }
    }

    final class HtmlRenderer {
        private(set) var output: [UInt16] = []
        private var previousWasLine = true
        var enableHtmlForInline = true
        var enableHtmlForBlock = true
        var enableHtmlEscape = true
        var implicitParagraph = false
        var useNonAsciiNoEscape = false
        private(set) var isFirstInContainer = false
        private(set) var isLastInContainer = false
        private var childrenDepth = 0
        var maximumNestingDepth = Markdown.defaultDepthLimit
        private(set) var depthLimitExceeded = false
        var objectRenderers: [ObjectRenderer] = []
        private var rendererCache: [ObjectIdentifier: ObjectRenderer?] = [:]

        init() {
            objectRenderers = [
                CodeBlockRenderer(), ListRenderer(), HeadingRenderer(), HtmlBlockRenderer(), ParagraphRenderer(), QuoteBlockRenderer(),
                ThematicBreakRenderer(), AutolinkInlineRenderer(), CodeInlineRenderer(), DelimiterInlineRenderer(), EmphasisInlineRenderer(),
                LineBreakInlineRenderer(), HtmlInlineRenderer(), HtmlEntityInlineRenderer(), LinkInlineRenderer(), LiteralInlineRenderer(),
            ]
        }

        var text: String { String(decoding: output, as: UTF16.self) }

        func find<T: ObjectRenderer>(_ type: T.Type) -> T? { objectRenderers.lazy.compactMap { $0 as? T }.first }

        func insertRenderer(_ renderer: ObjectRenderer, before type: ObjectRenderer.Type) {
            if let index = objectRenderers.firstIndex(where: { Swift.type(of: $0) == type }) {
                objectRenderers.insert(renderer, at: index)
            } else {
                objectRenderers.append(renderer)
            }
        }

        // MARK: Writing (TextRendererBase)

        private func writeIndent() { previousWasLine = false }

        func ensureLine() {
            if !previousWasLine {
                previousWasLine = true
                output.append(0x0A)
            }
        }

        /// `Write(string)`: does not track a final line feed.
        func write(_ content: String?) {
            writeIndent()
            if let content { output += content.utf16 }
        }

        /// `Write(char)`.
        func write(_ c: Char) {
            writeIndent()
            if c == "\n" { previousWasLine = true }
            output.append(c.value)
        }

        /// `Write(ReadOnlySpan<char>)`: a final line feed starts a new line.
        func writeSpan<C: BidirectionalCollection<Char>>(_ content: C) {
            guard let last = content.last else { return }
            writeIndent()
            output += content.lazy.map(\.value)
            if last == "\n" { previousWasLine = true }
        }

        func write(_ slice: Slice) { writeSpan(slice.chars) }

        func writeRaw(_ content: String?) { if let content { output += content.utf16 } }
        func writeRaw(_ c: Char) { output.append(c.value) }
        func writeRaw<C: Collection<Char>>(chars content: C) { output += content.lazy.map(\.value) }

        func writeLine() {
            writeIndent()
            output.append(0x0A)
            previousWasLine = true
        }

        func writeLine(_ content: String) {
            writeIndent()
            previousWasLine = true
            output += content.utf16
            output.append(0x0A)
        }

        func writeLine(_ c: Char) {
            writeIndent()
            previousWasLine = true
            output.append(c.value)
            output.append(0x0A)
        }

        // MARK: Escaping (HtmlRenderer)

        func writeEscape(_ content: String?) { writeEscape(chars: Markdown.chars(content ?? "")) }
        func writeEscape(_ slice: Slice, softEscape: Bool = false) { writeEscape(chars: slice.chars, softEscape: softEscape) }

        /// Escapes `<`, `>`, `&` and `"` (only `<` and `&` when soft); with escaping switched off they are dropped.
        func writeEscape<C: Collection<Char>>(chars content: C, softEscape: Bool = false) {
            if content.isEmpty { return }
            writeIndent()
            for c in content {
                switch c {
                case "<": if enableHtmlEscape { output += "&lt;".utf16 }
                case "&": if enableHtmlEscape { output += "&amp;".utf16 }
                case ">" where !softEscape: if enableHtmlEscape { output += "&gt;".utf16 }
                case "\"" where !softEscape: if enableHtmlEscape { output += "&quot;".utf16 }
                default: output.append(c.value)
                }
            }
        }

        private static let asciiNonEscape: Set<UInt16> = Set("!#$%()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz".utf16)

        /// A URL with unsafe characters percent-encoded (UTF-8) and the host of a non-ASCII absolute URL in punycode.
        func writeEscapeUrl(_ content: String?) {
            guard let content else { return }
            let chars = Markdown.chars(content)
            if !chars.allSatisfy({ $0.value < 128 }), let schemeOffset = Self.indexOfSchemeSeparator(chars), schemeOffset > 0 {
                let hostStart = schemeOffset + 3
                let domainEnd = chars[hostStart...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ":" } ?? chars.count
                if let ascii = Punycode.idnToAscii(Markdown.string(chars[hostStart..<domainEnd])) {
                    writeEscapeUrlCore(chars[0..<hostStart])
                    writeEscapeUrlCore(Markdown.chars(ascii)[...])
                    writeEscapeUrlCore(chars[domainEnd...])
                    return
                }
            }
            writeEscapeUrlCore(chars[...])
        }

        private static func indexOfSchemeSeparator(_ chars: [Char]) -> Int? {
            guard chars.count >= 3 else { return nil }
            for i in 0...(chars.count - 3) where chars[i] == ":" && chars[i + 1] == "/" && chars[i + 2] == "/" { return i }
            return nil
        }

        private func writeEscapeUrlCore(_ content: ArraySlice<Char>) {
            writeIndent()
            var i = content.startIndex
            while i < content.endIndex {
                let c = content[i]
                if Self.asciiNonEscape.contains(c.value) {
                    output.append(c.value)
                } else if c.value < 128 {
                    writeRaw(HtmlHelper.escapeUrlCharacter(c))
                } else if useNonAsciiNoEscape {
                    output.append(c.value)
                } else {
                    var units = [c.value]
                    if c.isHighSurrogate && i + 1 < content.endIndex {
                        units.append(content[i + 1].value)
                        i += 1
                    }
                    for byte in Array(String(decoding: units, as: UTF16.self).utf8) {
                        output += String(format: "%%%02X", byte).utf16
                    }
                }
                i += 1
            }
        }

        func writeAttributes(_ object: MarkdownObject) {
            // C# picks the HtmlAttributes overload for an HtmlAttributes argument.
            if let attributes = object as? HtmlAttributes { writeAttributes(attributes, classFilter: nil) } else { writeAttributes(object.tryGetAttributes()) }
        }

        func writeAttributes(_ attributes: HtmlAttributes?, classFilter: ((String) -> String)? = nil) {
            guard let attributes else { return }
            if let id = attributes.id {
                write(" id=\"")
                writeEscape(id)
                writeRaw("\"")
            }
            if let classes = attributes.classes?.items, !classes.isEmpty {
                write(" class=\"")
                for (i, cssClass) in classes.enumerated() {
                    if i > 0 { writeRaw(" ") }
                    writeEscape(classFilter?(cssClass) ?? cssClass)
                }
                writeRaw("\"")
            }
            if let properties = attributes.properties?.items, !properties.isEmpty {
                for (key, value) in properties {
                    write(" ")
                    writeRaw(key)
                    writeRaw("=\"")
                    writeEscape(value ?? "")
                    writeRaw("\"")
                }
            }
        }

        func writeLeafRawLines(_ leaf: LeafBlock, writeEndOfLines: Bool, escape: Bool, softEscape: Bool = false) {
            for (i, line) in leaf.lines.lines.enumerated() {
                if !writeEndOfLines && i > 0 { writeLine() }
                if escape { writeEscape(line.slice, softEscape: softEscape) } else { write(line.slice) }
                if writeEndOfLines { writeLine() }
            }
        }

        func writeLeafInline(_ leaf: LeafBlock) {
            var inline: Inline? = leaf.inline
            while let current = inline {
                write(current)
                inline = current.nextSibling
            }
        }

        // MARK: Dispatch (RendererBase)

        func writeChildren(_ container: ContainerBlock) {
            if childrenDepth > maximumNestingDepth { depthLimitExceeded = true }
            if depthLimitExceeded { return }
            childrenDepth += 1
            let savedFirst = isFirstInContainer
            let savedLast = isLastInContainer
            let children = container.children
            for (i, child) in children.enumerated() {
                isFirstInContainer = i == 0
                isLastInContainer = i + 1 == children.count
                write(child)
            }
            isFirstInContainer = savedFirst
            isLastInContainer = savedLast
            childrenDepth -= 1
        }

        func writeChildren(_ container: ContainerInline) {
            if childrenDepth > maximumNestingDepth { depthLimitExceeded = true }
            if depthLimitExceeded { return }
            childrenDepth += 1
            let savedFirst = isFirstInContainer
            let savedLast = isLastInContainer
            var isFirst = true
            var inline = container.firstChild
            while let current = inline {
                isFirstInContainer = isFirst
                isLastInContainer = current.nextSibling == nil
                write(current)
                inline = current.nextSibling
                isFirst = false
            }
            isFirstInContainer = savedFirst
            isLastInContainer = savedLast
            childrenDepth -= 1
        }

        func write(_ object: MarkdownObject?) {
            guard let object else { return }
            let key = ObjectIdentifier(type(of: object))
            let renderer: ObjectRenderer?
            if let cached = rendererCache[key] {
                renderer = cached
            } else {
                renderer = objectRenderers.first { $0.accepts(object) }
                rendererCache[key] = .some(renderer)
            }
            if let renderer {
                renderer.render(self, object)
            } else if let container = object as? ContainerInline {
                writeChildren(container)
            } else if let container = object as? ContainerBlock {
                writeChildren(container)
            }
        }
    }

    // MARK: Block renderers

    final class CodeBlockRenderer: ObjectRenderer {
        var outputAttributesOnPre = false
        /// Fence infos rendered as `<div>` (diagrams) or another element, case-insensitively.
        var blocksAsDiv: [String] = []
        var blockMapping: [(String, String)] = []

        override func accepts(_ object: MarkdownObject) -> Bool { object is CodeBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let code = object as! CodeBlock
            renderer.ensureLine()
            let info = (code as? FencedCodeBlock)?.info
            let special = info.flatMap { info in
                blocksAsDiv.contains { $0.caseInsensitiveCompare(info) == .orderedSame }
                    || blockMapping.contains { $0.0.caseInsensitiveCompare(info) == .orderedSame } ? info : nil
            }
            if let info = special {
                let prefix = (code.parser as? FencedCodeBlockParser)?.infoPrefix ?? FencedCodeBlockParser.defaultInfoPrefix
                let element = blockMapping.first { $0.0.caseInsensitiveCompare(info) == .orderedSame }?.1 ?? "div"
                if renderer.enableHtmlForBlock {
                    renderer.writeRaw("<")
                    renderer.write(element)
                    renderer.writeAttributes(code.tryGetAttributes()) { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
                    renderer.writeRaw(">")
                }
                renderer.writeLeafRawLines(code, writeEndOfLines: true, escape: true, softEscape: true)
                if renderer.enableHtmlForBlock {
                    renderer.write("</")
                    renderer.write(element)
                    renderer.writeLine(">")
                }
            } else {
                if renderer.enableHtmlForBlock {
                    renderer.write("<pre")
                    if outputAttributesOnPre { renderer.writeAttributes(code) }
                    renderer.writeRaw("><code")
                    if !outputAttributesOnPre { renderer.writeAttributes(code) }
                    renderer.writeRaw(">")
                }
                renderer.writeLeafRawLines(code, writeEndOfLines: true, escape: renderer.enableHtmlEscape)
                if renderer.enableHtmlForBlock { renderer.writeLine("</code></pre>") }
            }
            renderer.ensureLine()
        }
    }

    final class ListRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is ListBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let list = object as! ListBlock
            renderer.ensureLine()
            if renderer.enableHtmlForBlock {
                if list.isOrdered {
                    renderer.write("<ol")
                    if list.bulletType != "1" {
                        renderer.writeRaw(" type=\"")
                        renderer.writeRaw(list.bulletType)
                        renderer.writeRaw("\"")
                    }
                    if let start = list.orderedStart, start != "1" {
                        renderer.write(" start=\"")
                        renderer.writeRaw(start)
                        renderer.writeRaw("\"")
                    }
                    renderer.writeAttributes(list)
                    renderer.writeLine(">")
                } else {
                    renderer.write("<ul")
                    renderer.writeAttributes(list)
                    renderer.writeLine(">")
                }
            }
            for item in list.children {
                let listItem = item as! ListItemBlock
                let previousImplicit = renderer.implicitParagraph
                renderer.implicitParagraph = !list.isLoose
                renderer.ensureLine()
                if renderer.enableHtmlForBlock {
                    renderer.write("<li")
                    renderer.writeAttributes(listItem)
                    renderer.writeRaw(">")
                }
                renderer.writeChildren(listItem)
                if renderer.enableHtmlForBlock { renderer.writeLine("</li>") }
                renderer.ensureLine()
                renderer.implicitParagraph = previousImplicit
            }
            if renderer.enableHtmlForBlock { renderer.writeLine(list.isOrdered ? "</ol>" : "</ul>") }
            renderer.ensureLine()
        }
    }

    final class HeadingRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is HeadingBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let heading = object as! HeadingBlock
            let tag = "h\(heading.level)"
            if renderer.enableHtmlForBlock {
                renderer.write("<" as Char)
                renderer.writeRaw(tag)
                renderer.writeAttributes(heading)
                renderer.writeRaw(">")
            }
            renderer.writeLeafInline(heading)
            if renderer.enableHtmlForBlock {
                renderer.write("</")
                renderer.writeRaw(tag)
                renderer.writeLine(">" as Char)
            }
            renderer.ensureLine()
        }
    }

    final class HtmlBlockRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is HtmlBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            renderer.writeLeafRawLines(object as! HtmlBlock, writeEndOfLines: true, escape: false)
        }
    }

    final class ParagraphRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is ParagraphBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let paragraph = object as! ParagraphBlock
            if !renderer.implicitParagraph && renderer.enableHtmlForBlock {
                if !renderer.isFirstInContainer { renderer.ensureLine() }
                renderer.write("<p")
                renderer.writeAttributes(paragraph)
                renderer.writeRaw(">")
            }
            renderer.writeLeafInline(paragraph)
            if !renderer.implicitParagraph {
                if renderer.enableHtmlForBlock { renderer.writeLine("</p>") }
                renderer.ensureLine()
            }
        }
    }

    final class QuoteBlockRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is QuoteBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let quote = object as! QuoteBlock
            renderer.ensureLine()
            if renderer.enableHtmlForBlock {
                renderer.write("<blockquote")
                renderer.writeAttributes(quote)
                renderer.writeLine(">" as Char)
            }
            let saved = renderer.implicitParagraph
            renderer.implicitParagraph = false
            renderer.writeChildren(quote)
            renderer.implicitParagraph = saved
            if renderer.enableHtmlForBlock { renderer.writeLine("</blockquote>") }
            renderer.ensureLine()
        }
    }

    final class ThematicBreakRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is ThematicBreakBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            if renderer.enableHtmlForBlock {
                renderer.write("<hr")
                renderer.writeAttributes(object)
                renderer.writeLine(" />")
            }
        }
    }

    // MARK: Inline renderers

    final class AutolinkInlineRenderer: ObjectRenderer {
        var rel: String?

        override func accepts(_ object: MarkdownObject) -> Bool { object is AutolinkInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let link = object as! AutolinkInline
            if renderer.enableHtmlForInline {
                renderer.write(link.isEmail ? "<a href=\"mailto:" : "<a href=\"")
                renderer.writeEscapeUrl(link.url)
                renderer.writeRaw("\"")
                renderer.writeAttributes(link)
                if !link.isEmail, let rel, !rel.allSatisfy(\.isWhitespace) {
                    renderer.writeRaw(" rel=\"")
                    renderer.writeRaw(rel)
                    renderer.writeRaw("\"")
                }
                renderer.writeRaw(">")
            }
            renderer.writeEscape(link.url)
            if renderer.enableHtmlForInline { renderer.writeRaw("</a>") }
        }
    }

    final class CodeInlineRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is CodeInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let code = object as! CodeInline
            if renderer.enableHtmlForInline {
                renderer.write("<code")
                renderer.writeAttributes(code)
                renderer.writeRaw(">")
            }
            if renderer.enableHtmlEscape {
                renderer.writeEscape(code.content)
            } else {
                renderer.writeSpan(Markdown.chars(code.content))
            }
            if renderer.enableHtmlForInline { renderer.writeRaw("</code>") }
        }
    }

    final class DelimiterInlineRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is DelimiterInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let delimiter = object as! DelimiterInline
            renderer.writeEscape(delimiter.toLiteral())
            renderer.writeChildren(delimiter)
        }
    }

    final class EmphasisInlineRenderer: ObjectRenderer {
        /// The element for an emphasis; extensions add their characters (`GetTag`).
        var getTag: (EmphasisInline) -> String? = EmphasisInlineRenderer.defaultTag

        static func defaultTag(_ emphasis: EmphasisInline) -> String? {
            if emphasis.delimiterChar == "*" || emphasis.delimiterChar == "_" { return emphasis.delimiterCount == 2 ? "strong" : "em" }
            return nil
        }

        override func accepts(_ object: MarkdownObject) -> Bool { object is EmphasisInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let emphasis = object as! EmphasisInline
            var tag: String?
            if renderer.enableHtmlForInline {
                tag = getTag(emphasis)
                renderer.write("<" as Char)
                renderer.writeRaw(tag)
                renderer.writeAttributes(emphasis)
                renderer.writeRaw(">")
            }
            renderer.writeChildren(emphasis)
            if renderer.enableHtmlForInline {
                renderer.write("</")
                renderer.writeRaw(tag)
                renderer.writeRaw(">")
            }
        }
    }

    final class HtmlEntityInlineRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is HtmlEntityInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let entity = object as! HtmlEntityInline
            if renderer.enableHtmlEscape { renderer.writeEscape(entity.transcoded) } else { renderer.write(entity.transcoded) }
        }
    }

    final class HtmlInlineRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is HtmlInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            if renderer.enableHtmlForInline { renderer.write((object as! HtmlInline).tag) }
        }
    }

    final class LineBreakInlineRenderer: ObjectRenderer {
        var renderAsHardlineBreak = false

        override func accepts(_ object: MarkdownObject) -> Bool { object is LineBreakInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            if renderer.isLastInContainer { return }
            if renderer.enableHtmlForInline && ((object as! LineBreakInline).isHard || renderAsHardlineBreak) {
                renderer.writeLine("<br />")
            }
            renderer.ensureLine()
        }
    }

    final class LinkInlineRenderer: ObjectRenderer {
        var rel: String?

        override func accepts(_ object: MarkdownObject) -> Bool { object is LinkInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let link = object as! LinkInline
            if renderer.enableHtmlForInline {
                renderer.write(link.isImage ? "<img src=\"" : "<a href=\"")
                renderer.writeEscapeUrl(link.getDynamicUrl.map { $0() ?? link.url } ?? link.url)
                renderer.writeRaw("\"")
                renderer.writeAttributes(link)
            }
            if link.isImage {
                if renderer.enableHtmlForInline { renderer.writeRaw(" alt=\"") }
                let wasEnabled = renderer.enableHtmlForInline
                renderer.enableHtmlForInline = false
                renderer.writeChildren(link)
                renderer.enableHtmlForInline = wasEnabled
                if renderer.enableHtmlForInline { renderer.writeRaw("\"") }
            }
            if renderer.enableHtmlForInline, let title = link.title, !title.isEmpty {
                renderer.writeRaw(" title=\"")
                renderer.writeEscape(title)
                renderer.writeRaw("\"")
            }
            if link.isImage {
                if renderer.enableHtmlForInline { renderer.writeRaw(" />") }
            } else {
                if renderer.enableHtmlForInline {
                    if let rel, !rel.allSatisfy(\.isWhitespace) {
                        renderer.writeRaw(" rel=\"")
                        renderer.writeRaw(rel)
                        renderer.writeRaw("\"")
                    }
                    renderer.writeRaw(">")
                }
                renderer.writeChildren(link)
                if renderer.enableHtmlForInline { renderer.write("</a>") }
            }
        }
    }

    final class LiteralInlineRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is LiteralInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let literal = object as! LiteralInline
            if renderer.enableHtmlEscape { renderer.writeEscape(literal.content) } else { renderer.write(literal.content) }
        }
    }
}
