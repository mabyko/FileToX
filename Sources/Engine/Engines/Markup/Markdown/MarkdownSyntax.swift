// The Markdown syntax tree: blocks, inlines and their HTML attributes, with Markdig's structure and linking rules
// (inline siblings form a linked list whose quirks the parser relies on).

import Foundation

extension Markdown {
    /// Start and end (inclusive) of an object in the source.
    struct SourceSpan: Equatable {
        var start: Int
        var end: Int

        init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
        static let empty = SourceSpan(0, -1)
        var isEmpty: Bool { start > end }
        var length: Int { end - start + 1 }
    }

    /// Base of every block and inline (`MarkdownObject`).
    class MarkdownObject {
        var line = 0
        var column = 0
        var span = SourceSpan.empty
        /// `IsClosedInternal` (an inline that takes no more children).
        var closedFlag = false
        /// `InternalSpareBit` (LiteralInline.IsFirstCharacterEscaped).
        var spareFlag = false
        private var attributes: HtmlAttributes?
        /// Other attached data (`SetData` / `GetData`) by key.
        var data: [String: AnyObject] = [:]

        init() {}

        func tryGetAttributes() -> HtmlAttributes? { attributes }

        func getAttributes() -> HtmlAttributes {
            if let attributes { return attributes }
            let created = HtmlAttributes()
            attributes = created
            return created
        }

        func setAttributes(_ attributes: HtmlAttributes) { self.attributes = attributes }
    }

    /// Id, classes and other attributes of an element (`HtmlAttributes`). The class and property lists are shared
    /// by reference when copied, as in Markdig.
    final class HtmlAttributes: MarkdownObject {
        final class Strings { var items: [String] = []; init(_ items: [String] = []) { self.items = items } }
        final class Pairs { var items: [(String, String?)] = []; init(_ items: [(String, String?)] = []) { self.items = items } }

        var id: String?
        var classes: Strings?
        var properties: Pairs?

        func addClass(_ name: String) {
            let list = classes ?? Strings()
            classes = list
            if !list.items.contains(name) { list.items.append(name) }
        }

        func addProperty(_ name: String, _ value: String?) {
            let list = properties ?? Pairs()
            properties = list
            list.items.append((name, value))
        }

        func addPropertyIfNotExist(_ name: String, _ value: String?) {
            if let list = properties {
                if list.items.contains(where: { $0.0 == name }) { return }
                list.items.append((name, value))
            } else {
                properties = Pairs([(name, value)])
            }
        }

        func copyTo(_ target: HtmlAttributes, mergeIdAndProperties: Bool = false, shared: Bool = true) {
            if !mergeIdAndProperties || id != nil { target.id = id }
            if target.classes == nil {
                target.classes = shared ? classes : classes.map { Strings($0.items) }
            } else if let classes {
                target.classes!.items += classes.items
            }
            if target.properties == nil {
                target.properties = shared ? properties : properties.map { Pairs($0.items) }
            } else if let properties {
                if mergeIdAndProperties {
                    for (key, value) in properties.items { target.addPropertyIfNotExist(key, value) }
                } else {
                    target.properties!.items += properties.items
                }
            }
        }
    }

    // MARK: Blocks

    class Block: MarkdownObject {
        weak var parent: ContainerBlock?
        let parser: BlockParser?
        var isOpen = true
        var isBreakable = true
        var newLine = NewLine.none
        var removeAfterProcessInlines = false
        /// Called once before / after the inlines of this block are processed (Markdig's events).
        var processInlinesBegin: [(InlineProcessor, Inline?) -> Void] = []
        var processInlinesEnd: [(InlineProcessor, Inline?) -> Void] = []

        init(_ parser: BlockParser?) {
            self.parser = parser
        }

        var isLeafBlock: Bool { self is LeafBlock }
        var isContainerBlock: Bool { self is ContainerBlock }
        var isParagraphBlock: Bool { self is ParagraphBlock }

        func onProcessInlinesBegin(_ processor: InlineProcessor) {
            let callbacks = processInlinesBegin
            processInlinesBegin = []
            for callback in callbacks { callback(processor, nil) }
        }

        func onProcessInlinesEnd(_ processor: InlineProcessor) {
            let callbacks = processInlinesEnd
            processInlinesEnd = []
            for callback in callbacks { callback(processor, nil) }
        }

