// CommonMark block parsers: thematic breaks, ATX headings, block quotes, lists, HTML blocks, fenced and indented
// code, paragraphs with setext headings and link reference definitions (Markdig's core block parsers).

import Foundation

extension Markdown {
    /// Hook through which the generic attributes extension reads `{#id .class}` after a heading or fence.
    typealias TryParseAttributes = (BlockProcessor, inout Slice, Block) -> Bool

    final class ThematicBreakParser: BlockParser {
        static let shared = ThematicBreakParser()

        override init() {
            super.init()
            openingCharacters = ["-", "_", "*"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            let startPosition = processor.start
            var line = processor.line
            var breakCharCount = 0
            let breakChar = line.currentChar
            var hasSpacesSinceLastMatch = false
            var hasInnerSpaces = false
            var c = breakChar
            while c != .zero {
                if c == breakChar {
                    if hasSpacesSinceLastMatch { hasInnerSpaces = true }
                    breakCharCount += 1
                } else if c.isSpaceOrTab {
                    hasSpacesSinceLastMatch = true
                } else {
                    return .none
                }
                c = line.nextChar()
            }
            let previousParagraph = processor.currentBlock as? ParagraphBlock
            var isSetextHeading = previousParagraph != nil && breakChar == "-" && !hasInnerSpaces
            if isSetextHeading, let paragraph = previousParagraph, let parent = paragraph.parent {
                if paragraph.column != processor.column && (parent is QuoteBlock || parent is ListItemBlock) {
                    isSetextHeading = false
                }
            }
            if breakCharCount < 3 || isSetextHeading { return .none }
            let thematicBreak = ThematicBreakBlock(self)
            thematicBreak.column = processor.column
            thematicBreak.span = SourceSpan(startPosition, line.end)
            thematicBreak.thematicChar = breakChar
            thematicBreak.thematicCharCount = breakCharCount
            thematicBreak.content = Slice(line.text, startPosition, line.end, line.newLine)
            processor.newBlocks.append(thematicBreak)
            return .breakDiscard
        }
    }

    final class HeadingBlockParser: BlockParser {
        var maxLeadingCount = 6
        var tryParseAttributes: TryParseAttributes?

        override init() {
            super.init()
            openingCharacters = ["#"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            let column = processor.column
            let sourcePosition = processor.line.start
            var c = processor.line.currentChar
            let matchingChar = c
            var leadingCount = 0
            while c != .zero && leadingCount <= maxLeadingCount {
                if c != matchingChar { break }
                c = processor.nextChar()
                leadingCount += 1
            }
            if leadingCount > 0 && leadingCount <= maxLeadingCount && (c.isSpaceOrTab || c == .zero) {
                let heading = HeadingBlock(self)
                heading.headerChar = matchingChar
                heading.level = leadingCount
                heading.column = column
                heading.span.start = sourcePosition
                processor.goToColumn(column + leadingCount + 1)
                processor.newBlocks.append(heading)
                if let hook = tryParseAttributes {
                    var line = processor.line
                    _ = hook(processor, &line, heading)
                    processor.line = line
                }
                // The optional closing sequence of #s must be preceded by a space and may be followed by spaces only.
                var endState = 0
                var countClosingTags = 0
                var i = processor.line.end
                while i >= processor.line.start - 1 {
                    c = processor.line.text[i]
                    if endState == 0 {
                        if c.isSpaceOrTab { i -= 1; continue }
                        endState = 1
                    }
                    if endState == 1 {
                        if c == matchingChar {
                            countClosingTags += 1
                            i -= 1
                            continue
                        }
                        if countClosingTags > 0 && c.isSpaceOrTab { processor.line.end = i - 1 }
                        break
                    }
                    i -= 1
                }
                heading.span.end = processor.line.end
                return .break
            }
            processor.line.start = sourcePosition
            processor.column = column
            return .none
        }

        override func close(_ processor: BlockProcessor, _ block: Block) -> Bool {
            (block as! HeadingBlock).lines.trim()
            return true
        }
    }

