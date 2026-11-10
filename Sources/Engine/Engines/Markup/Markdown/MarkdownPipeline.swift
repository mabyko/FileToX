// Entry points of the Markdown library (parse, HTML, plain text) and the parser pipelines Filee uses: Markdig's
// `UseAdvancedExtensions()` with and without `UseYamlFrontMatter()`, plus plain CommonMark.

import Foundation

extension Markdown {
    /// A configured set of parsers and renderer extensions (`MarkdownPipeline`). Immutable once built.
    final class Pipeline {
        let blockParsers: BlockParserList
        let inlineParsers: InlineParserList
        let maximumNestingDepth = Markdown.defaultDepthLimit
        fileprivate let documentProcessed: [(MarkdownDocument) -> Void]
        fileprivate let rendererSetups: [(HtmlRenderer) -> Void]

        init(_ builder: PipelineBuilder) {
            for extensionSetup in builder.extensions { extensionSetup.setupPipeline(builder) }
            blockParsers = BlockParserList(builder.blockParsers)
            inlineParsers = InlineParserList(builder.inlineParsers)
            documentProcessed = builder.documentProcessed
            rendererSetups = builder.extensions.map { extensionSetup in { extensionSetup.setupRenderer($0) } }
        }

        /// Markdig's default pipeline: CommonMark without extensions.
        static let commonMark = Pipeline(PipelineBuilder())

        /// `UseAdvancedExtensions()` (Filee's Unhwp HTML output).
        static let advanced = Pipeline(PipelineBuilder().useAdvancedExtensions())

        /// `UseAdvancedExtensions().UseYamlFrontMatter()` (Filee's `MarkdownReader.Pipeline`).
        static let advancedWithYaml = Pipeline(PipelineBuilder().useAdvancedExtensions().useYamlFrontMatter())

        func setup(_ renderer: HtmlRenderer) {
            renderer.maximumNestingDepth = maximumNestingDepth
            for setup in rendererSetups { setup(renderer) }
        }
    }

    /// An extension adds parsers to the pipeline and renderers to the HTML renderer (`IMarkdownExtension`).
    protocol PipelineExtension: AnyObject {
        func setupPipeline(_ builder: PipelineBuilder)
        func setupRenderer(_ renderer: HtmlRenderer)
    }

    /// Collects parsers and extensions before building a pipeline (`MarkdownPipelineBuilder`).
    final class PipelineBuilder {
        var blockParsers: [BlockParser] = [
            ThematicBreakParser(), HeadingBlockParser(), QuoteBlockParser(), ListBlockParser(), HtmlBlockParser(),
            FencedCodeBlockParser(), IndentedCodeBlockParser(), ParagraphBlockParser(),
        ]
        var inlineParsers: [InlineParser] = [
            HtmlEntityParser(), LinkInlineParser(), EscapeInlineParser(), EmphasisInlineParser(), CodeInlineParser(),
            AutolinkInlineParser(), LineBreakInlineParser(),
        ]
        var extensions: [PipelineExtension] = []
        var documentProcessed: [(MarkdownDocument) -> Void] = []

        init() {}

        func block<T: BlockParser>(_ type: T.Type) -> T? { blockParsers.lazy.compactMap { $0 as? T }.first }
        func inline<T: InlineParser>(_ type: T.Type) -> T? { inlineParsers.lazy.compactMap { $0 as? T }.first }

        /// Inserts `parser` before the first parser of `type` (`OrderedList.InsertBefore`); false when absent.
        @discardableResult
        func insertBlock<T: BlockParser>(_ parser: BlockParser, before type: T.Type) -> Bool {
            guard let index = blockParsers.firstIndex(where: { $0 is T }) else { return false }
            blockParsers.insert(parser, at: index)
            return true
        }

        @discardableResult
        func insertInline<T: InlineParser>(_ parser: InlineParser, before type: T.Type) -> Bool {
            guard let index = inlineParsers.firstIndex(where: { $0 is T }) else { return false }
            inlineParsers.insert(parser, at: index)
            return true
        }

        @discardableResult
        func insertInline<T: InlineParser>(_ parser: InlineParser, after type: T.Type) -> Bool {
            guard let index = inlineParsers.firstIndex(where: { $0 is T }) else { return false }
            inlineParsers.insert(parser, at: index + 1)
            return true
        }

        func addExtensionIfNotAlready<T: PipelineExtension>(_ make: @autoclosure () -> T) {
            if !extensions.contains(where: { $0 is T }) { extensions.append(make()) }
        }

        func replaceOrAddExtension<T: PipelineExtension>(_ value: T) {
            if let index = extensions.firstIndex(where: { $0 is T }) { extensions[index] = value } else { extensions.append(value) }
        }
    }

    // MARK: Entry points

    /// Parses Markdown into a syntax tree (`Markdown.Parse`). Throws only for absurdly nested input, like Markdig.
    static func parse(_ markdown: String, _ pipeline: Pipeline) throws -> MarkdownDocument {
        let text = markdown.utf16.map { $0 == 0 ? Char.replacement : Char($0) }
        let document = MarkdownDocument()
        document.isOpen = true
        let blockProcessor = BlockProcessor(document, pipeline.blockParsers, maximumNestingDepth: pipeline.maximumNestingDepth)
        blockProcessor.open(document)
        var reader = LineReader(text)
        while let line = reader.readLine() { blockProcessor.processLine(line) }
        blockProcessor.closeAll(true)
        document.lineCount = blockProcessor.lineIndex
        if !document.depthLimitExceeded {
            processInlines(InlineProcessor(document, pipeline.inlineParsers), document, pipeline.maximumNestingDepth)
        }
        if document.depthLimitExceeded { throw DepthLimitError() }
        for processed in pipeline.documentProcessed { processed(document) }
        if document.depthLimitExceeded { throw DepthLimitError() }
        return document
    }

