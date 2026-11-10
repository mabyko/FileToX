// Port of Filee.Engines/Pdf/PdfDocumentReader.Layout.cs: page layout analysis for PdfDocumentReader: words → lines
// (split at column gutters) → paragraphs → reading order.
//
// Reading order handles the usual layouts: one column; two or three columns, with titles, figures or footers that span
// the columns in between. A gutter is a vertical strip that no narrow paragraph crosses while text sits next to it on
// both sides; paragraphs wider than a column (or crossing a gutter) separate the page into bands read one after the
// other, and inside a band the columns are read left to right.

import Foundation

extension PdfDocumentReader {
    /// Line starts that begin a new paragraph: bullets and "1." / "a)" / "(3)" numbers.
    private static let listStart = try! NSRegularExpression(
        pattern: "^([•◦▪▫●○■□‣⁃∙·\\-–—*]|\\(?\\d{1,3}[.)]|\\(?[a-zA-Z][.)]|[ivxIVX]{1,4}[.)]|[①-⑳]|[가-하][.)])$")

    // ───────────────────────── Lines ─────────────────────────

    /// Groups words on a common baseline into lines, top to bottom, and splits a line where the gap between two words
    /// is much wider than a space (a column gutter or a tab stop far away).
    static func lines(_ words: [TextWord]) -> [TextLine] {
        var rows: [[TextWord]] = []
        let ordered = words.enumerated().sorted { a, b in
            a.element.baseline != b.element.baseline ? a.element.baseline > b.element.baseline
                : a.element.left != b.element.left ? a.element.left < b.element.left : a.offset < b.offset
        }.map(\.element)
        for word in ordered {
            // Words belong to a recent row whose baseline is close; smaller superscripts sit a little higher.
            var row: Int?
            var r = rows.count - 1
            while r >= max(0, rows.count - 3) && row == nil {
                let first = rows[r][0]
                let tolerance = 0.5 * min(first.size, word.size)
                if abs(first.baseline - word.baseline) <= tolerance || (word.bottom < first.top && word.top > first.baseline && word.size < first.size * 0.8) {
                    row = r
                }
                r -= 1
            }
            if let row { rows[row].append(word) } else { rows.append([word]) }
        }

        // A space is about a quarter of the font size; the median gap between words of a line tells the page's spacing.
        var gaps: [Double] = []
        for r in rows.indices {
            rows[r] = rows[r].enumerated().sorted { $0.element.left != $1.element.left ? $0.element.left < $1.element.left : $0.offset < $1.offset }
                .map(\.element)
            for i in rows[r].indices.dropFirst() { gaps.append(rows[r][i].left - rows[r][i - 1].right) }
        }
        let space = gaps.isEmpty ? 3 : max(0.5, median(gaps.filter { $0 > 0 }))

        var lines: [TextLine] = []
        for (r, row) in rows.enumerated() {
            var current = [row[0]]
            for i in row.indices.dropFirst() {
                let gap = row[i].left - row[i - 1].right
                let size = min(row[i].size, row[i - 1].size)
                if gap > max(5 * space, 1.5 * size) {
                    lines.append(TextLine(current, r))
                    current = []
                }
                current.append(row[i])
            }
            lines.append(TextLine(current, r))
        }
        return lines
    }

