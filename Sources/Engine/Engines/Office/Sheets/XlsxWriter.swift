// Port of Filee.Engines/Office/Sheets/XlsxWriter.cs. XML and style insertion order match Filee.
import Foundation

enum XlsxWriter {
    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let builtInIds = [
        "0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10, "0.00E+00": 11, "@": 49,
    ]
    static func write(_ book: Workbook, _ path: String) throws {
        let sheets = book.sheets.isEmpty ? [Worksheet("Sheet1")] : book.sheets
        let names = uniqueNames(sheets.map(\.name))
        let styles = StyleTable()
        let sheetXml = try sheets.enumerated().map { try sheetXml($0.element, styles, $0.offset == 0) }
        let zip = try ZipWriter(path: path)
        let d = SheetXML.declaration
        try zip.add(
            "[Content_Types].xml",
            text: d
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
                + sheets.indices.map {
                    "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                }.joined() + "</Types>")
        try zip.add(
            "_rels/.rels",
            text: d
                + "\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(relationships)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        )
        try zip.add(
            "xl/_rels/workbook.xml.rels",
            text: d + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + sheets.indices.map {
                    "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(relationships)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
                }.joined()
                + "<Relationship Id=\"rIdStyles\" Type=\"\(relationships)/styles\" Target=\"styles.xml\"/></Relationships>"
        )
        try zip.add(
            "xl/workbook.xml",
            text: d + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(relationships)\"><sheets>"
                + names.enumerated().map {
                    "<sheet name=\"\(escape($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>"
                }.joined() + "</sheets></workbook>")
        try zip.add("xl/styles.xml", text: styles.xml())
        for i in sheets.indices { try zip.add("xl/worksheets/sheet\(i + 1).xml", text: sheetXml[i]) }
        try zip.close()
    }
    private static func sheetXml(_ sheet: Worksheet, _ styles: StyleTable, _ selected: Bool) throws -> String {
        var sb =
            SheetXML.declaration
            + "<worksheet xmlns=\"\(main)\" xmlns:r=\"\(relationships)\"><sheetViews><sheetView\(selected ? " tabSelected=\"1\"" : "") workbookViewId=\"0\">"
        if sheet.frozenRows > 0 {
            sb +=
                "<pane ySplit=\"\(sheet.frozenRows)\" topLeftCell=\"A\(sheet.frozenRows + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        }
        sb += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\" "
        if abs(sheet.defaultColumnWidth - Worksheet.standardColumnWidth) > 0.005 {
            sb += "defaultColWidth=\"\(SheetXML.decimal(sheet.defaultColumnWidth))\" "
        }
        sb += "/>" + columns(sheet) + "<sheetData>"
        let rows = Set(sheet.rows.keys).union(sheet.rowHeights.keys).union(sheet.hiddenRows).sorted()
        for row in rows {
            try Task.checkCancellation()
            sb += "<row r=\"\(row + 1)\""
            if let height = sheet.rowHeights[row] { sb += " ht=\"\(SheetXML.decimal(height, 2))\" customHeight=\"1\"" }
            if sheet.hiddenRows.contains(row) { sb += " hidden=\"1\"" }
            sb += ">"
            for (column, cell) in Worksheet.sortedCells(sheet.rows[row] ?? [:]) {
                sb += cellXml(columnName(column) + String(row + 1), cell, styles)
            }
            sb += "</row>"
        }
        sb += "</sheetData>"
        if !sheet.merges.isEmpty {
            sb += "<mergeCells count=\"\(sheet.merges.count)\">"
            for m in sheet.merges {
                sb += "<mergeCell ref=\"\(columnName(m.left))\(m.top + 1):\(columnName(m.right))\(m.bottom + 1)\"/>"
            }
            sb += "</mergeCells>"
        }
        return sb + "</worksheet>"
    }
    private static func columns(_ sheet: Worksheet) -> String {
        let cols = Set(sheet.columnWidths.keys).union(sheet.hiddenColumns).sorted()
        if cols.isEmpty { return "" }
        var sb = "<cols>"
        var i = 0
        while i < cols.count {
            let first = cols[i]
            let width = sheet.columnWidth(first)
            let hidden = sheet.hiddenColumns.contains(first)
            var last = first
            i += 1
            while i < cols.count && cols[i] == last + 1 && sheet.columnWidth(cols[i]) == width
                && sheet.hiddenColumns.contains(cols[i]) == hidden
            {
                last = cols[i]
                i += 1
            }
            sb +=
                "<col min=\"\(first + 1)\" max=\"\(last + 1)\" width=\"\(SheetXML.decimal(width))\" customWidth=\"1\"\(hidden ? " hidden=\"1\"" : "")/>"
        }
        return sb + "</cols>"
    }
    private static func cellXml(_ reference: String, _ cell: SheetCell, _ styles: StyleTable) -> String {
        let number = cell.value ?? (cell.isNumber ? SheetXML.double(cell.text) : nil)
        let style = styles.index(cell.style, number == nil || cell.isBoolean ? nil : cell.numberFormat)
        let s = style == 0 ? "" : " s=\"\(style)\""
        let start = "<c r=\"\(reference)\"\(s)"
        if cell.isBoolean, let number { return start + " t=\"b\"><v>\(number != 0 ? 1 : 0)</v></c>" }
        if let number, number.isFinite { return start + "><v>\(SheetXML.number(number))</v></c>" }
        if cell.text.isEmpty { return start + "/>" }
        return start + " t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(cell.text))</t></is></c>"
    }
    static func columnName(_ column: Int) -> String {
        var name = ""
        var c = column + 1
        while c > 0 {
            name = String(UnicodeScalar(65 + (c - 1) % 26)!) + name
            c = (c - 1) / 26
        }
        return name
    }
    static func uniqueNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        var result: [String] = []
        for name in names {
            var clean = String(name.filter { !":\\/?*[]".contains($0) }).trimmingCharacters(
                in: CharacterSet(charactersIn: "'")
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { clean = "Sheet\(result.count + 1)" }
            clean = String(decoding: clean.utf16.prefix(31), as: UTF16.self)
            var unique = clean
            var n = 2
            while !used.insert(unique.lowercased()).inserted {
                let suffix = " (\(n))"
                unique = String(decoding: clean.utf16.prefix(31 - suffix.utf16.count), as: UTF16.self) + suffix
                n += 1
            }
            result.append(unique)
        }
        return result
    }
    static func escape(_ text: String) -> String { SheetXML.escape(text) }
    private final class StyleTable {
        struct Key: Hashable {
            let style: CellStyle
            let format: String?
        }
        var xfs: [Key: Int] = [Key(style: .default, format: nil): 0]
        var xfXml = ["<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"]
        var formats: [String] = []
        var fonts = ["<font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"]
        var fills = [
            "<fill><patternFill patternType=\"none\"/></fill>", "<fill><patternFill patternType=\"gray125\"/></fill>",
        ]
        var borders = ["<border><left/><right/><top/><bottom/><diagonal/></border>"]
        func index(_ style: CellStyle, _ format: String?) -> Int {
            let key = Key(style: style, format: format)
            if let i = xfs[key] { return i }
            let formatId: Int
            if let format {
                if let b = builtInIds[format] { formatId = b } else { formatId = 164 + Self.add(&formats, format) }
            } else {
                formatId = 0
            }
            let fontId = Self.add(&fonts, Self.font(style))
            let fillId =
                style.fill.map {
                    Self.add(
                        &fills,
                        "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(Self.argb($0))\"/><bgColor indexed=\"64\"/></patternFill></fill>"
                    )
                } ?? 0
            let borderId = Self.add(
                &borders,
                "<border>" + Self.side("left", style.left) + Self.side("right", style.right)
                    + Self.side("top", style.top) + Self.side("bottom", style.bottom) + "<diagonal/></border>")
            var alignment = ""
            if style.align != .general { alignment += " horizontal=\"\(style.align)\"" }
            if style.verticalAlign != .bottom { alignment += " vertical=\"\(style.verticalAlign)\"" }
            if style.wrap { alignment += " wrapText=\"1\"" }
            xfXml.append(
                "<xf numFmtId=\"\(formatId)\" fontId=\"\(fontId)\" fillId=\"\(fillId)\" borderId=\"\(borderId)\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\">"
                    + (alignment.isEmpty ? "" : "<alignment\(alignment)/>") + "</xf>")
            xfs[key] = xfXml.count - 1
            return xfXml.count - 1
        }
        func xml() -> String {
            var sb = SheetXML.declaration + "<styleSheet xmlns=\"\(main)\">"
            if !formats.isEmpty {
                sb +=
                    "<numFmts count=\"\(formats.count)\">"
                    + formats.enumerated().map {
                        "<numFmt numFmtId=\"\(164 + $0.offset)\" formatCode=\"\(escape($0.element))\"/>"
                    }.joined() + "</numFmts>"
            }
            sb +=
                "<fonts count=\"\(fonts.count)\">\(fonts.joined())</fonts><fills count=\"\(fills.count)\">\(fills.joined())</fills><borders count=\"\(borders.count)\">\(borders.joined())</borders>"
            sb +=
                "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"\(xfXml.count)\">\(xfXml.joined())</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
            return sb
        }
        private static func add(_ list: inout [String], _ xml: String) -> Int {
            if let i = list.firstIndex(of: xml) { return i }
            list.append(xml)
            return list.count - 1
        }
        private static func argb(_ color: String) -> String {
            "FF" + color.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        }
        private static func font(_ st: CellStyle) -> String {
            "<font>" + (st.bold ? "<b/>" : "") + (st.italic ? "<i/>" : "") + (st.strike ? "<strike/>" : "")
                + (st.underline ? "<u/>" : "") + "<sz val=\"\(SheetXML.decimal(st.fontSize ?? 11, 2))\"/>"
                + (st.color.map { "<color rgb=\"\(argb($0))\"/>" } ?? "")
                + "<name val=\"Calibri\"/><family val=\"2\"/></font>"
        }
        private static func side(_ name: String, _ border: CellBorder) -> String {
            border.isVisible
                ? "<\(name) style=\"\(border.style)\"><color rgb=\"\(argb(border.color ?? "#000000"))\"/></\(name)>"
                : "<\(name)/>"
        }
    }
}
