// Port of Filee.Engines/Ebooks/PlainText.cs.
import Foundation

enum PlainText {
    static func toDocument(_ text: String) -> HDocument {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var paragraphs: [[String]] = [], current: [String] = []
        let hasEmptyLines = lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasEmptyLines {
                if !current.isEmpty { paragraphs.append(current) }; current = []
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            }
            current.append(String(line.reversed().drop(while: \.isWhitespace).reversed()))
        }
        if !current.isEmpty { paragraphs.append(current) }
        let multiLine = paragraphs.filter { $0.count > 1 }.flatMap { $0.dropLast() }
        let wrapped = !multiLine.isEmpty && Double(multiLine.filter { (50...100).contains($0.utf16.count) }.count) > Double(multiLine.count) * 0.7
        let section = HSection()
        for paragraph in paragraphs {
            let p = HParagraph()
            for i in paragraph.indices {
                if i > 0 { p.inlines.append(wrapped ? HText(" ") : HLineBreak()) }
                p.inlines.append(HText(i > 0 && wrapped ? String(paragraph[i].drop(while: \.isWhitespace)) : paragraph[i]))
            }
            HtmlReader.mergeRuns(&p.inlines)
            section.blocks.append(p)
        }
        let document = HDocument(); document.sections.append(section)
        return document
    }
}
