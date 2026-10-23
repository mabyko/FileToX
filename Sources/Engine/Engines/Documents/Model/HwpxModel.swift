// Port of Filee.Engines/Hwp/Hwpx/HwpxModel.cs: the in-memory document model between the document readers (DOCX,
// HTML, Markdown, PDF, PPTX, sheets, e-books, Pandoc AST, plain text) and the writers (HWPX, DOCX, Markdown, XHTML,
// plain text). Lengths are HWPUNIT (1/7200 inch), font sizes 1/100 pt, like OWPML. A nil format field means
// "inherit from the 한글 style". Classes keep Filee's reference semantics (readers fill lists in place).

import Foundation

/// A document ready to be written.
final class HDocument {
    var title: String?
    var sections: [HSection] = []
    init() {}
}

/// A run of pages sharing page setup, headers and footers (한글 "구역").
final class HSection {
    /// Paper and margins; nil keeps the template's A4 page.
    var page: HPage?
    var columns = HColumns.single
    var headers: [HHeaderFooter] = []
    var footers: [HHeaderFooter] = []
    /// Hide header / footer on the first page (DOCX "different first page" with an empty first header).
    var hideFirstHeader = false
    var hideFirstFooter = false
    /// Restart page numbering at this number; nil continues from the previous section.
    var startPageNumber: Int?
    var blocks: [HBlock] = []
    init() {}
}

/// Paper size and margins. Width/height as printed (landscape pages are wider than tall).
struct HPage: Hashable {
    var width: Int, height: Int, left: Int, right: Int
    /// Paper edge to the header (한글 "위쪽"); the body starts at top + header.
    var top: Int
    var bottom: Int
    var header: Int
    var footer: Int
    var gutter: Int

    init(width: Int, height: Int, left: Int, right: Int, top: Int, bottom: Int, header: Int, footer: Int, gutter: Int) {
        self.width = width; self.height = height; self.left = left; self.right = right
        self.top = top; self.bottom = bottom; self.header = header; self.footer = footer; self.gutter = gutter
    }

    var landscape: Bool { width > height }
    var textWidth: Int { max(2000, width - left - right - gutter) }
}

/// Newspaper-style columns.
struct HColumns: Hashable {
    var count: Int
    var gap: Int
    var separator: Bool

    init(count: Int, gap: Int, separator: Bool) { self.count = count; self.gap = gap; self.separator = separator }
    static let single = HColumns(count: 1, gap: 0, separator: false)
}

/// Which pages a header or footer applies to.
enum HPageType: Hashable { case both, even, odd }

final class HHeaderFooter {
    let pages: HPageType
    var blocks: [HBlock] = []
    init(_ pages: HPageType) { self.pages = pages }
}

// ───────────────────────── Blocks ─────────────────────────

class HBlock {}

final class HParagraph: HBlock {
    var format = HParaFormat()
    /// Format of the paragraph mark: decides the height of an empty paragraph.
    var markFormat = HCharFormat()
    /// 1…9 for headings (outline levels in 한글), else 0.
    var headingLevel = 0
    /// List numbering of this paragraph, or nil.
    var list: HListRef?
    var pageBreakBefore = false
    var columnBreakBefore = false
    /// Columns change here without a new page (DOCX continuous section break); nil = unchanged.
    var columnsChange: HColumns?
    var inlines: [HInline] = []
    override init() {}
}

/// A list a paragraph belongs to. `level` is 0-based; `numbered` is false for continuation paragraphs.
struct HListRef {
    let numbering: HNumbering
    let level: Int
    let numbered: Bool

    init(_ numbering: HNumbering, _ level: Int, _ numbered: Bool) {
        self.numbering = numbering
        self.level = level
        self.numbered = numbered
    }
}

/// A list definition: one entry per nesting level. Shared (by reference) by all items of one list.
final class HNumbering {
    var levels: [HNumberingLevel] = []
    init() {}
}

/// `format`: OWPML numFormat (DIGIT, LATIN_SMALL, HANGUL_SYLLABLE ...; ignored for bullets).
/// `text`: number text with ^n for the level-n counter ("^1.", "(^2)"), or the bullet character.
struct HNumberingLevel: Hashable {
    var format: String
    var text: String
    var start: Int
    var bullet: Bool

    init(_ format: String, _ text: String, _ start: Int, _ bullet: Bool) {
        self.format = format; self.text = text; self.start = start; self.bullet = bullet
    }
}

final class HTable: HBlock {
    var rows: [HRow] = []
    /// Absolute column widths; nil = use `relativeWidths` or share the text width equally.
    var columnWidths: [Int]?
    /// Column widths as fractions of the text width (Pandoc); zero entries share the rest.
    var relativeWidths: [Double]?
    var columnCount = 0
    var align = HAlign.left
    var indent = 0
    /// Cell padding; nil = 한글 default.
    var cellMargin: HInsets?
    /// Borders used where a cell does not define its own; nil = thin solid grid.
    var borders: HBorders?
    var caption: [HBlock] = []
    override init() {}
}

