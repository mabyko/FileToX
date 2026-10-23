// Port of HwpxWriter.Layout.cs. Cached measurements use UTF-16 code units as in Filee.
import Foundation

extension HwpxWriter {
    static func textWidth(_ text: String, _ size: Int) -> Double {
        var width = 0.0
        for c in text.utf16 {
            let advance: Double
            switch c {
            case 32, 160, 46, 44, 58, 59, 39, 33, 124, 40, 41, 91, 93, 45: advance = 0.3
            case 0x2000...0x206F: advance = 0.5
            case 0x1100...0xFFFF: advance = 0.92
            case 48...57: advance = 0.55
            case 65...90: advance = 0.65
            default: advance = 0.5
            }
            width += advance * Double(size)
        }
        return width
    }
    // Called per paragraph: firstDescendant stops at the match like C#'s lazy LINQ (the eager walk was quadratic).
    func baseSize(_ id: String) -> Int {
        DocumentXML.int(
            head.firstDescendant(Self.hh + "charPr") { $0.attributeValue("id") == id }?.attributeValue("height"))
            ?? 1000
    }
    func basePercent(_ id: String) -> Int {
        let line = head.firstDescendant(Self.hh + "paraPr") { $0.attributeValue("id") == id }?.firstDescendant(
            Self.hh + "lineSpacing")
        return line?.attributeValue("type") == "PERCENT" ? DocumentXML.int(line?.attributeValue("value")) ?? 160 : 160
    }
    func estimateHeight(_ blocks: [HBlock], _ width: Int) -> Int {
        var result = 0
        for b in blocks {
            if let p = b as? HParagraph {
                result += estimateHeight(p, width)
            } else if let t = b as? HTable {
                let (placed, c) = Self.placeCells(t)
                result += estimateRowHeights(t, placed, Self.columnWidths(t, c, width)).reduce(0, +)
            }
        }
        return result
    }
    func estimateHeight(_ p: HParagraph, _ width: Int) -> Int {
        let ids = headings[p.headingLevel] ?? base
        let size = Self.largestSize(p.inlines) ?? p.markFormat.size ?? baseSize(ids.char)
        let line: Int
        if let ls = p.format.lineSpacing {
            switch ls.kind {
            case .fixed: line = ls.value
            case .atLeast: line = max(ls.value, size * 13 / 10)
            case .percent: line = size * ls.value / 100
            }
        } else {
            line = size * basePercent(ids.para) / 100
        }
        let available = max(1000, width - (p.format.left ?? 0) - (p.format.right ?? 0))
        var lines = 0
        var current = Double(max(0, p.format.firstLine ?? 0))
        var objects = 0
        func measure(_ list: [HInline]) {
            for i in list {
                switch i {
                case let t as HText: current += Self.textWidth(t.text, t.format.size ?? size)
                case is HTab: current += 4000
                case is HLineBreak:
                    lines += Self.linesFor(current, available)
                    current = 0
                case let l as HLink: measure(l.content)
                case let image as HImage where image.anchor == nil: objects += image.height ?? 0
                case let box as HTextBox where box.anchor == nil: objects += box.height
                default: break
                }
            }
        }
        measure(p.inlines)
        lines += Self.linesFor(current, available)
        return lines * line + objects + (p.format.before ?? 0) + (p.format.after ?? 0)
    }
    static func linesFor(_ width: Double, _ available: Int) -> Int {
        max(1, Int(ceil(width / (Double(available) * 1.05))))
    }
    static func largestSize(_ list: [HInline]) -> Int? {
        list.compactMap { i in (i as? HText)?.format.size ?? (i as? HLink).flatMap { largestSize($0.content) } }.filter
        { $0 > 0 }.max()
    }
    func estimateRowHeights(_ table: HTable, _ placed: [[(cell: HCell, column: Int)]], _ widths: [Int]) -> [Int] {
        let margin = table.cellMargin ?? HInsets(510, 510, 141, 141)
        var heights = table.rows.map { max($0.height ?? 0, 0) }
        for pass in 0..<2 {
            for (r, row) in placed.enumerated() {
                for (cell, column) in row {
                    if (pass == 0) != (cell.rowSpan == 1) { continue }
                    let w = widths.dropFirst(column).prefix(cell.colSpan).reduce(0, +)
                    let needed =
                        estimateHeight(
                            cell.blocks.isEmpty ? [HParagraph()] : cell.blocks,
                            max(1000, w - margin.left - margin.right)) + margin.top + margin.bottom
                    let last = min(r + cell.rowSpan, heights.count) - 1
                    let have = heights[r...max(r, last)].reduce(0, +)
                    if needed > have { heights[max(r, last)] += needed - have }
                }
            }
        }
        return heights.map { max($0, 282) }
    }
    static func tabElements(_ p: HParagraph, _ size: Int) -> [String] {
        var result: [String] = []
        let stops = p.format.tabs ?? []
        let left = p.format.left ?? 0
        var x = Double(left + (p.format.firstLine ?? 0))
        var pieces: [(HInline, Double)] = []
        func flatten(_ list: [HInline]) {
            for i in list {
                if let l = i as? HLink {
                    flatten(l.content)
                } else {
                    pieces.append((i, (i as? HText).map { textWidth($0.text, $0.format.size ?? size) } ?? 0))
                }
            }
        }
        flatten(p.inlines)
        for (i, piece) in pieces.enumerated() {
            if piece.0 is HText {
                x += piece.1
            } else if piece.0 is HLineBreak {
                x = Double(left)
            } else if piece.0 is HTab {
                var following = 0.0
                var j = i + 1
                while j < pieces.count && !(pieces[j].0 is HTab) && !(pieces[j].0 is HLineBreak) {
                    following += pieces[j].1
                    j += 1
                }
                let type: Int
                let leader: Int
                let target: Double
                if let stop = stops.first(where: { Double($0.position) > x + 1 }) {
                    switch stop.kind {
                    case .right:
                        type = 2
                        target = Double(stop.position) - following
                    case .center:
                        type = 3
                        target = Double(stop.position) - following / 2
                    case .decimal:
                        type = 4
                        target = Double(stop.position) - following
                    default:
                        type = 1
                        target = Double(stop.position)
                    }
                    leader = ["SOLID": 1, "DOT": 2, "DASH": 3][stop.leader] ?? 0
                } else {
                    type = 1
                    leader = 0
                    target = (floor(x / 4000) + 1) * 4000
                }
                let w = max(0, Int(target - x))
                result.append("<hp:tab width=\"\(w)\" leader=\"\(leader)\" type=\"\(type)\"/>")
                x += Double(w)
            }
        }
        return result
    }
}
