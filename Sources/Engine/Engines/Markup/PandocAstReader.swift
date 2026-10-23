// Port of Filee.Engines/Hwp/Hwpx/PandocAstReader.cs: Pandoc JSON AST → HDocument. Used for formats Pandoc parses
// (ODT, RTF, reStructuredText, LaTeX).
//
// The mapping follows pypandoc-hwpx (MIT, https://github.com/msjang/pypandoc-hwpx), extended so nothing is dropped
// silently: BlockQuote, Div, Figure, LineBlock, DefinitionList, HorizontalRule, Span, Quoted, Cite, Strikeout,
// SmallCaps and Math are converted too, and list numbering honours the Pandoc list style (1. / A. / i) / (a) ...).
// Pandoc's model has no page setup or direct formatting, so those come from the HWPX template. The input is the
// `JSONSerialization` object of `pandoc -t json`.

import Foundation

final class PandocAstReader {
    /// Indent per block quote level.
    private static let quoteIndent = 2000

    private static let plain = HCharFormat()
    private let resolveImage: (String) -> String?

    private init(_ resolveImage: @escaping (String) -> String?) { self.resolveImage = resolveImage }

    /// Converts the output of `pandoc -t json`; `resolveImage` maps an image target to a local file, or nil.
    static func read(_ ast: Any, _ resolveImage: (String) -> String?) throws -> HDocument {
        withoutActuallyEscaping(resolveImage) { resolve in
            let reader = PandocAstReader(resolve)
            let document = HDocument()
            document.title = title(Json.member(ast, "meta"))
            let section = HSection()
            reader.blocks(Json.array(Json.member(ast, "blocks")), &section.blocks, Context())
            document.sections.append(section)
            return document
        }
    }

    /// List nesting and quote indentation of the blocks being read.
    private struct Context {
        var listLevel = 0
        var indent = 0
    }

    // MARK: Blocks

    private func blocks(_ blocks: [Any]?, _ output: inout [HBlock], _ context: Context) {
        for block in blocks ?? [] where block is [String: Any] { self.block(block, &output, context) }
    }

    private func block(_ block: Any, _ output: inout [HBlock], _ context: Context) {
        let content = Json.member(block, "c")
        switch Json.type(block) {
        case "Para", "Plain":
            output.append(paragraph(Json.array(content), context))
        case "Header":
            output.append(heading(content, context))
        case "BulletList":
            list(Json.array(content), Self.numbering(false, 1, "", ""), &output, context)
        case "OrderedList":
            let attributes = Json.item(content, 0)
            let numbering = Self.numbering(true, Json.int(Json.item(attributes, 0)) ?? 1, Json.type(Json.item(attributes, 1)),
                                           Json.type(Json.item(attributes, 2)))
            list(Json.array(Json.item(content, 1)), numbering, &output, context)
        case "CodeBlock":
            for line in (Json.string(Json.item(content, 1)) ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
                let paragraph = Self.newParagraph(context)
                paragraph.inlines.append(HText(String(line), Self.plain))
                output.append(paragraph)
            }
        case "LineBlock":
            for line in Json.array(content) ?? [] { output.append(paragraph(Json.array(line), context)) }
        case "BlockQuote":
            var inner = context
            inner.indent += Self.quoteIndent
            blocks(Json.array(content), &output, inner)
        case "Div":
            blocks(Json.array(Json.item(content, 1)), &output, context)
        case "Figure":
            // [attr, caption [short, blocks], blocks]
            blocks(Json.array(Json.item(content, 2)), &output, context)
            blocks(Json.array(Json.item(Json.item(content, 1), 1)), &output, context)
        case "DefinitionList":
            for item in Json.array(content) ?? [] {
                let term = Self.newParagraph(context)
                inlines(Json.array(Json.item(item, 0)), &term.inlines, HCharFormat(bold: true))
                output.append(term)
                var inner = context
                inner.indent += Self.quoteIndent
                for definition in Json.array(Json.item(item, 1)) ?? [] { blocks(Json.array(definition), &output, inner) }
            }
        case "HorizontalRule":
            output.append(Self.newParagraph(context))
        case "Table":
            output.append(table(content, context))
        default:
            break // RawBlock and unknown blocks carry no document text
        }
    }

    private static func newParagraph(_ context: Context) -> HParagraph {
        let paragraph = HParagraph()
        if context.indent > 0 { paragraph.format = HParaFormat(left: context.indent) }
        return paragraph
    }

    private func paragraph(_ inlines: [Any]?, _ context: Context) -> HParagraph {
        let paragraph = Self.newParagraph(context)
        self.inlines(inlines, &paragraph.inlines, Self.plain)
        return paragraph
    }

