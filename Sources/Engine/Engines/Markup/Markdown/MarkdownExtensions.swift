// The Markdig extensions of Filee's pipelines: `UseAdvancedExtensions()` (alerts, abbreviations, auto identifiers,
// citations, custom containers, definition lists, emphasis extras, figures, footers, footnotes, grid and pipe
// tables, mathematics, media links, list extras, task lists, diagrams, auto links, generic attributes) and
// `UseYamlFrontMatter()`, with Markdig's parser order and output.

import Foundation

extension Markdown.PipelineBuilder {
    /// `UseAdvancedExtensions()`.
    @discardableResult
    func useAdvancedExtensions() -> Markdown.PipelineBuilder {
        replaceOrAddExtension(Markdown.AlertExtension())
        addExtensionIfNotAlready(Markdown.AbbreviationExtension())
        addExtensionIfNotAlready(Markdown.AutoIdentifierExtension())
        addExtensionIfNotAlready(Markdown.CitationExtension())
        addExtensionIfNotAlready(Markdown.CustomContainerExtension())
        addExtensionIfNotAlready(Markdown.DefinitionListExtension())
        addExtensionIfNotAlready(Markdown.EmphasisExtraExtension())
        addExtensionIfNotAlready(Markdown.FigureExtension())
        addExtensionIfNotAlready(Markdown.FooterExtension())
        addExtensionIfNotAlready(Markdown.FootnoteExtension())
        addExtensionIfNotAlready(Markdown.GridTableExtension())
        addExtensionIfNotAlready(Markdown.MathExtension())
        addExtensionIfNotAlready(Markdown.MediaLinkExtension())
        addExtensionIfNotAlready(Markdown.PipeTableExtension())
        addExtensionIfNotAlready(Markdown.ListExtraExtension())
        addExtensionIfNotAlready(Markdown.TaskListExtension())
        addExtensionIfNotAlready(Markdown.DiagramExtension())
        replaceOrAddExtension(Markdown.AutoLinkExtension())
        addExtensionIfNotAlready(Markdown.GenericAttributesExtension())
        return self
    }

    /// `UseYamlFrontMatter()`.
    @discardableResult
    func useYamlFrontMatter() -> Markdown.PipelineBuilder {
        addExtensionIfNotAlready(Markdown.YamlFrontMatterExtension())
        return self
    }
}

extension Markdown.HtmlRenderer {
    func containsRenderer<T: Markdown.ObjectRenderer>(_ type: T.Type) -> Bool { objectRenderers.contains { $0 is T } }

    func addRendererIfNotAlready<T: Markdown.ObjectRenderer>(_ make: @autoclosure () -> T) {
        if !containsRenderer(T.self) { objectRenderers.append(make()) }
    }

    func insertRendererFirst<T: Markdown.ObjectRenderer>(_ make: @autoclosure () -> T) {
        if !containsRenderer(T.self) { objectRenderers.insert(make(), at: 0) }
    }
}

extension Markdown {
    // MARK: Alerts

    final class AlertBlock: QuoteBlock {
        var kind: Slice
        init(_ kind: Slice) {
            self.kind = kind
            super.init(nil)
        }
    }