final class HRow {
    var cells: [HCell] = []
    /// Minimum row height; nil = fit content.
    var height: Int?
    var header = false
    init() {}
}

final class HCell {
    /// Grid column of the cell; -1 = right after the previous cell (row spans are skipped).
    var column = -1
    var rowSpan = 1
    var colSpan = 1
    var verticalAlign = HVerticalAlign.top
    var fill: String?
    var borders: HBorders?
    var blocks: [HBlock] = []
    init() {}
}

enum HVerticalAlign: Hashable { case top, center, bottom }

struct HInsets: Hashable {
    var left: Int, right: Int, top: Int, bottom: Int
    init(_ left: Int, _ right: Int, _ top: Int, _ bottom: Int) { self.left = left; self.right = right; self.top = top; self.bottom = bottom }
}

/// One border line. Width is in mm (snapped to the widths 한글 offers when written).
struct HBorder: Hashable {
    var style: HBorderStyle
    var widthMm: Double
    var color: String

    init(_ style: HBorderStyle, _ widthMm: Double, _ color: String) { self.style = style; self.widthMm = widthMm; self.color = color }

    static let none = HBorder(.none, 0.1, "#000000")
    static let thin = HBorder(.solid, 0.12, "#000000")
}

enum HBorderStyle: Hashable { case none, solid, dash, dot, dashDot, double }

struct HBorders: Hashable {
    var left: HBorder, right: HBorder, top: HBorder, bottom: HBorder
    init(_ left: HBorder, _ right: HBorder, _ top: HBorder, _ bottom: HBorder) { self.left = left; self.right = right; self.top = top; self.bottom = bottom }

    static let grid = HBorders(.thin, .thin, .thin, .thin)
    static let empty = HBorders(.none, .none, .none, .none)
}

// ───────────────────────── Inlines ─────────────────────────

class HInline {}

final class HText: HInline {
    let text: String
    let format: HCharFormat
    init(_ text: String, _ format: HCharFormat = HCharFormat()) { self.text = text; self.format = format }
}

final class HLineBreak: HInline {
    let format: HCharFormat
    init(_ format: HCharFormat = HCharFormat()) { self.format = format }
}

final class HTab: HInline {
    let format: HCharFormat
    init(_ format: HCharFormat = HCharFormat()) { self.format = format }
}

/// Hyperlink to a URL, or to a bookmark when the target starts with '#'.
final class HLink: HInline {
    let target: String
    var content: [HInline] = []
    init(_ target: String) { self.target = target }
}

final class HBookmark: HInline {
    let name: String
    init(_ name: String) { self.name = name }
}

final class HNote: HInline {
    let endnote: Bool
    var blocks: [HBlock] = []
    init(_ endnote: Bool) { self.endnote = endnote }
}

enum HFieldKind: Hashable { case pageNumber, totalPages }

/// Automatic number (page number in headers and footers).
final class HField: HInline {
    let kind: HFieldKind
    let format: HCharFormat
    init(_ kind: HFieldKind, _ format: HCharFormat = HCharFormat()) { self.kind = kind; self.format = format }
}

/// Picture from a local file.
final class HImage: HInline {
    let path: String
    /// Display size; nil = natural size (capped to the text width).
    var width: Int?
    var height: Int?
    /// Position for floating pictures; nil = inline.
    var anchor: HAnchor?
    init(_ path: String) { self.path = path }
}

/// A box with its own paragraphs (DOCX text box, 한글 글상자).
final class HTextBox: HInline {
    var width = 0
    var height = 0
    var anchor: HAnchor?
    var fill: String?
    var gradient: HGradient?
    var line = HBorder.thin
    /// Outline of the box: `.rectangle` (default) or `.ellipse`.
    var shape = HShapeKind.rectangle
    /// Corner rounding of a rectangular box in percent (0 = square).
    var cornerRatio = 0
    var padding = HInsets(283, 283, 283, 283)
    var verticalAlign = HVerticalAlign.top
    var blocks: [HBlock] = []
    override init() {}
}

enum HShapeKind: Hashable { case rectangle, ellipse, line }

/// A drawing without text: rectangle, ellipse or straight line.
final class HShape: HInline {
    let kind: HShapeKind
    var width = 0
    var height = 0
    var anchor: HAnchor?
    var fill: String?
    var gradient: HGradient?
    var line = HBorder.thin
    var cornerRatio = 0
    /// Lines run from top-left to bottom-right unless flipped.
    var flipHorizontal = false
    var flipVertical = false
    init(_ kind: HShapeKind) { self.kind = kind }
}

/// Linear gradient fill: colours from start to end, angle in degrees.
struct HGradient: Hashable {
    var colors: [String]
    var angle: Int
    init(_ colors: [String], _ angle: Int) { self.colors = colors; self.angle = angle }
}

