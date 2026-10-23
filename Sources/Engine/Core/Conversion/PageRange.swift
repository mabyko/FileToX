// Port of Filee.Core/Conversion/PageRange.cs: parses user page selections such as "1-3, 5, 8-".

import Foundation

public enum PageRange {
    /// Parses a 1-based page range expression into sorted, distinct zero-based page indices. Empty or whitespace means
    /// every page. Forms: "3", "2-5", "7-" (to the end), "-4" (from the start), comma separated. Invalid parts are
    /// ignored, out-of-range pages dropped; when nothing valid remains, every page.
    public static func parse(_ expression: String?, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        guard let expression, !expression.allSatisfy(\.isWhitespace) else { return Array(0..<pageCount) }

        var pages = Set<Int>()
        for raw in expression.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !raw.isEmpty {
            var start: Int, end: Int
            if let dash = raw.firstIndex(of: "-") {
                let left = raw[..<dash].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = raw[raw.index(after: dash)...].trimmingCharacters(in: .whitespacesAndNewlines)
                start = left.isEmpty ? 1 : (Int(left) ?? -1)
                end = right.isEmpty ? pageCount : (Int(right) ?? -1)
                if start < 0 || end < 0 { continue }
            } else {
                guard let page = Int(raw) else { continue }
                start = page
                end = page
            }
            if start > end { swap(&start, &end) }
            let first = max(1, start), last = min(pageCount, end)
            if first <= last { for page in first...last { pages.insert(page - 1) } }
        }
        return pages.isEmpty ? Array(0..<pageCount) : pages.sorted()
    }
}
