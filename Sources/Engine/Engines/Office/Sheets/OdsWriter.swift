// Port of Filee.Engines/Office/Sheets/OdsWriter.cs.
import Foundation

enum OdsWriter {
    private static let mimeType = "application/vnd.oasis.opendocument.spreadsheet", version = "1.3"
    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    private static let namespaces =
        "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\""
    static func write(_ book: Workbook, _ path: String) throws {
        let sheets = book.sheets.isEmpty ? [Worksheet("Sheet1")] : book.sheets
        let names = XlsxWriter.uniqueNames(sheets.map(\.name))
        let styles = AutomaticStyles()
        var body = ""
        for i in sheets.indices { body += try table(sheets[i], names[i], styles) }
        let content =
            declaration
            + "<office:document-content \(namespaces) office:version=\"\(version)\"><office:automatic-styles>\(styles.xml())</office:automatic-styles><office:body><office:spreadsheet>\(body)</office:spreadsheet></office:body></office:document-content>"
        let frozen = sheets.indices.filter { sheets[$0].frozenRows > 0 }.map { (names[$0], sheets[$0].frozenRows) }
        let zip = try ZipWriter(path: path)
        try zip.add("mimetype", text: mimeType, level: .noCompression)
        try zip.add("content.xml", text: content)
        try zip.add(
            "styles.xml",
            text: declaration
                + "<office:document-styles \(namespaces) office:version=\"\(version)\"><office:styles><style:default-style style:family=\"table-cell\"><style:text-properties fo:font-size=\"11pt\" style:font-size-asian=\"11pt\" style:font-size-complex=\"11pt\"/></style:default-style><style:style style:name=\"Default\" style:family=\"table-cell\"/></office:styles></office:document-styles>"
        )
        if !frozen.isEmpty { try zip.add("settings.xml", text: settings(frozen)) }
        try zip.add(
            "META-INF/manifest.xml",
            text: declaration
                + "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"\(version)\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"\(version)\" manifest:media-type=\"\(mimeType)\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/>"
                + (frozen.isEmpty
                    ? ""
                    : "<manifest:file-entry manifest:full-path=\"settings.xml\" manifest:media-type=\"text/xml\"/>")
                + "</manifest:manifest>")
        try zip.close()
    }
    private struct Position: Hashable {
        let row: Int
        let column: Int
        init(_ row: Int, _ column: Int) {
            self.row = row
            self.column = column
        }
    }
    private static func table(_ sheet: Worksheet, _ name: String, _ styles: AutomaticStyles) throws -> String {
        let range = sheet.usedRange()
        let right = range?.right ?? 0
        let bottom = range?.bottom ?? 0
        var sb = "<table:table table:name=\"\(SheetXML.escape(name))\" table:style-name=\"ta1\">"
        var c = 0
        while c <= right {
            let width = sheet.columnWidth(c)
            let hidden = sheet.hiddenColumns.contains(c)
            var count = 1
            while c + count <= right && sheet.columnWidth(c + count) == width
                && sheet.hiddenColumns.contains(c + count) == hidden
            { count += 1 }
            sb +=
                "<table:table-column table:style-name=\"\(styles.column(width))\"\(repeated("columns",count))\(hidden ? " table:visibility=\"collapse\"" : "")/>"
            c += count
        }
        if right + 1 < 1024 {
            sb +=
                "<table:table-column table:style-name=\"\(styles.column(sheet.defaultColumnWidth))\"\(repeated("columns",1024 - right - 1))/>"
        }
        var anchors: [Position: CellRange] = [:]
        var covered = Set<Position>()
        for merge in sheet.merges {
            let pos = Position(merge.top, merge.left)
            if anchors[pos] != nil || covered.contains(pos) { continue }
            anchors[pos] = merge
            for r in merge.top...merge.bottom {
                try Task.checkCancellation()
                for c in merge.left...merge.right where r != merge.top || c != merge.left {
                    covered.insert(Position(r, c))
                }
            }
        }
        func empty(_ r: Int) -> Bool {
            sheet.rows[r] == nil && !(0...right).contains { covered.contains(Position(r, $0)) }
        }
        var r = 0
        while r <= bottom {
            try Task.checkCancellation()
            let height = sheet.rowHeights[r]
            let hidden = sheet.hiddenRows.contains(r)
            let visibility = hidden ? " table:visibility=\"collapse\"" : ""
            if empty(r) {
                var count = 1
                while r + count <= bottom && empty(r + count) && sheet.hiddenRows.contains(r + count) == hidden
                    && sheet.rowHeights[r + count] == height
                { count += 1 }
                sb +=
                    "<table:table-row table:style-name=\"\(styles.row(height))\"\(repeated("rows",count))\(visibility)><table:table-cell\(repeated("columns",right + 1))/></table:table-row>"
                r += count
                continue
            }
            sb += "<table:table-row table:style-name=\"\(styles.row(height))\"\(visibility)>"
            c = 0
            while c <= right {
                let cell = sheet.get(r, c)
                let isCovered = covered.contains(Position(r, c))
                if isCovered || cell == nil && anchors[Position(r, c)] == nil {
                    var count = 1
                    while c + count <= right && covered.contains(Position(r, c + count)) == isCovered
                        && (isCovered || sheet.get(r, c + count) == nil && anchors[Position(r, c + count)] == nil)
                    { count += 1 }
                    sb +=
                        (isCovered ? "<table:covered-table-cell" : "<table:table-cell") + repeated("columns", count)
                        + "/>"
                    c += count
                    continue
                }
                sb += cellXml(cell, anchors[Position(r, c)], styles)
                c += 1
            }
            sb += "</table:table-row>"
            r += 1
        }
        return sb + "</table:table>"
    }
    private static func cellXml(_ cell: SheetCell?, _ merge: CellRange?, _ styles: AutomaticStyles) -> String {
        var sb = "<table:table-cell"
        if let m = merge {
            if m.right > m.left { sb += " table:number-columns-spanned=\"\(m.right - m.left + 1)\"" }
            if m.bottom > m.top { sb += " table:number-rows-spanned=\"\(m.bottom - m.top + 1)\"" }
        }
        guard let cell else { return sb + "/>" }
        let number = cell.value ?? (cell.isNumber ? SheetXML.double(cell.text) : nil)
        var dataStyle: String?
        if cell.isBoolean, let flag = number {
            sb += " office:value-type=\"boolean\" office:boolean-value=\"\(flag != 0 ? "true" : "false")\""
        } else if let value = number, value.isFinite {
            let (name, type) = styles.dataStyle(cell.numberFormat)
            dataStyle = name
            sb += valueAttributes(value, type)
        } else if !cell.text.isEmpty {
            sb += " office:value-type=\"string\""
        }
        if let name = styles.cell(cell.style, dataStyle) { sb += " table:style-name=\"\(name)\"" }
        if cell.text.isEmpty { return sb + "/>" }
        return sb + ">" + paragraphs(cell.text) + "</table:table-cell>"
    }
    private static func valueAttributes(_ value: Double, _ type: String) -> String {
        if type == "date" && value > -657000 && value < 2_958_000 {
            let date = NumberFormatter.fromSerial(value)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let ms = Int((date.timeIntervalSince1970 * 1000).rounded()) % 1000
            formatter.dateFormat =
                value == floor(value) ? "yyyy-MM-dd" : ms == 0 ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd'T'HH:mm:ss.SSS"
            return " office:value-type=\"date\" office:date-value=\"\(formatter.string(from:date))\""
        }
        if type == "time" && abs(value) < 1e7 {
            let millis = (abs(value) * 86_400_000).rounded(.towardZero)
            let hours = Int64(millis / 3_600_000)
            let minutes = Int(millis / 60000) % 60
            let sec = millis.truncatingRemainder(dividingBy: 60000) / 1000
            let seconds = SheetXML.decimal(sec)
            let padded = sec < 10 ? "0" + seconds : seconds
            return
                " office:value-type=\"time\" office:time-value=\"\(value < 0 ? "-" : "")PT\(hours)H\(String(format:"%02d",minutes))M\(padded)S\""
        }
        return
            " office:value-type=\"\(["percentage","currency"].contains(type) ? type : "float")\" office:value=\"\(SheetXML.number(value))\""
    }
    private static func paragraphs(_ text: String) -> String {
        var sb = ""
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            sb += "<text:p>"
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if ch == " " {
                    var run = 1
                    while i + run < chars.count && chars[i + run] == " " { run += 1 }
                    let extra = i == 0 ? run : run - 1
                    if i > 0 { sb += " " }
                    if extra > 0 { sb += extra == 1 ? "<text:s/>" : "<text:s text:c=\"\(extra)\"/>" }
                    i += run
                } else {
                    if ch == "\t" { sb += "<text:tab/>" } else if ch != "\r" { sb += SheetXML.escape(String(ch)) }
                    i += 1
                }
            }
            sb += "</text:p>"
        }
        return sb
    }
    private static func repeated(_ what: String, _ count: Int) -> String {
        count > 1 ? " table:number-\(what)-repeated=\"\(count)\"" : ""
    }
    private static func settings(_ frozen: [(String, Int)]) -> String {
        var sb =
            declaration
            + "<office:document-settings xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\" office:version=\"\(version)\"><office:settings><config:config-item-set config:name=\"ooo:view-settings\"><config:config-item-map-indexed config:name=\"Views\"><config:config-item-map-entry><config:config-item config:name=\"ViewId\" config:type=\"string\">view1</config:config-item><config:config-item-map-named config:name=\"Tables\">"
        for (name, rows) in frozen {
            sb += "<config:config-item-map-entry config:name=\"\(SheetXML.escape(name))\">"
            for (item, type, value) in [
                ("HorizontalSplitMode", "short", 0), ("VerticalSplitMode", "short", 2),
                ("HorizontalSplitPosition", "int", 0), ("VerticalSplitPosition", "int", rows),
                ("ActiveSplitRange", "short", 2), ("PositionLeft", "int", 0), ("PositionRight", "int", 0),
                ("PositionTop", "int", 0), ("PositionBottom", "int", rows),
            ] {
                sb +=
                    "<config:config-item config:name=\"\(item)\" config:type=\"\(type)\">\(value)</config:config-item>"
            }
            sb += "</config:config-item-map-entry>"
        }
        return sb
            + "</config:config-item-map-named></config:config-item-map-entry></config:config-item-map-indexed></config:config-item-set></office:settings></office:document-settings>"
    }
    private final class AutomaticStyles {
        private var columns = "", rows = "", data = "", cells = ""
        private var columnNames: [Double: String] = [:], rowNames: [Double: String] = [:],
            dataNames: [String: (String?, String)] = [:]
        private struct Key: Hashable {
            let style: CellStyle
            let dataStyle: String?
        }
        private var cellNames: [Key: String] = [:]
        func column(_ width: Double) -> String {
            if let name = columnNames[width] { return name }
            let name = "co\(columnNames.count + 1)"
            columnNames[width] = name
            columns +=
                "<style:style style:name=\"\(name)\" style:family=\"table-column\"><style:table-column-properties fo:break-before=\"auto\" style:column-width=\"\(SheetXML.decimal(width * OdsReader.pointsPerCharacter))pt\"/></style:style>"
            return name
        }
        func row(_ height: Double?) -> String {
            let key = height ?? -1
            if let name = rowNames[key] { return name }
            let name = "ro\(rowNames.count + 1)"
            rowNames[key] = name
            rows +=
                "<style:style style:name=\"\(name)\" style:family=\"table-row\"><style:table-row-properties style:row-height=\"\(SheetXML.decimal(height ?? 15,2))pt\" fo:break-before=\"auto\" style:use-optimal-row-height=\"\(height == nil ? "true" : "false")\"/></style:style>"
            return name
        }
        func dataStyle(_ format: String?) -> (String?, String) {
            guard let format else { return (nil, "float") }
            if let cached = dataNames[format] { return cached }
            let name = "N\(dataNames.count + 1)"
            let result: (String?, String)
            if let (xml, type) = OdsNumberStyles.toOdf(format, name) {
                data += xml
                result = (name, type)
            } else {
                result = (nil, "float")
            }
            dataNames[format] = result
            return result
        }
        func cell(_ st: CellStyle, _ dataStyle: String?) -> String? {
            if st == .default && dataStyle == nil { return nil }
            let key = Key(style: st, dataStyle: dataStyle)
            if let name = cellNames[key] { return name }
            let name = "ce\(cellNames.count + 1)"
            cellNames[key] = name
            cells +=
                "<style:style style:name=\"\(name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\""
                + (dataStyle.map { " style:data-style-name=\"\($0)\"" } ?? "") + "><style:table-cell-properties"
            if let fill = st.fill { cells += " fo:background-color=\"\(fill)\"" }
            if st.left == st.right && st.left == st.top && st.left == st.bottom {
                if st.left.isVisible { cells += " fo:border=\"\(Self.border(st.left))\"" }
            } else {
                for (side, b) in [("left", st.left), ("right", st.right), ("top", st.top), ("bottom", st.bottom)] {
                    cells += " fo:border-\(side)=\"\(b.isVisible ? Self.border(b) : "none")\""
                }
            }
            if st.verticalAlign != .bottom {
                cells += " style:vertical-align=\"\(st.verticalAlign == .top ? "top" : "middle")\""
            }
            if st.wrap { cells += " fo:wrap-option=\"wrap\"" }
            if st.align != .general { cells += " style:text-align-source=\"fix\" style:repeat-content=\"false\"" }
            cells += "/>"
            if st.align != .general {
                cells +=
                    "<style:paragraph-properties fo:text-align=\"\(st.align == .left ? "start" : st.align == .center ? "center" : "end")\"/>"
            }
            var text = ""
            if st.bold {
                text += " fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\""
            }
            if st.italic {
                text +=
                    " fo:font-style=\"italic\" style:font-style-asian=\"italic\" style:font-style-complex=\"italic\""
            }
            if st.underline {
                text +=
                    " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\""
            }
            if st.strike { text += " style:text-line-through-style=\"solid\" style:text-line-through-type=\"single\"" }
            if let size = st.fontSize {
                let size = SheetXML.decimal(size, 2)
                text +=
                    " fo:font-size=\"\(size)pt\" style:font-size-asian=\"\(size)pt\" style:font-size-complex=\"\(size)pt\""
            }
            if let color = st.color { text += " fo:color=\"\(color)\"" }
            if !text.isEmpty { cells += "<style:text-properties\(text)/>" }
            cells += "</style:style>"
            return name
        }
        func xml() -> String {
            columns + rows
                + "<style:style style:name=\"ta1\" style:family=\"table\"><style:table-properties table:display=\"true\" style:writing-mode=\"lr-tb\"/></style:style>"
                + data + cells
        }
        private static func border(_ b: CellBorder) -> String {
            let pair: (Double, String)
            switch b.style {
            case "hair": pair = (0.1, "solid")
            case "medium": pair = (1.75, "solid")
            case "thick": pair = (2.5, "solid")
            case "double": pair = (2.25, "double")
            case "dotted": pair = (0.75, "dotted")
            case "dashed": pair = (0.75, "dashed")
            case "mediumDashed": pair = (1.75, "dashed")
            case "dashDot": pair = (0.75, "dot-dash")
            case "mediumDashDot", "slantDashDot": pair = (1.75, "dot-dash")
            case "dashDotDot": pair = (0.75, "dot-dot-dash")
            case "mediumDashDotDot": pair = (1.75, "dot-dot-dash")
            default: pair = (0.75, "solid")
            }
            return "\(SheetXML.number(pair.0))pt \(pair.1) \(b.color ?? "#000000")"
        }
    }
}
