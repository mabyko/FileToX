// Swift replacement for ExcelDataReader used by Filee's XlsReader.cs: BIFF2–8 records in an OLE2 container.
// As in Filee, XLS keeps values, alignment and layout; fonts, fills and borders are not exposed in its model.
import Foundation

enum XlsReader {
    private static let password =
        "The workbook is protected with a password (encrypted). Remove the password in Excel and convert it again."
    static func read(_ path: String) throws -> Workbook {
        let file = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
        if file.starts(with: [0x50, 0x4b]) { return try XlsxReader.read(path) }
        let stream: [UInt8]
        if let compound = try XlsLayout.workbookStream(file) {
            stream = compound
        } else if file.count >= 4 && [0x0009, 0x0209, 0x0409, 0x0809].contains(XlsLayout.u16(file)) {
            stream = file
        } else {
            throw ConversionError(
                file.starts(with: [60]) || file.starts(with: [0xef, 0xbb, 0xbf, 60])
                    ? "The file is not an Excel 97–2003 workbook but a web page or XML file saved with an .xls name. Open it in Excel and save it as XLSX."
                    : "The file is not an Excel 97–2003 workbook.")
        }
        return try Reader(stream).read()
    }
    private final class Reader {
        // ExcelDataReader 3.9 built-ins absent from Filee's shared (locale-independent) table.
        private static let additionalBuiltIns: [Int: String] = [
            5: "\"$\"#,##0_);(\"$\"#,##0)",
            6: "\"$\"#,##0_);[Red](\"$\"#,##0)",
            7: "\"$\"#,##0.00_);(\"$\"#,##0.00)",
            8: "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)",
            41: "_(\"$\"* #,##0_);_(\"$\"* (#,##0);_(\"$\"* \"-\"_);_(@_)",
            42: "_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)",
            43: "_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)",
            44: "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)",
            27: "[$-411]ge.m.d",
            28: "[$-411]ggge\"年\"m\"月\"d\"日\"",
            29: "[$-411]ggge\"年\"m\"月\"d\"日\"",
            30: "m/d/yy",
            31: "yyyy\"年\"m\"月\"d\"日\"",
            32: "h\"時\"mm\"分\"",
            33: "h\"時\"mm\"分\"ss\"秒\"",
            34: "yyyy\"年\"m\"月\"",
            35: "m\"月\"d\"日\"",
            36: "[$-411]ge.m.d",
            50: "[$-411]ge.m.d",
            51: "[$-411]ggge\"年\"m\"月\"d\"日\"",
            52: "yyyy\"年\"m\"月\"",
            53: "m\"月\"d\"日\"",
            54: "[$-411]ggge\"年\"m\"月\"d\"日\"",
            55: "yyyy\"年\"m\"月\"",
            56: "m\"月\"d\"日\"",
            57: "[$-411]ge.m.d",
            58: "[$-411]ggge\"年\"m\"月\"d\"日\"",
            59: "0",
            60: "0.00",
            61: "#,##0",
            62: "#,##0.00",
            67: "0%",
            68: "0.00%",
            69: "# ?/?",
            70: "# ??/??",
            71: "d/m/yyyy",
            72: "d-mmm-yy",
            73: "d-mmm",
            74: "mmm-yy",
            75: "h:mm",
            76: "h:mm:ss",
            77: "d/m/yyyy h:mm",
            78: "mm:ss",
            79: "[h]:mm:ss",
            80: "mm:ss.0",
            81: "d/m/yyyy",
        ]
        private static let builtinDates: Set<Int> = [
            14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 47, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 50, 51, 52, 53, 54, 55,
            56, 57, 58, 71, 72, 73, 74, 75, 76, 77, 78, 80, 81,
        ]