    /// Markdown as an HTML fragment (`Markdown.ToHtml`).
    static func toHtml(_ markdown: String, _ pipeline: Pipeline) throws -> String {
        try render(parse(markdown, pipeline), pipeline)
    }

    /// The HTML of a parsed document.
    static func render(_ document: MarkdownDocument, _ pipeline: Pipeline) throws -> String {
        let renderer = HtmlRenderer()
        pipeline.setup(renderer)
        renderer.write(document)
        if renderer.depthLimitExceeded { throw DepthLimitError() }
        return renderer.text
    }

    /// Markdown as plain text: the HTML renderer without tags and escapes (`Markdown.ToPlainText`).
    static func toPlainText(_ markdown: String, _ pipeline: Pipeline) throws -> String {
        let document = try parse(markdown, pipeline)
        let renderer = HtmlRenderer()
        renderer.enableHtmlForBlock = false
        renderer.enableHtmlForInline = false
        renderer.enableHtmlEscape = false
        pipeline.setup(renderer)
        renderer.write(document)
        if renderer.depthLimitExceeded { throw DepthLimitError() }
        return renderer.text
    }

    /// Parses the inlines of every leaf block, without recursion (`MarkdownParser.ProcessInlines`).
    private static func processInlines(_ processor: InlineProcessor, _ document: MarkdownDocument, _ maximumNestingDepth: Int) {
        final class Item {
            var container: ContainerBlock
            var index = 0
            init(_ container: ContainerBlock) { self.container = container }
        }
        var items = [Item(document)]
        document.onProcessInlinesBegin(processor)
        while let item = items.last {
            var descended = false
            while item.index < item.container.count {
                let block = item.container[item.index]
                if let leaf = block as? LeafBlock {
                    leaf.onProcessInlinesBegin(processor)
                    if leaf.processInlines {
                        processor.processInlineLeaf(leaf)
                        if document.depthLimitExceeded { return }
                        if let previous = processor.previousContainerToReplace, let replacement = processor.newContainerToReplace {
                            if item.container === previous {
                                item.container = replacement
                            } else if let parent = items.dropLast().last(where: { $0.container === previous }) {
                                parent.container = replacement
                            }
                            processor.previousContainerToReplace = nil
                            processor.newContainerToReplace = nil
                        }
                        if leaf.removeAfterProcessInlines {
                            item.container.removeAt(item.index)
                            item.index -= 1
                        } else if let replacement = processor.blockNew {
                            item.container[item.index] = replacement
                        }
                    }
                    leaf.onProcessInlinesEnd(processor)
                } else if let child = block as? ContainerBlock {
                    if block.removeAfterProcessInlines { item.container.removeAt(item.index) } else { item.index += 1 }
                    if items.count >= maximumNestingDepth {
                        document.depthLimitExceeded = true
                        return
                    }
                    items.append(Item(child))
                    block.onProcessInlinesBegin(processor)
                    descended = true
                    break
                }
                item.index += 1
            }
            if descended { continue }
            item.container.onProcessInlinesEnd(processor)
            items.removeLast()
        }
    }

    // MARK: Punycode

    /// IDNA ToASCII for link hosts (what .NET's `IdnMapping.GetAscii` does for Markdig): lower-case, NFKC, then
    /// each non-ASCII label as "xn--" punycode. Nil for an invalid name.
    enum Punycode {
        static func idnToAscii(_ domain: String) -> String? {
            let mapped = domain.lowercased().precomposedStringWithCompatibilityMapping
            if mapped.isEmpty { return nil }
            var labels: [String] = []
            let parts = mapped.split(separator: ".", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                if part.isEmpty {
                    if i == parts.count - 1 && i > 0 { labels.append(""); continue }
                    return nil
                }
                if part.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F || $0.properties.generalCategory == .control }) { return nil }
                if part.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    labels.append(String(part))
                } else {
                    guard let encoded = encode(Array(part.unicodeScalars)) else { return nil }
                    labels.append("xn--" + encoded)
                }
                if labels.last!.utf8.count > 63 { return nil }
            }
            return labels.joined(separator: ".")
        }

        /// RFC 3492 encoding of one label.
        static func encode(_ input: [Unicode.Scalar]) -> String? {
            let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
            var n = 128, delta = 0, bias = 72
            var output = String(String.UnicodeScalarView(input.filter(\.isASCII)))
            let basicCount = output.unicodeScalars.count
            var handled = basicCount
            if basicCount > 0 { output += "-" }
            func digit(_ d: Int) -> Character { Character(Unicode.Scalar(UInt8(d < 26 ? d + 97 : d + 22))) }
            func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
                var delta = first ? delta / damp : delta / 2
                delta += delta / count
                var k = 0
                while delta > ((base - tMin) * tMax) / 2 {
                    delta /= base - tMin
                    k += base
                }
                return k + (base - tMin + 1) * delta / (delta + skew)
            }
            while handled < input.count {
                guard let m = input.map({ Int($0.value) }).filter({ $0 >= n }).min() else { return nil }
                let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
                if overflow { return nil }
                delta += product
                n = m
                for scalar in input {
                    let c = Int(scalar.value)
                    if c < n { delta += 1 }
                    if c == n {
                        var q = delta
                        var k = base
                        while true {
                            let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                            if q < t { break }
                            output.append(digit(t + (q - t) % (base - t)))
                            q = (q - t) / (base - t)
                            k += base
                        }
                        output.append(digit(q))
                        bias = adapt(delta, handled + 1, handled == basicCount)
                        delta = 0
                        handled += 1
                    }
                }
                delta += 1
                n += 1
            }
            return output
        }
    }
}
