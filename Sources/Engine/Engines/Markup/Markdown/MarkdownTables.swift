// Pipe tables and grid tables (Markdig's Tables extension): the table model, the pipe table inline parser that turns
// a paragraph into a table, the grid table block parser and the HTML renderer.

import Foundation

extension Markdown {
    enum TableColumnAlign { case left, center, right }

    final class TableColumnDefinition {
        /// Width in percent (Markdig keeps a `float`).
        var width: Float = 0
        var alignment: TableColumnAlign?
        init(alignment: TableColumnAlign?, width: Float) {
            self.alignment = alignment
            self.width = width
        }
    }

    final class Table: ContainerBlock {
        var columnDefinitions: [TableColumnDefinition] = []

        func isValid() -> Bool {
            if count == 0 { return false }
            let columnCount = columnDefinitions.count
            var rows = [Int](repeating: 0, count: count)
            for i in 0..<count {
                let row = self[i] as! TableRow
                for j in 0..<row.count {
                    let cell = row[j] as! TableCell
                    rows[i] += cell.columnSpan
                    var rowSpan = cell.rowSpan - 1
                    while rowSpan > 0 {
                        if i + rowSpan > rows.count - 1 { return false }
                        rows[i + rowSpan] += cell.columnSpan
                        rowSpan -= 1
                    }
                }
                if rows[i] > columnCount { return false }
            }
            return true
        }

        func normalizeUsingMaxWidth() {
            var maxColumn = 0
            for case let row as TableRow in children where row.count > maxColumn { maxColumn = row.count }
            for case let row as TableRow in children {
                var j = row.count
                while j < maxColumn {
                    row.add(TableCell(nil))
                    j += 1
                }
            }
        }
    }

    final class TableRow: ContainerBlock {
        var isHeader = false
        init() { super.init(nil) }
    }

    final class TableCell: ContainerBlock {
        var columnIndex = -1
        var columnSpan = 1
        var rowSpan = 1
        var allowClose = true
    }

    final class PipeTableDelimiterInline: DelimiterInline {
        var localLineIndex = 0
        override func toLiteral() -> String { "|" }
    }

    /// `TableHelper.ParseColumnHeader`: `:---:` style column headers.
    static func parseColumnHeader(_ slice: inout Slice, _ delimiterChar: Char) -> (align: TableColumnAlign?, count: Int)? {
        slice.trimStart()
        var c = slice.currentChar
        var hasLeft = false
        var hasRight = false
        if c == ":" {
            hasLeft = true
            slice.skipChar()
        }
        slice.trimStart()
        c = slice.currentChar
        let count = slice.countAndSkipChar(delimiterChar)
        if count == 0 { return nil }
        slice.trimStart()
        c = slice.currentChar
        if c == ":" {
            hasRight = true
            slice.skipChar()
        }
        slice.trimStart()
        let align: TableColumnAlign? = hasLeft && hasRight ? .center : hasRight ? .right : hasLeft ? .left : nil
        return (align, count)
    }

    // MARK: Pipe tables