    final class QuoteBlockParser: BlockParser {
        override init() {
            super.init()
            openingCharacters = [">"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            let sourcePosition = processor.start
            let quoteChar = processor.currentChar
            let column = processor.column
            let c = processor.nextChar()
            let quote = QuoteBlock(self)
            quote.quoteChar = quoteChar
            quote.column = column
            quote.span = SourceSpan(sourcePosition, processor.line.end)
            if c == " " || c == "\t" { processor.nextColumn() }
            processor.newBlocks.append(quote)
            return .continue
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            if processor.isCodeIndent { return .none }
            let quote = block as! QuoteBlock
            var c = processor.currentChar
            if c != quote.quoteChar {
                return processor.isBlankLine ? .breakDiscard : .none
            }
            c = processor.nextChar()
            if c == " " || c == "\t" { processor.nextColumn() }
            quote.updateSpanEnd(processor.line.end)
            return .continue
        }
    }

    /// What a list item marker says about its list (`ListInfo`).
    struct ListInfo {
        var bulletType = Char.zero
        var orderedStart: String?
        var orderedDelimiter = Char.zero
        var defaultOrderedStart: String?
    }

    /// Parses one kind of list item marker (`ListItemParser`).
    class ListItemParser {
        var openingCharacters: [Char] = []
        var isOrdered: Bool { false }
        func tryParse(_ state: BlockProcessor, _ pendingBulletType: Char) -> ListInfo? { nil }
    }

    final class UnorderedListItemParser: ListItemParser {
        override init() {
            super.init()
            openingCharacters = ["-", "+", "*"]
        }

        override func tryParse(_ state: BlockProcessor, _ pendingBulletType: Char) -> ListInfo? {
            let info = ListInfo(bulletType: state.currentChar)
            state.nextChar()
            return info
        }
    }

    class OrderedListItemParser: ListItemParser {
        var orderedDelimiters: [Char] = [".", ")"]
        override var isOrdered: Bool { true }

        func tryParseDelimiter(_ state: BlockProcessor) -> Char? {
            let delimiter = state.currentChar
            if orderedDelimiters.contains(delimiter) {
                state.nextChar()
                return delimiter
            }
            return nil
        }
    }

    final class NumberedListItemParser: OrderedListItemParser {
        override init() {
            super.init()
            openingCharacters = (0..<10).map { Char(UInt16(0x30 + $0)) }
        }

        override func tryParse(_ state: BlockProcessor, _ pendingBulletType: Char) -> ListInfo? {
            var c = state.currentChar
            var countDigit = 0
            var startChar = -1
            var endChar = 0
            while c.isDigit {
                endChar = state.start
                if startChar < 0 && c != "0" { startChar = endChar }
                c = state.nextChar()
                countDigit += 1
            }
            if startChar < 0 { startChar = endChar }
            guard countDigit <= 9, let delimiter = tryParseDelimiter(state) else { return nil }
            let start: String
            if startChar == endChar {
                start = String(state.line.text[startChar].int - 0x30)
            } else {
                start = Markdown.string(state.line.text[startChar...endChar])
            }
            return ListInfo(bulletType: "1", orderedStart: start, orderedDelimiter: delimiter, defaultOrderedStart: "1")
        }
    }

    final class ListBlockParser: BlockParser {
        var itemParsers: [ListItemParser] = [UnorderedListItemParser(), NumberedListItemParser()]
        private var itemParserMap: [Char: ListItemParser] = [:]

        override init() {
            super.init()
        }

        override func initialize() {
            itemParserMap = [:]
            for itemParser in itemParsers {
                for c in itemParser.openingCharacters {
                    precondition(itemParserMap[c] == nil, "A list item parser with the same opening character `\(c)` is already registered")
                    itemParserMap[c] = itemParser
                }
            }
            // Like Markdig, the list parser has no opening characters: it is tried on every line, in pipeline order.
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            let thematic = ThematicBreakParser.shared
            if thematic.hasOpeningCharacter(processor.currentChar) {
                let result = thematic.tryOpen(processor)
                if result.isBreak { return result }
            }
            return tryParseListItem(processor, nil)
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let block = block!
            if block is ListBlock && processor.nextContinue is ListItemBlock { return .skip }
            let thematic = ThematicBreakParser.shared
            if !(processor.lastBlock is FencedCodeBlock) && thematic.hasOpeningCharacter(processor.currentChar) {
                let result = thematic.tryOpen(processor)
                if result.isBreak {
                    _ = processor.newBlocks.popLast()
                    return .none
                }
            }
            var result = BlockState.none
            if let listItem = block as? ListItemBlock { result = tryContinueListItem(processor, listItem) }
            if result == .none { result = tryParseListItem(processor, block) }
            return result
        }