/// Position of a floating object (OWPML horzRelTo/horzAlign/vertRelTo/vertAlign/textWrap values).
struct HAnchor: Hashable {
    var horizontalRelativeTo: String
    var horizontalAlign: String
    var horizontalOffset: Int
    var verticalRelativeTo: String
    var verticalAlign: String
    var verticalOffset: Int
    var wrap: String
    var allowOverlap: Bool

    init(_ horizontalRelativeTo: String, _ horizontalAlign: String, _ horizontalOffset: Int,
         _ verticalRelativeTo: String, _ verticalAlign: String, _ verticalOffset: Int, _ wrap: String, _ allowOverlap: Bool) {
        self.horizontalRelativeTo = horizontalRelativeTo; self.horizontalAlign = horizontalAlign; self.horizontalOffset = horizontalOffset
        self.verticalRelativeTo = verticalRelativeTo; self.verticalAlign = verticalAlign; self.verticalOffset = verticalOffset
        self.wrap = wrap; self.allowOverlap = allowOverlap
    }
}

// ───────────────────────── Formats ─────────────────────────

enum HAlign: Hashable { case left, center, right, justify, distribute }

enum HLineSpacingKind: Hashable {
    /// Percent of the font size (한글 default is 160%).
    case percent
    case fixed
    case atLeast
}

struct HLineSpacing: Hashable {
    var kind: HLineSpacingKind
    var value: Int
    init(_ kind: HLineSpacingKind, _ value: Int) { self.kind = kind; self.value = value }
}

/// Paragraph formatting; nil members keep the 한글 style's value. `firstLine` is relative to `left` (negative = hanging).
struct HParaFormat: Hashable {
    var align: HAlign?
    var left: Int?
    var right: Int?
    var firstLine: Int?
    var before: Int?
    var after: Int?
    var lineSpacing: HLineSpacing?
    var keepWithNext: Bool?
    var keepLines: Bool?
    var widowOrphan: Bool?
    var tabs: [HTabStop]?

    init(align: HAlign? = nil, left: Int? = nil, right: Int? = nil, firstLine: Int? = nil, before: Int? = nil, after: Int? = nil,
         lineSpacing: HLineSpacing? = nil, keepWithNext: Bool? = nil, keepLines: Bool? = nil, widowOrphan: Bool? = nil,
         tabs: [HTabStop]? = nil) {
        self.align = align; self.left = left; self.right = right; self.firstLine = firstLine; self.before = before
        self.after = after; self.lineSpacing = lineSpacing; self.keepWithNext = keepWithNext; self.keepLines = keepLines
        self.widowOrphan = widowOrphan; self.tabs = tabs
    }

    var isEmpty: Bool { self == HParaFormat() }

    // Tab stop lists compare by content (nil equals empty) so equal formats share one paraPr.
    static func == (a: HParaFormat, b: HParaFormat) -> Bool {
        a.align == b.align && a.left == b.left && a.right == b.right && a.firstLine == b.firstLine && a.before == b.before
            && a.after == b.after && a.lineSpacing == b.lineSpacing && a.keepWithNext == b.keepWithNext
            && a.keepLines == b.keepLines && a.widowOrphan == b.widowOrphan && (a.tabs ?? []) == (b.tabs ?? [])
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(align); hasher.combine(left); hasher.combine(right); hasher.combine(firstLine); hasher.combine(before)
        hasher.combine(after); hasher.combine(lineSpacing); hasher.combine(keepWithNext); hasher.combine(keepLines)
        hasher.combine(widowOrphan); hasher.combine(tabs?.count ?? 0)
    }
}

enum HTabKind: Hashable { case left, right, center, decimal }

/// `leader`: OWPML line type of the leader (NONE, DOT, DASH, SOLID ...).
struct HTabStop: Hashable {
    var position: Int
    var kind: HTabKind
    var leader: String
    init(_ position: Int, _ kind: HTabKind, _ leader: String) { self.position = position; self.kind = kind; self.leader = leader }
}

/// Character formatting; nil members keep the 한글 style's value. `size` in 1/100 pt; `font` for Latin text,
/// `eastAsianFont` for Hangul / Hanja / Japanese; colours "#RRGGBB" (`shade` = highlight).
struct HCharFormat: Hashable {
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var superscript: Bool?
    var `subscript`: Bool?
    var size: Int?
    var font: String?
    var eastAsianFont: String?
    var color: String?
    var shade: String?
    var spacing: Int?

    init(bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strike: Bool? = nil, superscript: Bool? = nil,
         subscript: Bool? = nil, size: Int? = nil, font: String? = nil, eastAsianFont: String? = nil, color: String? = nil,
         shade: String? = nil, spacing: Int? = nil) {
        self.bold = bold; self.italic = italic; self.underline = underline; self.strike = strike
        self.superscript = superscript; self.subscript = `subscript`; self.size = size; self.font = font
        self.eastAsianFont = eastAsianFont; self.color = color; self.shade = shade; self.spacing = spacing
    }

    var isEmpty: Bool { self == HCharFormat() }
}