    final class AlertExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.inline(AlertInlineParser.self) == nil { builder.insertInline(AlertInlineParser(), before: LinkInlineParser.self) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            if !renderer.objectRenderers.contains(where: { type(of: $0) == AlertBlockRenderer.self }) {
                renderer.insertRenderer(AlertBlockRenderer(), before: QuoteBlockRenderer.self)
            }
        }
    }

    final class AlertInlineParser: InlineParser {
        var allowNestedAlerts = false

        override init() {
            super.init()
            openingCharacters = ["["]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            if slice.peekChar() != "!" { return false }
            guard let paragraph = processor.block as? ParagraphBlock, let quote = paragraph.parent as? QuoteBlock,
                  paragraph.inline?.firstChild == nil, !(quote is AlertBlock), !Self.isInsideAlertBlock(quote),
                  allowNestedAlerts || quote.parent is MarkdownDocument else { return false }
            let saved = slice
            slice.skipChar()
            var c = slice.nextChar()
            var start = slice.start
            var end = start
            while c.isAlpha {
                end = slice.start
                c = slice.nextChar()
            }
            if c != "]" || start == end {
                slice = saved
                return false
            }
            let alertType = Slice(slice.text, start, end)
            c = slice.nextChar()
            start = slice.start
            while true {
                if c == .zero || c == "\n" || c == "\r" {
                    end = slice.start
                    if c == "\r" {
                        c = slice.nextChar()
                        if c == .zero || c == "\n" {
                            end = slice.start
                            if c == "\n" { slice.skipChar() }
                        }
                    } else if c == "\n" {
                        slice.skipChar()
                    }
                    break
                } else if !c.isSpaceOrTab {
                    slice = saved
                    return false
                }
                c = slice.nextChar()
            }
            let alert = AlertBlock(alertType)
            alert.span = quote.span
            alert.line = quote.line
            alert.column = quote.column
            let attributes = alert.getAttributes()
            attributes.addClass("markdown-alert")
            attributes.addClass("markdown-alert-" + alertType.description.lowercased())
            quote.replaceBy(alert)
            processor.replaceParentContainer(quote, alert)
            return true
        }

        private static func isInsideAlertBlock(_ block: Block) -> Bool {
            var parent = block.parent
            while let current = parent {
                if current is AlertBlock { return true }
                parent = current.parent
            }
            return false
        }
    }

    final class AlertBlockRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is AlertBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let alert = object as! AlertBlock
            renderer.ensureLine()
            if renderer.enableHtmlForBlock {
                renderer.write("<div")
                renderer.writeAttributes(alert)
                renderer.writeLine(">" as Char)
            }
            if alert.kind.length < 16, let title = Markdown.alertTitles[alert.kind.description.uppercased()] {
                renderer.writeLine(title)
            }
            let saved = renderer.implicitParagraph
            renderer.implicitParagraph = false
            renderer.writeChildren(alert)
            renderer.implicitParagraph = saved
            if renderer.enableHtmlForBlock { renderer.writeLine("</div>") }
            renderer.ensureLine()
        }
    }

    // MARK: Abbreviations

    final class Abbreviation: LeafBlock {
        var label: String?
        var text = Slice.empty
        var labelSpan = SourceSpan.empty
    }

    final class AbbreviationInline: LeafInline {
        let abbreviation: Abbreviation
        init(_ abbreviation: Abbreviation) { self.abbreviation = abbreviation }
    }

    /// The document's abbreviations by label; a later definition replaces an earlier one.
    final class AbbreviationMap {
        var entries: [(String, Abbreviation)] = []
        func set(_ label: String, _ abbreviation: Abbreviation) {
            if let index = entries.firstIndex(where: { $0.0 == label }) { entries[index].1 = abbreviation } else { entries.append((label, abbreviation)) }
        }
    }

    final class AbbreviationExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.block(AbbreviationParser.self) == nil { builder.blockParsers.append(AbbreviationParser()) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) { renderer.insertRendererFirst(HtmlAbbreviationRenderer()) }
    }

    final class AbbreviationParser: BlockParser {
        static let documentKey = "Abbreviations"

        override init() {
            super.init()
            openingCharacters = ["*"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            var slice = processor.line
            let startPosition = slice.start
            var c = slice.nextChar()
            if c != "[" { return .none }
            guard let parsed = LinkHelper.tryParseLabel(&slice) else { return .none }
            c = slice.currentChar
            if c != ":" { return .none }
            slice.skipChar()
            slice.trim()
            let abbreviation = Abbreviation(self)
            abbreviation.label = parsed.label
            abbreviation.text = slice
            abbreviation.span = SourceSpan(startPosition, slice.end)
            abbreviation.line = processor.lineIndex
            abbreviation.column = processor.column
            abbreviation.labelSpan = parsed.span
            let document = processor.document
            let map: AbbreviationMap
            if let existing = document.data[Self.documentKey] as? AbbreviationMap {
                map = existing
            } else {
                map = AbbreviationMap()
                document.data[Self.documentKey] = map
                document.processInlinesEnd.append { processor, _ in Self.documentOnProcessInlinesEnd(processor) }
            }
            map.set(parsed.label, abbreviation)
            return .breakDiscard
        }

        private static func documentOnProcessInlinesEnd(_ processor: InlineProcessor) {
            guard let map = processor.document.data[documentKey] as? AbbreviationMap else { return }
            let labels = map.entries.map { (Markdown.chars($0.0), $0.1) }
            for leaf in processor.document.blockDescendants(LeafBlock.self) {
                guard let root = leaf.inline else { continue }
                var stack: [ContainerInline] = [root]
                while let container = stack.popLast() {
                    var child = container.firstChild
                    while let current = child {
                        let next = current.nextSibling
                        if let literal = current as? LiteralInline {
                            substituteInLiteral(literal, labels)
                        } else if let inner = current as? ContainerInline {
                            stack.append(inner)
                        }
                        child = next
                    }
                }
            }
        }

        /// The longest label that starts at `index` (`CompactPrefixTree.TryMatchLongest`).
        private static func matchLongest(_ text: [Char], _ index: Int, _ end: Int, _ labels: [([Char], Abbreviation)]) -> ([Char], Abbreviation)? {
            var best: ([Char], Abbreviation)?
            for entry in labels where !entry.0.isEmpty && index + entry.0.count - 1 <= end {
                var matches = true
                for (k, c) in entry.0.enumerated() where text[index + k] != c {
                    matches = false
                    break
                }
                if matches && entry.0.count > (best?.0.count ?? 0) { best = entry }
            }
            return best
        }

        private static func substituteInLiteral(_ literal: LiteralInline, _ labels: [([Char], Abbreviation)]) {
            var content = literal.content
            let text = content.text
            guard literal.parent != nil else { return }
            let originalSpanEnd = literal.span.end
            var currentLiteral = literal
            var i = content.start
            while i <= content.end {
                if i != content.start {
                    var j = i - 1
                    var found = false
                    while j <= content.end {
                        if text[j].isWhitespace {
                            j += 1
                            found = true
                            break
                        }
                        j += 1
                    }
                    if !found { break }
                    i = j
                }
                if i <= content.end, let match = matchLongest(text, i, content.end, labels) {
                    if !isValidAbbreviationEnding(match.0.count, content, i) {
                        i += 1
                        continue
                    }
                    let indexAfterMatch = i + match.0.count
                    let charOffset = i - literal.content.start
                    let abbreviationSpanStart = literal.span.start + charOffset
                    let abbreviation = AbbreviationInline(match.1)
                    abbreviation.span = SourceSpan(abbreviationSpanStart, abbreviationSpanStart + match.0.count - 1)
                    abbreviation.line = literal.line
                    abbreviation.column = literal.column + charOffset
                    currentLiteral.content.end = i - 1
                    currentLiteral.span.end = abbreviationSpanStart - 1
                    currentLiteral.insertAfter(abbreviation)
                    if currentLiteral.content.end < currentLiteral.content.start { currentLiteral.remove() }
                    if indexAfterMatch <= content.end {
                        var remainingContent = content
                        remainingContent.start = indexAfterMatch
                        let remaining = LiteralInline(remainingContent)
                        remaining.span = SourceSpan(abbreviation.span.end + 1, originalSpanEnd)
                        remaining.line = literal.line
                        remaining.column = literal.column + (indexAfterMatch - literal.content.start)
                        abbreviation.insertAfter(remaining)
                        currentLiteral = remaining
                        content = remainingContent
                        i = indexAfterMatch - 1
                    } else {
                        break
                    }
                }
                i += 1
            }
        }

        private static func isValidAbbreviationEnding(_ matchLength: Int, _ content: Slice, _ matchIndex: Int) -> Bool {
            var index = matchIndex + matchLength
            let end = content.end + 1
            while index <= end {
                let c = content.peekCharAbsolute(index)
                if c.isWhitespace { break }
                if !c.isAsciiPunctuationOrZero { return false }
                index += 1
            }
            return true
        }
    }

    final class HtmlAbbreviationRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is AbbreviationInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let inline = object as! AbbreviationInline
            let abbreviation = inline.abbreviation
            if renderer.enableHtmlForInline {
                renderer.write("<abbr")
                renderer.writeAttributes(inline)
                renderer.write(" title=\"")
                renderer.writeEscape(abbreviation.text)
                renderer.write("\">")
            }
            renderer.write(abbreviation.label)
            if renderer.enableHtmlForInline { renderer.write("</abbr>") }
        }
    }

    // MARK: Auto identifiers

    final class HeadingLinkReferenceDefinition: LinkReferenceDefinition {
        let heading: HeadingBlock
        init(_ heading: HeadingBlock) {
            self.heading = heading
            super.init(nil, nil, nil)
            allowResolutionInsideOpenLink = false
        }
    }

    /// `UseAutoIdentifiers()` with the default options: heading ids from their text (ASCII only) and `[Heading]`
    /// links to them.
    final class AutoIdentifierExtension: PipelineExtension {
        private static let identifiersKey = "AutoIdentifier"
        private static let headingsKey = "AutoIdentifierHeadings"

        /// Heading texts and their implicit link definitions, in insertion order (a later heading replaces the entry).
        final class HeadingDefinitions {
            var entries: [(String, HeadingLinkReferenceDefinition)] = []
        }

        func setupPipeline(_ builder: PipelineBuilder) {
            let handler: (BlockProcessor, Block) -> Void = { [unowned self] processor, block in self.headingClosed(processor, block) }
            builder.block(HeadingBlockParser.self)?.closed.append(handler)
            if let paragraphParser = builder.blockParsers.first(where: { type(of: $0) == ParagraphBlockParser.self }) {
                paragraphParser.closed.append(handler)
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {}

        private func headingClosed(_ processor: BlockProcessor, _ block: Block) {
            guard let heading = block as? HeadingBlock else { return }
            let text = heading.lines.count > 0 ? heading.lines[0].slice.description : ""
            let definition = HeadingLinkReferenceDefinition(heading)
            definition.createLinkInline = { _, linkRef, _ in
                let heading = (linkRef as! HeadingLinkReferenceDefinition).heading
                let link = LinkInline()
                link.getDynamicUrl = { HtmlHelper.unescape("#" + (heading.getAttributes().id ?? "")) }
                link.title = HtmlHelper.unescape(linkRef.title)
                return link
            }
            let document = processor.document
            let definitions: HeadingDefinitions
            if let existing = document.data[Self.headingsKey] as? HeadingDefinitions {
                definitions = existing
            } else {
                definitions = HeadingDefinitions()
                document.data[Self.headingsKey] = definitions
                document.processInlinesBegin.append { processor, _ in Self.documentOnProcessInlinesBegin(processor) }
            }
            if let index = definitions.entries.firstIndex(where: { $0.0 == text }) {
                definitions.entries[index].1 = definition
            } else {
                definitions.entries.append((text, definition))
            }
            heading.processInlinesEnd.append { processor, _ in Self.headingProcessInlinesEnd(processor) }
        }

        private static func documentOnProcessInlinesBegin(_ processor: InlineProcessor) {
            let document = processor.document
            guard let definitions = document.data[headingsKey] as? HeadingDefinitions else { return }
            for (key, value) in definitions.entries where document.tryGetLinkReferenceDefinition(key) == nil {
                document.setLinkReferenceDefinition(key, value, addGroup: false)
            }
            document.data[headingsKey] = nil
        }

        final class Identifiers { var set = Set<String>() }

        private static func headingProcessInlinesEnd(_ processor: InlineProcessor) {
            let identifiers: Identifiers
            if let existing = processor.document.data[identifiersKey] as? Identifiers {
                identifiers = existing
            } else {
                identifiers = Identifiers()
                processor.document.data[identifiersKey] = identifiers
            }
            guard let heading = processor.block as? HeadingBlock, let inline = heading.inline else { return }
            let attributes = heading.getAttributes()
            if attributes.id != nil { return }
            let stripRenderer = HtmlRenderer()
            stripRenderer.enableHtmlForInline = false
            stripRenderer.enableHtmlEscape = false
            stripRenderer.write(inline)
            let headingText = LinkHelper.urilize(stripRenderer.text, allowOnlyAscii: true)
            let baseId = headingText.isEmpty ? "section" : headingText
            var headingId = baseId
            if !identifiers.set.insert(headingId).inserted {
                var index = 0
                repeat {
                    index += 1
                    headingId = "\(baseId)-\(index)"
                } while !identifiers.set.insert(headingId).inserted
            }
            attributes.id = headingId
        }
    }

    // MARK: Citations, emphasis extras, custom containers

    final class CitationExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if let parser = builder.inlineParsers.first(where: { type(of: $0) == EmphasisInlineParser.self }) as? EmphasisInlineParser,
               !parser.hasEmphasisChar("\"") {
                parser.emphasisDescriptors.append(EmphasisDescriptor("\"", 2, 2, false))
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            if let emphasis = renderer.objectRenderers.first(where: { type(of: $0) == EmphasisInlineRenderer.self }) as? EmphasisInlineRenderer {
                let previous = emphasis.getTag
                emphasis.getTag = { inline in
                    inline.delimiterCount == 2 && inline.delimiterChar == "\"" ? "cite" : previous(inline)
                }
            }
        }
    }

    final class EmphasisExtraExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            guard let parser = builder.inlineParsers.first(where: { type(of: $0) == EmphasisInlineParser.self }) as? EmphasisInlineParser else { return }
            let characters = parser.emphasisDescriptors.map(\.character)
            if !characters.contains("~") { parser.emphasisDescriptors.append(EmphasisDescriptor("~", 1, 2, true)) }
            if !characters.contains("^") { parser.emphasisDescriptors.append(EmphasisDescriptor("^", 1, 1, true)) }
            if !characters.contains("+") { parser.emphasisDescriptors.append(EmphasisDescriptor("+", 2, 2, true)) }
            if !characters.contains("=") { parser.emphasisDescriptors.append(EmphasisDescriptor("=", 2, 2, true)) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            if let emphasis = renderer.objectRenderers.first(where: { type(of: $0) == EmphasisInlineRenderer.self }) as? EmphasisInlineRenderer {
                let previous = emphasis.getTag
                emphasis.getTag = { inline in
                    switch inline.delimiterChar {
                    case "~": return inline.delimiterCount == 2 ? "del" : "sub"
                    case "^": return "sup"
                    case "+": return "ins"
                    case "=": return "mark"
                    default: return previous(inline)
                    }
                }
            }
        }
    }

    final class CustomContainer: ContainerBlock, FencedBlock {
        var fencedChar = Char.zero
        var openingFencedCharCount = 0
        var closingFencedCharCount = 0
        var info: String?
        var arguments: String?
    }

    final class CustomContainerInline: EmphasisInline {}

    final class CustomContainerParser: FencedBlockParserBase {
        override init() {
            super.init()
            openingCharacters = [":"]
            infoPrefix = nil
        }

        override func createFencedBlock(_ processor: BlockProcessor) -> FencedBlock { CustomContainer(self) }
    }

    final class CustomContainerExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.block(CustomContainerParser.self) == nil { builder.blockParsers.insert(CustomContainerParser(), at: 0) }
            if let parser = builder.inline(EmphasisInlineParser.self), !parser.hasEmphasisChar(":") {
                parser.emphasisDescriptors.append(EmphasisDescriptor(":", 2, 2, true))
                parser.tryCreateEmphasisInlineList.append { character, count in
                    guard count == 2 && character == ":" else { return nil }
                    let inline = CustomContainerInline()
                    inline.delimiterChar = ":"
                    inline.delimiterCount = 2
                    return inline
                }
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            renderer.insertRendererFirst(HtmlCustomContainerRenderer())
            renderer.insertRendererFirst(HtmlCustomContainerInlineRenderer())
        }
    }

    final class HtmlCustomContainerRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is CustomContainer }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let container = object as! CustomContainer
            renderer.ensureLine()
            if renderer.enableHtmlForBlock {
                renderer.write("<div")
                renderer.writeAttributes(container)
                renderer.write(">" as Char)
            }
            renderer.writeChildren(container)
            if renderer.enableHtmlForBlock { renderer.writeLine("</div>") }
        }
    }

    final class HtmlCustomContainerInlineRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is CustomContainerInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let inline = object as! CustomContainerInline
            renderer.write("<span")
            renderer.writeAttributes(inline)
            renderer.write(">" as Char)
            renderer.writeChildren(inline)
            renderer.write("</span>")
        }
    }

    // MARK: Definition lists

    final class DefinitionList: ContainerBlock {}

    final class DefinitionItem: ContainerBlock {
        var openingCharacter = Char.zero
    }

    final class DefinitionTerm: LeafBlock {
        override init(_ parser: BlockParser?) {
            super.init(parser)
            processInlines = true
        }
    }

    final class DefinitionListExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.block(DefinitionListParser.self) == nil { builder.blockParsers.insert(DefinitionListParser(), at: 0) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) { renderer.insertRendererFirst(HtmlDefinitionListRenderer()) }
    }

    final class DefinitionListParser: BlockParser {
        override init() {
            super.init()
            openingCharacters = [":", "~"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            guard !processor.isCodeIndent, let paragraph = processor.lastBlock as? ParagraphBlock,
                  paragraph.line + paragraph.lines.count - 1 - processor.lineIndex <= 1 else { return .none }
            let column = processor.columnBeforeIndent
            processor.nextChar()
            processor.parseIndent()
            let delta = processor.column - column
            if delta < 4 {
                processor.goToColumn(column)
                return .none
            }
            if delta > 4 { processor.goToColumn(column + 4) }
            let previousParent = paragraph.parent!
            var currentList = Self.currentDefinitionList(paragraph, previousParent)
            processor.discard(paragraph)
            paragraph.parent?.remove(paragraph)
            if currentList == nil {
                let list = DefinitionList(self)
                list.span = SourceSpan(paragraph.span.start, processor.line.end)
                list.column = paragraph.column
                list.line = paragraph.line
                previousParent.add(list)
                currentList = list
            }
            let item = DefinitionItem(self)
            item.line = processor.lineIndex
            item.column = column
            item.span = SourceSpan(paragraph.span.start, processor.line.end)
            item.openingCharacter = processor.currentChar
            for line in paragraph.lines.lines {
                let term = DefinitionTerm(self)
                term.column = paragraph.column
                term.line = line.line
                term.span = SourceSpan(paragraph.span.start, paragraph.span.end)
                term.isOpen = false
                term.appendLine(line.slice, column: line.column, line: line.line, sourceLinePosition: line.position)
                item.add(term)
            }
            currentList!.add(item)
            processor.open(item)
            currentList!.updateSpanEnd(processor.line.end)
            return .continue
        }

        private static func currentDefinitionList(_ paragraph: ParagraphBlock, _ previousParent: ContainerBlock) -> DefinitionList? {
            guard let paragraphIndex = previousParent.indexOf(paragraph) else { return nil }
            let index = paragraphIndex - 1
            if index < 0 { return nil }
            if let list = previousParent[index] as? DefinitionList { return list }
            if previousParent[index] is BlankLineBlock, index > 0, let list = previousParent[index - 1] as? DefinitionList {
                previousParent.removeAt(index)
                return list
            }
            return nil
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let item = block as! DefinitionItem
            if processor.isCodeIndent {
                processor.goToCodeIndent()
                return .continue
            }
            let list = item.parent as! DefinitionList
            let lastBlankLine = item.lastChild as? BlankLineBlock
            if openingCharacters!.contains(processor.currentChar) {
                let startPosition = processor.start
                let column = processor.columnBeforeIndent
                processor.nextChar()
                processor.parseIndent()
                let delta = processor.column - column
                if delta < 4 {
                    if lastBlankLine != nil { item.removeAt(item.count - 1) }
                    list.span.end = list.lastChild!.span.end
                    return .none
                }
                if delta > 4 { processor.goToColumn(column + 4) }
                processor.close(item)
                let next = DefinitionItem(self)
                next.span = SourceSpan(startPosition, processor.line.end)
                next.line = processor.lineIndex
                next.column = processor.column
                next.openingCharacter = processor.currentChar
                list.add(next)
                processor.open(next)
                return .continue
            }
            let isBreakable = item.lastChild?.isBreakable ?? true
            if processor.isBlankLine {
                if lastBlankLine == nil && isBreakable { item.add(BlankLineBlock()) }
                return isBreakable ? .continueDiscard : .continue
            }
            if lastBlankLine == nil && item.lastChild is ParagraphBlock { return .continue }
            if lastBlankLine != nil { item.removeAt(item.count - 1) }
            list.span.end = list.lastChild!.span.end
            return .break
        }
    }

    final class HtmlDefinitionListRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is DefinitionList }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let list = object as! DefinitionList
            renderer.ensureLine()
            renderer.write("<dl")
            renderer.writeAttributes(list)
            renderer.writeLine(">" as Char)
            for case let item as DefinitionItem in list.children {
                var hasOpenDd = false
                var countDd = 0
                var lastWasSimpleParagraph = false
                for i in 0..<item.count {
                    let child = item[i]
                    if let term = child as? DefinitionTerm {
                        if hasOpenDd {
                            if !lastWasSimpleParagraph { renderer.ensureLine() }
                            renderer.writeLine("</dd>")
                            lastWasSimpleParagraph = false
                            hasOpenDd = false
                            countDd = 0
                        }
                        renderer.write("<dt")
                        renderer.writeAttributes(term)
                        renderer.write(">" as Char)
                        renderer.writeLeafInline(term)
                        renderer.writeLine("</dt>")
                    } else {
                        if !hasOpenDd {
                            renderer.write("<dd")
                            renderer.writeAttributes(item)
                            renderer.write(">" as Char)
                            countDd = 0
                            hasOpenDd = true
                        }
                        let next: Block? = i + 1 < item.count ? item[i + 1] : nil
                        let isSimpleParagraph = (next == nil || next is DefinitionItem) && countDd == 0 && child is ParagraphBlock
                        let saved = renderer.implicitParagraph
                        if isSimpleParagraph {
                            renderer.implicitParagraph = true
                            lastWasSimpleParagraph = true
                        }
                        renderer.write(child)
                        renderer.implicitParagraph = saved
                        countDd += 1
                    }
                }
                if hasOpenDd {
                    if !lastWasSimpleParagraph { renderer.ensureLine() }
                    renderer.writeLine("</dd>")
                }
            }
            renderer.ensureLine()
            renderer.writeLine("</dl>")
        }
    }

    // MARK: Figures and footers

    final class Figure: ContainerBlock {
        var openingCharacterCount = 0
        var openingCharacter = Char.zero
    }

    final class FigureCaption: LeafBlock {
        override init(_ parser: BlockParser?) {
            super.init(parser)
            processInlines = true
        }
    }

    final class FigureExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            guard builder.block(FigureBlockParser.self) == nil else { return }
            if builder.block(FooterBlockParser.self) != nil {
                builder.insertBlock(FigureBlockParser(), before: FooterBlockParser.self)
            } else {
                builder.blockParsers.insert(FigureBlockParser(), at: 0)
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            renderer.addRendererIfNotAlready(HtmlFigureRenderer())
            renderer.addRendererIfNotAlready(HtmlFigureCaptionRenderer())
        }
    }

    final class FigureBlockParser: BlockParser {
        override init() {
            super.init()
            openingCharacters = ["^"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            var line = processor.line
            let openingChar = line.currentChar
            let count = line.countAndSkipChar(openingChar)
            if count < 3 { return .none }
            let startPosition = processor.start
            let column = processor.column
            let figure = Figure(self)
            figure.span = SourceSpan(startPosition, line.end)
            figure.line = processor.lineIndex
            figure.column = column
            figure.openingCharacter = openingChar
            figure.openingCharacterCount = count
            line.trimStart()
            if !line.isEmpty {
                let caption = FigureCaption(self)
                caption.span = SourceSpan(line.start, line.end)
                caption.line = processor.lineIndex
                caption.column = column + line.start - startPosition
                caption.isOpen = false
                caption.appendLine(line, column: caption.column, line: processor.lineIndex, sourceLinePosition: processor.currentLineStartPosition)
                figure.add(caption)
            }
            processor.newBlocks.append(figure)
            return .continueDiscard
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let figure = block as! Figure
            var count = figure.openingCharacterCount
            let column = processor.column
            var line = processor.line
            let startPosition = line.start
            count -= line.countAndSkipChar(figure.openingCharacter)
            if count <= 0 && !processor.isCodeIndent {
                line.trimStart()
                if !line.isEmpty {
                    let caption = FigureCaption(self)
                    caption.span = SourceSpan(line.start, line.end)
                    caption.line = processor.lineIndex
                    caption.column = column + line.start - startPosition
                    caption.isOpen = false
                    caption.appendLine(line, column: caption.column, line: processor.lineIndex, sourceLinePosition: processor.currentLineStartPosition)
                    figure.add(caption)
                }
                figure.updateSpanEnd(line.end)
                return .breakDiscard
            }
            processor.goToColumn(processor.columnBeforeIndent)
            figure.updateSpanEnd(line.end)
            return .continue
        }
    }

    final class HtmlFigureRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is Figure }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let figure = object as! Figure
            renderer.ensureLine()
            renderer.write("<figure")
            renderer.writeAttributes(figure)
            renderer.writeLine(">")
            renderer.writeChildren(figure)
            renderer.writeLine("</figure>")
        }
    }

    final class HtmlFigureCaptionRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is FigureCaption }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let caption = object as! FigureCaption
            renderer.ensureLine()
            renderer.write("<figcaption")
            renderer.writeAttributes(caption)
            renderer.write(">" as Char)
            renderer.writeLeafInline(caption)
            renderer.writeLine("</figcaption>")
        }
    }

    final class FooterBlock: ContainerBlock {
        var openingCharacter = Char.zero
    }

    final class FooterExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            guard builder.block(FooterBlockParser.self) == nil else { return }
            if let index = builder.blockParsers.firstIndex(where: { $0 is FigureBlockParser }) {
                builder.blockParsers.insert(FooterBlockParser(), at: index + 1)
            } else {
                builder.blockParsers.insert(FooterBlockParser(), at: 0)
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) { renderer.addRendererIfNotAlready(HtmlFooterBlockRenderer()) }
    }

    final class FooterBlockParser: BlockParser {
        override init() {
            super.init()
            openingCharacters = ["^"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            let column = processor.column
            let startPosition = processor.start
            let openingChar = processor.currentChar
            if processor.peekChar(1) != openingChar { return .none }
            processor.nextChar()
            let c = processor.nextChar()
            if c.isSpaceOrTab { processor.nextColumn() }
            let footer = FooterBlock(self)
            footer.span = SourceSpan(startPosition, processor.line.end)
            footer.openingCharacter = openingChar
            footer.column = column
            footer.line = processor.lineIndex
            processor.newBlocks.append(footer)
            return .continue
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            if processor.isCodeIndent { return .none }
            let footer = block as! FooterBlock
            var c = processor.currentChar
            if c != footer.openingCharacter || processor.peekChar(1) != c {
                return processor.isBlankLine ? .breakDiscard : .none
            }
            processor.nextChar()
            c = processor.nextChar()
            if c.isSpace { processor.nextChar() }
            footer.updateSpanEnd(processor.line.end)
            return .continue
        }
    }

    final class HtmlFooterBlockRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is FooterBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let footer = object as! FooterBlock
            renderer.ensureLine()
            renderer.write("<footer")
            renderer.writeAttributes(footer)
            renderer.write(">")
            let saved = renderer.implicitParagraph
            renderer.implicitParagraph = true
            renderer.writeChildren(footer)
            renderer.implicitParagraph = saved
            renderer.writeLine("</footer>")
        }
    }

    // MARK: Footnotes

    final class Footnote: ContainerBlock {
        var label: String?
        var order = -1
        var links: [FootnoteLink] = []
        var labelSpan = SourceSpan.empty
        var isLastLineEmpty = false
    }

    final class FootnoteGroup: ContainerBlock {
        var currentOrder = 0

        /// `ContainerBlock.Sort` (.NET's `Array.Sort`, an unstable introsort).
        func sort(_ comparison: (Block, Block) -> Int) {
            var items = children
            Markdown.introSort(&items, comparison)
            let moving = items
            clear()
            for item in moving { add(item) }
        }
    }

    /// A reference to a footnote, or the back link at the end of the footnote. Neither a leaf nor a container, like
    /// Markdig's (an `Inline`).
    final class FootnoteLink: Inline {
        let footnote: Footnote
        var isBackLink = false
        var index = 0
        init(_ footnote: Footnote) { self.footnote = footnote }
    }

    final class FootnoteLinkReferenceDefinition: LinkReferenceDefinition {
        let footnote: Footnote
        init(_ footnote: Footnote) {
            self.footnote = footnote
            super.init(nil, nil, nil)
        }
    }

    final class FootnoteExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.block(FootnoteParser.self) == nil { builder.blockParsers.insert(FootnoteParser(), at: 0) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            renderer.addRendererIfNotAlready(HtmlFootnoteGroupRenderer())
            renderer.addRendererIfNotAlready(HtmlFootnoteLinkRenderer())
        }
    }

    final class FootnoteParser: BlockParser {
        static let documentKey = "Footnotes"

        override init() {
            super.init()
            openingCharacters = ["["]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState { tryOpen(processor, isContinue: false) }

        private func tryOpen(_ processor: BlockProcessor, isContinue: Bool) -> BlockState {
            let currentContainer = processor.currentContainerOpened()
            if processor.isCodeIndent || (!isContinue && type(of: currentContainer) != MarkdownDocument.self)
                || (isContinue && !(currentContainer is FootnoteGroup)) {
                return .none
            }
            let saved = processor.column
            let start = processor.start
            var line = processor.line
            let parsed = LinkHelper.tryParseLabel(&line)
            processor.line = line
            guard let parsed, parsed.label.hasPrefix("^"), processor.currentChar == ":" else {
                processor.goToColumn(saved)
                return .none
            }
            processor.column += processor.start - start
            processor.nextChar()
            let footnote = Footnote(self)
            footnote.label = parsed.label
            footnote.labelSpan = parsed.span
            footnote.column = processor.column
            footnote.span = SourceSpan(processor.start, processor.line.end)
            let document = processor.document
            let group: FootnoteGroup
            if let existing = document.data[Self.documentKey] as? FootnoteGroup {
                group = existing
            } else {
                group = FootnoteGroup(self)
                document.add(group)
                document.data[Self.documentKey] = group
                document.processInlinesEnd.append { processor, _ in Self.documentProcessInlinesEnd(processor) }
            }
            group.add(footnote)
            let linkRef = FootnoteLinkReferenceDefinition(footnote)
            linkRef.createLinkInline = { state, linkRef, _ in Self.createLinkToFootnote(state, linkRef) }
            linkRef.line = processor.lineIndex
            linkRef.column = saved
            linkRef.span = SourceSpan(start, processor.start - 2)
            linkRef.labelSpan = parsed.span
            linkRef.label = parsed.label
            document.setLinkReferenceDefinition(parsed.label, linkRef, addGroup: true)
            processor.newBlocks.append(footnote)
            return .continue
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let footnote = block as! Footnote
            if processor.currentBlock == nil || processor.currentBlock!.isBreakable {
                if processor.isBlankLine {
                    footnote.isLastLineEmpty = true
                    return .continueDiscard
                }
                if processor.column == 0 {
                    if footnote.isLastLineEmpty {
                        processor.close(footnote)
                        return tryOpen(processor)
                    }
                    if tryOpen(processor, isContinue: true) == .continue {
                        processor.close(footnote)
                        return .continue
                    }
                }
            }
            footnote.isLastLineEmpty = false
            if processor.isCodeIndent { processor.goToCodeIndent() }
            return .continue
        }

        private static func documentProcessInlinesEnd(_ state: InlineProcessor) {
            let document = state.document
            guard let footnotes = document.data[documentKey] as? FootnoteGroup else { return }
            document.remove(footnotes)
            document.add(footnotes)
            document.data[documentKey] = nil
            footnotes.sort { left, right in
                let leftOrder = (left as! Footnote).order
                let rightOrder = (right as! Footnote).order
                return leftOrder >= 0 && rightOrder >= 0 ? (leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0) : 0
            }
            var linkIndex = 0
            var i = 0
            while i < footnotes.count {
                let footnote = footnotes[i] as! Footnote
                if footnote.order < 0 {
                    footnotes.removeAt(i)
                    continue
                }
                var paragraph = footnote.lastChild as? ParagraphBlock
                if paragraph == nil {
                    let created = ParagraphBlock(nil)
                    footnote.add(created)
                    paragraph = created
                }
                if paragraph!.inline == nil { paragraph!.inline = ContainerInline() }
                for link in footnote.links {
                    linkIndex += 1
                    link.index = linkIndex
                    let backLink = FootnoteLink(footnote)
                    backLink.index = linkIndex
                    backLink.isBackLink = true
                    paragraph!.inline!.appendChild(backLink)
                }
                i += 1
            }
        }

        private static func createLinkToFootnote(_ state: InlineProcessor, _ linkRef: LinkReferenceDefinition) -> Inline {
            let footnote = (linkRef as! FootnoteLinkReferenceDefinition).footnote
            if footnote.order < 0, let footnotes = state.document.data[documentKey] as? FootnoteGroup {
                footnotes.currentOrder += 1
                footnote.order = footnotes.currentOrder
            }
            let link = FootnoteLink(footnote)
            footnote.links.append(link)
            return link
        }
    }

    final class HtmlFootnoteGroupRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is FootnoteGroup }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let footnotes = object as! FootnoteGroup
            renderer.ensureLine()
            renderer.writeLine("<div class=\"footnotes\">")
            renderer.writeLine("<hr />")
            renderer.writeLine("<ol>")
            for case let footnote as Footnote in footnotes.children {
                renderer.writeLine("<li id=\"fn:\(footnote.order)\">")
                renderer.writeChildren(footnote)
                renderer.writeLine("</li>")
            }
            renderer.writeLine("</ol>")
            renderer.writeLine("</div>")
        }
    }

    final class HtmlFootnoteLinkRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is FootnoteLink }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let link = object as! FootnoteLink
            let order = link.footnote.order
            renderer.write(link.isBackLink
                ? "<a href=\"#fnref:\(link.index)\" class=\"footnote-back-ref\">&#8617;</a>"
                : "<a id=\"fnref:\(link.index)\" href=\"#fn:\(order)\" class=\"footnote-ref\"><sup>\(order)</sup></a>")
        }
    }

    // MARK: Mathematics

    final class MathBlock: FencedCodeBlock {}

    final class MathInline: LeafInline {
        var delimiter = Char.zero
        var delimiterCount = 0
        var content = Slice.empty
    }

    final class MathExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.inline(MathInlineParser.self) == nil { builder.inlineParsers.insert(MathInlineParser(), at: 0) }
            if builder.block(MathBlockParser.self) == nil { builder.blockParsers.insert(MathBlockParser(), at: 0) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            renderer.insertRendererFirst(HtmlMathInlineRenderer())
            renderer.insertRendererFirst(HtmlMathBlockRenderer())
        }
    }

    final class MathBlockParser: FencedBlockParserBase {
        override init() {
            super.init()
            openingCharacters = ["$"]
            minimumMatchCount = 2
            maximumMatchCount = 2
            infoParser = { _, line, _, _ in
                var i = line.start
                while i <= line.end {
                    if !line.text[i].isSpaceOrTab { return false }
                    i += 1
                }
                return true
            }
            infoPrefix = nil
        }

        override func createFencedBlock(_ processor: BlockProcessor) -> FencedBlock {
            let block = MathBlock(self)
            block.getAttributes().addClass("math")
            return block
        }
    }

    final class MathInlineParser: InlineParser {
        override init() {
            super.init()
            openingCharacters = ["$"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let match = slice.currentChar
            var previous = slice.peekCharExtra(-1)
            if previous == match { return false }
            let startPosition = slice.start
            var openDollars = 1
            var c = slice.nextChar()
            if c == match {
                openDollars += 1
                c = slice.nextChar()
            }
            let (openPrevIsWhiteSpace, openPrevIsPunctuation) = Markdown.unicodeCategory(of: previous)
            let openNextIsWhiteSpace = Markdown.unicodeCategory(of: c).space
            if !openPrevIsWhiteSpace && !openPrevIsPunctuation { return false }
            var closeDollars = 0
            while c.isSpaceOrTab { c = slice.nextChar() }
            let start = slice.start
            var end = 0
            previous = match
            var lastWhiteSpace = -1
            while c != .zero {
                if c == "\r" || c == "\n" { return false }
                if previous != "\\" {
                    if c.isSpaceOrTab {
                        if lastWhiteSpace < 0 { lastWhiteSpace = slice.start }
                    } else {
                        let hasClosingDollars = c == match
                        if hasClosingDollars {
                            closeDollars += slice.countAndSkipChar(match)
                            c = slice.currentChar
                        }
                        if closeDollars >= openDollars { break }
                        lastWhiteSpace = -1
                        if hasClosingDollars {
                            previous = match
                            continue
                        }
                    }
                }
                if closeDollars > 0 {
                    closeDollars = 0
                } else {
                    previous = c
                    c = slice.nextChar()
                }
            }
            guard closeDollars >= openDollars else { return false }
            let closePrevIsWhiteSpace = Markdown.unicodeCategory(of: previous).space
            let (closeNextIsWhiteSpace, closeNextIsPunctuation) = Markdown.unicodeCategory(of: c)
            if (!closeNextIsPunctuation && !closeNextIsWhiteSpace) || openNextIsWhiteSpace != closePrevIsWhiteSpace { return false }
            if closePrevIsWhiteSpace && lastWhiteSpace > 0 {
                end = lastWhiteSpace + openDollars - 1
            } else {
                end = slice.start - 1
            }
            let inline = MathInline()
            inline.span = SourceSpan(processor.getSourcePosition(startPosition), processor.getSourcePosition(slice.start - 1))
            inline.delimiter = match
            inline.delimiterCount = openDollars
            inline.content = slice
            inline.content.start = start
            inline.content.end = end - openDollars
            inline.getAttributes().addClass("math")
            processor.inline = inline
            return true
        }
    }

    final class HtmlMathBlockRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is MathBlock }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let block = object as! MathBlock
            renderer.ensureLine()
            if renderer.enableHtmlForBlock {
                renderer.write("<div")
                renderer.writeAttributes(block)
                renderer.writeLine(">")
                renderer.writeLine("\\[")
            }
            renderer.writeLeafRawLines(block, writeEndOfLines: true, escape: renderer.enableHtmlEscape)
            if renderer.enableHtmlForBlock {
                renderer.write("\\]")
                renderer.writeLine("</div>")
            }
        }
    }

    final class HtmlMathInlineRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is MathInline }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let inline = object as! MathInline
            if renderer.enableHtmlForInline {
                renderer.write("<span")
                renderer.writeAttributes(inline)
                renderer.write(">\\(")
            }
            if renderer.enableHtmlEscape { renderer.writeEscape(inline.content) } else { renderer.write(inline.content) }
            if renderer.enableHtmlForInline { renderer.write("\\)</span>") }
        }
    }

    // MARK: List extras, task lists, diagrams

    final class ListExtraExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if let parser = builder.block(ListBlockParser.self), !parser.itemParsers.contains(where: { $0 is ListExtraItemParser }) {
                parser.itemParsers.append(ListExtraItemParser())
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {}
    }

    /// `a.` / `A)` / `i.` / `IV.` list markers.
    final class ListExtraItemParser: OrderedListItemParser {
        override init() {
            super.init()
            var characters: [Char] = []
            for offset in 0..<26 {
                characters.append(Char(UInt16(0x41 + offset)))
                characters.append(Char(UInt16(0x61 + offset)))
            }
            openingCharacters = characters
        }

        override func tryParse(_ state: BlockProcessor, _ pendingBulletType: Char) -> ListInfo? {
            var info = ListInfo()
            var c = state.currentChar
            let isRomanLow = Markdown.isRomanLetterLowerPartial(c)
            let isRomanUp = !isRomanLow && Markdown.isRomanLetterUpperPartial(c)
            if (isRomanLow || isRomanUp) && (pendingBulletType == .zero || pendingBulletType == "i" || pendingBulletType == "I") {
                let startChar = state.start
                repeat {
                    c = state.nextChar()
                } while isRomanLow ? Markdown.isRomanLetterLowerPartial(c) : Markdown.isRomanLetterUpperPartial(c)
                let value = Markdown.romanToArabic(Array(state.line.text[startChar..<state.start]))
                info.orderedStart = String(value)
                info.bulletType = isRomanLow ? "i" : "I"
                info.defaultOrderedStart = isRomanLow ? "i" : "I"
            } else {
                let isUpper = c.isAlphaUpper
                info.orderedStart = String(Int(c.value | 0x20) - 0x61 + 1)
                info.bulletType = isUpper ? "A" : "a"
                info.defaultOrderedStart = isUpper ? "A" : "a"
                state.nextChar()
            }
            guard let delimiter = tryParseDelimiter(state) else { return nil }
            info.orderedDelimiter = delimiter
            return info
        }
    }

    final class TaskList: LeafInline {
        var checked = false
    }

    final class TaskListExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.inline(TaskListInlineParser.self) == nil { builder.insertInline(TaskListInlineParser(), before: LinkInlineParser.self) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) { renderer.addRendererIfNotAlready(HtmlTaskListRenderer()) }
    }

    final class TaskListInlineParser: InlineParser {
        override init() {
            super.init()
            openingCharacters = ["["]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            guard let listItem = processor.block?.parent as? ListItemBlock else { return false }
            let startingPosition = slice.start
            let c = slice.nextChar()
            if !c.isSpace && c != "x" && c != "X" { return false }
            if slice.nextChar() != "]" { return false }
            slice.skipChar()
            let task = TaskList()
            task.span.start = processor.getSourcePosition(startingPosition)
            task.span.end = task.span.start + 2
            task.checked = !c.isSpace
            processor.inline = task
            listItem.getAttributes().addClass("task-list-item")
            (listItem.parent as! ListBlock).getAttributes().addClass("contains-task-list")
            return true
        }
    }

    final class HtmlTaskListRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is TaskList }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let task = object as! TaskList
            if renderer.enableHtmlForInline {
                renderer.write("<input")
                renderer.writeAttributes(task)
                renderer.write(" disabled=\"disabled\" type=\"checkbox\"")
                if task.checked { renderer.write(" checked=\"checked\"") }
                renderer.write(" />")
            } else {
                renderer.write("[" as Char)
                renderer.write(task.checked ? "x" : " ")
                renderer.write("]" as Char)
            }
        }
    }

    final class DiagramExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {}

        func setupRenderer(_ renderer: HtmlRenderer) {
            guard let code = renderer.objectRenderers.first(where: { type(of: $0) == CodeBlockRenderer.self }) as? CodeBlockRenderer else { return }
            if let index = code.blockMapping.firstIndex(where: { $0.0.caseInsensitiveCompare("mermaid") == .orderedSame }) {
                code.blockMapping[index].1 = "pre"
            } else {
                code.blockMapping.append(("mermaid", "pre"))
            }
            if !code.blocksAsDiv.contains(where: { $0.caseInsensitiveCompare("nomnoml") == .orderedSame }) { code.blocksAsDiv.append("nomnoml") }
        }
    }

    // MARK: Auto links

    final class AutoLinkExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.inline(AutoLinkParser.self) == nil { builder.inlineParsers.insert(AutoLinkParser(), at: 0) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {}
    }

    /// Bare `http://`, `https://`, `ftp://`, `mailto:`, `tel:` and `www.` links.
    final class AutoLinkParser: InlineParser {
        var validPreviousCharacters: [Char] = ["*", "_", "~", "("]
        var useHttpsForWWWLinks = false
        var allowDomainWithoutPeriod = false
        var openInNewWindow = false

        override init() {
            super.init()
            openingCharacters = ["h", "f", "m", "t", "w"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let previous = slice.peekCharExtra(-1)
            if !previous.isWhitespaceOrZero && !validPreviousCharacters.contains(previous) { return false }
            let mayBeValid: Bool
            if slice.length < 4 {
                mayBeValid = false
            } else {
                switch slice.currentChar {
                case "h": mayBeValid = slice.match("https://") || slice.match("http://")
                case "w": mayBeValid = slice.match("www.")
                case "f": mayBeValid = slice.match("ftp://")
                case "m": mayBeValid = slice.match("mailto:")
                default: mayBeValid = slice.match("tel:")
                }
            }
            return mayBeValid && matchCore(processor, &slice)
        }

        private func matchCore(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let c = slice.currentChar
            let startPosition = slice.start
            var pendingEmphasis: [Char] = []
            if !Self.isAutoLinkValidInCurrentContext(processor, &pendingEmphasis) { return false }
            guard var link = LinkHelper.tryParseUrl(&slice, isAutoLink: true)?.link else { return false }
            if !pendingEmphasis.isEmpty {
                var chars = Markdown.chars(link)
                var i = chars.count - 1
                while i >= 0 {
                    if pendingEmphasis.contains(chars[i]) {
                        slice.start -= 1
                    } else {
                        if i < chars.count - 1 {
                            chars = Array(chars[0...i])
                            link = Markdown.string(chars)
                        }
                        break
                    }
                    i -= 1
                }
            }
            let linkChars = Markdown.chars(link)
            var domainOffset = 0
            switch c {
            case "h":
                if link == "http://" || link == "https://" { return false }
                domainOffset = linkChars.count > 4 && linkChars[4] == "s" ? 8 : 7
            case "w":
                domainOffset = 4
            case "f":
                if link == "ftp://" { return false }
                domainOffset = 6
            case "t":
                if link == "tel" { return false }
            case "m":
                guard let at = linkChars.firstIndex(of: "@"), at != 7 else { return false }
                domainOffset = at + 1
            default:
                break
            }
            if c != "t" && !LinkHelper.isValidDomain(link, domainOffset, allowDomainWithoutPeriod: allowDomainWithoutPeriod) { return false }
            let inline = LinkInline()
            inline.span.start = processor.getSourcePosition(startPosition)
            inline.url = c == "w" ? (useHttpsForWWWLinks ? "https://" : "http://") + link : link
            inline.isClosed = true
            inline.isAutoLink = true
            let skipFromBeginning = c == "m" ? 7 : c == "t" ? 4 : 0
            inline.span.end = inline.span.start + linkChars.count - 1
            inline.urlSpan = inline.span
            let literal = LiteralInline(Slice(slice.text, startPosition + skipFromBeginning, startPosition + linkChars.count - 1))
            literal.span = inline.span
            literal.isClosed = true
            inline.appendChild(literal)
            processor.inline = inline
            if openInNewWindow { inline.getAttributes().addPropertyIfNotExist("target", "_blank") }
            return true
        }

        private static func isAutoLinkValidInCurrentContext(_ processor: InlineProcessor, _ pendingEmphasis: inout [Char]) -> Bool {
            var current = processor.inline
            while let inline = current {
                if let html = inline as? HtmlInline {
                    if html.tag.lowercased().hasPrefix("</a") { break }
                    if html.tag.lowercased().hasPrefix("<a") { return false }
                }
                current = inline.previousSibling ?? inline.parent
            }
            current = processor.inline
            var countBrackets = 0
            while let inline = current {
                if let link = inline as? LinkDelimiterInline, link.isActive {
                    if link.type == .open { countBrackets += 1 } else if link.type == .close { countBrackets -= 1 }
                } else if let emphasis = inline as? EmphasisDelimiterInline, !pendingEmphasis.contains(emphasis.delimiterChar) {
                    pendingEmphasis.append(emphasis.delimiterChar)
                }
                current = inline.parent
            }
            return countBrackets <= 0
        }
    }

    // MARK: Generic attributes

    final class GenericAttributesExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.inline(GenericAttributesParser.self) == nil { builder.inlineParsers.insert(GenericAttributesParser(), at: 0) }
            for parser in builder.blockParsers {
                if let heading = parser as? HeadingBlockParser { heading.tryParseAttributes = Self.tryProcessAttributes }
                if let fenced = parser as? FencedBlockParserBase { fenced.tryParseAttributes = Self.tryProcessAttributes }
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {}

        /// `{...}` at the end of a heading or fence line.
        private static func tryProcessAttributes(_ processor: BlockProcessor, _ line: inout Slice, _ block: Block) -> Bool {
            guard line.start < line.end else { return false }
            let index = line.indexOf("{")
            guard index >= 0 else { return false }
            var copy = line
            copy.start = index
            let startOfAttributes = copy.start
            guard let attributes = GenericAttributesParser.tryParse(&copy) else { return false }
            let target = block.getAttributes()
            attributes.copyTo(target)
            target.line = processor.lineIndex
            target.column = startOfAttributes - processor.currentLineStartPosition
            target.span.start = startOfAttributes
            target.span.end = copy.start - 1
            line.end = index - 1
            return true
        }
    }

    final class GenericAttributesParser: InlineParser {
        override init() {
            super.init()
            openingCharacters = ["{"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let startPosition = slice.start
            guard let attributes = Self.tryParse(&slice) else { return false }
            var inline = processor.inline
            if inline is LiteralInline {
                while true {
                    inline = inline?.parent
                    if !(inline is DelimiterInline) { break }
                }
            }
            var objectToAttach: MarkdownObject = (inline == nil || inline === processor.root) ? processor.block! : inline!
            if let paragraph = objectToAttach as? ParagraphBlock, paragraph.inline?.firstChild == nil, processor.inline == nil,
               slice.isEmptyOrWhitespace(), let parent = paragraph.parent, let index = parent.indexOf(paragraph), index + 1 < parent.count {
                objectToAttach = parent[index + 1]
                paragraph.removeAfterProcessInlines = true
            }
            let current = objectToAttach.getAttributes()
            attributes.copyTo(current, mergeIdAndProperties: true, shared: false)
            current.span.start = processor.getSourcePosition(startPosition)
            current.span.end = current.span.start + slice.start - startPosition - 1
            return true
        }

        /// Parses `{#id .class name=value name="value" flag}`.
        static func tryParse(_ slice: inout Slice) -> HtmlAttributes? {
            if slice.peekCharExtra(-1) == "{" { return nil }
            var line = slice
            var id: String?
            var classes: [String]?
            var properties: [(String, String?)]?
            var isValid = false
            var c = line.nextChar()
            func text(_ start: Int, _ end: Int) -> String { Markdown.string(slice.text[start...end]) }
            loop: while true {
                if c == "}" {
                    isValid = true
                    line.skipChar()
                    if line.currentChar == "\n" {
                        line.skipChar()
                    } else if line.currentChar == "\r" && line.peekChar() == "\n" {
                        line.start += 2
                    }
                    break
                }
                if c == .zero { break }
                let isClass = c == "."
                if c == "#" || isClass {
                    c = line.nextChar()
                    let start = line.start
                    while c != "}" && !c.isWhitespaceOrZero { c = line.nextChar() }
                    let end = line.start - 1
                    if end == start { break }
                    let value = text(start, end)
                    if isClass { classes = (classes ?? []) + [value] } else { id = value }
                    continue
                }
                if !c.isWhitespace {
                    if !isStartAttributeName(c) { break }
                    let startName = line.start
                    while true {
                        c = line.nextChar()
                        if !(c.isAlphaNumeric || c == "_" || c == ":" || c == "." || c == "-") { break }
                    }
                    let name = Markdown.string(slice.text[startName..<line.start])
                    let hasSpace = c.isSpaceOrTab
                    line.trimStart()
                    c = line.currentChar
                    if (hasSpace && (c == "." || c == "#" || isStartAttributeName(c))) || c == "}" {
                        properties = (properties ?? []) + [(name, nil)]
                        continue
                    }
                    if line.currentChar != "=" { break }
                    line.skipChar()
                    line.trimStart()
                    var startValue = -1
                    var endValue = -1
                    c = line.currentChar
                    if c == "'" || c == "\"" {
                        let opening = c
                        startValue = line.start + 1
                        while true {
                            c = line.nextChar()
                            if c == .zero { return nil }
                            if c == opening { break }
                        }
                        endValue = line.start - 1
                        c = line.nextChar()
                    } else {
                        startValue = line.start
                        var valid = false
                        while true {
                            if c == .zero { return nil }
                            if c.isWhitespace || c == "}" { break }
                            c = line.nextChar()
                            valid = true
                        }
                        endValue = line.start - 1
                        if !valid { break loop }
                    }
                    let value = endValue >= startValue ? text(startValue, endValue) : ""
                    properties = (properties ?? []) + [(name, value)]
                    continue
                }
                c = line.nextChar()
            }
            guard isValid else { return nil }
            let attributes = HtmlAttributes()
            attributes.id = id
            attributes.classes = classes.map { HtmlAttributes.Strings($0) }
            attributes.properties = properties.map { HtmlAttributes.Pairs($0) }
            slice = line
            return attributes
        }

        private static func isStartAttributeName(_ c: Char) -> Bool { c.isAlpha || c == "_" || c == ":" }
    }

    // MARK: YAML front matter

    final class YamlFrontMatterBlock: CodeBlock {}

    final class YamlFrontMatterExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.block(YamlFrontMatterParser.self) == nil { builder.insertBlock(YamlFrontMatterParser(), before: ThematicBreakParser.self) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            if !renderer.containsRenderer(YamlFrontMatterHtmlRenderer.self) {
                renderer.insertRenderer(YamlFrontMatterHtmlRenderer(), before: CodeBlockRenderer.self)
            }
        }
    }

    final class YamlFrontMatterParser: BlockParser {
        override init() {
            super.init()
            openingCharacters = ["-"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            if processor.start != 0 { return .none }
            var count = 0
            var line = processor.line
            var c = line.currentChar
            while c == "-" && count < 4 {
                count += 1
                c = line.nextChar()
            }
            guard count == 3 && c.isWhitespaceOrZero && line.trimEnd() else { return .none }
            var hasFullFrontMatter = false
            var full = Slice(line.text, line.start, line.text.count - 1)
            c = full.currentChar
            while c != .zero {
                c = full.nextChar()
                if c == "\n" || c == "\r" {
                    var next = full.peekChar()
                    if c == "\r" && next == "\n" { c = full.nextChar() }
                    next = full.peekChar()
                    if next == "-" {
                        if full.nextChar() == "-" && full.nextChar() == "-" && full.nextChar() == "-"
                            && (full.nextChar() == .zero || full.skipSpacesToEndOfLineOrEndOfDocument()) {
                            hasFullFrontMatter = true
                            break
                        }
                    } else if next == "." {
                        if full.nextChar() == "." && full.nextChar() == "." && full.nextChar() == "."
                            && (full.nextChar() == .zero || full.skipSpacesToEndOfLineOrEndOfDocument()) {
                            hasFullFrontMatter = true
                            break
                        }
                    }
                }
            }
            guard hasFullFrontMatter else { return .none }
            let block = YamlFrontMatterBlock(self)
            block.column = processor.column
            block.span.start = 0
            block.span.end = line.start
            processor.newBlocks.append(block)
            return .continueDiscard
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            var line = processor.line
            var c = line.currentChar
            if processor.column == 0 && (c == "-" || c == ".") {
                let count = line.countAndSkipChar(c)
                c = line.currentChar
                if count == 3 && !processor.isCodeIndent && c.isWhitespaceOrZero && line.trimEnd() {
                    block?.updateSpanEnd(line.start - 1)
                    return .breakDiscard
                }
            }
            processor.goToColumn(processor.columnBeforeIndent)
            return .continue
        }
    }

    final class YamlFrontMatterHtmlRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is YamlFrontMatterBlock }
        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {}
    }

    // MARK: .NET sort

    /// .NET's `Array.Sort` with a comparison (introsort: insertion sort up to 16 items, median-of-three quicksort,
    /// heapsort past the depth limit). Unstable, so equal or incomparable items move exactly as in Markdig.
    static func introSort<T>(_ keys: inout [T], _ comparison: (T, T) -> Int) {
        guard keys.count > 1 else { return }
        let depthLimit = 2 * ((Int.bitWidth - keys.count.leadingZeroBitCount - 1) + 1)
        introSort(&keys, 0, keys.count, depthLimit, comparison)
    }

    private static func introSort<T>(_ keys: inout [T], _ lo: Int, _ count: Int, _ depthLimit: Int, _ comparison: (T, T) -> Int) {
        var partitionSize = count
        var depthLimit = depthLimit
        while partitionSize > 1 {
            if partitionSize <= 16 {
                if partitionSize == 2 {
                    swapIfGreater(&keys, comparison, lo, lo + 1)
                    return
                }
                if partitionSize == 3 {
                    swapIfGreater(&keys, comparison, lo, lo + 1)
                    swapIfGreater(&keys, comparison, lo, lo + 2)
                    swapIfGreater(&keys, comparison, lo + 1, lo + 2)
                    return
                }
                for i in 0..<(partitionSize - 1) {
                    let t = keys[lo + i + 1]
                    var j = i
                    while j >= 0 && comparison(t, keys[lo + j]) < 0 {
                        keys[lo + j + 1] = keys[lo + j]
                        j -= 1
                    }
                    keys[lo + j + 1] = t
                }
                return
            }
            if depthLimit == 0 {
                heapSort(&keys, lo, partitionSize, comparison)
                return
            }
            depthLimit -= 1
            let p = pickPivotAndPartition(&keys, lo, partitionSize, comparison)
            introSort(&keys, lo + p + 1, partitionSize - (p + 1), depthLimit, comparison)
            partitionSize = p
        }
    }

    private static func swapIfGreater<T>(_ keys: inout [T], _ comparison: (T, T) -> Int, _ i: Int, _ j: Int) {
        if comparison(keys[i], keys[j]) > 0 { keys.swapAt(i, j) }
    }

    private static func pickPivotAndPartition<T>(_ keys: inout [T], _ lo: Int, _ count: Int, _ comparison: (T, T) -> Int) -> Int {
        let hi = count - 1
        let middle = hi >> 1
        swapIfGreater(&keys, comparison, lo, lo + middle)
        swapIfGreater(&keys, comparison, lo, lo + hi)
        swapIfGreater(&keys, comparison, lo + middle, lo + hi)
        let pivot = keys[lo + middle]
        keys.swapAt(lo + middle, lo + hi - 1)
        var left = 0
        var right = hi - 1
        while left < right {
            repeat { left += 1 } while comparison(keys[lo + left], pivot) < 0
            repeat { right -= 1 } while comparison(pivot, keys[lo + right]) < 0
            if left >= right { break }
            keys.swapAt(lo + left, lo + right)
        }
        if left != hi - 1 { keys.swapAt(lo + left, lo + hi - 1) }
        return left
    }

    private static func heapSort<T>(_ keys: inout [T], _ lo: Int, _ n: Int, _ comparison: (T, T) -> Int) {
        var i = n >> 1
        while i >= 1 {
            downHeap(&keys, lo, i, n, comparison)
            i -= 1
        }
        i = n
        while i > 1 {
            keys.swapAt(lo, lo + i - 1)
            downHeap(&keys, lo, 1, i - 1, comparison)
            i -= 1
        }
    }

    private static func downHeap<T>(_ keys: inout [T], _ lo: Int, _ start: Int, _ n: Int, _ comparison: (T, T) -> Int) {
        var i = start
        let d = keys[lo + i - 1]
        while i <= n >> 1 {
            var child = 2 * i
            if child < n && comparison(keys[lo + child - 1], keys[lo + child]) < 0 { child += 1 }
            if !(comparison(d, keys[lo + child - 1]) < 0) { break }
            keys[lo + i - 1] = keys[lo + child - 1]
            i = child
        }
        keys[lo + i - 1] = d
    }
}