        private func tryContinueListItem(_ state: BlockProcessor, _ listItem: ListItemBlock) -> BlockState {
            let list = listItem.parent as! ListBlock
            if state.isBlankLine {
                if let current = state.currentBlock, current.isBreakable {
                    if !(state.nextContinue is ListBlock) {
                        list.countAllBlankLines += 1
                        listItem.add(BlankLineBlock())
                    }
                    list.countBlankLinesReset += 1
                }
                if list.countBlankLinesReset == 1 && listItem.columnWidth < 0 {
                    state.close(listItem)
                    list.countBlankLinesReset = 0
                    list.isOpen = true
                    return .continue
                }
                listItem.updateSpanEnd(state.line.end)
                return .continue
            }
            list.countBlankLinesReset = 0
            let columnWidth = abs(listItem.columnWidth)
            if state.indent >= columnWidth {
                if state.indent > columnWidth && state.isCodeIndent {
                    state.goToColumn(state.columnBeforeIndent + columnWidth)
                }
                listItem.updateSpanEnd(state.line.end)
                listItem.newLine = state.line.newLine
                return .continue
            }
            return .none
        }

        private func tryParseListItem(_ state: BlockProcessor, _ block: Block?) -> BlockState {
            let currentListItem = block as? ListItemBlock
            var currentParent = (block as? ListBlock) ?? (currentListItem?.parent as? ListBlock)
            if state.isCodeIndent && (currentListItem == nil || currentListItem!.lastChild is BlankLineBlock || !currentParent!.isOrdered) {
                return .none
            }
            let initColumnBeforeIndent = state.columnBeforeIndent
            let initColumn = state.column
            let sourcePosition = state.start
            let sourceEndPosition = state.line.end
            var c = state.currentChar
            guard let itemParser = itemParserMap[c] else { return .none }
            guard let listInfo = itemParser.tryParse(state, currentParent?.bulletType ?? .zero) else {
                state.goToColumn(initColumn)
                return .none
            }
            let isOrdered = itemParser.isOrdered
            c = state.currentChar
            let columnWidth: Int
            if c == .zero {
                columnWidth = -(state.column - initColumnBeforeIndent + 1)
            } else {
                if !c.isSpaceOrTab {
                    state.goToColumn(initColumn)
                    return .none
                }
                state.restartIndent()
                let columnBeforeIndent = state.column
                state.parseIndent()
                if state.indent > 4 { state.goToColumn(columnBeforeIndent + 1) }
                columnWidth = (state.isBlankLine ? columnBeforeIndent : state.column) - initColumnBeforeIndent
            }
            let previous = block ?? state.lastBlock
            if let previous, previous.isParagraphBlock {
                let isOrderedListInterruptingParagraph = !state.hasUnmatchedBlocks && state.isOpen(previous)
                    && listInfo.bulletType == "1" && listInfo.orderedStart != "1"
                if state.isBlankLine || isOrderedListInterruptingParagraph {
                    state.goToColumn(initColumn)
                    return .none
                }
            }
            let item = ListItemBlock(self)
            item.column = initColumn
            item.columnWidth = columnWidth
            item.order = MarkupConvert.tryParseInt(listInfo.orderedStart) ?? 0
            item.span = SourceSpan(sourcePosition, sourceEndPosition)
            state.newBlocks.append(item)
            if let parent = currentParent {
                if let currentListItem { state.close(currentListItem) }
                if parent.isOrdered != isOrdered || parent.orderedDelimiter != listInfo.orderedDelimiter || parent.bulletType != listInfo.bulletType {
                    state.close(parent)
                    currentParent = nil
                }
            }
            if currentParent == nil {
                let list = ListBlock(self)
                list.column = initColumn
                list.span = SourceSpan(sourcePosition, sourceEndPosition)
                list.isOrdered = isOrdered
                list.bulletType = listInfo.bulletType
                list.orderedDelimiter = listInfo.orderedDelimiter
                list.defaultOrderedStart = listInfo.defaultOrderedStart
                list.orderedStart = listInfo.orderedStart
                state.newBlocks.append(list)
            }
            return .continue
        }

