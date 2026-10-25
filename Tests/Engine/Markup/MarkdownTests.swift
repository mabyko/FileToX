// Port of Filee's MarkdownTests: Markdown without optional engines (the built-in parser), the progress estimate of
// silent engines, and routes. The LibreOffice warm-up fact belongs to the LibreOffice engine's tests.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class MarkdownTests: XCTestCase {
    private static let sample = """
        ---
        title: 회의록
        ---

        # 주간 회의

        오늘 결정한 것: **배포**, *문서 정리*, `v1.0.1`.

        | 항목 | 담당 |
        |------|------|
        | 설치 | 민지 |

        ![그림](chart.png)

        - [x] 끝낸 일
        - [ ] 남은 일
        """

    /// Only engines that ship with the app (or run in-process): no Pandoc or LibreOffice.
    private static let optionalEngines = ["pandoc", "libreoffice"]

    private func builtInPlanner(_ assumeInstalled: [String] = []) -> RoutePlanner {
        ConverterCatalog(MarkupTestSupport.converters(excluding: Self.optionalEngines)).createPlanner(assumeInstalled)
    }

    private func writeSample(_ folder: String) throws -> String {
        try MarkupTestSupport.png(160, 90).write(to: URL(fileURLWithPath: FilePath.combine(folder, "chart.png")))
        let md = FilePath.combine(folder, "회의록.md")
        try Data(Self.sample.utf8).write(to: URL(fileURLWithPath: md))
        return md
    }

    func testMarkdownRoutesNeedNoOptionalEngine() throws {
        let planner = builtInPlanner()
        XCTAssertEqual(planner.plan("md", "html")?.steps.map(\.converter.id), ["markdown"])
        XCTAssertEqual(planner.plan("md", "txt")?.steps.map(\.converter.id), ["markdown"])
        XCTAssertEqual(planner.plan("md", "hwpx")?.steps.map(\.converter.id), ["hwpx-writer"])
        // PDF: the built-in HWPX writer, then rhwp (bundled with the installer).
        XCTAssertEqual(builtInPlanner(["rhwp"]).plan("md", "pdf")?.steps.map(\.converter.id), ["hwpx-writer", "rhwp"])
    }

    func testBuiltInMarkdownWinsOverPandocForHtmlAndText() {
        let planner = ConverterCatalog(MarkupTestSupport.converters()).createPlanner(["pandoc"])
        XCTAssertEqual(planner.plan("md", "html")?.steps.map(\.converter.id), ["markdown"])
        XCTAssertEqual(planner.plan("md", "txt")?.steps.map(\.converter.id), ["markdown"])
    }

    func testMarkdownToHtmlAndText() async throws {
        let folder = try MarkupTestSupport.newFolder()
        let md = try writeSample(folder)

        let html = try String(contentsOfFile: try await MarkupTestSupport.convert(md, "html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<strong>배포</strong>"))
        XCTAssertTrue(html.contains("src=\"chart.png\"")) // next to the Markdown file the relative path still works
        XCTAssertFalse(html.contains("title: 회의록"))

        let text = try String(contentsOfFile: try await MarkupTestSupport.convert(md, "txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("주간 회의"))
        XCTAssertTrue(text.contains("배포"))
        XCTAssertFalse(text.contains("**"))
    }

    func testHtmlWrittenElsewherePointsImagesAtTheOriginalFiles() throws {
        let folder = try MarkupTestSupport.newFolder()
        let md = try writeSample(folder)

        let html = try MarkdownConverter.toHtml(Self.sample, md, FilePath.combine(try MarkupTestSupport.newFolder(), "step.html"))

        XCTAssertTrue(html.contains("src=\"\(MarkupConvert.fileUri(FilePath.combine(folder, "chart.png")))\""))
    }

    func testImageUrisAreEscapedLikeDotNet() {
        // Expected values: `new Uri(path).AbsoluteUri` on .NET 10.
        let cases = [
            ("/tmp/로고 1.png", "file:///tmp/%EB%A1%9C%EA%B3%A0%201.png"),
            ("/tmp/\u{1105}\u{1169}.png", "file:///tmp/%E1%84%85%E1%85%A9.png"), // no normalization either way
            ("/tmp/x~y #1?.png", "file:///tmp/x~y%20%231%3F.png"),
            ("/tmp/[a]{b}|c^d`e\"f<g>h\\i.png", "file:///tmp/[a]%7Bb%7D%7Cc%5Ed%60e%22f%3Cg%3Eh%5Ci.png"),
            ("/tmp/!$&'()*+,;=:@.png", "file:///tmp/!$&'()*+,;=:@.png"),
            ("/tmp/é😀\u{A0}\ttab.png", "file:///tmp/%C3%A9%F0%9F%98%80%C2%A0%09tab.png"),
            ("/tmp/a b/c%20d.png", "file:///tmp/a%20b/c%2520d.png"),
            ("/tmp/100%.png", "file:///tmp/100%25.png"),
        ]
        for (path, uri) in cases { XCTAssertEqual(MarkupConvert.fileUri(path), uri) }
    }

    func testHeadingReferenceIndexPreservesOrderAndUnicodeEquality() throws {
        let markdown = "# café\n\n# cafe\u{301}\n\n# CAFE\n\n[café] [CAFE]\n"
        let html = try Markdown.toHtml(markdown, .advancedWithYaml)
        XCTAssertTrue(html.contains("<a href=\"#cafe-1\">café</a> <a href=\"#cafe-1\">CAFE</a>"), html)
        XCTAssertEqual(Array(try Markdown.toPlainText(markdown, .advancedWithYaml).utf8), Array("café\ncafe\u{301}\nCAFE\ncafé CAFE\n".utf8))
    }

    func testMediaLinksMatchExtensionsCaseInsensitivelyLikeFoundation() throws {
        // ASCII in any case; "ſ" and "ﬂ" fold to "s" and "fl" in Foundation's case-insensitive comparison.
        let markdown = "![a](clip.MP4) ![b](song.Mp3) ![c](movie.aſf) ![d](clip.ﬂv) ![e](picture.png) ![f](https://example.com/talk.WebM?x=1)"
        let video = { (type: String, src: String) in "<video width=\"500\" height=\"281\" controls=\"\"><source type=\"\(type)\" src=\"\(src)\"></source></video>" }
        let expected = video("video/mp4", "clip.MP4") + " <audio width=\"500\" controls=\"\"><source type=\"audio/mpeg\" src=\"song.Mp3\"></source></audio> "
            + video("video/x-ms-asf", "movie.aſf") + " " + video("video/x-flv", "clip.ﬂv") + " <img src=\"picture.png\" alt=\"e\" /> "
            + video("video/webm", "https://example.com/talk.WebM?x=1")
        XCTAssertEqual(try Markdown.toHtml(markdown, .advancedWithYaml), "<p>" + expected + "</p>\n")
    }

    func testHeadingIdentifiersOfAsciiAndDecomposedText() throws {
        let html = try Markdown.toHtml("# Hello, World 2!\n\n# Ärger über Café\n\n# hello world 2\n\n# 2026 Plan_v2.final\n", .advancedWithYaml)
        XCTAssertEqual(html, "<h1 id=\"hello-world-2\">Hello, World 2!</h1>\n<h1 id=\"arger-uber-cafe\">Ärger über Café</h1>\n"
            + "<h1 id=\"hello-world-2-1\">hello world 2</h1>\n<h1 id=\"plan_v2.final\">2026 Plan_v2.final</h1>\n")
    }

    func testParserListsFindEachOpeningCharactersParsersInPipelineOrder() {
        func byCharacter(_ parsers: [AnyObject], _ characters: (AnyObject) -> [Markdown.Char]?) -> [Markdown.Char: [ObjectIdentifier]] {
            var result: [Markdown.Char: [ObjectIdentifier]] = [:]
            for parser in parsers { for c in characters(parser) ?? [] { result[c, default: []].append(ObjectIdentifier(parser)) } }
            return result
        }
        var mismatches: [String] = []
        for pipeline in [Markdown.Pipeline.commonMark, .advanced, .advancedWithYaml] {
            let blocks = byCharacter(pipeline.blockParsers.parsers) { ($0 as! Markdown.BlockParser).openingCharacters }
            let inlines = byCharacter(pipeline.inlineParsers.parsers) { ($0 as! Markdown.InlineParser).openingCharacters }
            for value in 0...0xFFFF {
                let c = Markdown.Char(UInt16(value))
                if (pipeline.blockParsers.parsersForOpeningCharacter(c)?.map(ObjectIdentifier.init) ?? []) != (blocks[c] ?? []) { mismatches.append("block \(value)") }
                if (pipeline.inlineParsers.parsersForOpeningCharacter(c)?.map(ObjectIdentifier.init) ?? []) != (inlines[c] ?? []) { mismatches.append("inline \(value)") }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testParserListsTakeAnyNumberOfOpeningCharacters() throws {
        final class InlineProbe: Markdown.InlineParser {
            init(_ characters: [Markdown.Char]) {
                super.init()
                openingCharacters = characters
            }
        }
        final class BlockProbe: Markdown.BlockParser {
            init(_ characters: [Markdown.Char]) {
                super.init()
                openingCharacters = characters
            }
        }
        // 295 distinct openings, more than one byte can index: ASCII letters and digits, Hangul syllables, CJK, U+FFFD.
        let characters = (Array("abcdefghijklmnopqrstuvwxyz0123456789".utf16) + Array(0xAC00..<0xAD00) + [0x4E00, 0x4E8C, 0xFFFD]).map(Markdown.Char.init)
        let builder = Markdown.PipelineBuilder()
        let inline = InlineProbe(characters), block = BlockProbe(characters)
        builder.inlineParsers.insert(inline, at: 0)
        builder.blockParsers.insert(block, at: 0)
        let pipeline = Markdown.Pipeline(builder)
        XCTAssertTrue(characters.allSatisfy { pipeline.inlineParsers.parsersForOpeningCharacter($0)?.first === inline })
        XCTAssertTrue(characters.allSatisfy { pipeline.blockParsers.parsersForOpeningCharacter($0)?.first === block })
        XCTAssertNil(pipeline.inlineParsers.parsersForOpeningCharacter("Z"))
        // The probes never match, so the text parses as without them.
        let markdown = "가나다 *emphasis* and `code`  \nnext 줄\n\n- 갈 item\n- b\n\n> quote 가\n\n[link](https://example.com) &amp; \\* <b>x</b>\n"
        XCTAssertEqual(try Markdown.toHtml(markdown, pipeline), try Markdown.toHtml(markdown, .commonMark))

        // Every UTF-16 code unit as a key: indexes up to 65,536 beside the empty entry.
        let (values, index) = Markdown.characterTable(Dictionary(uniqueKeysWithValues: (0...0xFFFF).map { (Markdown.Char(UInt16($0)), $0) }))
        XCTAssertTrue((0...0xFFFF).allSatisfy { index[$0] > 0 && values[Int(index[$0]) - 1] == $0 })
    }

    func testBlockParserContextRefreshesAfterFailedParserMutatesChildren() {
        final class ProbeParser: Markdown.BlockParser {
            let probe: (Markdown.BlockProcessor) -> Void
            init(_ probe: @escaping (Markdown.BlockProcessor) -> Void) {
                self.probe = probe
                super.init()
                openingCharacters = ["!"]
            }
            override func tryOpen(_ processor: Markdown.BlockProcessor) -> Markdown.BlockState {
                probe(processor)
                return .none
            }
        }
        let document = Markdown.MarkdownDocument()
        let first = Markdown.ParagraphBlock(nil), second = Markdown.ParagraphBlock(nil)
        document.add(first)
        var observations = 0
        let mutate = ProbeParser { processor in
            XCTAssertTrue(processor.currentContainer === document)
            XCTAssertTrue(processor.currentBlock === document)
            XCTAssertTrue(processor.lastBlock === first)
            document.add(second)
        }
        let observe = ProbeParser { processor in
            XCTAssertTrue(processor.currentContainer === document)
            XCTAssertTrue(processor.currentBlock === document)
            XCTAssertTrue(processor.lastBlock === second)
            observations += 1
        }
        let processor = Markdown.BlockProcessor(document, Markdown.BlockParserList([
            mutate, observe, Markdown.ParagraphBlockParser(),
        ]), maximumNestingDepth: Markdown.defaultDepthLimit)
        processor.open(document)
        processor.processLine(Markdown.Slice("! content"))
        XCTAssertEqual(observations, 1)
    }

    func testLinkDefinitionMembershipTracksRemovalAndRepeatedInsertion() {
        let group = Markdown.LinkReferenceDefinitionGroup()
        let link = Markdown.LinkReferenceDefinition(nil, nil, nil)
        group.set("first", link)
        group.set("second", link)
        XCTAssertEqual(group.count, 1)
        XCTAssertNil(group.tryGet("second"))
        XCTAssertTrue(group.remove(link))
        group.set("third", link)
        XCTAssertEqual(group.count, 1)
        XCTAssertTrue(group.tryGet("third") === link)
    }

    func testRetainedBlockLosesParentWhenContainerIsReleased() {
        let child = Markdown.ParagraphBlock(nil)
        weak var released: Markdown.ContainerBlock?
        do {
            let parent = Markdown.ContainerBlock(nil)
            released = parent
            parent.add(child)
            XCTAssertTrue(child.parent === parent)
        }
        XCTAssertNil(released)
        XCTAssertNil(child.parent)
    }

    func testReplacingBlockWithItsChildPreservesTheCurrentParent() {
        let outer = Markdown.ContainerBlock(nil), child = Markdown.ParagraphBlock(nil)
        weak var released: Markdown.ContainerBlock?
        do {
            let inner = Markdown.ContainerBlock(nil)
            released = inner
            outer.add(inner)
            inner.add(child)
            inner.replaceBy(child, moveChildren: false)
            XCTAssertTrue(child.parent === outer)
        }
        XCTAssertNil(released)
        XCTAssertTrue(child.parent === outer)
        child.remove()
        XCTAssertNil(child.parent)
        XCTAssertEqual(outer.count, 0)
    }

    func testInsertBeforeThenRemoveRetainedInlineLosesReleasedParent() {
        let last = Markdown.Inline()
        weak var released: Markdown.ContainerInline?
        do {
            let parent = Markdown.ContainerInline()
            let first = Markdown.Inline(), inserted = Markdown.Inline()
            released = parent
            parent.appendChild(first).appendChild(last)
            last.insertBefore(inserted)
            inserted.remove()
            withExtendedLifetime(parent) {}
        }
        XCTAssertNil(released)
        XCTAssertNil(last.parent)
    }

    func testInsertBeforeThenClearRetainedInlineLosesReleasedParent() {
        let first = Markdown.Inline()
        weak var released: Markdown.ContainerInline?
        do {
            let parent = Markdown.ContainerInline()
            let last = Markdown.Inline(), inserted = Markdown.Inline()
            released = parent
            parent.appendChild(first).appendChild(last)
            last.insertBefore(inserted)
            parent.clear()
            withExtendedLifetime(parent) {}
        }
        XCTAssertNil(released)
        XCTAssertNil(first.parent)
    }

    func testRetainedInlinesLoseOnlyReleasedBacklinks() {
        let middle = Markdown.LiteralInline(Markdown.Slice("middle"))
        let last = Markdown.LiteralInline(Markdown.Slice("last"))
        weak var releasedParent: Markdown.ContainerInline?
        weak var releasedFirst: Markdown.Inline?
        do {
            let parent = Markdown.ContainerInline()
            let first = Markdown.LiteralInline(Markdown.Slice("first"))
            releasedParent = parent
            releasedFirst = first
            parent.appendChild(first).appendChild(middle).appendChild(last)
            XCTAssertTrue(middle.previousSibling === first)
        }
        XCTAssertNil(releasedParent)
        XCTAssertNil(releasedFirst)
        XCTAssertNil(middle.parent)
        XCTAssertNil(last.parent)
        XCTAssertNil(middle.previousSibling)
        XCTAssertTrue(middle.nextSibling === last)
        XCTAssertTrue(last.previousSibling === middle)
    }

    func testRetainedChildrenSurviveTransferAndClear() {
        let block = Markdown.ParagraphBlock(nil)
        let inline = Markdown.Inline()
        let blocks = Markdown.ContainerBlock(nil)
        let inlines = Markdown.ContainerInline()
        do {
            let previousBlocks = Markdown.ContainerBlock(nil)
            let previousInlines = Markdown.ContainerInline()
            previousBlocks.add(block)
            previousInlines.appendChild(inline)
            previousBlocks.transferChildrenTo(blocks)
            previousInlines.transferChildrenTo(inlines)
        }
        XCTAssertTrue(block.parent === blocks)
        XCTAssertTrue(inline.parent === inlines)
        blocks.clear()
        inlines.clear()
        XCTAssertNil(block.parent)
        XCTAssertNil(inline.parent)
    }

    func testAppendingLinkedInlineLeavesASafeDetachedSuccessor() {
        let successor = Markdown.Inline()
        weak var releasedParent: Markdown.ContainerInline?
        weak var releasedChild: Markdown.Inline?
        do {
            let parent = Markdown.ContainerInline()
            let first = Markdown.Inline(), child = Markdown.Inline()
            releasedParent = parent
            releasedChild = child
            child.insertAfter(successor)
            parent.appendChild(first).appendChild(child)
            XCTAssertTrue(parent.firstChild === first)
            XCTAssertTrue(parent.lastChild === child)
            XCTAssertTrue(first.nextSibling === child)
            XCTAssertTrue(child.previousSibling === first)
            XCTAssertTrue(child.parent === parent)
            XCTAssertNil(child.nextSibling)
            XCTAssertNil(successor.parent)
            XCTAssertTrue(successor.previousSibling === child)
            withExtendedLifetime(parent) {}
        }
        XCTAssertNil(releasedParent)
        XCTAssertNil(releasedChild)
        XCTAssertNil(successor.previousSibling)
    }

    func testAppendingAfterATailWithASuccessorKeepsMarkdigEndpoints() {
        let parent = Markdown.ContainerInline()
        let first = Markdown.Inline(), successor = Markdown.Inline(), appended = Markdown.Inline()
        first.insertAfter(successor)
        parent.appendChild(first).appendChild(appended)
        XCTAssertTrue(parent.firstChild === first)
        XCTAssertTrue(parent.lastChild === first)
        XCTAssertTrue(first.nextSibling === appended)
        XCTAssertTrue(appended.previousSibling === first)
        XCTAssertTrue(appended.nextSibling === successor)
        XCTAssertTrue(successor.previousSibling === appended)
        XCTAssertTrue(appended.parent === parent)
        XCTAssertNil(successor.parent)
    }

    func testDetachedSiblingCleanupPreservesRewiredBacklink() {
        var previous: Markdown.Inline? = Markdown.Inline()
        let next = Markdown.Inline()
        previous!.insertAfter(next)
        previous!.remove()
        let replacement = Markdown.Inline()
        replacement.insertAfter(next)
        previous = nil
        XCTAssertTrue(next.previousSibling === replacement)
        XCTAssertTrue(replacement.nextSibling === next)
    }

    func testUnlinkedDetachedNodeLosesReleasedPreviousSibling() {
        let removed = Markdown.Inline()
        let replaced = Markdown.Inline()
        weak var released: Markdown.Inline?
        do {
            let previous = Markdown.Inline()
            released = previous
            previous.insertAfter(removed)
            removed.remove()
            XCTAssertTrue(removed.previousSibling === previous)
            previous.insertAfter(replaced)
            previous.insertBefore(Markdown.Inline())
        }
        XCTAssertNil(released)
        XCTAssertNil(removed.previousSibling)
    }

    func testReusedDetachedNodeLeavesSafeBacklinkOnOldSuccessor() {
        let successor = Markdown.Inline()
        weak var released: Markdown.Inline?
        do {
            let previous = Markdown.Inline()
            released = previous
            previous.insertAfter(successor)
            Markdown.Inline().insertBefore(previous)
            XCTAssertTrue(successor.previousSibling === previous)
        }
        XCTAssertNil(released)
        XCTAssertNil(successor.previousSibling)
    }

    func testRetainedDetachedSiblingLosesReleasedPreviousSibling() {
        let next = Markdown.Inline()
        weak var released: Markdown.Inline?
        do {
            let previous = Markdown.Inline()
            released = previous
            previous.insertAfter(next)
            XCTAssertTrue(next.previousSibling === previous)
        }
        XCTAssertNil(released)
        XCTAssertNil(next.previousSibling)
    }

    func testInlineOpeningCharactersCoverEveryUTF16CodeUnit() {
        let parser = Markdown.InlineParser()
        parser.openingCharacters = [Markdown.Char(0), Markdown.Char(0xD800), Markdown.Char(0xFFFF), "~"]
        let parsers = Markdown.InlineParserList([parser])
        let text = (0...65535).map { Markdown.Char(UInt16($0)) }
        for i in text.indices {
            XCTAssertEqual(parsers.indexOfOpeningCharacter(text, i, i), parser.openingCharacters!.contains(text[i]) ? i : -1)
        }
        XCTAssertEqual(parsers.indexOfOpeningCharacter(text, 1, 0), -1)
    }

    func testLiteralScanSkipsFailedAutolinkPrefixesAndPreservesOtherParsers() {
        let text = Markdown.chars("heading markdown footnote table wwwx httpx mailtoz https://example.com")
        let links = Markdown.AutoLinkParser()
        let parsers = Markdown.InlineParserList([links])
        let expected = text.count - "https://example.com".utf16.count
        XCTAssertEqual(parsers.indexOfOpeningCharacter(text, 0, text.count - 1), expected)

        let other = Markdown.InlineParser()
        other.openingCharacters = ["h"]
        let shared = Markdown.InlineParserList([links, other])
        XCTAssertEqual(shared.indexOfOpeningCharacter(text, 0, text.count - 1), 0)
        let global = Markdown.InlineParserList([links, Markdown.InlineParser()])
        XCTAssertEqual(global.indexOfOpeningCharacter(text, 0, text.count - 1), 0)
    }

    func testMarkdownToHwpxKeepsStructure() async throws {
        let folder = try MarkupTestSupport.newFolder()
        let hwpx = try await MarkupTestSupport.convert(try writeSample(folder), "hwpx")

        try HwpxAssert.validPackage(hwpx, 1)
        let document = try HwpxReader.read(hwpx, FilePath.combine(folder, "readback"))
        let text = document.sections.map { HDocumentWalker.inlines($0.blocks).compactMap { ($0 as? HText)?.text }.joined(separator: " ") }.joined()
        for expected in ["주간 회의", "배포", "v1.0.1", "설치", "민지", "☑", "끝낸 일", "☐", "남은 일"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains("title:"))
        XCTAssertEqual(try HwpxAssert.xml(hwpx).descendants(HwpxAssert.hp + "tbl").count, 1)
    }

    func testMarkdownToHwpxEscapesMarkupCharactersBeforeCombiningMarks() async throws {
        let md = FilePath.combine(try MarkupTestSupport.newFolder(), "marks.md")
        let text = "less <\u{338} than, R&\u{301}D, \"\u{1F3FB}, '\u{301} and >\u{20D2}"
        try Data(text.utf8).write(to: URL(fileURLWithPath: md))

        let hwpx = try await MarkupTestSupport.convert(md, "hwpx")

        try HwpxAssert.validPackage(hwpx) // every XML part parses
        let document = try HwpxReader.read(hwpx, FilePath.combine(FilePath.directoryName(md)!, "readback"))
        let read = document.sections.map { HDocumentWalker.inlines($0.blocks).compactMap { ($0 as? HText)?.text }.joined() }.joined()
        XCTAssertEqual(Array(read.unicodeScalars), Array(text.unicodeScalars))
    }

    func testFootnotesReferringToThemselvesAndLongChainsAreRead() async throws {
        // Filee's reader recursed forever on a footnote that refers to itself and overflowed the stack; the reference
        // inside the note is left out.
        let cycle = try MarkdownReader.read("Text[^a]\n\n[^a]: Note [^b]\n\n[^b]: Back to [^a] here.\n", NSTemporaryDirectory())
        let paragraph = try XCTUnwrap(cycle.sections.first?.blocks.first as? HParagraph)
        let a = try XCTUnwrap(paragraph.inlines.last as? HNote)
        let b = try XCTUnwrap((a.blocks.first as? HParagraph)?.inlines.last as? HNote)
        XCTAssertEqual(HDocumentWalker.inlines(b.blocks).compactMap { $0 as? HNote }.count, 0)
        XCTAssertEqual(HDocumentWalker.inlines(b.blocks).compactMap { ($0 as? HText)?.text }.joined(), "Back to  here.")

        // A chain of notes nests one level per note; read from a pool thread, as conversions are. (Releasing such a
        // document recurses per level too, so that happens on a large stack here.)
        let count = 3000
        let chain = "A[^1]\n\n" + (1..<count).map { "[^\($0)]: x[^\($0 + 1)]\n" }.joined(separator: "\n") + "\n[^\(count)]: end\n"
        let depth = try await Task.detached { () throws -> Int in
            var document: HDocument? = try MarkdownReader.read(chain, NSTemporaryDirectory())
            var depth = 0
            try MarkupConvert.onLargeStack {
                var inlines = (document?.sections.first?.blocks.first as? HParagraph)?.inlines ?? []
                while let note = inlines.last as? HNote {
                    depth += 1
                    inlines = (note.blocks.first as? HParagraph)?.inlines ?? []
                }
                inlines = []
                document = nil
            }
            return depth
        }.value
        XCTAssertEqual(depth, count)
    }

    func testDeepNestingFailsLikeMarkdigOrIsReadInsteadOfOverflowingTheStack() async throws {
        // Parsing up to Markdig's depth limits, reading and releasing the tree recurse per level, deeper than the stack
        // of the pool threads conversions run on.
        let folder = try MarkupTestSupport.newFolder()
        let lists = FilePath.combine(folder, "lists.md")
        try Data((String(repeating: "- ", count: 1000) + "x").utf8).write(to: URL(fileURLWithPath: lists))
        for target in ["html", "txt", "hwpx"] {
            let job = await MarkupTestSupport.run([lists], MarkupTestSupport.preset(target))
            XCTAssertEqual(job.files.first?.state, .failed, target)
            XCTAssertEqual(job.files.first?.errorDetail, Markdown.DepthLimitError().localizedDescription, target)
        }
        // 1 500 nested emphases: past the HTML renderer's limit, but read into HWPX (Filee's reader overflowed the stack).
        let emphasis = FilePath.combine(folder, "emphasis.md")
        try Data((String(repeating: "*", count: 3000) + "x" + String(repeating: "*", count: 3000)).utf8).write(to: URL(fileURLWithPath: emphasis))
        let html = await MarkupTestSupport.run([emphasis], MarkupTestSupport.preset("html"))
        XCTAssertEqual(html.files.first?.errorDetail, Markdown.DepthLimitError().localizedDescription)
        try HwpxAssert.validPackage(try await MarkupTestSupport.convert(emphasis, "hwpx"))
    }

    func testMarkdownToPdfWithBuiltInEngines() async throws {
        guard RhwpConverter.locate() != nil else { throw XCTSkip("rhwp not found (bundled engine)") }
        let pdf = try await MarkupTestSupport.convert(try writeSample(try MarkupTestSupport.newFolder()), "pdf")
        let data = try Data(contentsOf: URL(fileURLWithPath: pdf))
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
    }

    func testProgressEstimateRisesTowardsTheBoundAndNeverReachesIt() {
        let values = [0, 0.5, 1, 2, 4, 8, 30].map { ProgressEstimate.value(elapsed: $0, typical: 2, from: 0.1, to: 0.9) }
        XCTAssertEqual(values[0], 0.1, accuracy: 1e-6)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $1 > $0 })
        XCTAssertLessThan(values.last!, 0.9)
        let atTypical = ProgressEstimate.value(elapsed: 2, typical: 2, from: 0.1, to: 0.9)
        XCTAssertTrue((0.6...0.62).contains(atTypical)) // 1 - 1/e of the way
    }

    func testProgressEstimateReportsWhileRunningAndStopsWhenStopped() async throws {
        final class Reports: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func add(_ value: Double) { lock.withLock { values.append(value) } }
            var all: [Double] { lock.withLock { values } }
        }
        let reports = Reports()
        let estimate = ProgressEstimate.start({ reports.add($0) }, typical: 1)
        // Timer callbacks run late on a busy machine: wait for two reports, up to 10 s.
        let deadline = Date().addingTimeInterval(10)
        while reports.all.count < 2 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        estimate.stop()
        // A callback that was already running when the estimate stopped may still report once.
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = reports.all.count
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertEqual(reports.all.count, count)
        XCTAssertTrue(reports.all.allSatisfy { (0.1...0.9).contains($0) })
    }
}
