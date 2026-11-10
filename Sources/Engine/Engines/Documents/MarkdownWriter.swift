// Port of Filee's MarkdownWriter.cs: the dialect read by MarkdownReader.
import Foundation

final class MarkdownWriter {
    private let imageTarget: (String) -> String?
    private var notes: [String] = []
    private let numbers = ListNumbers()
    private init(_ imageTarget: @escaping (String) -> String?) { self.imageTarget = imageTarget }
    static func write(_ document: HDocument, _ imageTarget: @escaping (String) -> String?) -> String {
        let w = MarkdownWriter(imageTarget)
        var output = ""
        if let title = document.title, !DocumentXML.trim(title).isEmpty {
            output += "---\ntitle: \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\"\n---\n\n"
        }
        for section in document.sections { w.blocks(HDocumentWalker.flowBlocks(section), &output, "") }
        for (i, note) in w.notes.enumerated() { output += "\n[^\(i + 1)]: \(note)\n" }
        return DocumentXML.trimEnd(output) + "\n"
    }
    private func blocks(_ blocks: [HBlock], _ output: inout String, _ prefix: String) {
        var i = 0
        var listLevels: [Int] = []
        while i < blocks.count {
            if let item = (blocks[i] as? HParagraph)?.list {
                while let last = listLevels.last, last > item.level { listLevels.removeLast() }
                if listLevels.last != item.level { listLevels.append(item.level) }
            } else { listLevels = [] }
            if let p = blocks[i] as? HParagraph, isCode(p) {
                var lines: [String] = []
                while i < blocks.count, let code = blocks[i] as? HParagraph, isCode(code) {
                    lines.append(code.inlines.compactMap { ($0 as? HText)?.text }.joined())
                    i += 1
                }
                let fence = lines.contains { $0.contains("```") } ? "~~~~" : "```"
                output += prefix + fence + "\n" + lines.map { prefix + $0 + "\n" }.joined() + prefix + fence + "\n\n"
                continue
            } else if let p = blocks[i] as? HParagraph {
                paragraph(p, &output, prefix, i + 1 < blocks.count ? blocks[i + 1] : nil,
                          max(0, listLevels.count - 1), i > 0 && (blocks[i - 1] as? HParagraph)?.list != nil)
            } else if let t = blocks[i] as? HTable {
                table(t, &output, prefix)
            }
            i += 1
        }
    }
    private func isCode(_ p: HParagraph) -> Bool {
        p.list == nil && p.headingLevel == 0 && !p.inlines.isEmpty
            && p.inlines.allSatisfy { ($0 as? HText)?.format.shade == HtmlReader.codeShade }
    }
    private func paragraph(_ p: HParagraph, _ output: inout String, _ prefix: String, _ next: HBlock?, _ listDepth: Int,
                           _ allowContinuation: Bool) {
        let text = inlines(p.inlines)
        if p.inlines.contains(where: { ($0 as? HShape)?.kind == .line }), DocumentXML.trim(text).isEmpty {
            output += prefix + "---\n\n"
            return
        }
        if DocumentXML.trim(text).isEmpty { return }
        let quote = p.list == nil ? String(repeating: "> ", count: max(0, p.format.left ?? 0) / 2000) : ""
        let lead = prefix + quote
        if p.headingLevel > 0 {
            output +=
                lead + String(repeating: "#", count: min(max(p.headingLevel, 1), 6)) + " "
                + (text.utf8.contains(0x0A) ? text.replacingOccurrences(of: "\\\n", with: " ") : text) + "\n\n"
            return
        }
        if let list = p.list, list.numbered || allowContinuation {
            let indent = String(repeating: " ", count: listDepth * 4)
            let bullet =
                list.numbering.levels.isEmpty
                || list.numbering.levels[min(list.level, list.numbering.levels.count - 1)].bullet
            var marker = ""
            if list.numbered {
                if bullet {
                    marker = "- "
                } else {
                    let level = list.numbering.levels[min(list.level, list.numbering.levels.count - 1)]
                    let digits = numbers.next(list).filter { $0.isASCII && $0.isNumber }
                    marker = (level.format == "DIGIT" && !digits.isEmpty ? digits : "1") + ". "
                }
            }
            let continuation =
                lead + indent + String(repeating: " ", count: max(marker.utf16.count, list.numbered ? 0 : 4))
            output +=
                (list.numbered ? lead + indent + marker : continuation)
                + Self.replacingNewlines(text, "\n" + continuation) + "\n"
            if (next as? HParagraph)?.list == nil { output += "\n" }
            return
        }
        output += lead + Self.replacingNewlines(Self.escapeLineStart(text), "\n" + lead) + "\n\n"
    }
    private func table(_ t: HTable, _ output: inout String, _ prefix: String) {
        blocks(t.caption, &output, prefix)
        guard !t.rows.isEmpty else { return }
        let columns = max(t.columnCount, t.rows.map { $0.cells.reduce(0) { $0 + $1.colSpan } }.max() ?? 0)
        var grid: [[String]] = []
        var covered = Set<String>()
        for (r, row) in t.rows.enumerated() {
            var cells = [String](repeating: "", count: columns)
            var column = 0
            for cell in row.cells {
                while column < columns && covered.contains("\(r),\(column)") { column += 1 }
                if column >= columns { break }
                cells[column] = cellText(cell.blocks, row.header)
                    .replacingOccurrences(of: "|", with: "\\|")
                for rr in r..<(r + cell.rowSpan) {
                    for cc in column..<min(columns, column + cell.colSpan) { covered.insert("\(rr),\(cc)") }
                }
                column += cell.colSpan
            }
            grid.append(cells)
        }
        output +=
            prefix + "| " + grid[0].joined(separator: " | ") + " |\n" + prefix + "|"
            + String(repeating: "---|", count: columns) + "\n"
        for row in grid.dropFirst() { output += prefix + "| " + row.joined(separator: " | ") + " |\n" }
        output += "\n"
    }
    private func cellText(_ blocks: [HBlock], _ header: Bool = false) -> String {
        blocks.map { block -> String in
            if let p = block as? HParagraph {
                let list = p.inlines.map { i -> HInline in
                    if header, let text = i as? HText, !(i is HEquation) {
                        var f = text.format
                        f.bold = nil
                        return HText(text.text, f)
                    }
                    return i
                }
                return inlines(list).replacingOccurrences(of: "\\\n", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>")
            }
            if let t = block as? HTable {
                return ([cellText(t.caption)] + t.rows.map { row in
                    row.cells.map { cellText($0.blocks, row.header) }.joined(separator: " / ")
                }).filter { !$0.isEmpty }.joined(separator: "<br>")
            }
            return ""
        }.filter { !$0.isEmpty }.joined(separator: "<br>")
    }
    private func inlines(_ list: [HInline]) -> String {
        var text = ""
        var previousEquation = false
        for item in list {
            defer { previousEquation = item is HEquation }
            switch item {
            case let e as HEquation:
                if previousEquation { text += " " }
                if e.latex.isEmpty {
                    text += e.text.isEmpty ? e.fallback : Self.run(e.text, HCharFormat(shade: HtmlReader.codeShade))
                } else {
                    let delimiter = e.display ? "$$" : "$"
                    text += delimiter + e.latex + delimiter
                }
            case let t as HText: text += Self.run(t.text, t.format)
            case is HLineBreak: text += "\\\n"
            case is HTab: text += "    "
            case let l as HLink:
                let content = inlines(l.content)
                text +=
                    l.target.hasPrefix("#") || DocumentXML.trim(content).isEmpty
                    ? content : "[\(content)](<\(l.target)>)"
            case let image as HImage: if let target = imageTarget(image.path) { text += "![](<\(target)>)" }
            case let note as HNote:
                var content = ""
                blocks(note.blocks, &content, "")
                notes.append(DocumentXML.trim(content).replacingOccurrences(of: "\n\n", with: "\n    "))
                text += "[^\(notes.count)]"
            case let box as HTextBox:
                text += cellText(box.blocks)
            default: break
            }
        }
        return text
    }
    private static func run(_ text: String, _ f: HCharFormat) -> String {
        let trimmed = DocumentXML.trim(text)
        if trimmed.isEmpty { return text }
        if f.shade == HtmlReader.codeShade { return text.contains("`") ? "`` \(text) ``" : "`\(text)`" }
        var core = escape(trimmed)
        let lead = String(text.prefix(while: { $0.isWhitespace }))
        let trail = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
        if f.superscript == true {
            core = "^" + core.replacingOccurrences(of: " ", with: "\\ ") + "^"
        } else if f.subscript == true {
            core = "~" + core.replacingOccurrences(of: " ", with: "\\ ") + "~"
        }
        if f.strike == true { core = "~~\(core)~~" }
        if f.italic == true { core = "*\(core)*" }
        if f.bold == true { core = "**\(core)**" }
        if f.shade == HtmlReader.markShade { core = "==\(core)==" }
        return lead + core + trail
    }
    private static let escaped: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "~", "^", "|", "="]
    private static let escapedBytes: Set<UInt8> = Set("\\`*_[]<>~^|=".utf8)
    private static func escape(_ text: String) -> String {
        // Per Character, like the original map/joined: a mark attached to one of these characters leaves it alone.
        // Non-ASCII can canonically equal an escaped ASCII character (U+1FEF equals a backtick).
        guard text.utf8.contains(where: { $0 >= 0x80 || escapedBytes.contains($0) }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count + 8)
        for character in text {
            if escaped.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
    /// `replacingOccurrences(of: "\n", with: replacement)`, skipping Foundation when there is no line break.
    private static func replacingNewlines(_ text: String, _ replacement: String) -> String {
        text.utf8.contains(0x0A) ? text.replacingOccurrences(of: "\n", with: replacement) : text
    }
    private static func escapeLineStart(_ text: String) -> String {
        let t = String(text.drop(while: { $0.isWhitespace }))
        if t.hasPrefix("#") || t.hasPrefix("- ") || t.hasPrefix("+ ") { return "\\" + t }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, let next = t.dropFirst(digits.count).first, next == "." || next == ")" {
            return digits + "\\" + t.dropFirst(digits.count)
        }
        return text
    }
}