        override func close(_ processor: BlockProcessor, _ blockToClose: Block) -> Bool {
            guard let list = blockToClose as? ListBlock, list.countAllBlankLines > 0 else { return true }
            if let parentItem = list.parent as? ListItemBlock, let lastItem = list.lastChild as? ListItemBlock, lastItem.lastChild is BlankLineBlock {
                let parentList = parentItem.parent as! ListBlock
                parentList.countAllBlankLines += 1
                parentItem.add(BlankLineBlock())
            }
            var listIndex = list.count - 1
            while listIndex >= 0 {
                let item = list[listIndex] as! ListItemBlock
                var i = item.count - 1
                while i >= 0 {
                    if item[i] is BlankLineBlock {
                        if i == item.count - 1 ? listIndex < list.count - 1 : i > 0 { list.isLoose = true }
                        item.removeAt(i)
                        list.countAllBlankLines -= 1
                        if list.countAllBlankLines == 0 { return true }
                    }
                    i -= 1
                }
                listIndex -= 1
            }
            return true
        }
    }

    final class HtmlBlockParser: BlockParser {
        override init() {
            super.init()
            openingCharacters = ["<"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            var result = matchStart(processor)
            if result == .continue { result = matchEnd(processor, processor.newBlocks.last as! HtmlBlock) }
            return result
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            matchEnd(processor, block as! HtmlBlock)
        }

        private func matchStart(_ state: BlockProcessor) -> BlockState {
            if state.isCodeIndent { return .none }
            var line = state.line
            let startPosition = line.start
            line.skipChar()
            var result = tryParseTagType16(state, line, state.columnBeforeIndent, startPosition)
            if result == .none && !(state.currentBlock is ParagraphBlock) {
                result = tryParseTagType7(state, line, state.columnBeforeIndent, startPosition)
            }
            return result
        }

        private func tryParseTagType7(_ state: BlockProcessor, _ line: Slice, _ startColumn: Int, _ startPosition: Int) -> BlockState {
            var line = line
            var builder: [Char] = []
            var c = line.currentChar
            if (c == "/" && HtmlHelper.tryParseHtmlCloseTag(&line, &builder)) || HtmlHelper.tryParseHtmlTagOpenTag(&line, &builder) {
                c = line.currentChar
                while c != .zero {
                    if !c.isWhitespace { return .none }
                    c = line.nextChar()
                }
                return createHtmlBlock(state, .nonInterruptingBlock, startColumn, startPosition)
            }
            return .none
        }

        private func tryParseTagType16(_ state: BlockProcessor, _ line: Slice, _ startColumn: Int, _ startPosition: Int) -> BlockState {
            var line = line
            var c = line.currentChar
            if c == "!" {
                c = line.nextChar()
                if c == "-" && line.peekChar() == "-" { return createHtmlBlock(state, .comment, startColumn, startPosition) }
                if c.isAlphaUpper { return createHtmlBlock(state, .documentType, startColumn, startPosition) }
                if c == "[" && line.match("CDATA[", offset: 1) { return createHtmlBlock(state, .cData, startColumn, startPosition) }
                return .none
            }
            if c == "?" { return createHtmlBlock(state, .processingInstruction, startColumn, startPosition) }
            let hasLeadingClose = c == "/"
            if hasLeadingClose { c = line.nextChar() }
            var tag: [Char] = []
            while tag.count < 10 {
                if !c.isAlphaNumeric { break }
                tag.append(c.lowerInvariant)
                c = line.nextChar()
            }
            if !(c == ">" || (!hasLeadingClose && c == "/" && line.peekChar() == ">") || c.isWhitespaceOrZero) { return .none }
            if tag.isEmpty { return .none }
            let name = Markdown.string(tag)
            guard Self.blockTags.contains(name) else { return .none }
            if name == "pre" || name == "script" || name == "style" || name == "textarea" {
                if c == "/" || hasLeadingClose { return .none }
                return createHtmlBlock(state, .scriptPreOrStyle, startColumn, startPosition)
            }
            return createHtmlBlock(state, .interruptingBlock, startColumn, startPosition)
        }

        private func matchEnd(_ state: BlockProcessor, _ htmlBlock: HtmlBlock) -> BlockState {
            state.goToColumn(state.columnBeforeIndent)
            let line = state.line
            var result = BlockState.continue
            func find(_ end: String, ignoreCase: Bool = false) -> Bool {
                let index = line.indexOf(end, offset: 0, ignoreCase: ignoreCase)
                if index >= 0 {
                    htmlBlock.updateSpanEnd(index + end.utf16.count)
                    result = .break
                    return true
                }
                return false
            }
            switch htmlBlock.type {
            case .comment: _ = find("-->")
            case .cData: _ = find("]]>")
            case .processingInstruction: _ = find("?>")
            case .documentType:
                let index = line.indexOf(">")
                if index >= 0 {
                    htmlBlock.updateSpanEnd(index + 1)
                    result = .break
                }
            case .scriptPreOrStyle:
                if !find("</script>", ignoreCase: true), !find("</pre>", ignoreCase: true), !find("</style>", ignoreCase: true) {
                    _ = find("</textarea>", ignoreCase: true)
                }
            case .interruptingBlock, .nonInterruptingBlock:
                if state.isBlankLine { result = .breakDiscard }
            }
            if result != .breakDiscard {
                htmlBlock.span.end = line.end
                htmlBlock.newLine = state.line.newLine
            }
            return result
        }

        private func createHtmlBlock(_ state: BlockProcessor, _ type: HtmlBlockType, _ startColumn: Int, _ startPosition: Int) -> BlockState {
            let block = HtmlBlock(self)
            block.column = startColumn
            block.type = type
            block.span = SourceSpan(startPosition, startPosition + state.line.end)
            state.newBlocks.append(block)
            return .continue
        }

        static let blockTags: Set<String> = [
            "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup",
            "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame",
            "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link",
            "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "pre", "script", "section",
            "source", "style", "summary", "table", "textarea", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track",
            "ul", "search",
        ]
    }