    /// Joins the parts of a split row again, with a tab between them, where no column gutter lies between the parts and
    /// the gap is a tab: after a list number ("1."), wider than a column gutter with a ragged line end (6 em), or at the
    /// same place as a tab in a row right above or below (the value column of a form, whatever the label's length).
    /// "1.  RFP Published   08/14/2026" stays one row instead of three paragraphs. Nil when no row changes.
    static func joinTabbedRows(_ lines: [TextLine], _ items: [Item]) -> [TextLine]? {
        var rows: [[TextLine]] = []
        var rowOf: [Int: Int] = [:]
        for line in lines {
            if let index = rowOf[line.row] { rows[index].append(line) } else { rowOf[line.row] = rows.count; rows.append([line]) }
        }
        if items.isEmpty || rows.allSatisfy({ $0.count == 1 }) { return nil }
        let gutters = gutters(items, items.map(\.left).min()!, items.map(\.right).max()!)

        // Gaps that may be tabs: (row, index of the part after the gap, where that part starts).
        struct Key: Hashable { let row: Int, part: Int }
        var candidates: [(row: Int, part: Int, x: Double)] = []
        var tabs = Set<Key>()
        for row in rows {
            for p in row.indices.dropFirst() {
                let (before, after) = (row[p - 1], row[p])
                if gutters.contains(where: { $0.start >= before.right - 2 && $0.end <= after.left + 2 }) { continue }
                candidates.append((before.row, p, after.left))
                let number = before.words.count == 1 && isMatch(listStart, before.words[0].text)
                if number || after.left - before.right > 6 * max(before.size, after.size) { tabs.insert(Key(row: before.row, part: p)) }
            }
        }
        if tabs.isEmpty { return nil }
        var grown = true
        while grown {
            grown = false
            for (row, part, x) in candidates where !tabs.contains(Key(row: row, part: part)) {
                if candidates.contains(where: { tabs.contains(Key(row: $0.row, part: $0.part)) && abs($0.row - row) <= 2 && abs($0.x - x) <= 1.5 }) {
                    grown = tabs.insert(Key(row: row, part: part)).inserted || grown
                }
            }
        }

        var result: [TextLine] = []
        for row in rows {
            var current = row[0]
            for p in row.indices.dropFirst() {
                if tabs.contains(Key(row: current.row, part: p)) {
                    let joined = TextLine(current.words + row[p].words, current.row)
                    joined.tabs = current.tabs + [current.words.count]
                    current = joined
                } else {
                    result.append(current)
                    current = row[p]
                }
            }
            result.append(current)
        }
        return result
    }

    // ───────────────────────── Paragraphs ─────────────────────────

    /// Stacks lines into paragraphs. A line continues the paragraph right above it when it is close below (at most about
    /// one line pitch), overlaps it horizontally and has a similar size, unless it starts a new paragraph: a bullet or
    /// number, a first-line indent, or a previous line that ended early (its next word would have fit).
    static func paragraphs(_ lines: [TextLine]) -> [Item] {
        var items: [Item] = []
        for line in lines {
            var best: Item?
            var bestDistance = Double.greatestFiniteMagnitude
            for item in items {
                if !line.tabs.isEmpty { break } // a tabbed row starts its own paragraph
                let last = item.lines[item.lines.count - 1]
                // A tabbed row continues only with text under its last part (the wrapped text of "1.  Text …").
                let head = item.lines[0]
                if !head.tabs.isEmpty && abs(line.left - head.words[head.tabs[head.tabs.count - 1]].left) > 0.5 * line.size { continue }
                let distance = last.baseline - line.baseline
                let size = max(last.size, line.size)
                if distance <= 0 || distance > 1.9 * size || abs(last.size - line.size) > 0.2 * size { continue }
                if item.lines.count >= 2 && distance > 1.3 * pitch(item) { continue } // more space than between the lines so far
                let overlap = min(item.right, line.right) - max(item.left, line.left)
                if overlap < 0.3 * min(item.width, line.right - line.left) { continue }
                if distance < bestDistance { (best, bestDistance) = (item, distance) }
            }

            if let best, !startsParagraph(best, line) {
                best.lines.append(line)
            } else {
                let item = Item()
                item.lines.append(line)
                items.append(item)
            }
        }
        return items
    }

    private static func startsParagraph(_ item: Item, _ line: TextLine) -> Bool {
        let last = item.lines[item.lines.count - 1]
        let em = line.size
        if isMatch(listStart, line.words[0].text) { return true }

        // First-line indent: this line starts further right than the paragraph's other lines.
        let bodyLeft = item.lines.count > 1 ? item.lines.dropFirst().map(\.left).min()! : last.left
        let listItem = isMatch(listStart, item.lines[0].words[0].text) || !item.lines[0].tabs.isEmpty
        if line.left > bodyLeft + 0.8 * em && !listItem && (item.lines.count > 1 || line.left > last.left + 0.8 * em) { return true }

        // The previous line ended although the next word would have fitted: the paragraph ended there.
        let right = max(item.right, line.right)
        let firstWord = line.words[0].right - line.words[0].left
        return last.right + 0.3 * em + firstWord < right - 0.5 * em && right - item.left > 10 * em
    }

    // ───────────────────────── Reading order ─────────────────────────