        func updateSpanToInclude(_ include: SourceSpan) {
            if include.isEmpty { return }
            var current: Block? = self
            var depth = 0
            var root: Block = self
            while let block = current {
                if block.span.isEmpty {
                    block.span = include
                } else {
                    if include.start < block.span.start { block.span.start = include.start }
                    if include.end > block.span.end { block.span.end = include.end }
                }
                root = block
                current = block.parent
                depth += 1
            }
            Markdown.checkDepthLimit(depth, Markdown.largeDepthLimit, root)
        }

        func updateSpanEnd(_ end: Int) {
            var current: Block? = self
            var depth = 0
            var root: Block = self
            while let block = current {
                if end > block.span.end { block.span.end = end }
                root = block
                current = block.parent
                depth += 1
            }
            Markdown.checkDepthLimit(depth, Markdown.largeDepthLimit, root)
        }

        func remove() { _ = parent?.remove(self) }

        /// Replaces this block in its parent; container children move to the replacement.
        func replaceBy(_ replacement: Block, moveChildren: Bool = true) {
            guard let parent, let index = parent.indexOf(self) else { return }
            parent[index] = replacement
            if moveChildren, let source = self as? ContainerBlock, let destination = replacement as? ContainerBlock {
                source.transferChildrenTo(destination)
            }
        }
    }

    class ContainerBlock: Block {
        private(set) var children: [Block] = []

        var count: Int { children.count }
        var lastChild: Block? { children.last }
        subscript(index: Int) -> Block {
            get { children[index] }
            set {
                children[index].parent = nil
                newValue.parent = self
                children[index] = newValue
            }
        }

        func add(_ block: Block) {
            precondition(block.parent == nil, "Cannot add this block as it as already attached to another container")
            children.append(block)
            block.parent = self
            updateSpanEnd(block.span.end)
        }

        func insert(_ block: Block, at index: Int) {
            precondition(block.parent == nil, "Cannot add this block as it as already attached to another container")
            children.insert(block, at: index)
            block.parent = self
        }

        func indexOf(_ block: Block) -> Int? { children.firstIndex { $0 === block } }
        func contains(_ block: Block) -> Bool { indexOf(block) != nil }

        @discardableResult
        func remove(_ block: Block) -> Bool {
            guard let index = indexOf(block) else { return false }
            removeAt(index)
            return true
        }

        func removeAt(_ index: Int) {
            children[index].parent = nil
            children.remove(at: index)
        }

        func clear() {
            for child in children { child.parent = nil }
            children.removeAll()
        }

        func transferChildrenTo(_ destination: ContainerBlock) {
            if destination === self { return }
            let moving = children
            for child in moving { child.parent = nil }
            children.removeAll()
            for child in moving { destination.add(child) }
        }
    }

    class LeafBlock: Block {
        var lines = LineGroup(capacity: 0)
        var processInlines = false
        private var inlineStorage: ContainerInline?

        var inline: ContainerInline? {
            get { inlineStorage }
            set {
                newValue?.parentBlock = self
                inlineStorage?.parentBlock = nil
                inlineStorage = newValue
            }
        }

        /// Adds a line; a tab that only partly belongs to this block becomes the remaining spaces.
        func appendLine(_ slice: Slice, column: Int, line: Int, sourceLinePosition: Int) {
            if lines.capacity == 0 { lines.capacity = processInlines ? 8 : 4 }
            var stringLine = Line(slice, line: line, column: column, position: sourceLinePosition, newLine: slice.newLine)
            if slice.currentChar == "\t" && Markdown.isAcrossTab(column) {
                var builder = [Char](repeating: " ", count: Markdown.addTab(column) - column)
                var rest = slice
                rest.start += 1
                builder += rest.chars
                stringLine.slice = Slice(builder)
            }
            lines.add(stringLine)
            newLine = slice.newLine
        }
    }

    final class MarkdownDocument: ContainerBlock {
        var lineCount = 0
        /// Set when nesting went past Markdig's limits, where Markdig throws; the API reports `DepthLimitError`.
        var depthLimitExceeded = false
        init() { super.init(nil) }
    }

    /// Markdig's limit on nested containers (`ThrowHelper.DefaultDepthLimit`) and the large one for spans and inlines.
    static let defaultDepthLimit = 128
    static let largeDepthLimit = 10 * 1024

