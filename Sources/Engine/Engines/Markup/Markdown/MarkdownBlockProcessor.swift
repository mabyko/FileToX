// Block parsing: the line-by-line state machine of open blocks (continuation, lazy paragraph lines, new blocks) and
// the block parser contract, following Markdig's BlockProcessor.

import Foundation

extension Markdown {
    /// What a block parser did with a line (`BlockState`).
    enum BlockState: Equatable {
        case none, skip, `continue`, continueDiscard, `break`, breakDiscard

        var isDiscard: Bool { self == .continueDiscard || self == .breakDiscard }
        var isContinue: Bool { self == .continue || self == .continueDiscard }
        var isBreak: Bool { self == .break || self == .breakDiscard }
    }

    /// A parser for one kind of block (`BlockParser`).
    class BlockParser {
        /// Characters a block of this kind starts with; nil for parsers tried on every line.
        var openingCharacters: [Char]?
        /// Called when a block of this parser is closed and kept (Markdig's `Closed` event).
        var closed: [(BlockProcessor, Block) -> Void] = []

        init() {}

        func initialize() {}
        func hasOpeningCharacter(_ c: Char) -> Bool { openingCharacters?.contains(c) ?? false }
        func canInterrupt(_ processor: BlockProcessor, _ block: Block) -> Bool { true }
        func tryOpen(_ processor: BlockProcessor) -> BlockState { .none }
        func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState { .none }
        /// False removes the block.
        func close(_ processor: BlockProcessor, _ block: Block) -> Bool { true }
    }

    /// Block parsers by opening character, in pipeline order (`BlockParserList`).
    final class BlockParserList {
        let parsers: [BlockParser]
        private let candidates: [[BlockParser]]
        /// Per character: 1 + the index of its parsers in `candidates`, 0 for none (a lookup on every line).
        private let candidateIndex: [UInt32]
        let globalParsers: [BlockParser]?

        init(_ parsers: [BlockParser]) {
            self.parsers = parsers
            var byCharacter: [Char: [BlockParser]] = [:]
            var global: [BlockParser] = []
            for parser in parsers {
                parser.initialize()
                if let characters = parser.openingCharacters, !characters.isEmpty {
                    for c in characters { byCharacter[c, default: []].append(parser) }
                } else {
                    global.append(parser)
                }
            }
            globalParsers = global.isEmpty ? nil : global
            (candidates, candidateIndex) = Markdown.characterTable(byCharacter)
        }

        func parsersForOpeningCharacter(_ c: Char) -> [BlockParser]? {
            let index = candidateIndex[c.int]
            return index == 0 ? nil : candidates[Int(index) - 1]
        }
    }

    /// The state of block parsing: the current line, column and the stack of open blocks (`BlockProcessor`).
    final class BlockProcessor {
        let document: MarkdownDocument
        let parsers: BlockParserList
        let maximumNestingDepth: Int

        var newBlocks: [Block] = []
        private(set) var currentContainer: ContainerBlock?
        private(set) var currentBlock: Block?
        private(set) var lastBlock: Block?
        private var openedBlocks: [Block] = []
        /// Counts changes of `openedBlocks`; with the container's `mutations` it tells when the current blocks are known.
        private var openedChanges = 0
        private var updatedChanges = -1
        private var updatedMutations = -1
        private var currentStackIndex = 0
        private var originalLineStart = 0
        private var continueProcessingLine = false

        var line = Slice.empty
        private(set) var currentLineStartPosition = 0
        var lineIndex = 0
        var column = 0
        private(set) var columnBeforeIndent = 0
        private(set) var startBeforeIndent = 0
        private(set) var isLazy = false
        private(set) var hasUnmatchedBlocks = false

        init(_ document: MarkdownDocument, _ parsers: BlockParserList, maximumNestingDepth: Int) {
            self.document = document
            self.parsers = parsers
            self.maximumNestingDepth = maximumNestingDepth
        }

        /// A processor for nested content (grid table cells), sharing the document and parsers.
        func createChild() -> BlockProcessor { BlockProcessor(document, parsers, maximumNestingDepth: maximumNestingDepth) }

        var nextContinue: Block? {
            let index = currentStackIndex + 1
            return index < openedBlocks.count ? openedBlocks[index] : nil
        }

        var isBlankLine: Bool { line.isEmpty }
        var currentChar: Char { line.currentChar }
        var start: Int { line.start }
        var indent: Int { column - columnBeforeIndent }
        var isCodeIndent: Bool { indent >= 4 }

        func currentContainerOpened() -> ContainerBlock {
            var container = currentContainer
            while let block = container, !block.isOpen { container = block.parent }
            return container!
        }

        @discardableResult
        func nextChar() -> Char {
            let c = line.currentChar
            if c == "\t" { column = Markdown.addTab(column) } else { column += 1 }
            return line.nextChar()
        }

        func nextColumn() {
            let c = line.currentChar
            if c == "\t" && Markdown.isAcrossTab(column) {
                column += 1
            } else {
                line.nextChar()
                column += 1
            }
        }