        let stream: [UInt8]
        var biff8 = true, biff2 = false, date1904 = false, codepage = 1252
        let formatter = NumberFormatter()
        var formats: [Int: String] = [:], xfs: [(format: Int, style: CellStyle)] = [], strings: [String] = []
        init(_ stream: [UInt8]) { self.stream = stream }
        func read() throws -> Workbook {
            let globals = try XlsLayout.records(stream, 0)
            let version = globals.first.map { XlsLayout.u16($0.data) } ?? 0
            biff8 = version >= 0x0600
            biff2 = XlsLayout.u16(stream) == 0x0009
            var bounds: [(offset: Int, name: String, hidden: Bool)] = []
            var formatIndex = 0
            for (i, record) in globals.enumerated() {
                let d = record.data
                switch record.id {
                case 0x002f: throw ConversionError(password)
                case 0x0042: codepage = XlsLayout.u16(d)
                case 0x0022: date1904 = XlsLayout.u16(d) != 0
                case 0x0085 where d.count >= 7:
                    if d[5] == 0 {
                        let name =
                            biff8
                            ? try UnicodeCursor(segments(globals, i, 6)).string(true)
                            : ansi(Array(d.dropFirst(7).prefix(Int(d[6]))))
                        bounds.append((Int(XlsLayout.u32(d)), name, d[4] != 0))
                    }
                case 0x041e, 0x001e:
                    if biff8 {
                        if d.count >= 5 {
                            formats[XlsLayout.u16(d)] = try UnicodeCursor(segments(globals, i, 2)).string()
                        }
                    } else if d.count > 2 {
                        let id = record.id == 0x041e ? XlsLayout.u16(d) : formatIndex
                        let p = record.id == 0x041e ? 2 : 0
                        if p < d.count { formats[id] = ansi(Array(d.dropFirst(p + 1).prefix(Int(d[p])))) }
                        formatIndex += 1
                    }
                case 0x00e0, 0x0043, 0x0243, 0x0443:
                    var st = CellStyle()
                    let alignment = d.count > 6 ? Int(d[6]) : 0
                    switch alignment & 7 {
                    case 1, 4, 5, 7: st.align = .left
                    case 2, 6: st.align = .center
                    case 3: st.align = .right
                    default: break
                    }
                    switch (alignment >> 4) & 7 {
                    case 0: st.verticalAlign = .top
                    case 1, 3, 4: st.verticalAlign = .center
                    default: break
                    }
                    xfs.append((XlsLayout.u16(d, 2), st))
                case 0x00fc:
                    let cursor = UnicodeCursor(segments(globals, i))
                    _ = try cursor.uint32()
                    let count = Int(try cursor.uint32())
                    guard count <= stream.count else {
                        throw ConversionError(
                            "The Excel 97–2003 workbook could not be read: Invalid shared string count.")
                    }
                    strings = []
                    for n in 0..<count {
                        if n % 1024 == 0 { try Task.checkCancellation() }
                        strings.append(try cursor.string())
                    }
                default: break  // FONT, DIMENSION and non-cell metadata do not change Filee's displayed-cell model.
                }
            }
            if bounds.isEmpty {
                // BIFF2–4 consist of a single worksheet substream.
                let book = Workbook()
                book.sheets.append(try sheet(globals, "Sheet"))
                return book
            }
            let book = Workbook()
            for b in bounds where !b.hidden {
                try Task.checkCancellation()
                book.sheets.append(try sheet(XlsLayout.records(stream, b.offset), b.name.isEmpty ? "Sheet" : b.name))
            }
            return book
        }
        private func segments(_ records: [XlsLayout.Record], _ index: Int, _ skip: Int = 0) -> [[UInt8]] {
            var segments = [Array(records[index].data.dropFirst(skip))]
            var next = index + 1
            while next < records.count && records[next].id == 0x003c {
                segments.append(records[next].data)
                next += 1
            }
            return segments
        }
        private func ansi(_ bytes: [UInt8]) -> String {
            TextEncodings.decode(Data(bytes), encoding: TextEncodings.encoding(codePage: codepage) ?? .windowsCP1252)
        }
        private func number(_ v: Double, _ xf: Int) -> SheetCell {
            let spec = xf >= 0 && xf < xfs.count ? xfs[xf] : (format: 0, style: CellStyle.default)
            let format =
                NumberFormatter.builtInFormats[spec.format] ?? formats[spec.format]
                ?? Self.additionalBuiltIns[spec.format]
            var value = v
            if formatter.isDate(format) || Self.builtinDates.contains(spec.format) {
                // ExcelDataReader converts dates through DateTime before Filee gets their serial again.
                // This also rounds to milliseconds and maps the fictitious 1900-02-29 to February 28.
                let oa = date1904 ? v + 1462 : v >= 0 && v < 60 ? v + 1 : v
                if oa > -657435 && oa < 2_958_466 {
                    var millis = (oa * 86_400_000).rounded(.toNearestOrAwayFromZero)
                    if millis < 0 { millis -= millis.truncatingRemainder(dividingBy: 86_400_000) * 2 }
                    if millis < 0 {
                        let fraction = millis.truncatingRemainder(dividingBy: 86_400_000)
                        if fraction != 0 { millis -= (86_400_000 + fraction) * 2 }
                    }
                    let normalized = millis / 86_400_000
                    value = normalized >= 1 && normalized < 61 ? normalized - 1 : normalized
                }
            }
            return SheetCell(
                formatter.format(value, format), spec.style, isNumber: true, value: value,
                numberFormat: NumberFormatter.isGeneral(format) ? nil : format)
        }
        private func sheet(_ records: [XlsLayout.Record], _ name: String) throws -> Worksheet {
            let sheet = Worksheet(name)
            var pending: (Int, Int, CellStyle)?
            for (idx, record) in records.enumerated() {
                if idx % 1024 == 0 { try Task.checkCancellation() }
                let d = record.data
                let id = record.id
                if id == 0x002f { throw ConversionError(password) }
                if id == 0x0207 || id == 0x0007 {
                    if let (r, c, style) = pending {
                        let text =
                            biff8
                            ? try UnicodeCursor(segments(records, idx)).string()
                            : d.isEmpty ? "" : ansi(Array(d.dropFirst(1).prefix(Int(d[0]))))
                        sheet.set(r, c, SheetCell(text, style))
                        pending = nil
                    }
                    continue
                }
                if id == 0x00e5 && d.count >= 2 {
                    let count = min(XlsLayout.u16(d), (d.count - 2) / 8)
                    for i in 0..<count {
                        let p = 2 + i * 8
                        let m = CellRange(
                            XlsLayout.u16(d, p), XlsLayout.u16(d, p + 4), XlsLayout.u16(d, p + 2),
                            XlsLayout.u16(d, p + 6))
                        if m.bottom > m.top || m.right > m.left { sheet.merges.append(m) }
                    }
                    continue
                }
                if id == 0x00bd && d.count >= 12 {
                    let row = XlsLayout.u16(d)
                    let first = XlsLayout.u16(d, 2)
                    let count = (d.count - 6) / 6
                    for i in 0..<count {
                        let p = 4 + i * 6
                        sheet.set(row, first + i, number(Self.rk(XlsLayout.u32(d, p + 2)), XlsLayout.u16(d, p)))
                    }
                    continue
                }
                guard d.count >= (biff2 ? 7 : 6) else { continue }
                let row = XlsLayout.u16(d)
                let col = XlsLayout.u16(d, 2)
                let xf = biff2 ? Int(d[4] & 0x3f) : XlsLayout.u16(d, 4)
                let p = biff2 ? 7 : 6
                let style = xf < xfs.count ? xfs[xf].style : .default
                var cell: SheetCell?
                switch id {
                case 0x0203 where d.count >= p + 8, 0x0003 where d.count >= p + 8:
                    cell = number(XlsLayout.double(d, p), xf)
                case 0x0002 where d.count >= p + 2: cell = number(Double(XlsLayout.u16(d, p)), xf)
                case 0x027e where d.count >= 10: cell = number(Self.rk(XlsLayout.u32(d, 6)), xf)
                case 0x00fd where d.count >= 10:
                    let i = Int(XlsLayout.u32(d, 6))
                    cell = SheetCell(i < strings.count ? strings[i] : "", style)
                case 0x0204, 0x0004, 0x00d6:
                    if biff8 {
                        cell = SheetCell(try UnicodeCursor(segments(records, idx, p)).string(), style)
                    } else if d.count > p {
                        let lenSize = biff2 ? 1 : 2
                        let count = biff2 ? Int(d[p]) : XlsLayout.u16(d, p)
                        cell = SheetCell(ansi(Array(d.dropFirst(p + lenSize).prefix(count))), style)
                    }
                case 0x0205 where d.count >= p + 2, 0x0005 where d.count >= p + 2:
                    cell =
                        d[p + 1] != 0
                        ? SheetCell(Self.error(d[p]), style)
                        : SheetCell(d[p] != 0 ? "TRUE" : "FALSE", style, value: d[p] != 0 ? 1 : 0, isBoolean: true)
                case 0x0006 where d.count >= p + 8, 0x0206 where d.count >= p + 8, 0x0406 where d.count >= p + 8:
                    if d[p + 6] == 0xff && d[p + 7] == 0xff {
                        switch d[p] {
                        case 0: pending = (row, col, style)
                        case 1:
                            cell = SheetCell(
                                d[p + 2] != 0 ? "TRUE" : "FALSE", style, value: d[p + 2] != 0 ? 1 : 0, isBoolean: true)
                        case 2: cell = SheetCell(Self.error(d[p + 2]), style)
                        default: break
                        }
                    } else {
                        cell = number(XlsLayout.double(d, p), xf)
                    }
                default: break
                }
                if let cell, cell.hasContent { sheet.set(row, col, cell) }
            }
            let layout = XlsLayout.parse(records)
            for (c, value) in layout.columns {
                if value.hidden { sheet.hiddenColumns.insert(c) } else { sheet.columnWidths[c] = value.width }
            }
            for (r, value) in layout.rows {
                if value.hidden {
                    sheet.hiddenRows.insert(r)
                } else if value.custom {
                    sheet.rowHeights[r] = value.points
                }
            }
            return sheet
        }
        private static func rk(_ raw: UInt32) -> Double {
            let v =
                raw & 2 != 0 ? Double(Int32(bitPattern: raw) >> 2) : Double(bitPattern: UInt64(raw & 0xffff_fffc) << 32)
            return raw & 1 != 0 ? v / 100 : v
        }
        private static func error(_ code: UInt8) -> String {
            [
                0x00: "#NULL!", 0x07: "#DIV/0!", 0x0f: "#VALUE!", 0x17: "#REF!", 0x1d: "#NAME?", 0x24: "#NUM!",
                0x2a: "#N/A",
            ][Int(code)] ?? "#GETTING_DATA"
        }
    }
    // A CONTINUE record begins with a new compression flag only while continuing the character array;
    // rich-text runs and extension data cross record boundaries without that extra byte.
    private final class UnicodeCursor {
        let segments: [[UInt8]]
        var segment = 0, offset = 0
        init(_ segments: [[UInt8]]) { self.segments = segments }
        func byte() throws -> UInt8 {
            while segment < segments.count && offset >= segments[segment].count {
                segment += 1
                offset = 0
            }
            guard segment < segments.count else {
                throw ConversionError("The Excel 97–2003 workbook could not be read: Truncated string.")
            }
            let b = segments[segment][offset]
            offset += 1
            return b
        }
        func uint16() throws -> Int {
            let a = try byte()
            return Int(a) | Int(try byte()) << 8
        }
        func uint32() throws -> UInt32 {
            let a = try uint16()
            return UInt32(a) | UInt32(try uint16()) << 16
        }
        func string(_ short: Bool = false) throws -> String {
            let count = short ? Int(try byte()) : try uint16()
            let flags = try byte()
            let runs = flags & 8 != 0 ? try uint16() : 0
            let ext = flags & 4 != 0 ? Int(try uint32()) : 0
            var wide = flags & 1 != 0
            var chars: [UInt16] = []
            for _ in 0..<count {
                if segment < segments.count && offset >= segments[segment].count {
                    segment += 1
                    offset = 0
                    wide = try byte() & 1 != 0
                }
                chars.append(wide ? UInt16(try uint16()) : UInt16(try byte()))
            }
            guard runs <= 65535, ext <= 100_000_000 else {
                throw ConversionError("The Excel 97–2003 workbook could not be read: Invalid string extension.")
            }
            for i in 0..<(runs * 4 + ext) {
                if i % 4096 == 0 { try Task.checkCancellation() }
                _ = try byte()
            }
            return String(decoding: chars, as: UTF16.self)
        }
    }
}
