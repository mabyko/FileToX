// Ports of HDocumentWalker.cs and HwpxUnits.cs (Filee 21fdd05).
import Foundation

enum HDocumentWalker {
    /// Text exports show each header at its definition, and footers after the body.
    static func flowBlocks(_ section: HSection) -> [HBlock] {
        var result: [HBlock] = []
        let headers = Dictionary(grouping: section.headers) { min(max(0, $0.startBlockIndex), section.blocks.count) }
        for i in 0...section.blocks.count {
            for header in headers[i] ?? [] { result += header.blocks }
            if i < section.blocks.count { result.append(section.blocks[i]) }
        }
        for footer in section.footers { result += footer.blocks }
        return result
    }
    static func inlines(_ blocks: [HBlock]) -> [HInline] {
        var result: [HInline] = []
        for block in blocks {
            if let p = block as? HParagraph {
                result += walk(p.inlines)
            } else if let t = block as? HTable {
                result += inlines(t.caption)
                for row in t.rows { for cell in row.cells { result += inlines(cell.blocks) } }
            }
        }
        return result
    }
    private static func walk(_ list: [HInline]) -> [HInline] {
        var result = list
        for item in list {
            if let link = item as? HLink {
                result += walk(link.content)
            } else if let note = item as? HNote {
                result += inlines(note.blocks)
            } else if let box = item as? HTextBox {
                result += inlines(box.blocks)
            }
        }
        return result
    }
    static func inlinesOf(_ list: [HInline]) -> [HInline] {
        list.flatMap { item in [item] + ((item as? HLink).map { inlinesOf($0.content) } ?? []) }
    }
    static func images(_ document: HDocument) -> [HImage] {
        document.sections.flatMap { inlines($0.blocks).compactMap { $0 as? HImage } }
    }
    static func text(_ list: [HInline]) -> String {
        inlinesOf(list).map { ($0 as? HText)?.text ?? (($0 is HLineBreak || $0 is HTab) ? " " : "") }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HwpxUnits {
    static let perMm = 7200 / 25.4
    static let perPixel = 75.0
    static func fromTwips(_ value: Double) -> Int { Int((value * 5).rounded(.toNearestOrEven)) }
    static func fromEmu(_ value: Double) -> Int { Int((value / 127).rounded(.toNearestOrEven)) }
    static func fromPoints(_ value: Double) -> Int { Int((value * 100).rounded(.toNearestOrEven)) }
    static func parseLength(_ value: String?) -> Int? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        let numberText = text.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let n = Double(numberText) else { return nil }
        let unit = text.dropFirst(numberText.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let mm: Double
        switch unit {
        case "in": mm = n * 25.4
        case "cm": mm = n * 10
        case "mm": mm = n
        case "pt": mm = n * 25.4 / 72
        case "pc": mm = n * 25.4 / 6
        case "emu": mm = n / 36000
        case "%": mm = n * 1.5
        default: mm = n * 25.4 / 96
        }
        return Int((mm * perMm).rounded(.toNearestOrEven))
    }
}

// Document-local helpers; shared foundation stays unchanged.
enum DocumentXML {
    static func isDigit(_ unit: UInt16) -> Bool { UnicodeScalar(unit)?.properties.generalCategory == .decimalNumber }
    static func isLetter(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }
    static func moveReplacing(_ source: String, _ target: String) throws {
        if rename(source, target) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func int(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    static func double(_ text: String?) -> Double? {
        text.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    static func set(_ node: XElement?, _ name: XName, _ value: Int) { node?.setAttributeValue(name, String(value)) }
    static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func trimEnd(_ text: String) -> String {
        String(text.reversed().drop(while: { $0.isWhitespace }).reversed())
    }
    static func guid() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func overlay(_ b: HCharFormat, _ f: HCharFormat) -> HCharFormat {
        HCharFormat(
            bold: f.bold ?? b.bold, italic: f.italic ?? b.italic, underline: f.underline ?? b.underline,
            strike: f.strike ?? b.strike,
            superscript: f.superscript ?? b.superscript, subscript: f.subscript ?? b.subscript, size: f.size ?? b.size,
            font: f.font ?? b.font,
            eastAsianFont: f.eastAsianFont ?? b.eastAsianFont, color: f.color ?? b.color, shade: f.shade ?? b.shade,
            spacing: f.spacing ?? b.spacing)
    }
    static func overlay(_ b: HParaFormat, _ f: HParaFormat) -> HParaFormat {
        HParaFormat(
            align: f.align ?? b.align, left: f.left ?? b.left, right: f.right ?? b.right,
            firstLine: f.firstLine ?? b.firstLine,
            before: f.before ?? b.before, after: f.after ?? b.after, lineSpacing: f.lineSpacing ?? b.lineSpacing,
            keepWithNext: f.keepWithNext ?? b.keepWithNext, keepLines: f.keepLines ?? b.keepLines,
            widowOrphan: f.widowOrphan ?? b.widowOrphan, tabs: f.tabs ?? b.tabs)
    }
}