        func peekChar(_ offset: Int) -> Char { line.peekChar(offset) }

        func restartIndent() {
            startBeforeIndent = start
            columnBeforeIndent = column
        }

        func parseIndent() {
            var c = currentChar
            let previousStartBeforeIndent = startBeforeIndent
            let startBeforeIndentNow = start
            let previousColumnBeforeIndent = columnBeforeIndent
            let columnBeforeIndentNow = column
            while c != .zero {
                if c == "\t" { column = Markdown.addTab(column) } else if c == " " { column += 1 } else { break }
                c = line.nextChar()
            }
            if columnBeforeIndentNow == column {
                startBeforeIndent = previousStartBeforeIndent
                columnBeforeIndent = previousColumnBeforeIndent
            } else {
                startBeforeIndent = startBeforeIndentNow
                columnBeforeIndent = columnBeforeIndentNow
            }
        }

        func goToColumn(_ newColumn: Int) {
            if newColumn >= columnBeforeIndent {
                line.start = startBeforeIndent
                column = columnBeforeIndent
            } else {
                line.start = originalLineStart
                column = 0
                columnBeforeIndent = 0
                startBeforeIndent = originalLineStart
            }
            while line.start <= line.end && column < newColumn {
                let c = line.text[line.start]
                if c == "\t" {
                    column = Markdown.addTab(column)
                } else {
                    if !c.isSpaceOrTab {
                        columnBeforeIndent = column + 1
                        startBeforeIndent = line.start + 1
                    }
                    column += 1
                }
                line.start += 1
            }
            if column > newColumn {
                column = newColumn
                if line.start > 0 { line.start -= 1 }
            }
        }

        func unwindAllIndents() {
            let previousStart = line.start
            while line.start > originalLineStart {
                let c = line.peekCharAbsolute(line.start - 1)
                if c == .zero || !c.isSpaceOrTab { break }
                line.start -= 1
            }
            let targetStart = line.start
            if previousStart == targetStart { return }
            line.start = originalLineStart
            column = 0
            columnBeforeIndent = 0
            startBeforeIndent = originalLineStart
            while line.start < targetStart {
                let c = line.text[line.start]
                if c == "\t" {
                    column = Markdown.addTab(column)
                } else {
                    if !c.isSpaceOrTab {
                        columnBeforeIndent = column + 1
                        startBeforeIndent = line.start + 1
                    }
                    column += 1
                }
                line.start += 1
            }
            columnBeforeIndent = column
            startBeforeIndent = start
        }

        func goToCodeIndent(_ columnOffset: Int = 0) { goToColumn(columnBeforeIndent + 4 + columnOffset) }

        func open(_ block: Block) {
            precondition(block.isOpen, "The block must be opened")
            openedBlocks.append(block)
            openedChanges &+= 1
        }

        /// Closes `block` and every block opened after it.
        func close(_ block: Block) {
            var i = openedBlocks.count - 1
            while i >= 0 {
                if openedBlocks[i] === block {
                    var j = openedBlocks.count - 1
                    while j >= i { close(at: j); j -= 1 }
                    break
                }
                i -= 1
            }
        }

        func discard(_ block: Block) { _ = tryDiscard(block) }

        func tryDiscard(_ block: Block) -> Bool {
            var i = openedBlocks.count - 1
            while i >= 1 {
                if openedBlocks[i] === block {
                    block.parent?.remove(block)
                    openedBlocks.remove(at: i)
                    openedChanges &+= 1
                    return true
                }
                i -= 1
            }
            return false
        }

        func isOpen(_ block: Block) -> Bool { openedBlocks.contains { $0 === block } }

        func processLine(_ newLine: Slice) {
            currentLineStartPosition = newLine.start
            continueProcessingLine = true
            resetLine(newLine, column: 0)
            process()
            lineIndex += 1
        }

        /// Processes part of a line (a grid table cell) that starts at `column`.
        func processLinePart(_ part: Slice, column: Int) {
            currentLineStartPosition = part.start - column
            continueProcessingLine = true
            resetLine(part, column: column)
            process()
        }

        private func process() {
            tryContinueBlocks()
            tryOpenBlocks()
            closeAll(false)
        }

        private func close(at index: Int) {
            let block = openedBlocks[index]
            if let parser = block.parser {
                if !parser.close(self, block) {
                    block.parent?.remove(block)
                } else {
                    for handler in parser.closed { handler(self, block) }
                }
            }
            openedBlocks.remove(at: index)
            openedChanges &+= 1
        }

        func closeAll(_ force: Bool) {
            var i = openedBlocks.count - 1
            while i >= 1 {
                let block = openedBlocks[i]
                if !force && block.isOpen { break }
                close(at: i)
                i -= 1
            }
            updateLastBlockAndContainer()
        }

        private func openAll() {
            for i in 1..<max(1, openedBlocks.count) { openedBlocks[i].isOpen = true }
        }