    /// Markdig's `ArgumentException` for too deeply nested input.
    struct DepthLimitError: LocalizedError {
        var errorDescription: String? {
            "Markdown elements in the input are too deeply nested - depth limit exceeded. Input is most likely not sensible or is a very large table."
        }
    }

    /// `ThrowHelper.CheckDepthLimit`: marks the document whose block is `root` instead of throwing mid-parse.
    static func checkDepthLimit(_ depth: Int, _ limit: Int, _ root: Block?) {
        if depth > limit, let document = root as? MarkdownDocument { document.depthLimitExceeded = true }
    }

    final class BlankLineBlock: Block {
        init() {
            super.init(nil)
            isOpen = false
        }
    }

    class ParagraphBlock: LeafBlock {
        override init(_ parser: BlockParser?) {
            super.init(parser)
            processInlines = true
        }
    }

    class HeadingBlock: LeafBlock {
        var headerChar = Char.zero
        var level = 0
        var isSetext = false
        var headerCharCount = 0

        override init(_ parser: BlockParser?) {
            super.init(parser)
            processInlines = true
        }
    }

    class ThematicBreakBlock: LeafBlock {
        var thematicChar = Char.zero
        var thematicCharCount = 0
        var content = Slice.empty
    }

    class CodeBlock: LeafBlock {}

    /// A fenced block: code, or an extension's fenced container (`IFencedBlock`).
    protocol FencedBlock: Block {
        var fencedChar: Char { get set }
        var openingFencedCharCount: Int { get set }
        var closingFencedCharCount: Int { get set }
        var info: String? { get set }
        var arguments: String? { get set }
    }

    class FencedCodeBlock: CodeBlock, FencedBlock {
        var indentCount = 0
        var fencedChar = Char.zero
        var openingFencedCharCount = 0
        var closingFencedCharCount = 0
        var info: String?
        var arguments: String?

        override init(_ parser: BlockParser?) {
            super.init(parser)
            isBreakable = false
        }
    }

    enum HtmlBlockType { case documentType, cData, comment, processingInstruction, scriptPreOrStyle, interruptingBlock, nonInterruptingBlock }

    final class HtmlBlock: LeafBlock {
        var type = HtmlBlockType.documentType
    }

    class QuoteBlock: ContainerBlock {
        var quoteChar = Char.zero
    }

    final class ListBlock: ContainerBlock {
        var isOrdered = false
        var bulletType = Char.zero
        var orderedStart: String?
        var defaultOrderedStart: String?
        var orderedDelimiter = Char.zero
        var isLoose = false
        var countAllBlankLines = 0
        var countBlankLinesReset = 0
    }

    final class ListItemBlock: ContainerBlock {
        var columnWidth = 0
        var order = 0
    }

    /// A link reference definition `[label]: url "title"`.
    class LinkReferenceDefinition: LeafBlock {
        var label: String?
        var url: String?
        var title: String?
        var labelSpan = SourceSpan.empty
        var urlSpan = SourceSpan.empty
        var titleSpan = SourceSpan.empty
        /// Creates the inline for a reference to this definition (footnotes, abbreviations).
        var createLinkInline: ((InlineProcessor, LinkReferenceDefinition, Inline?) -> Inline)?
        var allowResolutionInsideOpenLink = true

        init(_ label: String?, _ url: String?, _ title: String?) {
            self.label = label
            self.url = url
            self.title = title
            super.init(nil)
            isOpen = false
        }
    }

    /// The document's link reference definitions; labels match ignoring case and diacritics (Markdig compares with
    /// the invariant culture, IgnoreCase | IgnoreNonSpace).
    final class LinkReferenceDefinitionGroup: ContainerBlock {
        private var links: [(String, LinkReferenceDefinition)] = []
        /// An ASCII label equals exactly the ASCII labels with its lower-case form, so those are found by it and only
        /// the other labels are compared one by one (thousands of footnotes made reading quadratic).
        private var asciiLabels: [String: Int] = [:]
        private var otherLabels: [Int] = []

        init() { super.init(nil) }

        static func sameLabel(_ a: String, _ b: String) -> Bool {
            a == b || a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }

        func set(_ label: String, _ link: LinkReferenceDefinition) {
            if !contains(link) {
                add(link)
                guard index(of: label) == nil else { return }
                if Self.isAscii(label) { asciiLabels[label.lowercased()] = links.count } else { otherLabels.append(links.count) }
                links.append((label, link))
            }
        }

