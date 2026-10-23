// Tolerant model comparison ported from HDocumentAssert.cs.
import Foundation
import XCTest

@testable import FileToXEngineKit

extension HDocumentAssert {
    final class Comparer {
        var differences: [String] = [], path: [String] = []
        func equal<T: Equatable>(_ e: T, _ a: T, _ label: String) {
            if e != a { differences.append(path.joined(separator: "/") + ": \(label): expected \(e), got \(a)") }
        }
        func set<T: Equatable>(_ e: T?, _ a: T?, _ label: String) { if let e { equal(Optional(e), a, label) } }
        func inside(_ name: String, _ body: () -> Void) {
            path.append(name)
            defer { path.removeLast() }
            body()
        }
        func document(_ e: HDocument, _ a: HDocument) {
            set(e.title, a.title, "title")
            let sections = e.sections.isEmpty ? [HSection()] : e.sections
            equal(sections.count, a.sections.count, "sections")
            for (i, pair) in zip(sections, a.sections).enumerated() {
                inside("section\(i)") { section(pair.0, pair.1) }
            }
        }
        func section(_ e: HSection, _ a: HSection) {
            set(e.page, a.page, "page")
            equal(e.columns, a.columns, "columns")
            equal(e.hideFirstHeader, a.hideFirstHeader, "hideFirstHeader")
            equal(e.hideFirstFooter, a.hideFirstFooter, "hideFirstFooter")
            set(e.startPageNumber, a.startPageNumber, "start page")
            headers("header", e.headers, a.headers)
            headers("footer", e.footers, a.footers)
            var b = e.blocks
            if b.isEmpty || !(b[0] is HParagraph) { b.insert(HParagraph(), at: 0) }
            blocks(b, a.blocks, true)
        }
        func headers(_ kind: String, _ e: [HHeaderFooter], _ a: [HHeaderFooter]) {
            equal(e.count, a.count, kind + "s")
            for (i, pair) in zip(e, a).enumerated() {
                inside(kind + String(i)) {
                    equal(pair.0.pages, pair.1.pages, "pages")
                    blocks(pair.0.blocks, pair.1.blocks)
                }
            }
        }
        func blocks(_ expected: [HBlock], _ actual: [HBlock], _ firstIsSetup: Bool = false) {
            let flat = expected.flatMap { b in [b] + ((b as? HTable)?.caption ?? []) }
            equal(flat.count, actual.count, "blocks")
            for (i, pair) in zip(flat, actual).enumerated() {
                inside("block\(i)") {
                    if let p = pair.0 as? HParagraph, let q = pair.1 as? HParagraph {
                        paragraph(p, q, firstIsSetup && i == 0)
                    } else if let t = pair.0 as? HTable, let u = pair.1 as? HTable {
                        table(t, u)
                    } else {
                        equal(String(describing: type(of: pair.0)), String(describing: type(of: pair.1)), "block type")
                    }
                }
            }
        }
        func paragraph(_ e: HParagraph, _ a: HParagraph, _ setup: Bool) {
            equal(e.headingLevel, a.headingLevel, "heading")
            equal(e.pageBreakBefore, a.pageBreakBefore, "page break")
            equal(e.columnBreakBefore, a.columnBreakBefore, "column break")
            equal(e.columnsChange, a.columnsChange, "columns change")
            list(e.list, a.list)
            paraFormat(e.format, a.format, e.list != nil)
            if e.inlines.isEmpty && !setup { charFormat(e.markFormat, a.markFormat) }
            inlines(e.inlines, a.inlines)
        }
        func list(_ e: HListRef?, _ a: HListRef?) {
            if e == nil || e?.numbered == false {
                equal(a == nil, true, "unexpected list")
                return
            }
            guard let e, let a else {
                differences.append("list missing")
                return
            }
            equal(e.level, a.level, "list level")
            equal(e.numbered, a.numbered, "numbered")
            if e.level < e.numbering.levels.count && a.level < a.numbering.levels.count {
                equal(e.numbering.levels[e.level], a.numbering.levels[a.level], "list definition")
            }
        }
        func paraFormat(_ e: HParaFormat, _ a: HParaFormat, _ inList: Bool) {
            set(e.align, a.align, "align")
            if !inList || e.left != nil {
                set(e.left, a.left, "left")
                set(e.firstLine, a.firstLine, "first line")
            }
            set(e.right, a.right, "right")
            set(e.before, a.before, "before")
            set(e.after, a.after, "after")
            set(e.lineSpacing, a.lineSpacing, "line spacing")
            set(e.keepWithNext, a.keepWithNext, "keep with next")
            set(e.keepLines, a.keepLines, "keep lines")
            set(e.widowOrphan, a.widowOrphan, "widow/orphan")
            if let t = e.tabs, !t.isEmpty { equal(t, a.tabs ?? [], "tabs") }
        }
        func charFormat(_ e: HCharFormat, _ a: HCharFormat) {
            set(e.bold, a.bold, "bold")
            set(e.italic, a.italic, "italic")
            set(e.underline, a.underline, "underline")
            set(e.strike, a.strike, "strike")
            set(e.superscript, a.superscript, "superscript")
            set(e.subscript, a.subscript, "subscript")
            set(e.size, a.size, "size")
            set(e.font ?? e.eastAsianFont, a.font, "font")
            set(e.eastAsianFont ?? e.font, a.eastAsianFont, "East Asian font")
            set(e.color, a.color, "color")
            set(e.shade, a.shade, "shade")
            set(e.spacing, a.spacing, "spacing")
        }
        static func normalize(_ list: [HInline]) -> [HInline] {
            var result: [HInline] = []
            for item in list {
                if let t = item as? HText {
                    if t.text.isEmpty { continue }
                    if let last = result.last as? HText, last.format == t.format {
                        result[result.count - 1] = HText(last.text + t.text, t.format)
                        continue
                    }
                }
                result.append(item)
            }
            return result
        }
        func inlines(_ e: [HInline], _ a: [HInline]) {
            let e = Self.normalize(e)
            let a = Self.normalize(a)
            equal(e.map { String(describing: type(of: $0)) }, a.map { String(describing: type(of: $0)) }, "inlines")
            if e.count != a.count { return }
            for (i, pair) in zip(e, a).enumerated() { inside("inline\(i)") { inline(pair.0, pair.1) } }
        }
        func inline(_ e: HInline, _ a: HInline) {
            switch (e, a) {
            case (let x as HText, let y as HText):
                equal(x.text, y.text, "text")
                charFormat(x.format, y.format)
            case (let x as HTab, let y as HTab): charFormat(x.format, y.format)
            case (let x as HLink, let y as HLink):
                equal(x.target, y.target, "target")
                inlines(x.content, y.content)
            case (let x as HBookmark, let y as HBookmark): equal(x.name, y.name, "bookmark")
            case (let x as HNote, let y as HNote):
                equal(x.endnote, y.endnote, "endnote")
                blocks(x.blocks, y.blocks)
            case (let x as HField, let y as HField): equal(x.kind, y.kind, "field")
            case (let x as HImage, let y as HImage):
                equal(
                    try? Data(contentsOf: URL(fileURLWithPath: x.path)),
                    try? Data(contentsOf: URL(fileURLWithPath: y.path)), "picture content")
                set(x.width, y.width, "width")
                set(x.height, y.height, "height")
                anchor(x.anchor, y.anchor)
            case (let x as HTextBox, let y as HTextBox):
                equal(x.width, y.width, "width")
                equal(x.height, y.height, "height")
                anchor(x.anchor, y.anchor)
                equal(x.fill, y.fill, "fill")
                equal(x.gradient, y.gradient, "gradient")
                line(x.line, y.line)
                equal(x.shape, y.shape, "shape")
                equal(x.cornerRatio, y.cornerRatio, "corner")
                equal(x.padding, y.padding, "padding")
                equal(x.verticalAlign, y.verticalAlign, "vertical align")
                blocks(x.blocks, y.blocks)
            case (let x as HShape, let y as HShape):
                equal(x.kind, y.kind, "kind")
                equal(max(1, x.width), max(1, y.width), "width")
                equal(max(1, x.height), max(1, y.height), "height")
                anchor(x.anchor, y.anchor)
                equal(x.fill, y.fill, "fill")
                equal(x.gradient, y.gradient, "gradient")
                line(x.line, y.line)
                equal(x.cornerRatio, y.cornerRatio, "corner")
                equal(x.flipHorizontal, y.flipHorizontal, "flipH")
                equal(x.flipVertical, y.flipVertical, "flipV")
            default: break
            }
        }
        func anchor(_ e: HAnchor?, _ a: HAnchor?) {
            if let e, let a {
                if e.horizontalOffset >= 0 && e.verticalOffset >= 0 {
                    equal(e, a, "anchor")
                } else {
                    equal(e.wrap, a.wrap, "wrap")
                }
            } else {
                equal(e == nil, a == nil, "floating")
            }
        }
        func line(_ e: HBorder, _ a: HBorder) {
            equal(e.style, a.style, "line style")
            if e.style == .none { return }
            equal(e.color, a.color, "line color")
            if abs(e.widthMm - a.widthMm) > 0.01 {
                differences.append("line width: expected \(e.widthMm), got \(a.widthMm)")
            }
        }
        static func snapped(_ b: HBorders?) -> String {
            guard let b else { return "-" }
            return [b.left, b.right, b.top, b.bottom].map {
                $0.style == .none ? "none" : "\($0.style):\(HwpxWriter.lineWidth($0.widthMm)):\($0.color)"
            }.joined(separator: " ")
        }
        func table(_ e: HTable, _ a: HTable) {
            equal(e.rows.count, a.rows.count, "rows")
            equal(e.align, a.align, "align")
            set(e.cellMargin, a.cellMargin, "cell margin")
            if let w = e.columnWidths, e.columnCount == w.count {
                if let got = a.columnWidths, got.count == w.count {
                    let sum = w.reduce(0, +)
                    let total = got.reduce(0, +)
                    if total > sum
                        || zip(w, got).contains(where: {
                            abs(Double($0.0) * Double(total) / Double(sum) - Double($0.1)) > 2
                        })
                    {
                        differences.append("column width proportions differ")
                    }
                } else {
                    differences.append("column widths missing")
                }
            }
            for (r, pair) in zip(e.rows, a.rows).enumerated() {
                inside("row\(r)") {
                    let (er, ar) = pair
                    equal(er.header, ar.header, "header")
                    if let h = er.height, (ar.height ?? -1) < h { differences.append("row height shrank") }
                    equal(er.cells.count, ar.cells.count, "cells")
                    for (c, pair) in zip(er.cells, ar.cells).enumerated() {
                        inside("cell\(c)") {
                            let (ec, ac) = pair
                            if ec.column >= 0 { equal(ec.column, ac.column, "column") }
                            equal(ec.rowSpan, ac.rowSpan, "row span")
                            equal(ec.colSpan, ac.colSpan, "column span")
                            equal(ec.verticalAlign, ac.verticalAlign, "vertical align")
                            equal(ec.fill, ac.fill, "fill")
                            equal(Self.snapped(ec.borders ?? e.borders ?? .grid), Self.snapped(ac.borders), "borders")
                            blocks(ec.blocks.isEmpty ? [HParagraph()] : ec.blocks, ac.blocks)
                        }
                    }
                }
            }
        }
    }
}
