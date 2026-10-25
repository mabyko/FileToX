// Inline parsing: the processor that walks a leaf block's text and the CommonMark inline parsers (literals, entities,
// escapes, emphasis, code spans, links and images, autolinks and raw HTML, line breaks), following Markdig.

import Foundation

extension Markdown {
    /// A parser for one kind of inline (`InlineParser`).
    class InlineParser {
        var openingCharacters: [Char]?
        /// Position in the pipeline (indexes the per-block parser states).
        var index = 0

        init() {}
        func initialize() {}
        func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool { false }
    }

    /// Runs after a container's inlines were parsed (emphasis resolution, tables, ...) (`IPostInlineProcessor`).
    protocol PostInlineProcessor: AnyObject {
        func postProcess(_ state: InlineProcessor, _ root: Inline?, _ lastChild: Inline?, _ index: Int, _ isFinalProcessing: Bool) -> Bool
    }

    final class InlineParserList {
        let parsers: [InlineParser]
        private let candidates: [[InlineParser]]
        /// Per character: 1 + the index of its parsers in `candidates`, 0 for none (a lookup at every inline).
        private let candidateIndex: [UInt8]
        let globalParsers: [InlineParser]?
        let postInlineProcessors: [PostInlineProcessor]
        // 0: literal, 1: parser, 2: autolink only (ordinary words can stay in the literal scan).
        private let openingCharacters: [UInt8]

        init(_ parsers: [InlineParser]) {
            self.parsers = parsers
            var byCharacter: [Char: [InlineParser]] = [:]
            var global: [InlineParser] = []
            for (i, parser) in parsers.enumerated() {
                parser.initialize()
                parser.index = i
                if let characters = parser.openingCharacters, !characters.isEmpty {
                    for c in characters { byCharacter[c, default: []].append(parser) }
                } else {
                    global.append(parser)
                }
            }
            globalParsers = global.isEmpty ? nil : global
            postInlineProcessors = parsers.compactMap { $0 as? PostInlineProcessor }
            var openingCharacters = [UInt8](repeating: 0, count: 65536)
            for (c, candidates) in byCharacter {
                openingCharacters[c.int] = global.isEmpty && candidates.count == 1 && candidates[0] is AutoLinkParser ? 2 : 1
            }
            self.openingCharacters = openingCharacters
            (candidates, candidateIndex) = Markdown.characterTable(byCharacter)
        }

        func parsersForOpeningCharacter(_ c: Char) -> [InlineParser]? {
            let index = candidateIndex[c.int]
            return index == 0 ? nil : candidates[Int(index) - 1]
        }

        /// The first possible parser opening in `start...end`, or -1.
        func indexOfOpeningCharacter(_ text: [Char], _ start: Int, _ end: Int) -> Int {
            guard start <= end else { return -1 }
            for i in start...end {
                let kind = openingCharacters[text[i].int]
                if kind == 1 || (kind == 2 && AutoLinkParser.hasSchemePrefix(Slice(text, i, end))) { return i }
            }
            return -1
        }
    }

    final class InlineProcessor {
        let document: MarkdownDocument
        let parsers: InlineParserList
        let literalInlineParser = LiteralInlineParser()
        private(set) var block: LeafBlock?
        var blockNew: Block?
        var inline: Inline?
        private(set) var root: ContainerInline?
        private(set) var lineIndex = 0
        private var parserStates: [AnyObject?]
        var previousContainerToReplace: ContainerBlock?
        var newContainerToReplace: ContainerBlock?

        init(_ document: MarkdownDocument, _ parsers: InlineParserList) {
            self.document = document
            self.parsers = parsers
            parserStates = Array(repeating: nil, count: parsers.parsers.count)
        }

        /// Without precise source locations Markdig reports 0 for every position.
        func getSourcePosition(_ sliceOffset: Int) -> Int { 0 }
        func getSourcePositionFromLocalSpan(_ span: SourceSpan) -> SourceSpan { span.isEmpty ? .empty : SourceSpan(0, 0) }