    private func heading(_ content: Any?, _ context: Context) -> HParagraph {
        let inlines = Json.array(Json.item(content, 2)) ?? []
        let paragraph = Self.newParagraph(context)
        paragraph.headingLevel = min(max(Json.int(Json.item(content, 0)) ?? 1, 1), 9)
        // A line break at the very start of a heading means "column break" (pypandoc-hwpx convention).
        paragraph.columnBreakBefore = !inlines.isEmpty && Json.type(inlines[0]) == "LineBreak"
        self.inlines(Array(inlines.dropFirst(paragraph.columnBreakBefore ? 1 : 0)), &paragraph.inlines, Self.plain)
        // Heading ids are link targets ("#id" links, e.g. a generated table of contents).
        if let id = Json.string(Json.item(Json.item(content, 1), 0)), !id.isEmpty { paragraph.inlines.insert(HBookmark(id), at: 0) }
        return paragraph
    }

    private static func numbering(_ ordered: Bool, _ start: Int, _ style: String, _ delimiter: String) -> HNumbering {
        let bullets = ["●", "○", "■"]
        let defaultFormats = ["DIGIT", "LATIN_CAPITAL", "ROMAN_SMALL"]
        let numbering = HNumbering()
        for level in 1...7 {
            if !ordered {
                numbering.levels.append(HNumberingLevel("DIGIT", bullets[(level - 1) % 3], 1, true))
                continue
            }
            let format: String
            switch style {
            case "Decimal": format = "DIGIT"
            case "LowerAlpha": format = "LATIN_SMALL"
            case "UpperAlpha": format = "LATIN_CAPITAL"
            case "LowerRoman": format = "ROMAN_SMALL"
            case "UpperRoman": format = "ROMAN_CAPITAL"
            default: format = defaultFormats[(level - 1) % 3]
            }
            let text: String
            switch delimiter {
            case "OneParen": text = "^\(level))"
            case "TwoParens": text = "(^\(level))"
            default: text = "^\(level)."
            }
            numbering.levels.append(HNumberingLevel(format, text, level == 1 ? max(1, start) : 1, false))
        }
        return numbering
    }

    private func list(_ items: [Any]?, _ numbering: HNumbering, _ output: inout [HBlock], _ context: Context) {
        for item in items ?? [] {
            // Only the first paragraph of an item carries the bullet or number.
            var first = true
            for block in Json.array(item) ?? [] where !(block is NSNull) {
                switch Json.type(block) {
                case "Para", "Plain":
                    let paragraph = self.paragraph(Json.array(Json.member(block, "c")), context)
                    paragraph.list = HListRef(numbering, context.listLevel, first)
                    output.append(paragraph)
                    first = false
                case "BulletList", "OrderedList":
                    var inner = context
                    inner.listLevel += 1
                    self.block(block, &output, inner)
                default:
                    self.block(block, &output, context)
                    first = false
                }
            }
        }
    }

    private func table(_ content: Any?, _ context: Context) -> HTable {
        // Pandoc ≥ 2.10: [attr, caption, colSpecs, head, bodies, foot]; row = [attr, cells];
        // cell = [attr, align, rowspan, colspan, blocks]
        let specs = Json.array(Json.item(content, 2)) ?? []
        let table = HTable()
        table.columnCount = specs.count
        table.relativeWidths = specs.map { spec in
            Json.type(Json.item(spec, 1)) == "ColWidth" ? Json.double(Json.member(Json.item(spec, 1), "c")) ?? 0 : 0
        }
        table.indent = context.indent

        func addRows(_ rows: [Any]?, _ header: Bool) {
            for row in rows ?? [] {
                let hRow = HRow()
                hRow.header = header
                for cell in Json.array(Json.item(row, 1)) ?? [] where !(cell is NSNull) {
                    let hCell = HCell()
                    hCell.rowSpan = max(1, Json.int(Json.item(cell, 2)) ?? 1)
                    hCell.colSpan = max(1, Json.int(Json.item(cell, 3)) ?? 1)
                    blocks(Json.array(Json.item(cell, 4)), &hCell.blocks, Context())
                    hRow.cells.append(hCell)
                }
                table.rows.append(hRow)
            }
        }

        addRows(Json.array(Json.item(Json.item(content, 3), 1)), true)
        for body in Json.array(Json.item(content, 4)) ?? [] {
            addRows(Json.array(Json.item(body, 2)), false)
            addRows(Json.array(Json.item(body, 3)), false)
        }
        addRows(Json.array(Json.item(Json.item(content, 5), 1)), false)
        blocks(Json.array(Json.item(Json.item(content, 1), 1)), &table.caption, context)
        return table
    }

    // MARK: Inlines

