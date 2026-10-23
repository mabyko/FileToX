// Port of PlainTextWriter.cs, including Filee's list counter and number formats.
import Foundation

enum PlainTextWriter {
    static func write(_ document: HDocument) -> String {
        let writer = State()
        let numbers = ListNumbers()
        var output = ""
        for section in document.sections { writer.blocks(section.blocks, &output, numbers) }
        if !writer.notes.isEmpty {
            output += "\n----\n"
            for (i, note) in writer.notes.enumerated() { output += "[\(i + 1)] \(note)\n" }
        }
        return DocumentXML.trimEnd(output) + "\n"
    }
    private final class State {
        var notes: [String] = []
        func blocks(_ blocks: [HBlock], _ output: inout String, _ numbers: ListNumbers) {
            var previous: HBlock?
            for block in blocks {
                if let p = block as? HParagraph {
                    var text = inlines(p.inlines)
                    if p.inlines.contains(where: { ($0 as? HShape)?.kind == .line }), text.isEmpty { text = "* * *" }
                    if DocumentXML.trim(text).isEmpty && p.list == nil { continue }
                    let before = previous as? HParagraph
                    let together =
                        before.map { ($0.list != nil && p.list != nil) || (isCode($0) && isCode(p)) } ?? false
                    if !output.isEmpty { output += "\n" }
                    if !output.isEmpty && !together { output += "\n" }
                    let indent = max(0, p.format.left ?? 0) / 1000
                    if let list = p.list {
                        let marker = list.numbered ? numbers.next(list) + " " : ""
                        output += String(repeating: " ", count: list.level * 4 + indent) + marker
                        output += text.replacingOccurrences(
                            of: "\n",
                            with: "\n" + String(repeating: " ", count: list.level * 4 + indent + marker.utf16.count))
                    } else {
                        output +=
                            String(repeating: " ", count: indent)
                            + (indent > 0
                                ? text.replacingOccurrences(
                                    of: "\n", with: "\n" + String(repeating: " ", count: indent)) : text)
                    }
                    previous = p
                } else if let t = block as? HTable, !t.rows.isEmpty {
                    if !output.isEmpty { output += "\n\n" }
                    output += t.rows.map { row in
                        row.cells.map { cell in
                            cell.blocks.compactMap { $0 as? HParagraph }.map {
                                inlines($0.inlines).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(
                                    of: "\t", with: " ")
                            }.filter { !$0.isEmpty }.joined(separator: " ")
                        }.joined(separator: "\t")
                    }.joined(separator: "\n")
                    previous = t
                }
            }
        }
        func isCode(_ p: HParagraph) -> Bool {
            !p.inlines.isEmpty && p.inlines.allSatisfy { ($0 as? HText)?.format.shade == HtmlReader.codeShade }
        }
        func inlines(_ list: [HInline]) -> String {
            var text = ""
            for item in list {
                switch item {
                case let t as HText: text += t.text
                case is HLineBreak: text += "\n"
                case is HTab: text += "\t"
                case let l as HLink: text += inlines(l.content)
                case let n as HNote:
                    var content = ""
                    blocks(n.blocks, &content, ListNumbers())
                    notes.append(DocumentXML.trim(content).replacingOccurrences(of: "\n\n", with: " "))
                    text += "[\(notes.count)]"
                case let b as HTextBox:
                    text += b.blocks.compactMap { $0 as? HParagraph }.map { inlines($0.inlines) }.joined(separator: " ")
                default: break
                }
            }
            return DocumentXML.trimEnd(text)
        }
    }
}

final class ListNumbers {
    private var counters: [ObjectIdentifier: [Int]] = [:]
    func next(_ item: HListRef) -> String {
        let levels = item.numbering.levels
        if levels.isEmpty { return "•" }
        let level = min(item.level, levels.count - 1)
        let definition = levels[min(item.level, levels.count - 1)]
        if definition.bullet { return definition.text.isEmpty ? "•" : definition.text }
        let key = ObjectIdentifier(item.numbering)
        var values = counters[key] ?? [Int](repeating: 0, count: max(10, levels.count))
        values[level] = values[level] == 0 ? definition.start : values[level] + 1
        for i in (level + 1)..<values.count { values[i] = 0 }
        counters[key] = values
        var text = definition.text
        for l in stride(from: min(9, levels.count), through: 1, by: -1) {
            text = text.replacingOccurrences(
                of: "^\(l)",
                with: Self.format(values[l - 1] == 0 ? levels[l - 1].start : values[l - 1], levels[l - 1].format))
        }
        return text
    }
    static func format(_ value: Int, _ format: String) -> String {
        switch format {
        case "LATIN_SMALL", "LATIN_CAPITAL":
            if value < 1 { return String(value) }
            var n = value
            var result = ""
            while n > 0 {
                result = String(UnicodeScalar((format == "LATIN_SMALL" ? 97 : 65) + (n - 1) % 26)!) + result
                n = (n - 1) / 26
            }
            return result
        case "ROMAN_SMALL", "ROMAN_CAPITAL":
            if !(1...3999).contains(value) { return String(value) }
            var n = value
            var result = ""
            for (v, s) in [
                (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
                (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
            ] {
                while n >= v {
                    result += s
                    n -= v
                }
            }
            return format == "ROMAN_SMALL" ? result.lowercased() : result
        case "HANGUL_SYLLABLE":
            return (1...14).contains(value) ? String(Array("가나다라마바사아자차카타파하")[value - 1]) : String(value)
        case "CIRCLED_DIGIT":
            return (1...20).contains(value) ? String(UnicodeScalar(0x2460 + value - 1)!) : String(value)
        default: return String(value)
        }
    }
}
