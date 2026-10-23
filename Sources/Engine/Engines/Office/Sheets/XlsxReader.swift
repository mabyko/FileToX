// Port of Filee.Engines/Office/Sheets/XlsxReader.cs.
import Foundation

final class XlsxReader {
    private static let s = XNamespace("http://schemas.openxmlformats.org/spreadsheetml/2006/main")
    private static let r = XNamespace("http://schemas.openxmlformats.org/officeDocument/2006/relationships")
    private let package: OpcPackage
    private var sharedStrings: [String] = []
    private var cellFormats: [(CellStyle, String)] = []
    private var formatter = NumberFormatter()
    private var date1904 = false
    private init(_ package: OpcPackage) { self.package = package }
    static func read(_ path: String) throws -> Workbook { try XlsxReader(OpcPackage(path)).readWorkbook() }
    private func readWorkbook() throws -> Workbook {
        let s = Self.s
        let workbookPath = package.mainPartPath ?? "xl/workbook.xml"
        guard let workbook = try package.part(workbookPath)?.root else {
            throw ConversionError("The file is not an Excel workbook (no xl/workbook.xml).")
        }
        date1904 = ["1", "true"].contains(workbook.element(s + "workbookPr")?.attributeValue("date1904") ?? "")
        formatter = NumberFormatter(date1904)
        let colors = OoxmlColors.fromTheme(
            try package.targetOfType(workbookPath, "/theme").flatMap { try package.part($0) })
        if let shared = package.targetOfType(workbookPath, "/sharedStrings"), let xml = try package.part(shared) {
            sharedStrings = xml.root.elements(s + "si").map(Self.richText)
        }
        if let styles = package.targetOfType(workbookPath, "/styles") { readStyles(try package.part(styles), colors) }
        let result = Workbook()
        for sheet in workbook.element(s + "sheets")?.elements(s + "sheet") ?? [] {
            try Task.checkCancellation()
            if ["hidden", "veryHidden"].contains(sheet.attributeValue("state") ?? "") { continue }
            guard let target = package.target(workbookPath, sheet.attributeValue(Self.r + "id")),
                let xml = try package.part(target)?.root, xml.name == s + "worksheet"
            else { continue }
            result.sheets.append(try readSheet(sheet.attributeValue("name") ?? "Sheet", xml))
        }
        return result
    }
    private static func richText(_ item: XElement) -> String {
        if let plain = item.element(s + "t") { return plain.value }
        return item.elements(s + "r").map { $0.element(s + "t")?.value ?? "" }.joined()
    }
    private func readStyles(_ xml: XDocument?, _ colors: OoxmlColors) {
        guard let root = xml?.root else { return }
        let s = Self.s
        var formats: [Int: String] = [:]
        for f in root.element(s + "numFmts")?.elements(s + "numFmt") ?? [] {
            if let id = SheetXML.int(f.attributeValue("numFmtId")) {
                formats[id] = f.attributeValue("formatCode") ?? "General"
            }
        }
        let fonts: [CellStyle] = (root.element(s + "fonts")?.elements(s + "font") ?? []).map { f in
            var st = CellStyle()
            st.bold = Self.on(f.element(s + "b"))
            st.italic = Self.on(f.element(s + "i"))
            st.strike = Self.on(f.element(s + "strike"))
            st.underline = f.element(s + "u").map { $0.attributeValue("val") != "none" } ?? false
            st.fontSize = SheetXML.double(f.element(s + "sz")?.attributeValue("val"))
            st.color = colors.spreadsheet(f.element(s + "color"))
            return st
        }
        let fills: [String?] = (root.element(s + "fills")?.elements(s + "fill") ?? []).map { f in
            let p = f.element(s + "patternFill")
            let type = p?.attributeValue("patternType")
            return type == nil || type == "none" || type == "gray125"
                ? nil : colors.spreadsheet(p?.element(s + "fgColor")) ?? colors.spreadsheet(p?.element(s + "bgColor"))
        }
        func side(_ el: XElement?) -> CellBorder {
            guard let style = el?.attributeValue("style") else { return .none }
            return CellBorder(style, colors.spreadsheet(el?.element(s + "color")))
        }
        let borders = (root.element(s + "borders")?.elements(s + "border") ?? []).map { b in
            [
                side(b.element(s + "left") ?? b.element(s + "start")),
                side(b.element(s + "right") ?? b.element(s + "end")), side(b.element(s + "top")),
                side(b.element(s + "bottom")),
            ]
        }
        for xf in root.element(s + "cellXfs")?.elements(s + "xf") ?? [] {
            let fi = Self.index(xf, "fontId")
            let fl = Self.index(xf, "fillId")
            let bi = Self.index(xf, "borderId")
            var st = fi < fonts.count ? fonts[fi] : CellStyle.default
            st.fill = fl < fills.count ? fills[fl] : nil
            let border = bi < borders.count ? borders[bi] : [.none, .none, .none, .none]
            st.left = border[0]
            st.right = border[1]
            st.top = border[2]
            st.bottom = border[3]
            let a = xf.element(s + "alignment")
            switch a?.attributeValue("horizontal") {
            case "left": st.align = .left
            case "center", "centerContinuous": st.align = .center
            case "right": st.align = .right
            default: st.align = .general
            }
            switch a?.attributeValue("vertical") {
            case "top": st.verticalAlign = .top
            case "center": st.verticalAlign = .center
            default: st.verticalAlign = .bottom
            }
            st.wrap = Self.on(a?.attributeValue("wrapText"))
            let id = Self.index(xf, "numFmtId")
            cellFormats.append((st, formats[id] ?? NumberFormatter.builtInFormats[id] ?? "General"))
        }
    }
    private static func index(_ el: XElement, _ attr: XName) -> Int {
        max(0, SheetXML.int(el.attributeValue(attr)) ?? 0)
    }
    private static func on(_ el: XElement?) -> Bool {
        el.map { $0.attributeValue("val") == nil || on($0.attributeValue("val")) } ?? false
    }
    private static func on(_ value: String?) -> Bool { value == "1" || value == "true" }
    private func readSheet(_ name: String, _ xml: XElement) throws -> Worksheet {
        let s = Self.s
        let sheet = Worksheet(name)
        if let w = SheetXML.double(xml.element(s + "sheetFormatPr")?.attributeValue("defaultColWidth")) {
            sheet.defaultColumnWidth = w
        }
        let pane = xml.element(s + "sheetViews")?.elements(s + "sheetView").first?.element(s + "pane")
        if ["frozen", "frozenSplit"].contains(pane?.attributeValue("state") ?? ""),
            let frozen = SheetXML.double(pane?.attributeValue("ySplit")), frozen.isFinite, frozen >= 0,
            frozen < Double(Int.max)
        {
            sheet.frozenRows = Int(frozen)
        }
        for col in xml.element(s + "cols")?.elements(s + "col") ?? [] {
            let minC = Self.index(col, "min")
            let maxC = min(Self.index(col, "max"), minC + 16384)
            let width = SheetXML.double(col.attributeValue("width"))
            if minC > 0 && maxC >= minC {
                for c in minC...maxC {
                    if let width { sheet.columnWidths[c - 1] = width }
                    if Self.on(col.attributeValue("hidden")) || width == 0 { sheet.hiddenColumns.insert(c - 1) }
                }
            }
        }
        var nextRow = 0
        for row in xml.element(s + "sheetData")?.elements(s + "row") ?? [] {
            try Task.checkCancellation()
            let r = SheetXML.int(row.attributeValue("r")).map { $0 - 1 } ?? nextRow
            nextRow = r + 1
            if Self.on(row.attributeValue("hidden")) { sheet.hiddenRows.insert(r) }
            if Self.on(row.attributeValue("customHeight")), let height = SheetXML.double(row.attributeValue("ht")) {
                sheet.rowHeights[r] = height
            }
            var nextColumn = 0
            for cell in row.elements(s + "c") {
                let c = CellRange.parseCell(cell.attributeValue("r") ?? "")?.column ?? nextColumn
                nextColumn = c + 1
                let idx = Self.index(cell, "s")
                let (style, format) = idx < cellFormats.count ? cellFormats[idx] : (.default, "General")
                let value = value(cell, style, format)
                if value.hasContent { sheet.set(r, c, value) }
            }
        }
        for merge in xml.element(s + "mergeCells")?.elements(s + "mergeCell") ?? [] {
            if let range = CellRange.parse(merge.attributeValue("ref")),
                range.bottom > range.top || range.right > range.left
            {
                sheet.merges.append(range)
            }
        }
        return sheet
    }
    private func value(_ cell: XElement, _ style: CellStyle, _ format: String) -> SheetCell {
        let s = Self.s
        let raw = cell.element(s + "v")?.value
        switch cell.attributeValue("t") ?? "n" {
        case "s":
            let i = SheetXML.int(raw) ?? -1
            return SheetCell(i >= 0 && i < sharedStrings.count ? sharedStrings[i] : "", style)
        case "inlineStr": return SheetCell(cell.element(s + "is").map(Self.richText) ?? raw ?? "", style)
        case "str", "e": return SheetCell(raw ?? "", style)
        case "b":
            let on = raw == "1" || raw == "true"
            return SheetCell(on ? "TRUE" : "FALSE", style, value: on ? 1 : 0, isBoolean: true)
        case "d":
            return raw.flatMap(SheetXML.date).map {
                number(NumberFormatter.toSerial($0) - (date1904 ? 1462 : 0), style, format)
            } ?? SheetCell(raw ?? "", style)
        default: return SheetXML.double(raw).map { number($0, style, format) } ?? SheetCell(raw ?? "", style)
        }
    }
    private func number(_ value: Double, _ style: CellStyle, _ format: String) -> SheetCell {
        SheetCell(
            formatter.format(value, format), style, isNumber: true,
            value: date1904 && formatter.isDate(format) ? value + 1462 : value,
            numberFormat: NumberFormatter.isGeneral(format) ? nil : format)
    }
}