        func tryGet(_ label: String) -> LinkReferenceDefinition? { index(of: label).map { links[$0].1 } }

        func containsKey(_ label: String) -> Bool { index(of: label) != nil }

        /// The first label added that equals `label`.
        private func index(of label: String) -> Int? {
            guard Self.isAscii(label) else { return links.indices.first { Self.sameLabel(links[$0].0, label) } }
            let ascii = asciiLabels[label.lowercased()]
            let other = otherLabels.first { Self.sameLabel(links[$0].0, label) }
            if let ascii, let other { return min(ascii, other) }
            return ascii ?? other
        }

        private static func isAscii(_ label: String) -> Bool { label.utf8.allSatisfy { $0 < 0x80 } }
    }

    // MARK: Inlines

    class Inline: MarkdownObject {
        weak var parent: ContainerInline?
        weak var previousSibling: Inline?
        var nextSibling: Inline?

        var isClosed: Bool {
            get { closedFlag }
            set { closedFlag = newValue }
        }

        var isContainerInline: Bool { self is ContainerInline }

        /// Inserts `next` right after this inline (Markdig's linking, including its parent bookkeeping).
        func insertAfter(_ next: Inline) {
            precondition(next.parent == nil, "Inline has already a parent")
            let previousNext = nextSibling
            previousNext?.previousSibling = next
            next.previousSibling = self
            next.nextSibling = previousNext
            nextSibling = next
            if let parent {
                parent.onChildInsert(next)
                next.parent = parent
            }
        }

        /// Inserts `previous` right before this inline. Like Markdig, the inserted inline's previous sibling is not
        /// linked back.
        func insertBefore(_ previous: Inline) {
            precondition(previous.parent == nil, "Inline has already a parent")
            previousSibling?.nextSibling = previous
            previousSibling = previous
            previous.nextSibling = self
            if let parent {
                parent.onChildInsert(previous)
                previous.parent = parent
            }
        }

        func remove() {
            previousSibling?.nextSibling = nextSibling
            nextSibling?.previousSibling = previousSibling
            if let parent {
                parent.onChildRemove(self)
                previousSibling = nil
                nextSibling = nil
                self.parent = nil
            }
        }

        /// Replaces this inline by `inline`; children move into it (or after it when it is a leaf). Returns the last
        /// inline placed.
        @discardableResult
        func replaceBy(_ inline: Inline, copyChildren: Bool = true) -> Inline {
            let parent = self.parent
            let previous = previousSibling
            let next = nextSibling
            remove()
            if let previous {
                previous.insertAfter(inline)
            } else if let next {
                next.insertBefore(inline)
            } else if let parent {
                parent.appendChild(inline)
            }
            if copyChildren, let container = self as? ContainerInline {
                let newContainer = (inline as? ContainerInline).flatMap { $0.isClosed ? nil : $0 }
                var child = container.firstChild
                var lastChild = inline
                while let current = child {
                    let nextChild = current.nextSibling
                    current.remove()
                    if let newContainer { newContainer.appendChild(current) } else { lastChild.insertAfter(current) }
                    lastChild = current
                    child = nextChild
                }
                return lastChild
            }
            return inline
        }

        func containsParentOfType<T: Inline>(_ type: T.Type) -> Bool {
            var inline: Inline? = self
            while let current = inline {
                if current is T { return true }
                inline = current.parent
            }
            return false
        }

        func containsParentOrSiblingOfType<T: Inline>(_ type: T.Type) -> Bool {
            if containsParentOfType(type) { return true }
            var root = parent
            while let parentOfRoot = root?.parent { root = parentOfRoot }
            var sibling = root?.firstChild
            while let current = sibling {
                if current is T { return true }
                sibling = current.nextSibling
            }
            return false
        }

        func firstParentOfType<T: Inline>(_ type: T.Type) -> T? {
            var inline: Inline? = self
            while let current = inline {
                if let found = current as? T { return found }
                inline = current.parent
            }
            return nil
        }

        func findBestParent() -> Inline {
            var current: Inline = self
            while current.parent != nil || current.previousSibling != nil {
                if let parent = current.parent { current = parent; continue }
                current = current.previousSibling!
            }
            return current
        }
    }

