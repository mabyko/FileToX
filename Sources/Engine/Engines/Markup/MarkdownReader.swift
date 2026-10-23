// Port of Filee.Engines/Hwp/Hwpx/MarkdownReader.cs: Markdown → HDocument, so Markdown → HWPX needs no external engine.
//
// Mirrors PandocAstReader: headings (with their ids as bookmarks), paragraphs, bold / italic / strike / sub- and
// superscript / inserted / marked text, code, lists (1. / a. / i. / A. / I. with the start number, nested levels),
// task lists, block quotes, pipe and grid tables with spans, definition lists, links, images, footnotes and math.
// The YAML front matter's "title" becomes the document title. Raw HTML is skipped, except <br>. The Markdown is
// parsed by the Markdig-compatible parser in Markdown/ with Filee's pipeline.

import Foundation

final class MarkdownReader {
    /// Indent per block quote level (same as PandocAstReader).
    private static let quoteIndent = 2000

    /// GitHub-style Markdown plus the common extensions (tables, footnotes, task lists, math, ...): Filee's
    /// `UseAdvancedExtensions().UseYamlFrontMatter()`.
    static let pipeline = Markdown.Pipeline.advancedWithYaml

    private static let plain = HCharFormat()
    private static let codeFormat = HCharFormat(shade: "#F1F0F5")
    private let baseFolder: String
    /// The footnotes being read (a reference to one of them is left out).
    private var footnotes: Set<ObjectIdentifier> = []

    private init(_ baseFolder: String) { self.baseFolder = baseFolder }

    /// Parses Markdown text; relative image paths are resolved against `baseFolder` (the Markdown file's folder).
    static func read(_ markdown: String, _ baseFolder: String) throws -> HDocument {
        let parsed = try Markdown.parse(markdown, pipeline)
        let reader = MarkdownReader(baseFolder)
        let section = HSection()
        // Nested emphasis (up to Markdig's 10 240 inline levels) and chains of footnotes recurse here.
        try MarkupConvert.onLargeStack { reader.blocks(parsed, &section.blocks, Context()) }
        let document = HDocument()
        document.title = title(parsed)
        document.sections.append(section)
        return document
    }

    /// List nesting and quote indentation of the blocks being read.
    private struct Context {
        var listLevel = 0
        var indent = 0
    }

    // MARK: Blocks

    private func blocks(_ container: Markdown.ContainerBlock, _ output: inout [HBlock], _ context: Context) {
        for block in container.children { self.block(block, &output, context) }
    }

    private func block(_ block: Markdown.Block, _ output: inout [HBlock], _ context: Context) {
        switch block {
        // First: YAML front matter is a code block and HTML blocks are leaf blocks in the tree; raw HTML, metadata and
        // definitions carry no document text (footnotes are read at their links).
        case is Markdown.HtmlBlock, is Markdown.YamlFrontMatterBlock, is Markdown.LinkReferenceDefinitionGroup, is Markdown.FootnoteGroup:
            break
        case let heading as Markdown.HeadingBlock:
            output.append(self.heading(heading, context))
        case let paragraph as Markdown.ParagraphBlock:
            output.append(self.paragraph(paragraph.inline, context))
        case let list as Markdown.ListBlock:
            self.list(list, &output, context)
        case let quote as Markdown.QuoteBlock:
            var inner = context
            inner.indent += Self.quoteIndent
            blocks(quote, &output, inner)
        case let math as Markdown.MathBlock:
            var format = Self.plain
            format.italic = true
            Self.codeLines(math, &output, context, format)
        case let code as Markdown.CodeBlock:
            Self.codeLines(code, &output, context, Self.codeFormat)
        case is Markdown.ThematicBreakBlock:
            output.append(Self.newParagraph(context))
        case let table as Markdown.Table:
            output.append(tableBlock(table, context))
        case let definitions as Markdown.DefinitionList:
            definitionList(definitions, &output, context)
        case let container as Markdown.ContainerBlock:
            blocks(container, &output, context) // figures, custom containers, ...
        case let leaf as Markdown.LeafBlock:
            if let inline = leaf.inline { output.append(paragraph(inline, context)) }
        default:
            break
        }
    }

    private static func newParagraph(_ context: Context) -> HParagraph {
        let paragraph = HParagraph()
        if context.indent > 0 { paragraph.format = HParaFormat(left: context.indent) }
        return paragraph
    }

    private func paragraph(_ inlines: Markdown.ContainerInline?, _ context: Context) -> HParagraph {
        let paragraph = Self.newParagraph(context)
        self.inlines(inlines, &paragraph.inlines, Self.plain)
        return paragraph
    }

    private func heading(_ heading: Markdown.HeadingBlock, _ context: Context) -> HParagraph {
        let paragraph = self.paragraph(heading.inline, context)
        paragraph.headingLevel = min(max(heading.level, 1), 9)
        // Heading ids are link targets ("#id" links, e.g. a table of contents).
        if let id = heading.getAttributes().id, !id.isEmpty { paragraph.inlines.insert(HBookmark(id), at: 0) }
        return paragraph
    }