        func replaceParentContainer(_ previous: ContainerBlock, _ new: ContainerBlock) {
            precondition(previousContainerToReplace == nil, "A block is already being replaced")
            previousContainerToReplace = previous
            newContainerToReplace = new
        }

        /// `ParserStates[index]`: per-block state of a parser, cleared for every leaf block.
        func state(_ parser: InlineParser) -> AnyObject? { parserStates[parser.index] }
        func setState(_ parser: InlineParser, _ value: AnyObject?) { parserStates[parser.index] = value }

        func parserState<State: AnyObject>(_ parser: InlineParser, _ factory: () -> State) -> State {
            if let state = parserStates[parser.index] as? State { return state }
            let state = factory()
            parserStates[parser.index] = state
            return state
        }

        func processInlineLeaf(_ leafBlock: LeafBlock) {
            previousContainerToReplace = nil
            newContainerToReplace = nil
            for i in parserStates.indices { parserStates[i] = nil }
            let root = ContainerInline()
            root.isClosed = false
            self.root = root
            leafBlock.inline = root
            inline = nil
            block = leafBlock
            blockNew = nil
            lineIndex = leafBlock.line
            var text = leafBlock.lines.toSlice()
            leafBlock.lines = LineGroup()
            var previousStart = -1
            // Markdig throws as soon as a limit is exceeded; going on would only redo the deepening walk per character.
            while !text.isEmpty && !document.depthLimitExceeded {
                precondition(previousStart != text.start, "The parser is in an invalid infinite loop while parsing inlines")
                previousStart = text.start
                let c = text.currentChar
                let saved = text
                var matched = false
                if let candidates = parsers.parsersForOpeningCharacter(c) {
                    for parser in candidates {
                        text = saved
                        if parser.match(self, &text) { matched = true; break }
                    }
                }
                if !matched, let global = parsers.globalParsers {
                    for parser in global {
                        text = saved
                        if parser.match(self, &text) { matched = true; break }
                    }
                }
                if !matched {
                    text = saved
                    _ = literalInlineParser.match(self, &text)
                }
                if let next = inline {
                    if next.parent == nil {
                        let container = findLastContainer()
                        if container !== next { container.appendChild(next) }
                        if container === root {
                            if container.span.isEmpty { container.span = next.span }
                            container.span.end = next.span.end
                        }
                    }
                } else {
                    let container = findLastContainer()
                    inline = container.lastChild is LeafInline ? container.lastChild : container
                    if inline === root { inline = nil }
                }
            }
            inline = nil
            if document.depthLimitExceeded { return }
            postProcessInlines(0, root, nil, true)
            if let last = root.lastChild {
                root.span.end = last.span.end
                leafBlock.updateSpanEnd(root.span.end)
            }
        }

        func postProcessInlines(_ startingIndex: Int, _ root: Inline?, _ lastChild: Inline?, _ isFinalProcessing: Bool) {
            let processors = parsers.postInlineProcessors
            var i = startingIndex
            while i < processors.count {
                if !processors[i].postProcess(self, root, lastChild, i, isFinalProcessing) { break }
                i += 1
            }
        }

        /// Appends an inline to the deepest open container (`Emit`).
        func emit(_ inline: Inline) {
            precondition(inline.parent == nil, "Inline has already a parent")
            let container = findLastContainer()
            container.appendChild(inline)
            if container === root && !inline.span.isEmpty {
                if container.span.isEmpty {
                    container.span = inline.span
                } else {
                    if inline.span.start < container.span.start { container.span.start = inline.span.start }
                    if inline.span.end > container.span.end { container.span.end = inline.span.end }
                }
                block?.updateSpanToInclude(inline.span)
            }
            self.inline = inline
        }