    class ContainerInline: Inline {
        weak var parentBlock: LeafBlock?
        private(set) var firstChild: Inline?
        private(set) var lastChild: Inline?

        func clear() {
            var child = lastChild
            while let current = child {
                current.parent = nil
                child = current.previousSibling
            }
            firstChild = nil
            lastChild = nil
        }

        @discardableResult
        func appendChild(_ child: Inline) -> ContainerInline {
            precondition(child.parent == nil, "Inline has already a parent")
            if firstChild == nil {
                firstChild = child
                lastChild = child
                child.parent = self
            } else {
                lastChild!.insertAfter(child)
            }
            return self
        }

        func containsChild(_ find: Inline) -> Bool {
            var child = firstChild
            while let current = child {
                if current === find { return true }
                child = current.nextSibling
            }
            return false
        }

        /// Descendants of type `T`, depth first (walks `lastChild` / `previousSibling` like Markdig).
        func findDescendants<T: Inline>(_ type: T.Type) -> [T] {
            var result: [T] = []
            var stack: [Inline] = []
            var child = lastChild
            while let current = child { stack.append(current); child = current.previousSibling }
            while let current = stack.popLast() {
                if let found = current as? T { result.append(found) }
                if let container = current as? ContainerInline {
                    var inner = container.lastChild
                    while let item = inner { stack.append(item); inner = item.previousSibling }
                }
            }
            return result
        }

        func transferChildrenTo(_ destination: ContainerInline) {
            if destination === self { return }
            var child = firstChild
            while let current = child {
                let next = current.nextSibling
                current.remove()
                destination.appendChild(current)
                child = next
            }
        }

        func moveChildrenAfter(_ parent: Inline) {
            var child = firstChild
            var nextSibling = parent
            while let current = child {
                let next = current.nextSibling
                current.remove()
                nextSibling.insertAfter(current)
                nextSibling = current
                child = next
            }
        }

        func embraceChildrenBy(_ container: ContainerInline) {
            var child = firstChild
            while let current = child {
                let next = current.nextSibling
                current.remove()
                container.appendChild(current)
                child = next
            }
            appendChild(container)
        }

        func onChildInsert(_ child: Inline) {
            if child.previousSibling == nil && child.nextSibling === firstChild {
                firstChild = child
            } else if child.nextSibling == nil && child.previousSibling === lastChild {
                lastChild = child
            }
            if lastChild == nil { lastChild = firstChild } else if firstChild == nil { firstChild = lastChild }
        }

        func onChildRemove(_ child: Inline) {
            if child === firstChild {
                if firstChild === lastChild {
                    firstChild = nil
                    lastChild = nil
                } else {
                    firstChild = child.nextSibling ?? lastChild
                }
            } else if child === lastChild {
                lastChild = child.previousSibling ?? firstChild
            }
        }

        /// The children (from `firstChild` along `nextSibling`).
        var children: [Inline] {
            var result: [Inline] = []
            var child = firstChild
            while let current = child { result.append(current); child = current.nextSibling }
            return result
        }
    }

    class LeafInline: Inline {}

    final class LiteralInline: LeafInline, CustomStringConvertible {
        var content: Slice

        override init() { content = .empty }
        init(_ content: Slice) { self.content = content }
        init(_ text: String) { content = Slice(text) }

        var isFirstCharacterEscaped: Bool {
            get { spareFlag }
            set { spareFlag = newValue }
        }

        var description: String { content.description }
    }

    final class CodeInline: LeafInline {
        var content: String
        var delimiter = Char.zero
        var delimiterCount = 0
        init(_ content: String) { self.content = content }
    }

    final class AutolinkInline: LeafInline {
        var url: String
        var isEmail = false
        init(_ url: String) { self.url = url }
    }

    final class HtmlInline: LeafInline {
        var tag: String
        init(_ tag: String) { self.tag = tag }
    }

    final class HtmlEntityInline: LeafInline {
        var original = Slice.empty
        var transcoded = Slice.empty
    }

    final class LineBreakInline: LeafInline {
        var isHard = false
        var isBackslash = false
        var newLine = NewLine.none
    }

    class EmphasisInline: ContainerInline {
        var delimiterChar = Char.zero
        var delimiterCount = 0
    }