    final class PipeTableExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.block(PipeTableBlockParser.self) == nil { builder.blockParsers.insert(PipeTableBlockParser(), at: 0) }
            let lineBreakParser = builder.inlineParsers.first { type(of: $0) == LineBreakInlineParser.self } as! LineBreakInlineParser
            if builder.inline(PipeTableParser.self) == nil {
                builder.insertInline(PipeTableParser(lineBreakParser), before: EmphasisInlineParser.self)
            }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            if !renderer.containsRenderer(HtmlTableRenderer.self) { renderer.objectRenderers.append(HtmlTableRenderer()) }
        }
    }

    /// Keeps a paragraph open over a `---|---` line so the pipe table parser sees the whole table.
    final class PipeTableBlockParser: BlockParser {
        override init() {
            super.init()
            openingCharacters = ["-"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            guard !processor.isCodeIndent, let paragraph = processor.currentBlock as? ParagraphBlock else { return .none }
            var line = processor.line
            var countPipe = 0
            while true {
                let c = line.nextChar()
                if c == .zero {
                    if countPipe > 0 {
                        paragraph.appendLine(processor.line, column: processor.column, line: processor.lineIndex, sourceLinePosition: processor.line.start)
                        paragraph.isOpen = true
                        return .breakDiscard
                    }
                    return .none
                }
                if c.isSpace || c == "-" || c == "|" || c == ":" {
                    if c == "|" { countPipe += 1 }
                    continue
                }
                return .none
            }
        }
    }

    final class PipeTableParser: InlineParser, PostInlineProcessor {
        private let lineBreakParser: LineBreakInlineParser
        var requireHeaderSeparator = true

        final class TableState {
            var isInvalidTable = false
            var lineHasPipe = false
            var columnAndLineDelimiters: [Inline] = []
            var cells: [TableCell] = []
            var endOfLines: [Inline] = []
        }

        init(_ lineBreakParser: LineBreakInlineParser) {
            self.lineBreakParser = lineBreakParser
            super.init()
            openingCharacters = ["|", "\n", "\r", ":"]
        }

        override func match(_ processor: InlineProcessor, _ slice: inout Slice) -> Bool {
            guard processor.block?.isParagraphBlock == true else { return false }
            let c = slice.currentChar
            if c == ":" {
                guard processor.state(self) is TableState, Self.isHeaderSeparatorColonBeforePipe(slice) else { return false }
                Self.matchLiteralColon(processor, &slice)
                return true
            }
            var tableState = processor.state(self) as? TableState
            var isFirstLineEmpty = false
            if tableState == nil {
                if processor.inline != nil && (c == "\n" || c == "\r") { return false }
                if processor.inline == nil { isFirstLineEmpty = true }
                tableState = TableState()
                processor.setState(self, tableState)
            }
            let state = tableState!
            if c == "\n" || c == "\r" {
                if !isFirstLineEmpty && !state.lineHasPipe { state.isInvalidTable = true }
                state.lineHasPipe = false
                _ = lineBreakParser.match(processor, &slice)
                if !isFirstLineEmpty {
                    state.columnAndLineDelimiters.append(processor.inline!)
                    state.endOfLines.append(processor.inline!)
                }
            } else {
                let delimiter = PipeTableDelimiterInline(self)
                delimiter.isClosed = true
                processor.inline = delimiter
                state.lineHasPipe = true
                slice.skipChar()
                state.columnAndLineDelimiters.append(delimiter)
            }
            return true
        }

        private static func isHeaderSeparatorColonBeforePipe(_ slice: Slice) -> Bool {
            if slice.peekChar() != "|" { return false }
            let text = slice.text
            let currentLineStart = findLineStart(text, slice.start)
            let currentLineEnd = findLineEnd(text, slice.start, slice.end)
            if !isHeaderSeparatorLine(text, currentLineStart, currentLineEnd) { return false }
            let previousLineStart = findPreviousLineStart(text, currentLineStart)
            return previousLineStart >= 0 && lineHasPipe(text, previousLineStart, currentLineStart - 1)
        }

        private static func matchLiteralColon(_ processor: InlineProcessor, _ slice: inout Slice) {
            if let previous = processor.inline as? LiteralInline, previous.content.sharesText(with: slice), previous.content.end + 1 == slice.start {
                previous.content.end = slice.start
                processor.inline = previous
            } else {
                processor.inline = LiteralInline(Slice(slice.text, slice.start, slice.start))
            }
            slice.skipChar()
        }

        private static func findLineStart(_ text: [Char], _ position: Int) -> Int {
            var i = position - 1
            while i >= 0 {
                if text[i] == "\r" || text[i] == "\n" { return i + 1 }
                i -= 1
            }
            return 0
        }

        private static func findLineEnd(_ text: [Char], _ position: Int, _ sliceEnd: Int) -> Int {
            let end = min(sliceEnd, text.count - 1)
            var i = position
            while i <= end {
                if text[i] == "\r" || text[i] == "\n" { return i - 1 }
                i += 1
            }
            return end
        }

        private static func findPreviousLineStart(_ text: [Char], _ currentLineStart: Int) -> Int {
            var previousLineEnd = currentLineStart - 2
            if previousLineEnd >= 0 && text[previousLineEnd] == "\r" { previousLineEnd -= 1 }
            if previousLineEnd < 0 { return -1 }
            var i = previousLineEnd
            while i >= 0 {
                if text[i] == "\r" || text[i] == "\n" { return i + 1 }
                i -= 1
            }
            return 0
        }

        private static func isHeaderSeparatorLine(_ text: [Char], _ start: Int, _ end: Int) -> Bool {
            var hasPipe = false
            var hasDash = false
            var i = start
            while i <= end {
                switch text[i] {
                case "|": hasPipe = true
                case "-": hasDash = true
                case ":", " ", "\t": break
                default: return false
                }
                i += 1
            }
            return hasPipe && hasDash
        }

        private static func lineHasPipe(_ text: [Char], _ start: Int, _ end: Int) -> Bool {
            var i = start
            while i <= end {
                if text[i] == "|" { return true }
                i += 1
            }
            return false
        }

        func postProcess(_ state: InlineProcessor, _ root: Inline?, _ lastChild: Inline?, _ index: Int, _ isFinalProcessing: Bool) -> Bool {
            let container = root as? ContainerInline
            let tableState = state.state(self) as? TableState
            if !isFinalProcessing {
                guard let container, let tableState else { return true }
                var child = container.lastChild
                var delimitersToRemove: [PipeTableDelimiterInline] = []
                while let current = child {
                    if let pipe = current as? PipeTableDelimiterInline { delimitersToRemove.append(pipe) }
                    if current === lastChild { break }
                    child = current.previousSibling
                }
                if !delimitersToRemove.isEmpty {
                    var leftIsDelimiter = false
                    var rightIsDelimiter = false
                    for (i, pipe) in delimitersToRemove.enumerated() {
                        pipe.replaceByLiteral()
                        let delimiters = tableState.columnAndLineDelimiters
                        let delimiterIndex = delimiters.firstIndex { $0 === pipe } ?? -1
                        if i == 0 {
                            leftIsDelimiter = delimiterIndex > 0 && delimiters[delimiterIndex - 1] is PipeTableDelimiterInline
                        } else if i + 1 == delimitersToRemove.count {
                            rightIsDelimiter = delimiterIndex >= 0 && delimiterIndex + 1 < delimiters.count && delimiters[delimiterIndex + 1] is PipeTableDelimiterInline
                        }
                        if let position = tableState.columnAndLineDelimiters.firstIndex(where: { $0 === pipe }) {
                            tableState.columnAndLineDelimiters.remove(at: position)
                        }
                    }
                    if !leftIsDelimiter && !rightIsDelimiter { tableState.lineHasPipe = false }
                }
                return true
            }
            state.setState(self, nil)
            guard let tableState, let container, !tableState.isInvalidTable, tableState.lineHasPipe else {
                if let tableState {
                    for case let pipe as PipeTableDelimiterInline in tableState.columnAndLineDelimiters { pipe.replaceByLiteral() }
                }
                return true
            }
            var delimiters = tableState.columnAndLineDelimiters
            let aligns = findHeaderRow(delimiters)
            if requireHeaderSeparator && aligns == nil {
                for case let pipe as PipeTableDelimiterInline in delimiters { pipe.replaceByLiteral() }
                return true
            }
            let table = Table(nil)
            if let attributes = state.block?.tryGetAttributes() { attributes.copyTo(table.getAttributes()) }
            var cells: [TableCell] = []
            if Self.hasNestedDelimiters(delimiters, container) { Self.promoteNestedLineBreaksToRootLevel(container) }
            Self.promoteNestedPipesToRootLevel(delimiters, container)
            if !(delimiters[delimiters.count - 1] is LineBreakInline) {
                var lastElement = delimiters[delimiters.count - 1]
                while let next = lastElement.nextSibling { lastElement = next }
                let endOfTable = LineBreakInline()
                lastElement.insertAfter(endOfTable)
                delimiters.append(endOfTable)
                tableState.endOfLines.append(endOfTable)
            }
            var row: TableRow?
            for delimiter in delimiters {
                let pipeSeparator = delimiter as? PipeTableDelimiterInline
                let isLine = delimiter is LineBreakInline
                if row == nil {
                    row = TableRow()
                    let previousSignificant = Self.skipPreviousEmptyInlines(delimiter.previousSibling)
                    if pipeSeparator != nil && (previousSignificant == nil || previousSignificant is LineBreakInline) {
                        delimiter.remove()
                        continue
                    }
                }
                var endOfCell: Inline?
                var beginOfCell: Inline?
                var iterator = delimiter.previousSibling
                while let current = iterator {
                    if current is LineBreakInline || current is PipeTableDelimiterInline { break }
                    if type(of: current) == ContainerInline.self && current.parent == nil { break }
                    beginOfCell = current
                    if endOfCell == nil { endOfCell = current }
                    iterator = current.previousSibling
                }
                if !isLine || (beginOfCell != nil && endOfCell != nil && !Self.isEmptyInlineRange(beginOfCell!, endOfCell!)) {
                    Self.trimStart(beginOfCell)
                    Self.trimEnd(endOfCell)
                    let cellContainer = ContainerInline()
                    var cellIterator = beginOfCell
                    while let current = cellIterator, !(current is LineBreakInline), !(current is PipeTableDelimiterInline) {
                        let next = current.nextSibling
                        if Self.isEmptyInline(current, whitespaceIsEmpty: false) {
                            current.remove()
                            cellIterator = next
                            continue
                        }
                        current.remove()
                        Self.appendCellInline(cellContainer, current)
                        cellIterator = next
                    }
                    Self.trimStart(cellContainer.firstChild)
                    Self.trimEnd(cellContainer.lastChild)
                    Self.removeEmptyBoundaryInlines(cellContainer)
                    if !isLine { delimiter.remove() }
                    let paragraph = ParagraphBlock(nil)
                    paragraph.inline = cellContainer
                    let cell = TableCell(nil)
                    cell.add(paragraph)
                    row!.add(cell)
                    cells.append(cell)
                }
                if isLine {
                    table.add(row!)
                    row = nil
                }
            }
            for endOfLine in tableState.endOfLines { endOfLine.remove() }
            let firstRow = table[0] as! TableRow
            firstRow.isHeader = requireHeaderSeparator
            if let aligns {
                firstRow.isHeader = true
                table.removeAt(1)
                table.columnDefinitions += aligns
            }
            for cell in cells {
                let paragraph = cell[0] as! ParagraphBlock
                state.postProcessInlines(0, paragraph.inline, nil, true)
            }
            table.normalizeUsingMaxWidth()
            if let leading = state.block as? ParagraphBlock, leading.inline?.firstChild != nil {
                state.postProcessInlines(0, leading.inline, nil, true)
                let parent = leading.parent!
                parent.processInlinesEnd.append { _, _ in
                    parent.insert(table, at: (parent.indexOf(leading) ?? -1) + 1)
                }
            } else {
                state.blockNew = table
            }
            return false
        }

        private func findHeaderRow(_ delimiters: [Inline]) -> [TableColumnDefinition]? {
            var isValidRow = false
            var totalDelimiterCount = 0
            var columnDefinitions: [TableColumnDefinition]?
            for i in delimiters.indices {
                if !(delimiters[i] is LineBreakInline) { continue }
                var j = i + 1
                while j < delimiters.count {
                    let delimiter = delimiters[j]
                    let next: Inline? = j + 1 < delimiters.count ? delimiters[j + 1] : nil
                    if j == i + 1 && Self.isStartOfLineColumnDelimiter(delimiter as? PipeTableDelimiterInline) {
                        j += 1
                        continue
                    }
                    if delimiter is LineBreakInline {
                        let previousSignificant = Self.skipTrailingWhitespace(delimiter.previousSibling)
                        if previousSignificant is PipeTableDelimiterInline {
                            isValidRow = (columnDefinitions?.count ?? 0) > 0
                            break
                        }
                        guard let header = Self.tryParseHeaderColumn(previousSignificant) else { break }
                        totalDelimiterCount += header.count
                        columnDefinitions = (columnDefinitions ?? []) + [TableColumnDefinition(alignment: header.align, width: Float(header.count))]
                        isValidRow = true
                        break
                    }
                    guard let header = Self.tryParseHeaderColumn(delimiter.previousSibling) else { break }
                    totalDelimiterCount += header.count
                    columnDefinitions = (columnDefinitions ?? []) + [TableColumnDefinition(alignment: header.align, width: Float(header.count))]
                    if next == nil {
                        let nextSibling = delimiter.nextSibling
                        if Self.isNullOrSpace(nextSibling) {
                            isValidRow = true
                            break
                        }
                        guard let trailing = Self.tryParseHeaderColumn(nextSibling) else { break }
                        totalDelimiterCount += trailing.count
                        isValidRow = true
                        columnDefinitions!.append(TableColumnDefinition(alignment: trailing.align, width: Float(trailing.count)))
                        break
                    }
                    j += 1
                }
                break
            }
            guard isValidRow, let columnDefinitions, totalDelimiterCount != 0 else { return nil }
            for definition in columnDefinitions { definition.width = 0 }
            return columnDefinitions
        }

        private static func tryParseHeaderColumn(_ inline: Inline?) -> (align: TableColumnAlign?, count: Int)? {
            guard let inline, !(inline is PipeTableDelimiterInline) else { return (nil, 0) }
            if let literal = inline as? LiteralInline, literal.content.isEmptyOrWhitespace() { return (nil, 0) }
            guard let literal = inline as? LiteralInline else { return nil }
            var line = literal.content
            guard let parsed = Markdown.parseColumnHeader(&line, "-"), line.currentChar == .zero else { return nil }
            return parsed
        }

        private static func skipTrailingWhitespace(_ inline: Inline?) -> Inline? {
            var current = inline
            while let literal = current as? LiteralInline, literal.content.isEmptyOrWhitespace() { current = literal.previousSibling }
            return current
        }

        private static func skipPreviousEmptyInlines(_ inline: Inline?) -> Inline? {
            var current = inline
            while let item = current, isEmptyInline(item, whitespaceIsEmpty: true) { current = item.previousSibling }
            return current
        }

        private static func isEmptyInlineRange(_ begin: Inline, _ end: Inline) -> Bool {
            var inline: Inline? = begin
            while let current = inline {
                if !isEmptyInline(current, whitespaceIsEmpty: true) { return false }
                if current === end { return true }
                inline = current.nextSibling
            }
            return true
        }

        private static func isEmptyInline(_ inline: Inline, whitespaceIsEmpty: Bool) -> Bool {
            if let literal = inline as? LiteralInline {
                return whitespaceIsEmpty ? literal.content.isEmptyOrWhitespace() : literal.content.isEmpty
            }
            if type(of: inline) == ContainerInline.self {
                var child = (inline as! ContainerInline).firstChild
                while let current = child {
                    if !isEmptyInline(current, whitespaceIsEmpty: whitespaceIsEmpty) { return false }
                    child = current.nextSibling
                }
                return true
            }
            return false
        }

        private static func isStartOfLineColumnDelimiter(_ inline: Inline?) -> Bool {
            guard let inline else { return false }
            var previous = inline.previousSibling
            if previous == nil { return true }
            if let literal = previous as? LiteralInline {
                if !literal.content.isEmptyOrWhitespace() { return false }
                previous = literal.previousSibling
            }
            return previous == nil || previous is LineBreakInline
        }

        private static func trimStart(_ inline: Inline?) {
            var current = inline
            while let container = current as? ContainerInline, !(container is DelimiterInline) { current = container.firstChild }
            if let literal = current as? LiteralInline { literal.content.trimStart() }
        }

        private static func trimEnd(_ inline: Inline?) {
            var current = inline
            while let container = current as? ContainerInline, !(container is PipeTableDelimiterInline) { current = container.lastChild }
            if let literal = current as? LiteralInline { literal.content.trimEnd() }
        }

        private static func isNullOrSpace(_ inline: Inline?) -> Bool {
            guard let inline else { return true }
            if let literal = inline as? LiteralInline { return literal.content.isEmptyOrWhitespace() }
            return false
        }

        private static func appendCellInline(_ cell: ContainerInline, _ inline: Inline) {
            if type(of: inline) == ContainerInline.self {
                var child = (inline as! ContainerInline).firstChild
                while let current = child {
                    let next = current.nextSibling
                    current.remove()
                    appendCellInline(cell, current)
                    child = next
                }
                return
            }
            if isEmptyInline(inline, whitespaceIsEmpty: false) { return }
            cell.appendChild(inline)
        }

        private static func removeEmptyBoundaryInlines(_ container: ContainerInline) {
            while let first = container.firstChild, isEmptyInline(first, whitespaceIsEmpty: true) { first.remove() }
            while let last = container.lastChild, isEmptyInline(last, whitespaceIsEmpty: true) { last.remove() }
        }

        private static func hasNestedDelimiters(_ delimiters: [Inline], _ root: ContainerInline) -> Bool {
            delimiters.contains { $0.parent !== root }
        }

        private static func promoteNestedLineBreaksToRootLevel(_ root: ContainerInline) {
            var nested: [Inline] = []
            var stack: [Inline] = []
            var child = root.lastChild
            while let current = child {
                stack.append(current)
                child = current.previousSibling
            }
            while let inline = stack.popLast() {
                if inline is LineBreakInline && inline.parent !== root { nested.append(inline) }
                if let container = inline as? ContainerInline {
                    var inner = container.lastChild
                    while let current = inner {
                        stack.append(current)
                        inner = current.previousSibling
                    }
                }
            }
            for lineBreak in nested { promoteNestedDelimiterToRootLevel(lineBreak, root) }
        }

        private static func promoteNestedPipesToRootLevel(_ delimiters: [Inline], _ root: ContainerInline) {
            for delimiter in delimiters where delimiter is PipeTableDelimiterInline || delimiter is LineBreakInline {
                promoteNestedDelimiterToRootLevel(delimiter, root)
            }
        }

        private static func promoteNestedDelimiterToRootLevel(_ delimiter: Inline, _ root: ContainerInline) {
            if delimiter.parent === root { return }
            var ancestor = delimiter.parent
            while let current = ancestor, let parent = current.parent, parent !== root { ancestor = parent }
            guard let ancestor, ancestor.parent === root else { return }
            guard let parent = delimiter.parent else { return }
            var contentAfter: [Inline] = []
            var current = delimiter.nextSibling
            while let item = current {
                contentAfter.append(item)
                current = item.nextSibling
            }
            for inline in contentAfter { inline.remove() }
            delimiter.remove()
            ancestor.insertAfter(delimiter)
            if !contentAfter.isEmpty {
                let container = ContainerInline()
                container.span = parent.span
                container.line = parent.line
                container.column = parent.column
                for inline in contentAfter { container.appendChild(inline) }
                delimiter.insertAfter(container)
            }
        }
    }

    // MARK: Grid tables

    final class GridTableExtension: PipelineExtension {
        func setupPipeline(_ builder: PipelineBuilder) {
            if builder.block(GridTableParser.self) == nil { builder.blockParsers.insert(GridTableParser(), at: 0) }
        }

        func setupRenderer(_ renderer: HtmlRenderer) {
            if !renderer.containsRenderer(HtmlTableRenderer.self) { renderer.objectRenderers.append(HtmlTableRenderer()) }
        }
    }

    final class GridTableState {
        final class ColumnSlice {
            let start: Int
            let end: Int
            let align: TableColumnAlign?
            var currentColumnSpan = -1
            var previousColumnSpan = 0
            var blockProcessor: BlockProcessor?
            var currentCell: TableCell?
            init(_ start: Int, _ end: Int, _ align: TableColumnAlign?) {
                self.start = start
                self.end = end
                self.align = align
            }
        }

        let start: Int
        var lines = LineGroup(capacity: 4)
        var columnSlices: [ColumnSlice]?
        var startRowGroup = 0

        init(start: Int) { self.start = start }

        func addLine(_ line: Slice) { lines.add(line) }
        func addColumn(_ start: Int, _ end: Int, _ align: TableColumnAlign?) {
            columnSlices = (columnSlices ?? []) + [ColumnSlice(start, end, align)]
        }
    }

    final class GridTableParser: BlockParser {
        static let stateKey = "GridTableState"

        override init() {
            super.init()
            openingCharacters = ["+"]
        }

        override func tryOpen(_ processor: BlockProcessor) -> BlockState {
            if processor.isCodeIndent { return .none }
            var line = processor.line
            var tableState: GridTableState?
            var c = line.currentChar
            let lineStart = line.start
            while c == "+" {
                let columnStart = line.start
                line.skipChar()
                line.trimStart()
                c = line.currentChar
                if c == .zero { break }
                guard let header = Markdown.parseColumnHeader(&line, "-") else { return .none }
                if tableState == nil { tableState = GridTableState(start: processor.start) }
                tableState!.addColumn(columnStart - lineStart, line.start - lineStart, header.align)
                c = line.currentChar
            }
            guard c == .zero, let tableState else { return .none }
            tableState.addLine(processor.line)
            let table = Table(self)
            table.line = processor.lineIndex
            table.column = processor.column
            table.span.start = lineStart
            table.data[Self.stateKey] = tableState
            var totalWidth = 0
            for column in tableState.columnSlices! { totalWidth += column.end - column.start - 1 }
            for column in tableState.columnSlices! {
                let width = Float(column.end - column.start - 1) * Float(100) / Float(totalWidth)
                table.columnDefinitions.append(TableColumnDefinition(alignment: column.align, width: width))
            }
            processor.newBlocks.append(table)
            return .continueDiscard
        }

        override func tryContinue(_ processor: BlockProcessor, _ block: Block?) -> BlockState {
            let table = block as! Table
            let tableState = table.data[Self.stateKey] as! GridTableState
            tableState.addLine(processor.line)
            if processor.currentChar == "+" {
                table.updateSpanEnd(processor.line.end)
                return handleNewRow(processor, tableState, table)
            }
            if processor.currentChar == "|" {
                table.updateSpanEnd(processor.line.end)
                return handleContents(processor, tableState, table)
            }
            Self.terminateCurrentRow(processor, tableState, table, true)
            if !table.isValid() { Self.undo(processor, tableState, table) }
            return .break
        }

        private func handleNewRow(_ processor: BlockProcessor, _ tableState: GridTableState, _ table: Table) -> BlockState {
            let columns = tableState.columnSlices!
            let (isHeaderRow, hasRowSpan) = Self.setRowSpanState(columns, processor.line)
            Self.setColumnSpanState(columns, processor.line)
            Self.terminateCurrentRow(processor, tableState, table, false)
            if isHeaderRow {
                for case let row as TableRow in table.children { row.isHeader = true }
            }
            tableState.startRowGroup = table.count
            if hasRowSpan { _ = handleContents(processor, tableState, table) }
            return .continueDiscard
        }

        private static func setRowSpanState(_ columns: [GridTableState.ColumnSlice], _ original: Slice) -> (Bool, Bool) {
            var line = original
            let lineStart = line.start
            let lineEnd = line.end
            let isHeaderRow = line.peekChar() == "=" || line.peekChar(2) == "="
            var hasRowSpan = false
            for column in columns {
                guard let cell = column.currentCell else { continue }
                line.start = lineStart + column.start + 1
                line.end = min(lineStart + column.end - 1, lineEnd)
                line.trim()
                if line.isEmptyOrWhitespace() || !isRowSeparator(line) {
                    hasRowSpan = true
                    cell.rowSpan += 1
                    cell.allowClose = false
                } else {
                    cell.allowClose = true
                }
            }
            return (isHeaderRow, hasRowSpan)
        }

        private static func isRowSeparator(_ slice: Slice) -> Bool {
            var slice = slice
            var c = slice.currentChar
            while true {
                if c != "-" && c != "=" && c != ":" { return c == .zero }
                c = slice.nextChar()
            }
        }

        private static func terminateCurrentRow(_ processor: BlockProcessor, _ tableState: GridTableState, _ table: Table, _ isLastRow: Bool) {
            let columns = tableState.columnSlices!
            var currentRow: TableRow?
            for column in columns {
                if let cell = column.currentCell {
                    if currentRow == nil {
                        let first = columns.first { $0.currentCell != nil }!.currentCell!
                        let last = columns.last { $0.currentCell != nil }!.currentCell!
                        let row = TableRow()
                        row.span = SourceSpan(first.span.start, last.span.end)
                        row.line = first.line
                        currentRow = row
                    }
                    if cell.parent == nil { currentRow!.add(cell) }
                    if cell.allowClose { column.blockProcessor!.close(cell) }
                }
                if column.blockProcessor != nil && (column.currentCell == nil || column.currentCell!.allowClose) {
                    column.blockProcessor = isLastRow ? nil : processor.createChild()
                }
                if isLastRow || column.currentColumnSpan == 0 || (column.currentCell?.allowClose ?? false) {
                    column.currentCell = nil
                }
            }
            if let currentRow, currentRow.count > 0 { table.add(currentRow) }
        }

        private func handleContents(_ processor: BlockProcessor, _ tableState: GridTableState, _ table: Table) -> BlockState {
            let isRowLine = processor.currentChar == "+"
            let columns = tableState.columnSlices!
            let line = processor.line
            Self.setColumnSpanState(columns, line)
            if !isRowLine && !Self.canContinueRow(columns) { Self.terminateCurrentRow(processor, tableState, table, false) }
            var i = 0
            while i < columns.count {
                let column = columns[i]
                let nextColumnIndex = i + column.currentColumnSpan
                if nextColumnIndex == i { break }
                let nextColumn: GridTableState.ColumnSlice? = nextColumnIndex < columns.count ? columns[nextColumnIndex] : nil
                var sliceForCell = line
                sliceForCell.start = line.start + column.start + 1
                if let nextColumn {
                    sliceForCell.end = line.start + nextColumn.start - 1
                } else {
                    let columnEnd = columns[columns.count - 1].end
                    let columnEndChar = line.peekCharExtra(columnEnd)
                    if columnEndChar == "|" || (isRowLine && columnEndChar == "+") {
                        sliceForCell.end = line.start + columnEnd - 1
                    } else if line.peekCharExtra(line.end - line.start) == "|" {
                        sliceForCell.end = line.end - 1
                    }
                }
                sliceForCell.trimEnd()
                if !isRowLine || !Self.isRowSeparator(sliceForCell) {
                    if column.currentCell == nil {
                        let cell = TableCell(self)
                        cell.columnSpan = column.currentColumnSpan
                        cell.columnIndex = i
                        cell.column = column.start
                        cell.line = processor.lineIndex
                        cell.span = SourceSpan(line.start + column.start, line.start + column.end)
                        column.currentCell = cell
                        if column.blockProcessor == nil { column.blockProcessor = processor.createChild() }
                        column.blockProcessor!.open(cell)
                    }
                    column.blockProcessor!.lineIndex = processor.lineIndex
                    column.blockProcessor!.processLinePart(sliceForCell, column: sliceForCell.start - line.start)
                }
                i = nextColumnIndex
            }
            return .continueDiscard
        }

        private static func setColumnSpanState(_ columns: [GridTableState.ColumnSlice], _ line: Slice) {
            for column in columns {
                column.previousColumnSpan = column.currentColumnSpan
                column.currentColumnSpan = 0
            }
            var columnIndex = -1
            for (i, column) in columns.enumerated() {
                let peek = line.peekChar(column.start)
                if peek == "|" || peek == "+" { columnIndex = i }
                if columnIndex >= 0 { columns[columnIndex].currentColumnSpan += 1 }
            }
        }

        private static func canContinueRow(_ columns: [GridTableState.ColumnSlice]) -> Bool {
            columns.allSatisfy { $0.previousColumnSpan == $0.currentColumnSpan }
        }

        private static func undo(_ processor: BlockProcessor, _ tableState: GridTableState, _ table: Table) {
            let parser = processor.parsers.parsers.first { type(of: $0) == ParagraphBlockParser.self }
            let parent = table.parent!
            processor.discard(table)
            let paragraph = ParagraphBlock(parser)
            paragraph.lines = tableState.lines
            parent.add(paragraph)
            processor.open(paragraph)
        }

        override func close(_ processor: BlockProcessor, _ block: Block) -> Bool {
            if let table = block as? Table, let tableState = table.data[Self.stateKey] as? GridTableState {
                Self.terminateCurrentRow(processor, tableState, table, true)
                if !table.isValid() { Self.undo(processor, tableState, table) }
            }
            return true
        }
    }

    // MARK: Rendering

    final class HtmlTableRenderer: ObjectRenderer {
        override func accepts(_ object: MarkdownObject) -> Bool { object is Table }

        override func write(_ renderer: HtmlRenderer, _ object: MarkdownObject) {
            let table = object as! Table
            guard renderer.enableHtmlForBlock else {
                let saved = renderer.implicitParagraph
                renderer.implicitParagraph = true
                for case let row as TableRow in table.children {
                    for cell in row.children {
                        renderer.write(cell)
                        renderer.write(" " as Char)
                    }
                }
                renderer.implicitParagraph = saved
                return
            }
            renderer.ensureLine()
            renderer.write("<table")
            renderer.writeAttributes(table)
            renderer.writeLine(">" as Char)
            var hasBody = false
            var hasAlreadyHeader = false
            var isHeaderOpen = false
            let hasColumnWidth = table.columnDefinitions.contains { $0.width != 0 && $0.width != 1 }
            if hasColumnWidth {
                for definition in table.columnDefinitions {
                    let width = (Double(definition.width * 100)).rounded(.toNearestOrEven) / 100
                    renderer.writeLine("<col style=\"width:\(Self.formatWidth(width))%\" />")
                }
            }
            for case let row as TableRow in table.children {
                if row.isHeader {
                    if !hasAlreadyHeader {
                        renderer.writeLine("<thead>")
                        isHeaderOpen = true
                    }
                    hasAlreadyHeader = true
                } else if !hasBody {
                    if isHeaderOpen {
                        renderer.writeLine("</thead>")
                        isHeaderOpen = false
                    }
                    renderer.writeLine("<tbody>")
                    hasBody = true
                }
                renderer.write("<tr")
                renderer.writeAttributes(row)
                renderer.writeLine(">" as Char)
                for i in 0..<row.count {
                    let cell = row[i] as! TableCell
                    renderer.ensureLine()
                    renderer.write(row.isHeader ? "<th" : "<td")
                    if cell.columnSpan != 1 { renderer.write(" colspan=\"\(cell.columnSpan)\"") }
                    if cell.rowSpan != 1 { renderer.write(" rowspan=\"\(cell.rowSpan)\"") }
                    if !table.columnDefinitions.isEmpty {
                        var columnIndex = cell.columnIndex < 0 || cell.columnIndex >= table.columnDefinitions.count ? i : cell.columnIndex
                        if columnIndex >= table.columnDefinitions.count { columnIndex = table.columnDefinitions.count - 1 }
                        switch table.columnDefinitions[columnIndex].alignment {
                        case .center: renderer.write(" style=\"text-align: center;\"")
                        case .right: renderer.write(" style=\"text-align: right;\"")
                        case .left: renderer.write(" style=\"text-align: left;\"")
                        case nil: break
                        }
                    }
                    renderer.writeAttributes(cell)
                    renderer.write(">" as Char)
                    let saved = renderer.implicitParagraph
                    if cell.count == 1 { renderer.implicitParagraph = true }
                    renderer.write(cell)
                    renderer.implicitParagraph = saved
                    renderer.writeLine(row.isHeader ? "</th>" : "</td>")
                }
                renderer.writeLine("</tr>")
            }
            if hasBody {
                renderer.writeLine("</tbody>")
            } else if isHeaderOpen {
                renderer.writeLine("</thead>")
            }
            renderer.writeLine("</table>")
        }

        /// `string.Format(InvariantCulture, "{0:0.##}", value)`.
        static func formatWidth(_ value: Double) -> String {
            let scaled = (abs(value) * 100).rounded(.toNearestOrAwayFromZero)
            var text = String(Int64(scaled) / 100)
            let fraction = Int64(scaled) % 100
            if fraction != 0 {
                var digits = String(format: "%02d", fraction)
                while digits.hasSuffix("0") { digits.removeLast() }
                text += "." + digits
            }
            return value < 0 && scaled != 0 ? "-" + text : text
        }
    }
}
