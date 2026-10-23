// Port of Filee.Engines/Office/Sheets/OdsReader.cs.
import Foundation

final class OdsReader {
    private static let office = XNamespace("urn:oasis:names:tc:opendocument:xmlns:office:1.0")
    private static let table = XNamespace("urn:oasis:names:tc:opendocument:xmlns:table:1.0")
    private static let text = XNamespace("urn:oasis:names:tc:opendocument:xmlns:text:1.0")
    private static let config = XNamespace("urn:oasis:names:tc:opendocument:xmlns:config:1.0")
    private static let style = OdsNumberStyles.style, fo = OdsNumberStyles.fo
    static let pointsPerCharacter = 5.25
    private var styles: [String: [String: XElement]] = [:], dataStyles: [String: XElement] = [:]
    private var cellStyles: [String: (CellStyle, String?)] = [:], formats: [String: String?] = [:],
        frozenRows: [String: Int] = [:]
    private var defaultCellStyle: XElement?
    private let formatter = NumberFormatter()
    static func read(_ path: String) throws -> Workbook {
        let zip = try ZipReader(path: path)
        func load(_ name: String) throws -> XDocument? {
            try zip.data(named: name).map { try XDocument.load(data: $0, preserveWhitespace: true) }
        }
        let manifest = XNamespace("urn:oasis:names:tc:opendocument:xmlns:manifest:1.0")
        if try load("META-INF/manifest.xml")?.root.descendants(manifest + "encryption-data").isEmpty == false {
            throw ConversionError(
                "The spreadsheet is protected with a password (encrypted). Remove the password in LibreOffice and convert it again."
            )
        }
        guard let content = try load("content.xml") else {
            throw ConversionError("The file is not an OpenDocument spreadsheet (no content.xml).")
        }
        guard let spreadsheet = content.root.element(office + "body")?.element(office + "spreadsheet") else {
            throw ConversionError("The file is not an OpenDocument spreadsheet (no office:spreadsheet).")
        }
        let reader = OdsReader()
        reader.readStyles(try load("styles.xml"), content)
        reader.readSettings(try load("settings.xml"))
        let book = Workbook()
        for t in spreadsheet.elements(table + "table") {
            try Task.checkCancellation()
            if reader.find("table", t.attributeValue(table + "style-name"))?.element(style + "table-properties")?
                .attributeValue(table + "display") != "false"
            {
                book.sheets.append(try reader.readTable(t))
            }
        }
        return book
    }
    private func readStyles(_ xml: XDocument?, _ content: XDocument) {
        for container in [
            xml?.root.element(Self.office + "styles"), xml?.root.element(Self.office + "automatic-styles"),
            content.root.element(Self.office + "automatic-styles"),
        ].compactMap({ $0 }) {
            for el in container.elements() {
                let name = el.attributeValue(Self.style + "name")
                if el.name == Self.style + "default-style" && el.attributeValue(Self.style + "family") == "table-cell" {
                    defaultCellStyle = el
                } else if el.name == Self.style + "style", let name {
                    styles[el.attributeValue(Self.style + "family") ?? "", default: [:]][name] = el
                } else if el.name.namespace == OdsNumberStyles.number, let name {
                    dataStyles[name] = el
                }
            }
        }
    }
    private func find(_ family: String, _ name: String?) -> XElement? { name.flatMap { styles[family]?[$0] } }
    private func cellStyleOf(_ name: String?) -> (CellStyle, String?) {
        let name = name ?? "Default"
        if let cached = cellStyles[name] { return cached }
        var chain: [XElement] = []
        var el = find("table-cell", name)
        while let current = el, chain.count < 20 {
            chain.insert(current, at: 0)
            el = find("table-cell", current.attributeValue(Self.style + "parent-style-name"))
        }
        if let defaultCellStyle { chain.insert(defaultCellStyle, at: 0) }
        var st = CellStyle()
        var dataStyle: String?
        var textAlign: String?
        var alignSource: String?
        let s = Self.style
        let fo = Self.fo
        for el in chain {
            if let t = el.element(s + "text-properties") {
                if let weight = t.attributeValue(fo + "font-weight") ?? t.attributeValue(s + "font-weight-asian") {
                    st.bold = weight == "bold" || (Int(weight) ?? 0) >= 600
                }
                if let italic = t.attributeValue(fo + "font-style") ?? t.attributeValue(s + "font-style-asian") {
                    st.italic = ["italic", "oblique"].contains(italic)
                }
                if let underline = t.attributeValue(s + "text-underline-style") { st.underline = underline != "none" }
                if let strike = t.attributeValue(s + "text-line-through-style") { st.strike = strike != "none" }
                if let size = Self.points(t.attributeValue(fo + "font-size")) { st.fontSize = size }
                if let color = Self.color(t.attributeValue(fo + "color")) { st.color = color }
            }
            if let c = el.element(s + "table-cell-properties") {
                if let fill = c.attributeValue(fo + "background-color") {
                    st.fill = fill == "transparent" ? nil : Self.color(fill)
                }
                if let all = Self.border(c.attributeValue(fo + "border")) {
                    st.left = all
                    st.right = all
                    st.top = all
                    st.bottom = all
                }
                st.left = Self.border(c.attributeValue(fo + "border-left")) ?? st.left
                st.right = Self.border(c.attributeValue(fo + "border-right")) ?? st.right
                st.top = Self.border(c.attributeValue(fo + "border-top")) ?? st.top
                st.bottom = Self.border(c.attributeValue(fo + "border-bottom")) ?? st.bottom
                if let v = c.attributeValue(s + "vertical-align") {
                    st.verticalAlign = v == "top" ? .top : v == "middle" ? .center : .bottom
                }
                if let wrap = c.attributeValue(fo + "wrap-option") { st.wrap = wrap == "wrap" }
                alignSource = c.attributeValue(s + "text-align-source") ?? alignSource
            }
            textAlign = el.element(s + "paragraph-properties")?.attributeValue(fo + "text-align") ?? textAlign
            dataStyle = el.attributeValue(s + "data-style-name") ?? dataStyle
        }
        st.align =
            alignSource == "value-type"
            ? .general
            : ["start": .left, "left": .left, "justify": .left, "center": .center, "end": .right, "right": .right][
                textAlign ?? ""] ?? .general
        cellStyles[name] = (st, dataStyle)
        return (st, dataStyle)
    }
    private func formatOf(_ dataStyle: String?) -> String? {
        guard let dataStyle else { return nil }
        if let cached = formats[dataStyle] { return cached }
        let value = dataStyles[dataStyle].flatMap { OdsNumberStyles.toExcel($0) { self.dataStyles[$0] } }
        formats[dataStyle] = .some(value)
        return value
    }
    private static func color(_ value: String?) -> String? {
        guard let value, value.utf8.count == 7, value.hasPrefix("#"), value.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return nil }
        return value.uppercased()
    }
    private static func border(_ value: String?) -> CellBorder? {
        guard let value else { return nil }
        let parts = value.split(separator: " ").map(String.init)
        guard
            let pattern = parts.first(where: {
                [
                    "solid", "dotted", "dashed", "dot-dash", "dot-dot-dash", "double", "groove", "ridge", "inset",
                    "outset", "fine-dashed", "dash-dot", "dash-dot-dot", "none", "hidden",
                ].contains($0)
            }), pattern != "none", pattern != "hidden"
        else { return CellBorder.none }
        let width = parts.compactMap(points).first ?? 0.75
        let color = parts.compactMap(color).first
        let style: String
        switch pattern {
        case "double": style = "double"
        case "dotted": style = "dotted"
        case "dashed", "fine-dashed": style = width > 1.1 ? "mediumDashed" : "dashed"
        case "dot-dash", "dash-dot": style = width > 1.1 ? "mediumDashDot" : "dashDot"
        case "dot-dot-dash", "dash-dot-dot": style = width > 1.1 ? "mediumDashDotDot" : "dashDotDot"
        default: style = width < 0.3 ? "hair" : width <= 1.1 ? "thin" : width <= 2.1 ? "medium" : "thick"
        }
        return CellBorder(style, color)
    }
    static func points(_ length: String?) -> Double? {
        guard let length, !length.isEmpty else { return nil }
        let numeric = String(length.prefix { "-+.0123456789".contains($0) })
        guard let value = Double(numeric) else { return nil }
        return ["pt": 1.0, "in": 72, "cm": 72 / 2.54, "mm": 72 / 25.4, "pc": 12, "px": 0.75][
            String(length.dropFirst(numeric.count))
        ].map { value * $0 }
    }
    private func readSettings(_ xml: XDocument?) {
        let c = Self.config
        let tables = xml?.root.descendants(c + "config-item-map-named").first {
            $0.attributeValue(c + "name") == "Tables"
        }
        for entry in tables?.elements(c + "config-item-map-entry") ?? [] {
            func item(_ name: String) -> String? {
                entry.elements(c + "config-item").first { $0.attributeValue(c + "name") == name }?.value
            }
            if item("VerticalSplitMode") == "2", let rows = SheetXML.int(item("VerticalSplitPosition")), rows > 0,
                let name = entry.attributeValue(c + "name")
            {
                frozenRows[name] = rows
            }
        }
    }
    private struct Span {
        let start: Int
        let count: Int
        let size: Double?
        let hidden: Bool
        let defaultStyle: String?
    }
    private struct CellRun {
        let column: Int
        let count: Int
        let cell: SheetCell?
        let columnSpan: Int
        let rowSpan: Int
    }
    private func readTable(_ table: XElement) throws -> Worksheet {
        let t = Self.table
        let s = Self.style
        let name = table.attributeValue(Self.table + "name") ?? "Sheet"
        let sheet = Worksheet(table.attributeValue(Self.table + "name") ?? "Sheet")
        var columns: [Span] = []
        var c = 0
        for (column, _) in Self.children(
            table, "table-column", "table-header-columns", ["table-column-group", "table-columns"])
        {
            if c >= 16384 { break }
            let count = min(Self.repeated(column, "number-columns-repeated"), 16384 - c)
            let width = Self.points(
                find("table-column", column.attributeValue(t + "style-name"))?.element(s + "table-column-properties")?
                    .attributeValue(s + "column-width"))
            columns.append(
                Span(
                    start: c, count: count, size: width.map { $0 / Self.pointsPerCharacter },
                    hidden: Self.collapsed(column), defaultStyle: column.attributeValue(t + "default-cell-style-name")))
            c += count
        }
        var rows: [Span] = []
        var r = 0
        var headerRows = 0
        for (row, header) in Self.children(table, "table-row", "table-header-rows", ["table-row-group", "table-rows"]) {
            try Task.checkCancellation()
            if r >= 1_048_576 { break }
            let count = min(Self.repeated(row, "number-rows-repeated"), 1_048_576 - r)
            let props = find("table-row", row.attributeValue(t + "style-name"))?.element(s + "table-row-properties")
            let height =
                props?.attributeValue(s + "use-optimal-row-height") == "true"
                ? nil : Self.points(props?.attributeValue(s + "row-height"))
            rows.append(Span(start: r, count: count, size: height, hidden: Self.collapsed(row), defaultStyle: nil))
            if header && headerRows == r { headerRows += count }
            let cells = cells(row, columns)
            let hasText = cells.contains { !($0.cell?.text.isEmpty ?? true) || $0.columnSpan > 1 || $0.rowSpan > 1 }
            let copies = hasText ? count : cells.contains(where: { $0.cell != nil }) && count <= 256 ? count : 0
            for copy in 0..<copies {
                if copy % 1024 == 0 { try Task.checkCancellation() }
                for run in cells {
                    for i in 0..<run.count {
                        if let cell = run.cell { sheet.set(r + copy, run.column + i, cell) }
                        if run.columnSpan > 1 || run.rowSpan > 1 {
                            sheet.merges.append(
                                CellRange(
                                    r + copy, run.column + i, r + copy + run.rowSpan - 1,
                                    run.column + i + run.columnSpan - 1))
                        }
                    }
                }
            }
            r += count
        }
        let used = sheet.usedRange()
        let right = max(used?.right ?? -1, sheet.merges.map(\.right).max() ?? -1)
        let bottom = max(used?.bottom ?? -1, sheet.merges.map(\.bottom).max() ?? -1)
        for span in columns {
            if span.start <= right {
                for i in span.start..<min(span.start + span.count, right + 1) {
                    if let width = span.size {
                        sheet.columnWidths[i] = (width * 10000).rounded(.toNearestOrEven) / 10000
                    }
                    if span.hidden { sheet.hiddenColumns.insert(i) }
                }
            }
            if let rest = span.size, span.start <= right + 1, right + 1 < span.start + span.count {
                sheet.defaultColumnWidth = (rest * 10000).rounded(.toNearestOrEven) / 10000
            }
        }
        for span in rows where span.start <= bottom {
            for i in span.start..<min(span.start + span.count, bottom + 1) {
                if let height = span.size { sheet.rowHeights[i] = (height * 100).rounded(.toNearestOrEven) / 100 }
                if span.hidden { sheet.hiddenRows.insert(i) }
            }
        }
        sheet.frozenRows = frozenRows[name] ?? headerRows
        return sheet
    }
    private static func children(_ parent: XElement, _ item: String, _ header: String, _ groups: [String]) -> [(
        XElement, Bool
    )] {
        var result: [(XElement, Bool)] = []
        for el in parent.elements() {
            if el.name == table + item {
                result.append((el, false))
            } else if el.name == table + header {
                result += children(el, item, header, groups).map { ($0.0, true) }
            } else if groups.contains(where: { el.name == table + $0 }) {
                result += children(el, item, header, groups)
            }
        }
        return result
    }
    private static func repeated(_ el: XElement, _ attr: String) -> Int {
        max(1, SheetXML.int(el.attributeValue(table + attr)) ?? 1)
    }
    private static func collapsed(_ el: XElement) -> Bool {
        ["collapse", "filter"].contains(el.attributeValue(table + "visibility") ?? "")
    }
    private func cells(_ row: XElement, _ columns: [Span]) -> [CellRun] {
        let t = Self.table
        let rowDefault = row.attributeValue(Self.table + "default-cell-style-name")
        var runs: [CellRun] = []
        var c = 0
        for el in row.elements() {
            let covered = el.name == t + "covered-table-cell"
            if !covered && el.name != t + "table-cell" { continue }
            if c >= 16384 { break }
            let count = min(Self.repeated(el, "number-columns-repeated"), 16384 - c)
            if !covered {
                let name =
                    el.attributeValue(t + "style-name") ?? rowDefault
                    ?? columns.first { $0.start <= c && c < $0.start + $0.count }?.defaultStyle
                var cell: SheetCell? = cell(el, name)
                if cell?.hasContent == false || cell?.text.isEmpty == true && count > 256 { cell = nil }
                let cs = Self.repeated(el, "number-columns-spanned")
                let rs = Self.repeated(el, "number-rows-spanned")
                if cell != nil || cs > 1 || rs > 1 {
                    runs.append(CellRun(column: c, count: count, cell: cell, columnSpan: cs, rowSpan: rs))
                }
            }
            c += count
        }
        return runs
    }
    private func cell(_ el: XElement, _ name: String?) -> SheetCell {
        let (style, dataStyle) = cellStyleOf(name)
        let o = Self.office
        let type = el.attributeValue(Self.office + "value-type")
        var value: Double?
        switch type {
        case "float", "percentage", "currency": value = SheetXML.double(el.attributeValue(o + "value"))
        case "date": value = el.attributeValue(o + "date-value").flatMap(SheetXML.date).map(NumberFormatter.toSerial)
        case "time": value = el.attributeValue(o + "time-value").flatMap(Self.duration)
        case "boolean": value = ["true", "1"].contains(el.attributeValue(o + "boolean-value") ?? "") ? 1 : 0
        default: break
        }
        let text = Self.paragraphs(el)
        if type == "boolean" {
            return SheetCell(text ?? (value == 1 ? "TRUE" : "FALSE"), style, value: value, isBoolean: true)
        }
        guard let v = value else { return SheetCell(text ?? el.attributeValue(o + "string-value") ?? "", style) }
        var format = formatOf(dataStyle)
        if format == nil {
            switch type {
            case "date": format = v == floor(v) ? "yyyy-mm-dd" : "yyyy-mm-dd hh:mm:ss"
            case "time": format = "hh:mm:ss"
            case "percentage": format = "0%"
            default: break
            }
        }
        if NumberFormatter.isGeneral(format) { format = nil }
        return SheetCell(text ?? formatter.format(v, format), style, isNumber: true, value: v, numberFormat: format)
    }
    static func duration(_ text: String) -> Double? {
        let pattern =
            "^(-)?P(?:(\\d+(?:\\.\\d+)?)Y)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)D)?(?:T(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?)?$"
        guard let re = try? NSRegularExpression(pattern: pattern),
            let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func num(_ i: Int) -> Double { Range(match.range(at: i), in: text).flatMap { Double(text[$0]) } ?? 0 }
        return (num(2) * 365 + num(3) * 30 + num(4) + num(5) / 24 + num(6) / 1440 + num(7) / 86400)
            * (match.range(at: 1).location == NSNotFound ? 1 : -1)
    }
    private static func paragraphs(_ cell: XElement) -> String? {
        let paragraphs = cell.elements().filter { $0.name == text + "p" || $0.name == text + "h" }
        if paragraphs.isEmpty { return nil }
        var sb = ""
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { sb += "\n" }
            inline(p, &sb)
        }
        return sb
    }
    private static func inline(_ el: XElement, _ sb: inout String) {
        for node in el.nodes {
            if let text = node.text {
                for scalar in text.unicodeScalars {
                    let c = [9, 10, 13].contains(scalar.value) ? UnicodeScalar(32)! : scalar
                    if c.value != 32 || sb.isEmpty || !sb.hasSuffix(" ") { sb.unicodeScalars.append(c) }
                }
            } else if let child = node.element {
                if child.name == text + "s" {
                    sb += String(
                        repeating: " ",
                        count: min(1_048_576, max(1, SheetXML.int(child.attributeValue(text + "c")) ?? 1)))
                } else if child.name == text + "tab" {
                    sb += "\t"
                } else if child.name == text + "line-break" {
                    sb += "\n"
                } else if child.name != office + "annotation" && child.name != text + "note" {
                    inline(child, &sb)
                }
            }
        }
    }
}