    struct DelimiterType: OptionSet {
        let rawValue: UInt8
        static let open = DelimiterType(rawValue: 1)
        static let close = DelimiterType(rawValue: 2)
    }

    class DelimiterInline: ContainerInline {
        let parser: InlineParser
        var type = DelimiterType()
        var isActive = true

        init(_ parser: InlineParser) { self.parser = parser }

        func toLiteral() -> String { "" }

        func replaceByLiteral() {
            let literal = LiteralInline(Slice(toLiteral()))
            literal.span = span
            literal.line = line
            literal.column = column
            literal.isClosed = true
            replaceBy(literal)
        }
    }

    final class EmphasisDelimiterInline: DelimiterInline {
        let descriptor: EmphasisDescriptor
        let delimiterChar: Char
        var delimiterCount = 0
        var content: Slice

        init(_ parser: InlineParser, _ descriptor: EmphasisDescriptor, _ content: Slice) {
            self.descriptor = descriptor
            delimiterChar = descriptor.character
            self.content = content
            super.init(parser)
        }

        override func toLiteral() -> String {
            String(repeating: delimiterChar.description, count: max(0, delimiterCount))
        }

        func asLiteralInline() -> LiteralInline {
            let literal = LiteralInline(content)
            literal.isClosed = true
            literal.span = span
            literal.line = line
            literal.column = column
            return literal
        }
    }

    final class LinkDelimiterInline: DelimiterInline {
        var isImage = false
        var label: String?
        var labelSpan = SourceSpan.empty

        override func toLiteral() -> String { isImage ? "![" : "[" }
    }

    final class LinkInline: ContainerInline {
        var isImage = false
        var label: String?
        var labelSpan = SourceSpan.empty
        var reference: LinkReferenceDefinition?
        var url: String?
        var urlSpan = SourceSpan.empty
        var getDynamicUrl: (() -> String?)?
        var title: String?
        var titleSpan = SourceSpan.empty
        var isShortcut = false
        var isAutoLink = false

        override init() {}
        init(_ url: String?, _ title: String?) {
            self.url = url
            self.title = title
        }
    }

    /// An emphasis character the emphasis parser handles (`EmphasisDescriptor`).
    final class EmphasisDescriptor {
        let character: Char
        let minimumCount: Int
        let maximumCount: Int
        let enableWithinWord: Bool

        init(_ character: Char, _ minimumCount: Int, _ maximumCount: Int, _ enableWithinWord: Bool) {
            self.character = character
            self.minimumCount = minimumCount
            self.maximumCount = maximumCount
            self.enableWithinWord = enableWithinWord
        }
    }
}

extension Markdown.MarkdownObject {
    /// Every descendant (blocks and inlines) in document order (`Descendants()`).
    func descendants() -> [Markdown.MarkdownObject] {
        var result: [Markdown.MarkdownObject] = []
        var stack: [(Markdown.MarkdownObject, Bool)] = [(self, false)]
        while let (object, emit) = stack.popLast() {
            if emit { result.append(object) }
            if let container = object as? Markdown.ContainerBlock {
                var index = container.count
                while index > 0 {
                    index -= 1
                    let child = container[index]
                    if let leaf = child as? Markdown.LeafBlock, let inline = leaf.inline { stack.append((inline, false)) }
                    stack.append((child, true))
                }
            } else if let container = object as? Markdown.ContainerInline {
                var child = container.lastChild
                while let current = child {
                    stack.append((current, true))
                    child = current.previousSibling
                }
            }
        }
        return result
    }

    /// Descendants of a block type, without entering leaf blocks (`Descendants<T>()` for blocks).
    func blockDescendants<T: Markdown.Block>(_ type: T.Type) -> [T] {
        guard let root = self as? Markdown.ContainerBlock else { return [] }
        var result: [T] = []
        var stack: [Markdown.Block] = root.children.reversed()
        while let block = stack.popLast() {
            if let found = block as? T { result.append(found) }
            if let container = block as? Markdown.ContainerBlock { stack += container.children.reversed() }
        }
        return result
    }

    /// Descendants of an inline type (`Descendants<T>()` for inlines).
    func inlineDescendants<T: Markdown.Inline>(_ type: T.Type) -> [T] {
        if self is Markdown.ContainerBlock { return descendants().compactMap { $0 as? T } }
        if let container = self as? Markdown.ContainerInline { return container.findDescendants(type) }
        return []
    }
}
