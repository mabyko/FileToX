// Stand-ins for APIs of the HWPX documents port (Filee Hwp/Hwpx/HwpxUnits.cs and HDocumentWalker.cs) that the
// Markup readers consume, under the names the cross-group naming rule gives them. They are faithful copies rather
// than throwing stubs because every reader needs them; delete this file when the documents group's port is merged.

import Foundation

enum HwpxUnits {
    static let perMm = 7200 / 25.4
    static let perPixel = 7200 / 96.0

    /// Parses a CSS-like length ("2in", "300px", "12pt", "50%") into HWPUNIT.
    static func parseLength(_ value: String?) -> Int? {
        guard let value, !value.allSatisfy(\.isWhitespace) else { return nil }
        let text = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars)
        var split = 0
        while split < text.count && (text[split].properties.generalCategory == .decimalNumber || text[split] == "." || text[split] == "-") {
            split += 1
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text[..<split])
        guard let number = Double(String(view)) else { return nil }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: text[split...])
        let mm: Double = switch String(rest).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "in": number * 25.4
        case "cm": number * 10
        case "mm": number
        case "pt": number * 25.4 / 72
        case "pc": number * 25.4 / 6
        case "emu": number / 36000
        case "%": number * 1.5 // % of a ~150 mm text width
        default: number * 25.4 / 96 // px or unitless
        }
        return MarkupConvert.int32((mm * perMm).rounded(.toNearestOrEven))
    }
}

enum HDocumentWalker {
    /// Every inline, depth first: the content of links, notes and text boxes follows them.
    static func inlines(_ blocks: [HBlock]) -> [HInline] {
        var result: [HInline] = []
        func walk(_ blocks: [HBlock]) {
            for block in blocks {
                if let paragraph = block as? HParagraph {
                    walk(paragraph.inlines)
                } else if let table = block as? HTable {
                    walk(table.caption)
                    for row in table.rows { for cell in row.cells { walk(cell.blocks) } }
                }
            }
        }
        func walk(_ inlines: [HInline]) {
            result += inlines
            for inline in inlines {
                if let link = inline as? HLink { walk(link.content) }
                else if let note = inline as? HNote { walk(note.blocks) }
                else if let box = inline as? HTextBox { walk(box.blocks) }
            }
        }
        walk(blocks)
        return result
    }

    /// The inlines of one paragraph with the content of its links (not notes or text boxes).
    static func inlinesOf(_ inlines: [HInline]) -> [HInline] {
        inlines.flatMap { inline -> [HInline] in
            if let link = inline as? HLink { return [inline] + inlinesOf(link.content) }
            return [inline]
        }
    }

    /// The visible text of a paragraph's inlines (links included, notes left out), line breaks as spaces.
    static func text(_ inlines: [HInline]) -> String {
        var text = ""
        for inline in inlinesOf(inlines) {
            if let run = inline as? HText { text += run.text }
            else if inline is HLineBreak || inline is HTab { text += " " }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