    private func inlines(_ inlines: [Any]?, _ output: inout [HInline], _ format: HCharFormat) {
        for inline in inlines ?? [] where !(inline is NSNull) {
            let c = Json.member(inline, "c")
            var changed = format
            switch Json.type(inline) {
            case "Str":
                output.append(HText(Json.string(c) ?? "", format))
            case "Space", "SoftBreak":
                output.append(HText(" ", format))
            case "LineBreak":
                output.append(HLineBreak(format))
            case "Strong":
                changed.bold = true
                self.inlines(Json.array(c), &output, changed)
            case "Emph":
                changed.italic = true
                self.inlines(Json.array(c), &output, changed)
            case "Underline":
                changed.underline = true
                self.inlines(Json.array(c), &output, changed)
            case "Strikeout":
                changed.strike = true
                self.inlines(Json.array(c), &output, changed)
            case "Superscript":
                changed.superscript = true
                changed.subscript = nil
                self.inlines(Json.array(c), &output, changed)
            case "Subscript":
                changed.subscript = true
                changed.superscript = nil
                self.inlines(Json.array(c), &output, changed)
            case "SmallCaps":
                self.inlines(Json.array(c), &output, format)
            case "Span":
                if let id = Json.string(Json.item(Json.item(c, 0), 0)), !id.isEmpty { output.append(HBookmark(id)) }
                self.inlines(Json.array(Json.item(c, 1)), &output, format)
            case "Cite":
                self.inlines(Json.array(Json.item(c, 1)), &output, format)
            case "Quoted":
                let single = Json.type(Json.item(c, 0)) == "SingleQuote"
                output.append(HText(single ? "‘" : "“", format))
                self.inlines(Json.array(Json.item(c, 1)), &output, format)
                output.append(HText(single ? "’" : "”", format))
            case "Code":
                output.append(HText(Json.string(Json.item(c, 1)) ?? "", format))
            case "Math":
                changed.italic = true
                output.append(HText(Json.string(Json.item(c, 1)) ?? "", changed))
            case "Link":
                let link = HLink(Json.string(Json.item(Json.item(c, 2), 0)) ?? "")
                self.inlines(Json.array(Json.item(c, 1)), &link.content, format)
                output.append(link)
            case "Image":
                if let image = image(c) { output.append(image) }
            case "Note":
                let note = HNote(false)
                blocks(Json.array(c), &note.blocks, Context())
                output.append(note)
            default:
                break // RawInline: format-specific markup, nothing to show.
            }
        }
    }

    private func image(_ content: Any?) -> HImage? {
        // [attr [id, classes, [[key, value]]], caption inlines, [target, title]]
        guard let path = resolveImage(Json.string(Json.item(Json.item(content, 2), 0)) ?? ""), FileManager.default.fileExists(path) else {
            return nil // missing image: skip rather than produce a broken reference
        }
        var attributes: [String: String?] = [:]
        for pair in Json.array(Json.item(Json.item(content, 0), 2)) ?? [] {
            guard let entry = pair as? [Any], entry.count == 2 else { continue }
            let key = Json.string(entry[0]) ?? ""
            if attributes[key] == nil { attributes[key] = .some(Json.string(entry[1])) }
        }
        let image = HImage(path)
        image.width = HwpxUnits.parseLength(attributes["width"] ?? nil)
        image.height = HwpxUnits.parseLength(attributes["height"] ?? nil)
        return image
    }

    // MARK: Helpers

    private static func title(_ meta: Any?) -> String? {
        let title = Json.member(meta, "title")
        switch Json.type(title) {
        case "MetaInlines": return plainText(Json.array(Json.member(title, "c")))
        case "MetaString": return Json.string(Json.member(title, "c"))
        default: return nil
        }
    }

    private static func plainText(_ inlines: [Any]?) -> String {
        var text = ""
        for inline in inlines ?? [] {
            let c = Json.member(inline, "c")
            switch Json.type(inline) {
            case "Str": text += Json.string(c) ?? ""
            case "Space", "SoftBreak", "LineBreak": text += " "
            case "Code", "Math": text += Json.string(Json.item(c, 1)) ?? ""
            case "Link", "Image", "Span", "Cite": text += plainText(Json.array(Json.item(c, 1)))
            case "Quoted": text += "\"" + plainText(Json.array(Json.item(c, 1))) + "\""
            case "Strong", "Emph", "Underline", "Strikeout", "Superscript", "Subscript", "SmallCaps": text += plainText(Json.array(c))
            default: break
            }
        }
        return text
    }

    /// Reading `JSONSerialization` values like `System.Text.Json.Nodes` (missing members and items are nil).
    private enum Json {
        static func member(_ node: Any?, _ name: String) -> Any? { (node as? [String: Any])?[name] }

        static func item(_ node: Any?, _ index: Int) -> Any? {
            guard let array = node as? [Any], index >= 0, index < array.count else { return nil }
            return array[index]
        }

        static func array(_ node: Any?) -> [Any]? { node as? [Any] }
        static func string(_ node: Any?) -> String? { node as? String }

        static func int(_ node: Any?) -> Int? {
            guard let number = node as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.intValue
        }

        static func double(_ node: Any?) -> Double? {
            guard let number = node as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }

        /// The "t" of a JSON object, "" otherwise.
        static func type(_ node: Any?) -> String { string(member(node, "t")) ?? "" }
    }
}