    private static func codeLines(_ code: Markdown.LeafBlock, _ output: inout [HBlock], _ context: Context, _ format: HCharFormat) {
        let text = code.lines.toSlice().description.replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let paragraph = newParagraph(context)
            if !line.isEmpty { paragraph.inlines.append(HText(String(line), format)) }
            output.append(paragraph)
        }
    }

    private static func numbering(_ list: Markdown.ListBlock) -> HNumbering {
        let bullets = ["●", "○", "■"]
        let defaultFormats = ["DIGIT", "LATIN_CAPITAL", "ROMAN_SMALL"]
        let numbering = HNumbering()
        let start = MarkupConvert.tryParseInt(list.orderedStart).map { max(1, $0) } ?? 1
        for level in 1...7 {
            if !list.isOrdered {
                numbering.levels.append(HNumberingLevel("DIGIT", bullets[(level - 1) % 3], 1, true))
                continue
            }
            // The first level follows the Markdown list; deeper levels use the usual 1. → A. → i. sequence.
            let format: String
            if level > 1 {
                format = defaultFormats[(level - 1) % 3]
            } else {
                switch list.bulletType {
                case "a": format = "LATIN_SMALL"
                case "A": format = "LATIN_CAPITAL"
                case "i": format = "ROMAN_SMALL"
                case "I": format = "ROMAN_CAPITAL"
                default: format = "DIGIT"
                }
            }
            let text = list.orderedDelimiter == ")" ? "^\(level))" : "^\(level)."
            numbering.levels.append(HNumberingLevel(format, text, level == 1 ? start : 1, false))
        }
        return numbering
    }

    private func list(_ list: Markdown.ListBlock, _ output: inout [HBlock], _ context: Context) {
        let numbering = Self.numbering(list)
        for case let item as Markdown.ListItemBlock in list.children {
            // Only the first paragraph of an item carries the bullet or number.
            var first = true
            for block in item.children {
                switch block {
                case let paragraphBlock as Markdown.ParagraphBlock:
                    let paragraph = self.paragraph(paragraphBlock.inline, context)
                    paragraph.list = HListRef(numbering, context.listLevel, first)
                    output.append(paragraph)
                    first = false
                case let nested as Markdown.ListBlock:
                    var inner = context
                    inner.listLevel += 1
                    self.list(nested, &output, inner)
                default:
                    self.block(block, &output, context)
                    first = false
                }
            }
        }
    }

    private func tableBlock(_ table: Markdown.Table, _ context: Context) -> HTable {
        let rows = table.children.compactMap { $0 as? Markdown.TableRow }
        let widest = rows.isEmpty ? 1 : rows.map { $0.children.compactMap { $0 as? Markdown.TableCell }.reduce(0) { $0 + max(1, $1.columnSpan) } }.max()!
        let columns = max(table.columnDefinitions.count, widest)
        var widths = table.columnDefinitions.map { Double($0.width) / 100 }
        while widths.count < columns { widths.append(0) }
        let hTable = HTable()
        hTable.columnCount = columns
        let used = Array(widths.prefix(columns))
        hTable.relativeWidths = used.allSatisfy { $0 <= 0 } ? nil : used
        hTable.indent = context.indent
        for row in rows {
            let hRow = HRow()
            hRow.header = row.isHeader
            for case let cell as Markdown.TableCell in row.children {
                let hCell = HCell()
                hCell.rowSpan = max(1, cell.rowSpan)
                hCell.colSpan = max(1, cell.columnSpan)
                blocks(cell, &hCell.blocks, Context())
                if row.isHeader { Self.boldHeader(hCell.blocks) }
                hRow.cells.append(hCell)
            }
            hTable.rows.append(hRow)
        }
        return hTable
    }

    /// Header cells are bold, as Markdown renderers show them.
    private static func boldHeader(_ blocks: [HBlock]) {
        for case let paragraph as HParagraph in blocks {
            for i in paragraph.inlines.indices {
                if let text = paragraph.inlines[i] as? HText, text.format.bold == nil {
                    var format = text.format
                    format.bold = true
                    paragraph.inlines[i] = HText(text.text, format)
                }
            }
        }
    }

    private func definitionList(_ definitions: Markdown.DefinitionList, _ output: inout [HBlock], _ context: Context) {
        for case let item as Markdown.DefinitionItem in definitions.children {
            for block in item.children {
                if let term = block as? Markdown.DefinitionTerm {
                    let paragraph = Self.newParagraph(context)
                    inlines(term.inline, &paragraph.inlines, HCharFormat(bold: true))
                    output.append(paragraph)
                } else {
                    var inner = context
                    inner.indent += Self.quoteIndent
                    self.block(block, &output, inner)
                }
            }
        }
    }

    // MARK: Inlines

    private func inlines(_ container: Markdown.ContainerInline?, _ output: inout [HInline], _ format: HCharFormat) {
        guard let container else { return }
        var child = container.firstChild
        while let inline = child {
            child = inline.nextSibling
            switch inline {
            case let literal as Markdown.LiteralInline:
                output.append(HText(literal.content.description, format))
            case let code as Markdown.CodeInline:
                var shaded = format
                shaded.shade = Self.codeFormat.shade
                output.append(HText(code.content, shaded))
            case let lineBreak as Markdown.LineBreakInline:
                output.append(lineBreak.isHard ? HLineBreak(format) : HText(" ", format))
            case let emphasis as Markdown.EmphasisInline:
                inlines(emphasis, &output, Self.emphasis(emphasis, format))
            case let image as Markdown.LinkInline where image.isImage:
                if let picture = self.image(image) { output.append(picture) }
            case let link as Markdown.LinkInline:
                self.link(link.url, link, &output, format)
            case let autolink as Markdown.AutolinkInline:
                let lower = autolink.url.lowercased()
                let target = autolink.isEmail && !lower.hasPrefix("mailto:") ? "mailto:" + autolink.url : autolink.url
                let hLink = HLink(target)
                hLink.content.append(HText(autolink.url, format))
                output.append(hLink)
            case let entity as Markdown.HtmlEntityInline:
                output.append(HText(entity.transcoded.description, format))
            case let html as Markdown.HtmlInline:
                if html.tag.lowercased().hasPrefix("<br") { output.append(HLineBreak(format)) } // other raw HTML has no text
            case let task as Markdown.TaskList:
                output.append(HText(task.checked ? "☑" : "☐", format)) // the following text starts with a space
            case let math as Markdown.MathInline:
                var italic = format
                italic.italic = true
                output.append(HText(math.content.description, italic))
            case let footnote as Markdown.FootnoteLink:
                // A footnote referring to itself (directly or through others) would nest without end; Filee's reader
                // overflows the stack and the helper dies. The inner reference is left out, like the "↩" back link.
                if !footnote.isBackLink, footnotes.insert(ObjectIdentifier(footnote.footnote)).inserted {
                    let note = HNote(false)
                    blocks(footnote.footnote, &note.blocks, Context())
                    footnotes.remove(ObjectIdentifier(footnote.footnote))
                    output.append(note)
                } // else: the "↩" back link inside a footnote
            case let other as Markdown.ContainerInline:
                inlines(other, &output, format)
            default:
                break
            }
        }
    }

    private static func emphasis(_ emphasis: Markdown.EmphasisInline, _ format: HCharFormat) -> HCharFormat {
        var result = format
        switch emphasis.delimiterChar {
        case "*", "_":
            if emphasis.delimiterCount >= 3 {
                result.bold = true
                result.italic = true
            } else if emphasis.delimiterCount == 2 {
                result.bold = true
            } else {
                result.italic = true
            }
        case "~":
            if emphasis.delimiterCount >= 2 {
                result.strike = true
            } else {
                result.subscript = true
                result.superscript = nil
            }
        case "^":
            result.superscript = true
            result.subscript = nil
        case "+":
            result.underline = true
        case "=":
            result.shade = "#FFF3A3"
        default:
            break
        }
        return result
    }

    private func link(_ url: String?, _ content: Markdown.ContainerInline, _ output: inout [HInline], _ format: HCharFormat) {
        guard let url, !url.allSatisfy(\.isWhitespace) else {
            inlines(content, &output, format)
            return
        }
        let link = HLink(url)
        inlines(content, &link.content, format)
        output.append(link)
    }

    private func image(_ image: Markdown.LinkInline) -> HImage? {
        // A remote or missing image is skipped rather than produce a broken reference.
        guard let path = Self.resolveImage(image.url, baseFolder) else { return nil }
        // Sizes from the generic attributes extension: ![](a.png){width=50% height=3cm}
        let properties = image.getAttributes().properties?.items ?? []
        func attribute(_ name: String) -> String? {
            properties.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }
        let picture = HImage(path)
        picture.width = HwpxUnits.parseLength(attribute("width"))
        picture.height = HwpxUnits.parseLength(attribute("height"))
        return picture
    }

    /// Local image path of a Markdown image target, or nil for remote / missing images.
    static func resolveImage(_ target: String?, _ baseFolder: String) -> String? {
        guard let target, !target.allSatisfy(\.isWhitespace) else { return nil }
        let isFile = target.lowercased().hasPrefix("file:")
        if target.contains("://") && !isFile { return nil }
        let path: String
        if isFile {
            // `new Uri(target).LocalPath`: an absolute file URI, unescaped.
            guard let url = URL(string: target), url.isFileURL, url.path.hasPrefix("/") else { return nil }
            path = url.path
        } else {
            path = MarkupConvert.unescapeDataString(target)
        }
        if path.contains("\0") { return nil }
        let candidate = path.hasPrefix("/") ? path : FilePath.combine(baseFolder, path)
        return FileManager.default.fileExists(candidate) ? FilePath.fullPath(candidate) : nil
    }

    // MARK: Helpers

    /// "title:" from the YAML front matter, if any.
    private static func title(_ document: Markdown.MarkdownDocument) -> String? {
        guard let yaml = document.blockDescendants(Markdown.YamlFrontMatterBlock.self).first else { return nil }
        for line in yaml.lines.toSlice().description.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("title:") {
                let value = trimmed.dropFirst("title:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
