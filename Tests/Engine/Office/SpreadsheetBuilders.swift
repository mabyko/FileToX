import Foundation

@testable import FileToXEngineKit

enum OdsBuilder {
    static let odsStyles = #"""
        <style:default-style style:family="table-cell"><style:text-properties fo:font-size="10pt"/></style:default-style>
        <style:style style:name="Default" style:family="table-cell"/>
        <style:style style:name="Heading" style:family="table-cell" style:parent-style-name="Default"><style:text-properties fo:font-weight="bold" fo:font-size="14pt"/></style:style>
        <number:number-style style:name="N4"><number:number number:decimal-places="2" number:min-decimal-places="2" number:min-integer-digits="1" number:grouping="true"/></number:number-style>
        """#
    static let odsAutomaticStyles = #"""
        <style:style style:name="co1" style:family="table-column"><style:table-column-properties style:column-width="2.54cm"/></style:style>
        <style:style style:name="co2" style:family="table-column"><style:table-column-properties style:column-width="0.8in"/></style:style>
        <style:style style:name="ro1" style:family="table-row"><style:table-row-properties style:row-height="0.178in" style:use-optimal-row-height="true"/></style:style>
        <style:style style:name="ro2" style:family="table-row"><style:table-row-properties style:row-height="30pt" style:use-optimal-row-height="false"/></style:style>
        <style:style style:name="ta1" style:family="table"><style:table-properties table:display="true"/></style:style>
        <style:style style:name="ta2" style:family="table"><style:table-properties table:display="false"/></style:style>
        <number:percentage-style style:name="N10"><number:number number:decimal-places="1" number:min-decimal-places="1" number:min-integer-digits="1"/><number:text>%</number:text></number:percentage-style>
        <number:currency-style style:name="N11P0" style:volatile="true"><number:currency-symbol>₩</number:currency-symbol><number:number number:decimal-places="0" number:min-integer-digits="1" number:grouping="true"/></number:currency-style>
        <number:currency-style style:name="N11"><style:text-properties fo:color="#ff0000"/><number:text>-</number:text><number:currency-symbol>₩</number:currency-symbol><number:number number:decimal-places="0" number:min-integer-digits="1" number:grouping="true"/><style:map style:condition="value()&gt;=0" style:apply-style-name="N11P0"/></number:currency-style>
        <number:date-style style:name="N12"><number:year number:style="long"/><number:text>년 </number:text><number:month/><number:text>월 </number:text><number:day/><number:text>일</number:text></number:date-style>
        <number:time-style style:name="N13"><number:hours number:style="long"/><number:text>:</number:text><number:minutes number:style="long"/></number:time-style>
        <style:style style:name="ce1" style:family="table-cell" style:parent-style-name="Heading"><style:table-cell-properties fo:background-color="#1f4e79" fo:border="0.75pt solid #000000" style:text-align-source="fix" style:vertical-align="middle"/><style:paragraph-properties fo:text-align="center"/><style:text-properties fo:color="#ffffff"/></style:style>
        <style:style style:name="ce2" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N4"/>
        <style:style style:name="ce3" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N10"/>
        <style:style style:name="ce4" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N11"/>
        <style:style style:name="ce5" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N12"/>
        <style:style style:name="ce6" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N13"/>
        <style:style style:name="ce7" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:border-bottom="2.5pt double #c00000" fo:wrap-option="wrap"/><style:text-properties fo:font-style="italic" style:text-underline-style="solid" style:text-line-through-style="solid"/></style:style>
        <style:style style:name="ce8" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:background-color="#ffff00"/></style:style>
        """#
    static let odsTables = #"""
        <table:table table:name="매출" table:style-name="ta1">
          <table:table-column table:style-name="co1" table:default-cell-style-name="Default"/>
          <table:table-column table:style-name="co2" table:number-columns-repeated="2" table:default-cell-style-name="Default"/>
          <table:table-column table:style-name="co2" table:visibility="collapse" table:default-cell-style-name="Default"/>
          <table:table-column table:style-name="co1" table:number-columns-repeated="16380" table:default-cell-style-name="Default"/>
          <table:table-header-rows>
            <table:table-row table:style-name="ro2">
              <table:table-cell table:style-name="ce1" office:value-type="string" table:number-columns-spanned="3" table:number-rows-spanned="1"><text:p>지점별 매출</text:p></table:table-cell>
              <table:covered-table-cell table:number-columns-repeated="2"/>
              <table:table-cell table:number-columns-repeated="16381"/>
            </table:table-row>
          </table:table-header-rows>
          <table:table-row table:style-name="ro1">
            <table:table-cell table:style-name="ce2" office:value-type="float" office:value="1234.5"><text:p>1,234.50</text:p></table:table-cell>
            <table:table-cell table:style-name="ce3" office:value-type="percentage" office:value="0.128"><text:p>12.8%</text:p></table:table-cell>
            <table:table-cell table:style-name="ce4" office:value-type="currency" office:currency="KRW" office:value="-5000"><text:p>-₩5,000</text:p></table:table-cell>
            <table:table-cell table:number-columns-repeated="16381"/>
          </table:table-row>
          <table:table-row table:style-name="ro1">
            <table:table-cell table:style-name="ce5" office:value-type="date" office:date-value="2026-10-01"><text:p>2026년 10월 1일</text:p></table:table-cell>
            <table:table-cell table:style-name="ce6" office:value-type="time" office:time-value="PT13H30M00S"><text:p>13:30</text:p></table:table-cell>
            <table:table-cell office:value-type="boolean" office:boolean-value="true"><text:p>TRUE</text:p></table:table-cell>
            <table:table-cell office:value-type="string" calcext:value-type="error"><text:p>#DIV/0!</text:p></table:table-cell>
            <table:table-cell table:number-columns-repeated="16380"/>
          </table:table-row>
          <table:table-row table:style-name="ro1" table:number-rows-repeated="2">
            <table:table-cell office:value-type="float" office:value="7" table:number-columns-repeated="3"><text:p>7</text:p></table:table-cell>
            <table:table-cell table:number-columns-repeated="16381"/>
          </table:table-row>
          <table:table-row table:style-name="ro1" table:visibility="collapse">
            <table:table-cell office:value-type="string"><text:p>숨긴 행</text:p></table:table-cell>
            <table:table-cell table:number-columns-repeated="16383"/>
          </table:table-row>
          <table:table-row table:style-name="ro1">
            <table:table-cell table:style-name="ce7" office:value-type="string"><office:annotation><text:p>메모는 셀 내용이 아님</text:p></office:annotation><text:p><text:s/>앞 공백<text:s text:c="2"/>세 칸<text:tab/>탭<text:line-break/>줄</text:p><text:p><text:span>둘째</text:span> <text:span>문단</text:span></text:p></table:table-cell>
            <table:table-cell table:number-columns-repeated="16383"/>
          </table:table-row>
          <table:table-row table:style-name="ro1" table:number-rows-repeated="1048569">
            <table:table-cell table:number-columns-repeated="16384"/>
          </table:table-row>
        </table:table>
        <table:table table:name="비밀" table:style-name="ta2">
          <table:table-column/>
          <table:table-row><table:table-cell office:value-type="string"><text:p>보이면 안 됨</text:p></table:table-cell></table:table-row>
        </table:table>
        <table:table table:name="색칠" table:style-name="ta1">
          <table:table-column table:default-cell-style-name="ce8" table:number-columns-repeated="2"/>
          <table:table-column table:number-columns-repeated="16382"/>
          <table:table-row>
            <table:table-cell office:value-type="float" office:value="1"><text:p>1</text:p></table:table-cell>
            <table:table-cell/>
            <table:table-cell table:number-columns-repeated="16382"/>
          </table:table-row>
          <table:table-row table:number-rows-repeated="1048575">
            <table:table-cell table:style-name="ce8" table:number-columns-repeated="2"/>
            <table:table-cell table:number-columns-repeated="16382"/>
          </table:table-row>
        </table:table>
        """#
    static let odsSettings = #"""
        <office:document-settings \#(namespaces) office:version="1.3"><office:settings>
          <config:config-item-set config:name="ooo:view-settings"><config:config-item-map-indexed config:name="Views"><config:config-item-map-entry>
            <config:config-item-map-named config:name="Tables">
              <config:config-item-map-entry config:name="색칠">
                <config:config-item config:name="VerticalSplitMode" config:type="short">2</config:config-item>
                <config:config-item config:name="VerticalSplitPosition" config:type="int">1</config:config-item>
              </config:config-item-map-entry>
            </config:config-item-map-named>
          </config:config-item-map-entry></config:config-item-map-indexed></config:config-item-set>
        </office:settings></office:document-settings>
        """#
}

extension OdsBuilder {
    static let namespaces =
        "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\" xmlns:config=\"urn:oasis:names:tc:opendocument:xmlns:config:1.0\" xmlns:calcext=\"urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0\""
    static func sales(_ path: String, _ encrypted: Bool = false) throws -> String {
        let zip = try ZipWriter(path: path)
        try zip.add("mimetype", text: "application/vnd.oasis.opendocument.spreadsheet", level: .noCompression)
        try zip.add(
            "content.xml",
            text: SheetXML.declaration
                + "<office:document-content \(namespaces) office:version=\"1.3\"><office:automatic-styles>\(odsAutomaticStyles)</office:automatic-styles><office:body><office:spreadsheet>\(odsTables)</office:spreadsheet></office:body></office:document-content>"
        )
        try zip.add(
            "styles.xml",
            text: SheetXML.declaration
                + "<office:document-styles \(namespaces) office:version=\"1.3\"><office:styles>\(odsStyles)</office:styles></office:document-styles>"
        )
        try zip.add("settings.xml", text: SheetXML.declaration + odsSettings)
        try zip.add(
            "META-INF/manifest.xml",
            text:
                "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\"><manifest:file-entry manifest:full-path=\"content.xml\">"
                + (encrypted ? "<manifest:encryption-data/>" : "") + "</manifest:file-entry></manifest:manifest>")
        try zip.close()
        return path
    }
}

final class XlsBuilder {
    var strings: [String] = [], sheets: [Sheet] = [], date1904 = false
    struct Cell {
        let row: Int
        let column: Int
        let xf: Int
        let id: Int
        let data: [UInt8]
    }
    final class Sheet {
        let book: XlsBuilder, name: String, hidden: Bool
        var cells: [Cell] = [], extra: [(Int, [UInt8])] = [], merges: [CellRange] = []
        init(_ book: XlsBuilder, _ name: String, _ hidden: Bool) {
            self.book = book
            self.name = name
            self.hidden = hidden
        }
        @discardableResult func text(_ r: Int, _ c: Int, _ text: String, _ xf: Int = 0) -> Sheet {
            let i = book.strings.firstIndex(of: text) ?? book.strings.count
            if i == book.strings.count { book.strings.append(text) }
            cells.append(Cell(row: r, column: c, xf: xf, id: 0x00fd, data: XlsBuilder.u32(i)))
            return self
        }
        @discardableResult func number(_ r: Int, _ c: Int, _ v: Double, _ xf: Int = 0) -> Sheet {
            cells.append(Cell(row: r, column: c, xf: xf, id: 0x0203, data: XlsBuilder.f64(v)))
            return self
        }
        @discardableResult func bool(_ r: Int, _ c: Int, _ v: Bool) -> Sheet {
            cells.append(Cell(row: r, column: c, xf: 0, id: 0x0205, data: [v ? 1 : 0, 0]))
            return self
        }
        @discardableResult func error(_ r: Int, _ c: Int, _ code: UInt8) -> Sheet {
            cells.append(Cell(row: r, column: c, xf: 0, id: 0x0205, data: [code, 1]))
            return self
        }
        @discardableResult func width(_ c: Int, _ width: Double, _ hidden: Bool = false) -> Sheet {
            extra.append(
                (
                    0x007d,
                    XlsBuilder.u16(c) + XlsBuilder.u16(c) + XlsBuilder.u16(Int(width * 256)) + XlsBuilder.u16(15)
                        + XlsBuilder.u16(hidden ? 3 : 2) + [0, 0]
                ))
            return self
        }
        @discardableResult func height(_ r: Int, _ height: Double, _ hidden: Bool = false) -> Sheet {
            extra.append(
                (
                    0x0208,
                    XlsBuilder.u16(r) + [0, 0, 5, 0] + XlsBuilder.u16(Int(height * 20)) + [0, 0, 0, 0]
                        + XlsBuilder.u16(hidden ? 0x160 : 0x140) + [15, 0]
                ))
            return self
        }
        @discardableResult func merge(_ m: CellRange) -> Sheet {
            merges.append(m)
            return self
        }
        func bytes() -> [UInt8] {
            var b = XlsBuilder.record(0x0809, XlsBuilder.bof(0x10)) + XlsBuilder.record(0x0225, [0, 0, 44, 1])
            for (id, data) in extra { b += XlsBuilder.record(id, data) }
            for cell in cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
                b += XlsBuilder.record(
                    cell.id,
                    XlsBuilder.u16(cell.row) + XlsBuilder.u16(cell.column) + XlsBuilder.u16(cell.xf) + cell.data)
            }
            if !merges.isEmpty {
                b += XlsBuilder.record(
                    0x00e5,
                    XlsBuilder.u16(merges.count)
                        + merges.flatMap {
                            XlsBuilder.u16($0.top) + XlsBuilder.u16($0.bottom) + XlsBuilder.u16($0.left)
                                + XlsBuilder.u16($0.right)
                        })
            }
            return b + XlsBuilder.record(0x000a, [])
        }
    }
    func sheet(_ name: String, _ hidden: Bool = false) -> Sheet {
        let sheet = Sheet(self, name, hidden)
        sheets.append(sheet)
        return sheet
    }
    func save(_ path: String, _ encrypted: Bool = false) throws -> String {
        var b = Self.record(0x0809, Self.bof(5))
        if encrypted { b += Self.record(0x002f, [0, 0, 0x34, 0x12, 1, 0]) }
        b += Self.record(0x0042, Self.u16(1200)) + Self.record(0x0022, Self.u16(date1904 ? 1 : 0))
        for (id, code) in [(164, "#,##0\"원\""), (165, "0.0%")] {
            b += Self.record(0x041e, Self.u16(id) + Self.unicode(code))
        }
        for (f, h, v) in [(0, 0, 2), (0, 2, 2), (164, 0, 2), (14, 0, 2), (165, 0, 2), (20, 0, 2), (0, 3, 0)] {
            b += Self.record(
                0x00e0, [0, 0] + Self.u16(f) + [1, 0, UInt8(h | v << 4), 0, 0, 0xfc] + Array(repeating: 0, count: 10))
        }
        var positions: [Int] = []
        for sheet in sheets {
            positions.append(b.count + 4)
            b += Self.record(0x0085, [0, 0, 0, 0, sheet.hidden ? 1 : 0, 0] + Self.unicode(sheet.name, true))
        }
        b +=
            Self.record(
                0x00fc, Self.u32(strings.count) + Self.u32(strings.count) + strings.flatMap { Self.unicode($0) })
            + Self.record(0x000a, [])
        for (i, sheet) in sheets.enumerated() {
            b.replaceSubrange(positions[i]..<positions[i] + 4, with: Self.u32(b.count))
            b += sheet.bytes()
        }
        try Self.compound(path, b)
        return path
    }
    static func u16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
    static func u32(_ v: Int) -> [UInt8] { u16(v) + u16(v >> 16) }
    static func f64(_ v: Double) -> [UInt8] {
        let bits = v.bitPattern
        return (0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
    }
    static func unicode(_ text: String, _ short: Bool = false) -> [UInt8] {
        (short ? [UInt8(text.utf16.count)] : u16(text.utf16.count)) + [1] + text.utf16.flatMap { u16(Int($0)) }
    }
    static func record(_ id: Int, _ data: [UInt8]) -> [UInt8] { u16(id) + u16(data.count) + data }
    static func bof(_ type: Int) -> [UInt8] { u16(0x600) + u16(type) + [0xbb, 0x0d, 0xcc, 7, 0, 0, 0, 0, 6, 0, 0, 0] }
    static func compound(_ path: String, _ data: [UInt8]) throws {
        let mini = data.count < 4096
        let miniCount = (data.count + 63) / 64
        let content = mini ? data + Array(repeating: UInt8(0), count: miniCount * 64 - data.count) : data
        let count = (content.count + 511) / 512
        let dir = count + (mini ? 1 : 0)
        var fatCount = 1
        while fatCount * 128 < dir + 1 + fatCount { fatCount += 1 }
        var fat = Array(repeating: 0xffff_ffff, count: fatCount * 128)
        for i in 0..<count { fat[i] = i + 1 < count ? i + 1 : 0xffff_fffe }
        if mini { fat[count] = 0xffff_fffe }
        fat[dir] = 0xffff_fffe
        for i in 0..<fatCount { fat[dir + 1 + i] = 0xffff_fffd }
        var header = Array(repeating: UInt8(0), count: 512)
        func put(_ p: Int, _ bytes: [UInt8], _ buffer: inout [UInt8]) {
            buffer.replaceSubrange(p..<p + bytes.count, with: bytes)
        }
        put(0, [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1], &header)
        for (p, v) in [(24, 0x3e), (26, 3), (28, 0xfffe), (30, 9), (32, 6)] { put(p, u16(v), &header) }
        for (p, v) in [
            (44, fatCount), (48, dir), (56, 4096), (60, mini ? count : 0xffff_fffe), (64, mini ? 1 : 0),
            (68, 0xffff_fffe),
        ] { put(p, u32(v), &header) }
        for i in 0..<109 { put(76 + i * 4, u32(i < fatCount ? dir + 1 + i : 0xffff_ffff), &header) }
        var out = header + content + Array(repeating: UInt8(0), count: count * 512 - content.count)
        if mini {
            out += (0..<128).flatMap { u32($0 < miniCount ? ($0 + 1 < miniCount ? $0 + 1 : 0xffff_fffe) : 0xffff_ffff) }
        }
        var directory = Array(repeating: UInt8(0), count: 512)
        for (p, name, type, start, size) in [
            (0, "Root Entry", 5, mini ? 0 : 0xffff_fffe, mini ? content.count : 0), (128, "Workbook", 2, 0, data.count),
        ] {
            put(p, name.utf16.flatMap { u16(Int($0)) }, &directory)
            put(p + 64, u16((name.utf16.count + 1) * 2), &directory)
            directory[p + 66] = UInt8(type)
            directory[p + 67] = 1
            for offset in [68, 72, 76] { put(p + offset, u32(offset == 76 && p == 0 ? 1 : 0xffff_ffff), &directory) }
            put(p + 116, u32(start), &directory)
            put(p + 120, u32(size), &directory)
        }
        out += directory + fat.flatMap(u32)
        try Data(out).write(to: URL(fileURLWithPath: path))
    }
    static func sales(_ path: String, _ filler: Int = 0) throws -> String {
        let b = XlsBuilder()
        let s = b.sheet("매출")
        s.text(0, 0, "지점별 매출", 1).merge(CellRange(0, 0, 0, 3)).text(1, 0, "지점").text(1, 1, "매출").text(1, 2, "일자").text(
            1, 3, "성장률")
        s.text(2, 0, "서울 강남").number(2, 1, 1_350_000, 2).number(2, 2, 46296, 3).number(2, 3, 0.128, 4).text(
            2, 4, "숨긴 열")
        s.text(3, 0, "부산 서면").number(3, 1, 870000, 2).number(3, 2, 46297, 3).number(3, 3, 0.09, 4)
        s.text(4, 0, "합계").number(4, 1, 2_220_000, 2).bool(4, 2, true).error(4, 3, 7).text(5, 0, "숨긴 행").height(
            5, 15, true)
        s.number(6, 0, 0.5, 5).number(6, 1, 3.5).text(6, 2, "오른쪽 위", 6).height(6, 30).width(0, 14).width(1, 12).width(
            2, 12
        ).width(3, 12).width(4, 20, true)
        b.sheet("비밀", true).text(0, 0, "보이면 안 됨")
        let memo = b.sheet("메모").text(0, 0, "첫 줄\n둘째 줄").number(1, 0, 42)
        for i in 0..<filler { memo.number(2 + i, 0, Double(i) * 1.5) }
        return try b.save(path)
    }
}