        private func updateLastBlockAndContainer(_ stackIndex: Int = -1) {
            currentStackIndex = stackIndex < 0 ? openedBlocks.count - 1 : stackIndex
            // Same open blocks and the same children of the container found for them: the same three blocks.
            if openedChanges == updatedChanges, let container = currentContainer, container.mutations == updatedMutations { return }
            let blocks = openedBlocks
            let current = blocks.last
            for block in blocks.reversed() {
                if let container = block as? ContainerBlock {
                    if currentContainer !== container { currentContainer = container }
                    let last = container.lastChild
                    if lastBlock !== last { lastBlock = last }
                    if currentBlock !== current { currentBlock = current }
                    (updatedChanges, updatedMutations) = (openedChanges, container.mutations)
                    return
                }
            }
            currentBlock = current
            lastBlock = nil
            updatedChanges = -1
        }

        private func tryContinueBlocks() {
            isLazy = false
            hasUnmatchedBlocks = false
            for i in 1..<max(1, openedBlocks.count) { openedBlocks[i].isOpen = false }
            var i = 1
            while i < openedBlocks.count {
                let block = openedBlocks[i]
                parseIndent()
                if block.isParagraphBlock { break }
                let parser = block.parser!
                updateLastBlockAndContainer(i)
                let result = parser.tryContinue(self, block)
                if result == .skip { i += 1; continue }
                if result == .none {
                    hasUnmatchedBlocks = true
                    break
                }
                restartIndent()
                if i >= openedBlocks.count { i = openedBlocks.count - 1 }
                precondition(!(i + 1 < openedBlocks.count && !newBlocks.isEmpty),
                             "A pending parser cannot add a new block when it is not the last pending block")
                if let leaf = block as? LeafBlock, newBlocks.isEmpty {
                    continueProcessingLine = false
                    if !result.isDiscard {
                        leaf.appendLine(line, column: column, line: lineIndex, sourceLinePosition: currentLineStartPosition)
                    }
                }
                block.isOpen = result == .continue || result == .continueDiscard
                if result == .breakDiscard {
                    continueProcessingLine = false
                    break
                }
                let isLast = i == openedBlocks.count - 1
                if continueProcessingLine { processNewBlocks(result, allowClosing: false) }
                if isLast || !continueProcessingLine { break }
                i += 1
            }
        }

        private func tryOpenBlocks() {
            var previousStart = -1
            while continueProcessingLine {
                precondition(previousStart != start, "The parser is in an invalid infinite loop at line \(lineIndex)")
                previousStart = start
                parseIndent()
                if let candidates = parsers.parsersForOpeningCharacter(currentChar), tryOpenBlocks(candidates) {
                    restartIndent()
                    continue
                }
                if let global = parsers.globalParsers, continueProcessingLine, tryOpenBlocks(global) {
                    restartIndent()
                    continue
                }
                break
            }
        }

        private func tryOpenBlocks(_ candidates: [BlockParser]) -> Bool {
            for blockParser in candidates {
                isLazy = false
                if line.isEmpty {
                    continueProcessingLine = false
                    break
                }
                updateLastBlockAndContainer()
                let last = currentBlock!
                if !blockParser.canInterrupt(self, last) { continue }
                isLazy = last.isParagraphBlock && blockParser is ParagraphBlockParser
                let result = isLazy ? blockParser.tryContinue(self, last) : blockParser.tryOpen(self)
                if result == .none {
                    if isLazy && isBlankLine {
                        continueProcessingLine = false
                        break
                    }
                    continue
                }
                updateLastBlockAndContainer()
                if isLazy, let paragraph = currentBlock as? ParagraphBlock {
                    if !result.isDiscard {
                        paragraph.appendLine(line, column: column, line: lineIndex, sourceLinePosition: currentLineStartPosition)
                    }
                    openAll()
                    continueProcessingLine = false
                    break
                }
                if newBlocks.isEmpty && result == .breakDiscard {
                    continueProcessingLine = false
                    break
                }
                processNewBlocks(result, allowClosing: true)
                return continueProcessingLine
            }
            isLazy = false
            return false
        }

        private func processNewBlocks(_ result: BlockState, allowClosing: Bool) {
            while let block = newBlocks.popLast() {
                precondition(block.parser != nil, "The new block [\(type(of: block))] must have a valid parser")
                block.line = lineIndex
                if let leaf = block as? LeafBlock {
                    if !result.isDiscard {
                        leaf.appendLine(line, column: column, line: lineIndex, sourceLinePosition: currentLineStartPosition)
                    }
                    precondition(newBlocks.isEmpty, "The NewBlocks is not empty. This is happening if a LeafBlock is not the last to be pushed")
                }
                if allowClosing { closeAll(false) }
                if block.parent == nil {
                    updateLastBlockAndContainer()
                    currentContainer!.add(block)
                }
                block.isOpen = result.isContinue
                openedBlocks.append(block)
                openedChanges &+= 1
                if block is LeafBlock {
                    continueProcessingLine = false
                    return
                }
            }
            continueProcessingLine = !result.isDiscard
        }

        private func resetLine(_ newLine: Slice, column: Int) {
            line = newLine
            self.column = column
            columnBeforeIndent = 0
            startBeforeIndent = start
            originalLineStart = newLine.start - column
        }
    }
}