        private func findLastContainer() -> ContainerInline {
            var container = block!.inline!
            var depth = 0
            while let last = container.lastChild, last.isContainerInline, !last.closedFlag {
                container = unsafeDowncast(last, to: ContainerInline.self)
                depth += 1
            }
            if depth > Markdown.largeDepthLimit { document.depthLimitExceeded = true }
            return container
        }
    }

    // MARK: Core inline parsers

    final class LiteralInlineParser: InlineParser {
        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let text = slice.text
            var nextStart = processor.parsers.indexOfOpeningCharacter(text, slice.start + 1, slice.end)
            var length: Int
            if nextStart < 0 || nextStart >= text.count {
                nextStart = slice.end + 1
                length = nextStart - slice.start
            } else {
                length = nextStart - slice.start
                if text[nextStart] == "\n" || text[nextStart] == "\r" {
                    var end = nextStart - 1
                    while length > 0 && text[end].isSpace {
                        length -= 1
                        end -= 1
                    }
                }
            }
            let endPosition = slice.start + length - 1
            if let previous = processor.inline as? LiteralInline, previous.content.sharesText(with: slice),
               previous.content.end + 1 == slice.start {
                previous.content.end = endPosition
                previous.span.end = processor.getSourcePosition(endPosition)
            } else if length > 0 {
                let literal = LiteralInline(Slice(slice.text, slice.start, endPosition))
                literal.span = SourceSpan(processor.getSourcePosition(slice.start), processor.getSourcePosition(endPosition))
                processor.inline = literal
            }
            slice.start = nextStart
            return true
        }
    }

    final class HtmlEntityParser: InlineParser {
        override init() {
            super.init()
            openingCharacters = ["&"]
        }

        /// The decoded text of an entity at the slice and its length.
        static func tryParse(_ slice: Slice) -> (literal: String, match: Int)? {
            let scan = HtmlHelper.scanEntity(slice)
            if scan.match == 0 { return nil }
            var literal: String?
            if scan.nameLength > 0 {
                literal = EntityHelper.decodeEntity(Markdown.string(slice.text[scan.nameStart..<(scan.nameStart + scan.nameLength)]))
            } else if scan.numeric >= 0 {
                literal = EntityHelper.decodeEntity(scan.numeric)
            }
            return literal.map { ($0, scan.match) }
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            guard let parsed = Self.tryParse(slice) else { return false }
            var matched = slice
            matched.end = slice.start + parsed.match - 1
            let entity = HtmlEntityInline()
            entity.original = matched
            entity.transcoded = Slice(parsed.literal)
            entity.span = SourceSpan(processor.getSourcePosition(slice.start), processor.getSourcePosition(matched.end))
            processor.inline = entity
            slice.start += parsed.match
            return true
        }
    }

    final class EscapeInlineParser: InlineParser {
        override init() {
            super.init()
            openingCharacters = ["\\"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let startPosition = slice.start
            let c = slice.nextChar()
            if c.isAsciiPunctuation {
                let literal = LiteralInline(Slice(slice.text, slice.start, slice.start))
                literal.span.start = processor.getSourcePosition(startPosition)
                literal.span.end = literal.span.start + 1
                literal.isFirstCharacterEscaped = true
                processor.inline = literal
                slice.skipChar()
                return true
            }
            if c == "\n" || c == "\r" {
                var newLine: NewLine = c == "\n" ? .lineFeed : .carriageReturn
                if c == "\r" && slice.peekChar() == "\n" { newLine = .carriageReturnLineFeed }
                let lineBreak = LineBreakInline()
                lineBreak.isHard = true
                lineBreak.isBackslash = true
                lineBreak.span.start = processor.getSourcePosition(startPosition)
                lineBreak.span.end = lineBreak.span.start + 1
                processor.inline = lineBreak
                slice.skipChar()
                if newLine == .carriageReturnLineFeed { slice.skipChar() }
                return true
            }
            return false
        }
    }

    final class LineBreakInlineParser: InlineParser {
        var enableSoftAsHard = false

        override init() {
            super.init()
            openingCharacters = ["\n", "\r"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            guard processor.block?.isParagraphBlock == true else { return false }
            let startPosition = slice.start
            let hasDoubleSpacesBefore = slice.peekCharExtra(-1).isSpace && slice.peekCharExtra(-2).isSpace
            if slice.currentChar == "\r" && slice.peekChar() == "\n" { slice.skipChar() }
            slice.skipChar()
            let lineBreak = LineBreakInline()
            lineBreak.span.start = processor.getSourcePosition(startPosition)
            lineBreak.isHard = enableSoftAsHard || (slice.start != 0 && hasDoubleSpacesBefore)
            lineBreak.newLine = .lineFeed
            lineBreak.span.end = lineBreak.span.start
            processor.inline = lineBreak
            return true
        }
    }

    final class CodeInlineParser: InlineParser {
        override init() {
            super.init()
            openingCharacters = ["`"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let match = slice.currentChar
            if slice.peekCharExtra(-1) == match { return false }
            let openingStart = slice.start
            let openSticks = slice.countAndSkipChar(match)
            // Scan the rest of the slice for a closing run of the same length.
            let content = Array(slice.chars)
            var position = 0
            var containsNewLines = false
            while true {
                guard let found = content[position...].firstIndex(where: { $0 == "\r" || $0 == "\n" || $0 == match }) else { return false }
                var i = found
                var closeSticks = 0
                while i < content.count && content[i] == match {
                    closeSticks += 1
                    i += 1
                }
                position = i
                if openSticks == closeSticks { break }
                if closeSticks == 0 {
                    let rest = content[position...].drop(while: { $0 == "\r" || $0 == "\n" })
                    if rest.first == "|", let current = processor.inline, current.containsParentOrSiblingOfType(PipeTableDelimiterInline.self) {
                        slice.start = openingStart
                        return false
                    }
                    containsNewLines = true
                    position += 1
                }
            }
            let rawLength = position - openSticks
            let raw = Array(content[0..<rawLength])
            var text: [Char]
            if containsNewLines {
                text = []
                for c in raw where c != "\r" { text.append(c == "\n" ? " " : c) }
            } else {
                text = raw
            }
            if raw.count > 2 && (raw[0] == " " || raw[0] == "\n") && (raw[raw.count - 1] == " " || raw[raw.count - 1] == "\n")
                && raw.contains(where: { $0 != " " && $0 != "\r" && $0 != "\n" }) {
                text = Array(text[1..<(text.count - 1)])
            }
            var startPosition = slice.start
            slice.start = startPosition + rawLength + openSticks
            startPosition -= openSticks
            let code = CodeInline(Markdown.string(text))
            code.delimiter = slice.text[startPosition]
            code.span = SourceSpan(processor.getSourcePosition(startPosition), processor.getSourcePosition(slice.start - 1))
            code.delimiterCount = openSticks
            processor.inline = code
            return true
        }
    }

    final class AutolinkInlineParser: InlineParser {
        var enableHtmlParsing = true
        var openInNewWindow = false

        override init() {
            super.init()
            openingCharacters = ["<"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let saved = slice
            if let parsed = LinkHelper.tryParseAutolink(&slice) {
                let autolink = AutolinkInline(parsed.link)
                autolink.isEmail = parsed.isEmail
                autolink.span = SourceSpan(processor.getSourcePosition(saved.start), processor.getSourcePosition(slice.start - 1))
                if openInNewWindow { autolink.getAttributes().addPropertyIfNotExist("target", "_blank") }
                processor.inline = autolink
            } else if enableHtmlParsing {
                slice = saved
                guard let tag = HtmlHelper.tryParseHtmlTag(&slice) else { return false }
                let html = HtmlInline(tag)
                html.span = SourceSpan(processor.getSourcePosition(saved.start), processor.getSourcePosition(slice.start - 1))
                if openInNewWindow { html.getAttributes().addPropertyIfNotExist("target", "_blank") }
                processor.inline = html
            } else {
                return false
            }
            return true
        }
    }

    final class EmphasisInlineParser: InlineParser, PostInlineProcessor {
        var emphasisDescriptors: [EmphasisDescriptor] = [EmphasisDescriptor("*", 1, 2, true), EmphasisDescriptor("_", 1, 2, false)]
        /// Extensions create their own emphasis inlines for their characters (newest first).
        var tryCreateEmphasisInlineList: [(Char, Int) -> EmphasisInline?] = []
        private var emphasisMap: [Char: EmphasisDescriptor] = [:]

        override func initialize() {
            var characters: [Char] = []
            emphasisMap = [:]
            for descriptor in emphasisDescriptors {
                precondition(!characters.contains(descriptor.character), "The character `\(descriptor.character)` is already used by another emphasis descriptor")
                characters.append(descriptor.character)
                emphasisMap[descriptor.character] = descriptor
            }
            openingCharacters = characters
        }

        func hasEmphasisChar(_ c: Char) -> Bool { emphasisDescriptors.contains { $0.character == c } }

        func postProcess(_ state: InlineProcessor, _ root: Inline?, _ lastChild: Inline?, _ index: Int, _ isFinalProcessing: Bool) -> Bool {
            guard let container = root as? ContainerInline else { return true }
            var delimiters: [EmphasisDelimiterInline] = []
            if let delimiter = container as? EmphasisDelimiterInline { delimiters.append(delimiter) }
            var child = container.firstChild
            while let current = child {
                if current === lastChild { break }
                if let delimiterInline = current as? DelimiterInline {
                    if let delimiter = delimiterInline as? EmphasisDelimiterInline { delimiters.append(delimiter) }
                    child = delimiterInline.firstChild ?? delimiterInline.nextSibling
                } else {
                    child = current.nextSibling
                }
            }
            if !delimiters.isEmpty { processEmphasis(state, &delimiters) }
            return true
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            let delimiterChar = slice.currentChar
            guard let descriptor = emphasisMap[delimiterChar] else { return false }
            var previous: Unicode.Scalar = "\0"
            if let entity = processor.inline as? HtmlEntityInline, entity.transcoded.length > 0 {
                previous = Markdown.string(entity.transcoded.chars).unicodeScalars.last ?? "\0"
            }
            if previous == "\0" {
                previous = slice.peekRuneExtra(-1)
                if previous.value == UInt32(delimiterChar.value) && slice.peekCharExtra(-2) != "\\" { return false }
            }
            let startPosition = slice.start
            let delimiterCount = slice.countAndSkipChar(delimiterChar)
            if delimiterCount < descriptor.minimumCount { return false }
            var next = slice.currentRune
            if let entity = HtmlEntityParser.tryParse(slice) {
                next = entity.literal.unicodeScalars.first ?? "\u{FFFD}"
            }
            let (canOpen, canClose) = Markdown.checkOpenCloseDelimiter(previous, next, enableWithinWord: descriptor.enableWithinWord)
            if canOpen || canClose {
                var type = DelimiterType()
                if canOpen { type.insert(.open) }
                if canClose { type.insert(.close) }
                let delimiter = EmphasisDelimiterInline(self, descriptor, Slice(slice.text, startPosition, slice.start - 1))
                delimiter.delimiterCount = delimiterCount
                delimiter.type = type
                delimiter.span = SourceSpan(processor.getSourcePosition(startPosition), processor.getSourcePosition(slice.start - 1))
                processor.inline = delimiter
                return true
            }
            return false
        }

        private func processEmphasis(_ processor: InlineProcessor, _ delimiters: inout [EmphasisDelimiterInline]) {
            var i = 0
            while i < delimiters.count {
                let closeDelimiter = delimiters[i]
                guard let descriptor = emphasisMap[closeDelimiter.delimiterChar] else { i += 1; continue }
                if closeDelimiter.type.contains(.close) {
                    outer: while closeDelimiter.delimiterCount >= descriptor.minimumCount {
                        var openDelimiter: EmphasisDelimiterInline?
                        var openDelimiterIndex = -1
                        var j = i - 1
                        while j >= 0 {
                            let previous = delimiters[j]
                            let isOddMatch = (closeDelimiter.type.contains(.open) || previous.type.contains(.close))
                                && previous.delimiterCount != closeDelimiter.delimiterCount
                                && (previous.delimiterCount + closeDelimiter.delimiterCount) % 3 == 0
                                && (previous.delimiterCount % 3 != 0 || closeDelimiter.delimiterCount % 3 != 0)
                            if previous.delimiterChar == closeDelimiter.delimiterChar && previous.type.contains(.open)
                                && previous.delimiterCount >= descriptor.minimumCount && !isOddMatch {
                                openDelimiter = previous
                                openDelimiterIndex = j
                                break
                            }
                            j -= 1
                        }
                        guard let open = openDelimiter else { break }
                        // process_delims: the opener and closer may match several times.
                        while true {
                            let delimiterDelta = min(min(open.delimiterCount, closeDelimiter.delimiterCount), descriptor.maximumCount)
                            var emphasis: EmphasisInline?
                            for create in tryCreateEmphasisInlineList.reversed() {
                                emphasis = create(closeDelimiter.delimiterChar, delimiterDelta)
                                if emphasis != nil { break }
                            }
                            let created = emphasis ?? {
                                let made = EmphasisInline()
                                made.delimiterChar = closeDelimiter.delimiterChar
                                made.delimiterCount = delimiterDelta
                                return made
                            }()
                            let openCount = open.delimiterCount
                            let closeCount = closeDelimiter.delimiterCount
                            created.span.start = open.span.start + openCount - delimiterDelta
                            created.line = open.line
                            created.column = open.column + openCount - delimiterDelta
                            created.span.end = closeDelimiter.span.end - closeCount + delimiterDelta
                            open.span.end -= delimiterDelta
                            open.content.end -= delimiterDelta
                            closeDelimiter.content.start += delimiterDelta
                            closeDelimiter.span.start += delimiterDelta
                            closeDelimiter.column += delimiterDelta
                            open.delimiterCount -= delimiterDelta
                            closeDelimiter.delimiterCount -= delimiterDelta
                            if let attributes = closeDelimiter.tryGetAttributes() { created.setAttributes(attributes) }
                            (open as ContainerInline).embraceChildrenBy(created)
                            var k = i - 1
                            while k >= openDelimiterIndex + 1 {
                                let literalDelimiter = delimiters[k]
                                literalDelimiter.replaceBy(literalDelimiter.asLiteralInline())
                                delimiters.remove(at: k)
                                i -= 1
                                k -= 1
                            }
                            if closeDelimiter.delimiterCount == 0 {
                                let newParent: Inline = open.delimiterCount > 0 ? created : created.parent!
                                closeDelimiter.moveChildrenAfter(newParent)
                                closeDelimiter.remove()
                                delimiters.remove(at: i)
                                i -= 1
                                if open.delimiterCount == 0 {
                                    open.moveChildrenAfter(open)
                                    open.remove()
                                    delimiters.remove(at: openDelimiterIndex)
                                    i -= 1
                                }
                                break outer
                            }
                            if open.delimiterCount >= descriptor.minimumCount && closeDelimiter.delimiterCount >= descriptor.minimumCount {
                                continue
                            } else if open.delimiterCount > 0 {
                                open.replaceBy(open.asLiteralInline())
                                delimiters.remove(at: openDelimiterIndex)
                                i -= 1
                            } else {
                                let firstChild = open.firstChild!
                                firstChild.remove()
                                open.replaceBy(firstChild)
                                firstChild.isClosed = true
                                closeDelimiter.remove()
                                firstChild.insertAfter(closeDelimiter)
                                delimiters.remove(at: openDelimiterIndex)
                                i -= 1
                            }
                            break
                        }
                    }
                    if closeDelimiter.delimiterCount > 0, let parentEmphasis = closeDelimiter.parent as? EmphasisInline {
                        var outermost = parentEmphasis
                        while let ancestor = outermost.parent as? EmphasisInline { outermost = ancestor }
                        closeDelimiter.moveChildrenAfter(outermost)
                    }
                    if closeDelimiter.delimiterCount > 0 && !closeDelimiter.type.contains(.open) {
                        closeDelimiter.replaceBy(closeDelimiter.asLiteralInline())
                        delimiters.remove(at: i)
                        i -= 1
                    }
                }
                i += 1
            }
            for delimiter in delimiters { delimiter.replaceBy(delimiter.asLiteralInline()) }
            delimiters.removeAll()
        }
    }

    final class LinkInlineParser: InlineParser {
        var openInNewWindow = false

        override init() {
            super.init()
            openingCharacters = ["[", "]", "!"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            var c = slice.currentChar
            let startPosition = processor.getSourcePosition(slice.start)
            var isImage = false
            if c == "!" {
                isImage = true
                c = slice.nextChar()
                if c != "[" { return false }
            }
            switch c {
            case "[":
                let saved = slice
                var label: String?
                var labelSpan = SourceSpan.empty
                if let parsed = LinkHelper.tryParseLabel(&slice) {
                    labelSpan = parsed.span
                    label = processor.document.containsLinkReferenceDefinition(parsed.label) ? parsed.label : nil
                }
                slice = saved
                slice.skipChar()
                let delimiter = LinkDelimiterInline(self)
                delimiter.type = .open
                delimiter.label = label
                delimiter.labelSpan = processor.getSourcePositionFromLocalSpan(labelSpan)
                delimiter.isImage = isImage
                delimiter.span = SourceSpan(startPosition, processor.getSourcePosition(slice.start - 1))
                processor.inline = delimiter
                return true
            case "]":
                slice.skipChar()
                if processor.inline != nil && tryProcessLinkOrImage(processor, &slice) { return true }
                return false
            default:
                return false
            }
        }

        private func processLinkReference(_ state: InlineProcessor, _ label: String, _ isShortcut: Bool, _ labelSpan: SourceSpan,
                                          _ parent: LinkDelimiterInline, _ endPosition: Int) -> Bool {
            guard let linkRef = state.document.tryGetLinkReferenceDefinition(label) else { return false }
            if !linkRef.allowResolutionInsideOpenLink && Self.hasActiveAncestorLink(parent) { return false }
            var link: Inline?
            if let create = linkRef.createLinkInline {
                let created = create(state, linkRef, parent.firstChild)
                created.span = SourceSpan(parent.span.start, endPosition)
                created.line = parent.line
                created.column = parent.column
                link = created
            }
            if link == nil {
                let linkInline = LinkInline()
                linkInline.url = HtmlHelper.unescape(linkRef.url, removeBackSlash: false)
                linkInline.title = HtmlHelper.unescape(linkRef.title, removeBackSlash: false)
                linkInline.label = label
                linkInline.labelSpan = labelSpan
                linkInline.urlSpan = linkRef.urlSpan
                linkInline.isImage = parent.isImage
                linkInline.isShortcut = isShortcut
                linkInline.reference = linkRef
                linkInline.span = SourceSpan(parent.span.start, endPosition)
                linkInline.line = parent.line
                linkInline.column = parent.column
                if openInNewWindow { linkInline.getAttributes().addPropertyIfNotExist("target", "_blank") }
                link = linkInline
            }
            let result = link!
            if let container = result as? ContainerInline {
                var child = parent.firstChild
                if child == nil {
                    let empty = LiteralInline(Slice.empty)
                    empty.isClosed = true
                    empty.span = parent.span
                    empty.line = parent.line
                    empty.column = parent.column
                    container.appendChild(empty)
                } else {
                    while let current = child {
                        let next = current.nextSibling
                        current.remove()
                        container.appendChild(current)
                        child = next
                    }
                }
            }
            result.isClosed = true
            state.postProcessInlines(0, result, nil, false)
            state.inline = result
            return true
        }

        private func tryProcessLinkOrImage(_ inlineState: InlineProcessor, _ text: inout Slice) -> Bool {
            guard let openParent = inlineState.inline!.firstParentOfType(LinkDelimiterInline.self) else { return false }
            if !openParent.isActive {
                let literal = LiteralInline("[")
                literal.span = openParent.span
                literal.line = openParent.line
                literal.column = openParent.column
                inlineState.inline = literal
                openParent.replaceBy(literal)
                return false
            }
            let parentDelimiter = openParent.parent
            let savedText = text
            if text.currentChar == "(" {
                if let parsed = LinkHelper.tryParseInlineLink(&text) {
                    let link = LinkInline()
                    link.url = HtmlHelper.unescape(parsed.link, removeBackSlash: false)
                    link.title = parsed.title.map { HtmlHelper.unescape($0, removeBackSlash: false) }
                    link.isImage = openParent.isImage
                    link.labelSpan = openParent.labelSpan
                    link.urlSpan = inlineState.getSourcePositionFromLocalSpan(parsed.linkSpan)
                    link.titleSpan = inlineState.getSourcePositionFromLocalSpan(parsed.titleSpan)
                    link.span = SourceSpan(openParent.span.start, inlineState.getSourcePosition(text.start - 1))
                    link.line = openParent.line
                    link.column = openParent.column
                    openParent.replaceBy(link)
                    inlineState.inline = link
                    inlineState.postProcessInlines(0, link, nil, false)
                    if !openParent.isImage { Self.markParentAsInactive(parentDelimiter) }
                    link.isClosed = true
                    return true
                }
                text = savedText
            }
            var labelSpan = SourceSpan.empty
            var label: String?
            var isLabelSpanLocal = true
            var isShortcut = false
            if text.currentChar == "[" {
                if text.peekChar() == "]" {
                    label = openParent.label
                    labelSpan = openParent.labelSpan
                    isLabelSpanLocal = false
                    text.skipChar()
                    text.skipChar()
                }
            } else {
                label = openParent.label
                isShortcut = true
            }
            if label == nil, let parsed = LinkHelper.tryParseLabel(&text, allowEmpty: true) {
                label = parsed.label
                labelSpan = parsed.span
            }
            if let label {
                if isLabelSpanLocal { labelSpan = inlineState.getSourcePositionFromLocalSpan(labelSpan) }
                if processLinkReference(inlineState, label, isShortcut, labelSpan, openParent, inlineState.getSourcePosition(text.start - 1)) {
                    openParent.remove()
                    if !openParent.isImage { Self.markParentAsInactive(parentDelimiter) }
                    return true
                } else if text.currentChar != "]" && text.currentChar != "[" {
                    return false
                }
            }
            let literal = LiteralInline(openParent.isImage ? "![" : "[")
            literal.span = openParent.span
            inlineState.inline = openParent.replaceBy(literal)
            return false
        }

        private static func hasActiveAncestorLink(_ delimiter: LinkDelimiterInline) -> Bool {
            var inline = delimiter.parent as Inline?
            while let current = inline {
                if let link = current as? LinkDelimiterInline, link.isActive { return true }
                inline = current.parent
            }
            return false
        }

        private static func markParentAsInactive(_ inline: Inline?) {
            var current = inline
            while let item = current {
                if let link = item as? LinkDelimiterInline {
                    if link.isImage { break }
                    link.isActive = false
                }
                current = item.parent
            }
        }
    }
}