    /// Fenced blocks: code fences here, custom containers and figures in extensions (`FencedBlockParserBase`).
    class FencedBlockParserBase: BlockParser {
        var infoPrefix: String?
        var minimumMatchCount = 3
        var maximumMatchCount = Int.max
        var tryParseAttributes: TryParseAttributes?
        /// Parses the info string; false rejects the fence (Markdig's `InfoParser`).
        var infoParser: ((BlockProcessor, inout Slice, FencedBlock, Char) -> Bool)? = FencedBlockParserBase.defaultInfoParser

        func createFencedBlock(_ processor: BlockProcessor) -> FencedBlock { fatalError("abstract") }

        static func defaultInfoParser(_ state: BlockProcessor, _ line: inout Slice, _ fenced: FencedBlock, _ openingCharacter: Char) -> Bool {
            var firstSpace = -1
            if !line.isEmpty {
                let chars = Array(line.chars)
                if openingCharacter == "`" {
                    if let index = chars.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "`" }) {
                        firstSpace = index
                        if chars[index...].contains("`") { return false }
                    }
                } else if let index = chars.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    firstSpace = index
                }
            }
            var infoSlice: Slice
            if firstSpace >= 0 {
                firstSpace += line.start
                infoSlice = Slice(line.text, line.start, firstSpace - 1)
                var argumentSlice = Slice(line.text, firstSpace, line.end)
                argumentSlice.trim()
                fenced.arguments = HtmlHelper.unescape(argumentSlice.description)
            } else {
                infoSlice = line
                fenced.arguments = ""
            }
            infoSlice.trim()
            fenced.info = HtmlHelper.unescape(infoSlice.description)
            return true
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            var line = processor.line
            let matchChar = line.currentChar
            let count = line.countAndSkipChar(matchChar)
            if count < minimumMatchCount || count > maximumMatchCount { return .none }
            line.trimStart()
            let fenced = createFencedBlock(processor)
            fenced.column = processor.column
            fenced.fencedChar = matchChar
            fenced.openingFencedCharCount = count
            fenced.span.start = processor.start
            fenced.span.end = line.start
            if let hook = tryParseAttributes { _ = hook(processor, &line, fenced) }
            if let infoParser, !infoParser(processor, &line, fenced, matchChar) { return .none }
            if let info = fenced.info, !info.isEmpty {
                fenced.getAttributes().addClass((infoPrefix ?? "") + info)
            }
            processor.newBlocks.append(fenced)
            return .continueDiscard
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let fence = block as! FencedBlock
            var line = processor.line
            let closingCount = line.countAndSkipChar(fence.fencedChar)
            let c = line.currentChar
            let startBeforeTrim = line.start
            if fence.openingFencedCharCount <= closingCount && !processor.isCodeIndent && c.isWhitespaceOrZero && line.trimEnd() {
                fence.updateSpanEnd(startBeforeTrim - 1)
                fence.closingFencedCharCount = closingCount
                return .breakDiscard
            }
            processor.goToColumn(processor.columnBeforeIndent)
            return .continue
        }
    }