    /// Orders a page's paragraphs and pictures for reading and sets the column each one sits in.
    static func readingOrder(_ items: [Item]) -> [Item] {
        if items.isEmpty { return items }
        let areaLeft = items.map(\.left).min()!
        let areaRight = items.map(\.right).max()!
        for item in items { (item.containerLeft, item.containerRight) = (areaLeft, areaRight) }

        let gutters = gutters(items, areaLeft, areaRight)
        if gutters.isEmpty {
            return stableSorted(items) { a, b in a.top != b.top ? (a.top > b.top ? -1 : 1) : (a.left < b.left ? -1 : a.left > b.left ? 1 : 0) }
        }

        // Column bounds between the gutters.
        var edges = [areaLeft]
        for gutter in gutters { edges += [gutter.start, gutter.end] }
        edges.append(areaRight)
        func columnOf(_ item: Item) -> Int {
            let center = (item.left + item.right) / 2
            for c in 0..<edges.count / 2 where center <= edges[2 * c + 1] + 1 { return c }
            return edges.count / 2 - 1
        }
        func spans(_ item: Item) -> Bool { gutters.contains { item.left < $0.start - 1 && item.right > $0.end + 1 } }

        let columnItems = items.filter { !spans($0) }
        for item in columnItems {
            let column = columnOf(item)
            let members = columnItems.filter { columnOf($0) == column }
            (item.containerLeft, item.containerRight) = (members.map(\.left).min()!, members.map(\.right).max()!)
        }

        // Spanning items split the page into bands; each band is read column by column.
        func byColumn(_ list: [Item]) -> [Item] {
            stableSorted(list) { a, b in
                let (ca, cb) = (columnOf(a), columnOf(b))
                return ca != cb ? (ca < cb ? -1 : 1) : (a.top > b.top ? -1 : a.top < b.top ? 1 : 0)
            }
        }
        var result: [Item] = []
        var remaining = columnItems
        for separator in stableSorted(items.filter(spans), { a, b in a.top > b.top ? -1 : a.top < b.top ? 1 : 0 }) {
            let above = remaining.filter { $0.top > separator.top }
            result += byColumn(above)
            remaining.removeAll { item in above.contains { $0 === item } }
            result.append(separator)
        }
        result += byColumn(remaining)
        return result
    }

    /// LINQ OrderBy/ThenBy: a stable sort with a three-way comparison.
    private static func stableSorted(_ items: [Item], _ compare: (Item, Item) -> Int) -> [Item] {
        items.enumerated().sorted { a, b in
            let order = compare(a.element, b.element)
            return order != 0 ? order < 0 : a.offset < b.offset
        }.map(\.element)
    }

    /// Vertical strips between columns: no narrow item crosses them, text lies on both sides next to each other over
    /// several lines, and the strip is at least a few points wide.
    static func gutters(_ items: [Item], _ left: Double, _ right: Double) -> [(start: Double, end: Double)] {
        let width = right - left
        let narrow = items.filter { $0.width < width * 0.6 }
        if narrow.count < 2 || width < 100 { return [] }

        let bin = 2.0
        let bins = Int((width / bin).rounded(.up))
        var covered = [Bool](repeating: false, count: bins)
        for item in narrow {
            var b = max(0, Int((item.left - left) / bin))
            while b < min(bins, Int(((item.right - left) / bin).rounded(.up))) {
                covered[b] = true
                b += 1
            }
        }

        var gutters: [(start: Double, end: Double)] = []
        var b = 0
        while b < bins {
            if covered[b] {
                b += 1
                continue
            }
            let start = b
            while b < bins && !covered[b] { b += 1 }
            let (gapLeft, gapRight) = (left + Double(start) * bin, left + Double(b) * bin)
            if start == 0 || b >= bins || gapRight - gapLeft < 6 { continue }

            // Real columns: both sides hold a good share of the page's text height (a heading and a date on one line do
            // not), with text next to each other over a few lines.
            let leftSide = narrow.filter { $0.right <= gapLeft + 1 }
            let rightSide = narrow.filter { $0.left >= gapRight - 1 }
            let textHeight = max(1, (items.map(\.top).max()! - items.map(\.bottom).min()!) * 0.2)
            func height(_ side: [Item]) -> Double { side.reduce(0) { $0 + $1.top - $1.bottom } }
            func lineCount(_ side: [Item]) -> Int { side.reduce(0) { $0 + max(1, $1.lines.count) } }
            let overlapping = leftSide.contains { l in rightSide.contains { r in min(l.top, r.top) - max(l.bottom, r.bottom) > 2 * max(l.size, r.size) } }
            if height(leftSide) >= textHeight && height(rightSide) >= textHeight && lineCount(leftSide) >= 3 && lineCount(rightSide) >= 3 && overlapping {
                gutters.append((gapLeft, gapRight))
            }
        }
        return gutters
    }
}
