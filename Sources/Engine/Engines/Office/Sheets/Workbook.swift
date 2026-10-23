// Port of Filee.Engines/Office/Sheets/Workbook.cs: the in-memory spreadsheet between the readers (XLSX, XLS, ODS,
// CSV/TSV) and the writers (XLSX, ODS, CSV/TSV, HWPX tables). Cells hold the text as the spreadsheet shows it (numbers
// and dates already formatted) plus, for numbers, the value and its number format.

import Foundation

final class Workbook {
    var sheets: [Worksheet] = []
    init() {}
}

final class Worksheet {
    /// Excel's default column width, in characters of the default font.
    static let standardColumnWidth = 8.43

    let name: String
    /// Cells by 0-based row, then 0-based column. Only cells with a value or visible formatting.
    /// (Filee uses SortedDictionary; iterate with `sortedRows` / `sortedCells` for its order.)
    var rows: [Int: [Int: SheetCell]] = [:]
    /// Column widths in characters, for columns that set one.
    var columnWidths: [Int: Double] = [:]
    var defaultColumnWidth = Worksheet.standardColumnWidth
    /// Row heights in points, for rows with a custom height.
    var rowHeights: [Int: Double] = [:]
    var hiddenRows = Set<Int>()
    var hiddenColumns = Set<Int>()
    var merges: [CellRange] = []
    /// Rows frozen at the top (usually headers): repeated on every printed page.
    var frozenRows = 0

    init(_ name: String) { self.name = name }

    func set(_ row: Int, _ column: Int, _ cell: SheetCell) { rows[row, default: [:]][column] = cell }

    func get(_ row: Int, _ column: Int) -> SheetCell? { rows[row]?[column] }

    func columnWidth(_ column: Int) -> Double { columnWidths[column] ?? defaultColumnWidth }

    /// Rows in ascending order (SortedDictionary order).
    var sortedRows: [(row: Int, cells: [Int: SheetCell])] { rows.keys.sorted().map { ($0, rows[$0]!) } }

    /// Cells of one row in ascending column order.
    static func sortedCells(_ cells: [Int: SheetCell]) -> [(column: Int, cell: SheetCell)] { cells.keys.sorted().map { ($0, cells[$0]!) } }

    /// The smallest range holding every cell with text, fill or borders (merged areas included); nil for an empty sheet.
    func usedRange() -> CellRange? {
        var top = Int.max, left = Int.max, bottom = -1, right = -1
        for (row, cells) in rows {
            for (column, cell) in cells where cell.hasContent {
                top = min(top, row); bottom = max(bottom, row)
                left = min(left, column); right = max(right, column)
            }
        }
        if bottom < 0 { return nil }
        for merge in merges where merge.top <= bottom && merge.left <= right && merge.top >= top && merge.left >= left {
            bottom = max(bottom, merge.bottom)
            right = max(right, merge.right)
        }
        return CellRange(top, left, bottom, right)
    }
}

/// An inclusive, 0-based range of cells.
struct CellRange: Hashable {
    var top: Int, left: Int, bottom: Int, right: Int

    init(_ top: Int, _ left: Int, _ bottom: Int, _ right: Int) { self.top = top; self.left = left; self.bottom = bottom; self.right = right }

    func contains(_ row: Int, _ column: Int) -> Bool { row >= top && row <= bottom && column >= left && column <= right }

    /// Parses "B2" or "A1:C3" ($ signs ignored).
    static func parse(_ reference: String?) -> CellRange? {
        guard let reference, !reference.allSatisfy(\.isWhitespace) else { return nil }
        let parts = reference.replacingOccurrences(of: "$", with: "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let (r1, c1) = parseCell(parts[0]) else { return nil }
        if parts.count == 1 { return CellRange(r1, c1, r1, c1) }
        guard let (r2, c2) = parseCell(parts[1]) else { return nil }
        return CellRange(min(r1, r2), min(c1, c2), max(r1, r2), max(c1, c2))
    }

    /// "AB12" → (row 11, column 27); nil when it is no cell reference.
    static func parseCell(_ reference: String) -> (row: Int, column: Int)? {
        var column = 0
        var index = reference.startIndex
        var letters = 0
        while index < reference.endIndex, let ascii = reference[index].asciiValue, (65...90).contains(ascii) || (97...122).contains(ascii) {
            column = column * 26 + Int((ascii & 0xDF) - 65 + 1)
            index = reference.index(after: index)
            letters += 1
        }
        guard letters > 0, index < reference.endIndex, let row = Int(reference[index...]), row >= 1 else { return nil }
        return (row - 1, column - 1)
    }
}

enum CellAlign: Hashable { case general, left, center, right }

enum CellVerticalAlign: Hashable { case bottom, center, top }

/// One border side: Excel style name ("thin", "medium", "dashed", ...) and colour.
struct CellBorder: Hashable {
    var style: String
    var color: String?
    init(_ style: String, _ color: String?) { self.style = style; self.color = color }

    static let none = CellBorder("none", nil)
    var isVisible: Bool { style != "none" && !style.isEmpty }
}

struct CellStyle: Hashable {
    static let `default` = CellStyle()

    var bold = false
    var italic = false
    var underline = false
    var strike = false
    /// Font size in points; nil = the workbook default.
    var fontSize: Double?
    var color: String?
    var fill: String?
    var align = CellAlign.general
    var verticalAlign = CellVerticalAlign.bottom
    var wrap = false
    var left = CellBorder.none
    var right = CellBorder.none
    var top = CellBorder.none
    var bottom = CellBorder.none

    init() {}

    var hasBorders: Bool { left.isVisible || right.isVisible || top.isVisible || bottom.isVisible }
}

/// A cell as displayed: formatted text ("1,234.50", "2026-10-01", "TRUE") plus style. Numbers (and dates) align right
/// under the General alignment.
struct SheetCell: Hashable {
    var text: String
    var style: CellStyle
    var isNumber: Bool
    /// The value behind `text`: numbers, dates and times as Excel serial days (1900 date system), booleans as 1 / 0;
    /// nil for text and errors. Writers store it instead of the text.
    var value: Double?
    /// Excel number format code of `value` ("#,##0", "yyyy-mm-dd"); nil = General.
    var numberFormat: String?
    /// A TRUE / FALSE cell (`value` is 1 or 0).
    var isBoolean = false

    init(_ text: String, _ style: CellStyle, isNumber: Bool = false, value: Double? = nil, numberFormat: String? = nil, isBoolean: Bool = false) {
        self.text = text; self.style = style; self.isNumber = isNumber
        self.value = value; self.numberFormat = numberFormat; self.isBoolean = isBoolean
    }

    var hasContent: Bool { !text.isEmpty || style.fill != nil || style.hasBorders }
}