    final class FencedCodeBlockParser: FencedBlockParserBase {
        static let defaultInfoPrefix = "language-"

        override init() {
            super.init()
            openingCharacters = ["`", "~"]
            infoPrefix = Self.defaultInfoPrefix
        }

        override func createFencedBlock(_ processor: BlockProcessor) -> FencedBlock {
            let block = FencedCodeBlock(self)
            block.indentCount = processor.indent
            return block
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let result = super.tryContinue(processor, block)
            if result == .continue {
                var c = processor.currentChar
                var indentCount = (block as! FencedCodeBlock).indentCount
                while indentCount > 0 && c.isSpace {
                    indentCount -= 1
                    c = processor.nextChar()
                }
            }
            return result
        }
    }

    final class IndentedCodeBlockParser: BlockParser {
        override func canInterrupt(_ processor: BlockProcessor, _ block: Block) -> Bool { !block.isParagraphBlock }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            let result = tryContinue(processor, nil)
            if result == .continue {
                let column = processor.column
                processor.unwindAllIndents()
                let code = CodeBlock(self)
                code.column = processor.column
                code.span = SourceSpan(processor.start, processor.line.end)
                processor.newBlocks.append(code)
                processor.goToColumn(column)
            }
            return result
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            if !processor.isCodeIndent || processor.isBlankLine {
                if block == nil || !processor.isBlankLine {
                    if let code = block as? CodeBlock { removeTrailingBlankLines(code) }
                    return .none
                }
            }
            if processor.indent > 4 { processor.goToCodeIndent() }
            block?.updateSpanEnd(processor.line.end)
            return .continue
        }

        override func close(_ processor: BlockProcessor, _ block: Block) -> Bool {
            removeTrailingBlankLines(block as! CodeBlock)
            return true
        }

        private func removeTrailingBlankLines(_ code: CodeBlock) {
            var i = code.lines.count - 1
            while i >= 0 {
                if code.lines[i].slice.isEmpty { code.lines.removeAt(i) } else { break }
                i -= 1
            }
        }
    }

    final class ParagraphBlockParser: BlockParser {
        var parseSetextHeadings = true

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isBlankLine { return .none }
            let paragraph = ParagraphBlock(self)
            paragraph.column = processor.column
            paragraph.span = SourceSpan(processor.line.start, processor.line.end)
            processor.newBlocks.append(paragraph)
            return .continue
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let block = block!
            if processor.isBlankLine { return .breakDiscard }
            if !processor.isCodeIndent && parseSetextHeadings { return tryParseSetextHeading(processor, block) }
            block.newLine = processor.line.newLine
            block.updateSpanEnd(processor.line.end)
            return .continue
        }

        override func close(_ processor: BlockProcessor, _ block: Block) -> Bool {
            if let paragraph = block as? ParagraphBlock {
                Self.tryMatchLinkReferenceDefinition(paragraph, processor)
                let lineCount = paragraph.lines.count
                if lineCount == 0 { return false }
                for i in 0..<lineCount { paragraph.lines.lines[i].slice.trimStart() }
                paragraph.lines.lines[lineCount - 1].slice.trimEnd()
            }
            return true
        }

        private func tryParseSetextHeading(_ state: BlockProcessor, _ block: Block) -> BlockState {
            var line = state.line
            var count = 0
            let headingChar = Self.headingChar(&line, &count)
            if headingChar != .zero {
                let paragraph = block as! ParagraphBlock
                let foundDefinition = Self.tryMatchLinkReferenceDefinition(paragraph, state)
                let parent = block.parent
                let isSetextHeading = !state.isLazy || paragraph.column == state.column || !(parent is QuoteBlock || parent is ListItemBlock)
                if !(foundDefinition && paragraph.lines.count == 0) && isSetextHeading {
                    state.discard(paragraph)
                    while state.currentChar == headingChar { state.nextChar() }
                    let heading = HeadingBlock(self)
                    heading.column = paragraph.column
                    heading.span = SourceSpan(paragraph.span.start, line.end)
                    heading.level = headingChar == "=" ? 1 : 2
                    heading.lines = paragraph.lines
                    heading.isSetext = true
                    heading.headerCharCount = count
                    heading.lines.trim()
                    state.newBlocks.append(heading)
                    return .breakDiscard
                }
            }
            block.updateSpanEnd(state.line.end)
            return .continue
        }

        private static func headingChar(_ line: inout Slice, _ count: inout Int) -> Char {
            let headingChar = line.currentChar
            if headingChar == "=" || headingChar == "-" {
                count = line.countAndSkipChar(headingChar)
                while line.currentChar.isSpaceOrTab { line.nextChar() }
                if line.isEmpty { return headingChar }
            }
            return .zero
        }

        /// Moves leading link reference definitions of a paragraph into the document.
        @discardableResult
        static func tryMatchLinkReferenceDefinition(_ paragraph: LeafBlock, _ state: BlockProcessor) -> Bool {
            var found = false
            while true {
                var iterator = LineGroup.Iterator(paragraph.lines)
                let startSpan = iterator.start
                guard let parsed = LinkHelper.tryParseLinkReferenceDefinition(&iterator) else { break }
                let definition = LinkReferenceDefinition(parsed.label, parsed.url, parsed.title)
                definition.labelSpan = parsed.labelSpan
                definition.urlSpan = parsed.urlSpan
                definition.titleSpan = parsed.titleSpan
                definition.span = SourceSpan(startSpan, parsed.titleSpan.end > 0 ? parsed.titleSpan.end : parsed.urlSpan.end)
                state.document.setLinkReferenceDefinition(parsed.label, definition, addGroup: true)
                found = true
                definition.line = paragraph.lines.count > 0 ? paragraph.lines[0].line : 0
                paragraph.lines = iterator.remaining()
            }
            return found
        }
    }
}

extension Markdown.MarkdownDocument {
    private static let referencesKey = "LinkReferenceDefinitionGroup"

    func linkReferenceDefinitions(addGroup: Bool) -> Markdown.LinkReferenceDefinitionGroup {
        if let existing = data[Self.referencesKey] as? Markdown.LinkReferenceDefinitionGroup { return existing }
        let group = Markdown.LinkReferenceDefinitionGroup()
        data[Self.referencesKey] = group
        if addGroup { add(group) }
        return group
    }

    func setLinkReferenceDefinition(_ label: String, _ definition: Markdown.LinkReferenceDefinition, addGroup: Bool) {
        linkReferenceDefinitions(addGroup: addGroup).set(label, definition)
    }

    func containsLinkReferenceDefinition(_ label: String) -> Bool {
        (data[Self.referencesKey] as? Markdown.LinkReferenceDefinitionGroup)?.containsKey(label) ?? false
    }

    func tryGetLinkReferenceDefinition(_ label: String) -> Markdown.LinkReferenceDefinition? {
        (data[Self.referencesKey] as? Markdown.LinkReferenceDefinitionGroup)?.tryGet(label)
    }
}
