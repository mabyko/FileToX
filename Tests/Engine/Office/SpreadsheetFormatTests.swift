import Foundation
import XCTest

@testable import FileToXEngineKit

final class SpreadsheetFormatTests: OfficeTestCase {
    func testXlsValuesFormatsAndLayout() throws {
        for filler in [0, 400] {
            let book = try XlsReader.read(XlsBuilder.sales(path("sales\(filler).xls"), filler))
            let sales = book.sheets[0]
            XCTAssertEqual(book.sheets.map(\.name), ["매출", "메모"])
            for (r, c, text) in [
                (2, 1, "1,350,000원"), (2, 2, "2026-10-01"), (2, 3, "12.8%"), (4, 1, "2,220,000원"), (4, 2, "TRUE"),
                (4, 3, "#DIV/0!"), (6, 0, "12:00"), (6, 1, "3.5"),
            ] { XCTAssertEqual(sales.get(r, c)?.text, text) }
            XCTAssertEqual(sales.get(2, 1)?.value, 1_350_000)
            XCTAssertEqual(sales.get(2, 1)?.numberFormat, "#,##0\"원\"")
            XCTAssertEqual(sales.get(2, 2)?.value, 46296)
            XCTAssertEqual(sales.get(4, 2)?.isBoolean, true)
            XCTAssertEqual(sales.get(0, 0)?.style.align, .center)
            XCTAssertEqual(sales.get(6, 2)?.style.align, .right)
            XCTAssertEqual(sales.get(6, 2)?.style.verticalAlign, .top)
            XCTAssertEqual(sales.merges, [CellRange(0, 0, 0, 3)])
            XCTAssertEqual((0..<4).map(sales.columnWidth), [14, 12, 12, 12])
            XCTAssertEqual(sales.hiddenColumns, [4])
            XCTAssertEqual(sales.hiddenRows, [5])
            XCTAssertEqual(sales.rowHeights, [6: 30])
            XCTAssertEqual(book.sheets[1].get(0, 0)?.text, "첫 줄\n둘째 줄")
            XCTAssertEqual(book.sheets[1].get(1, 0)?.text, "42")
        }
    }
    func testPasswordErrorsAndMislabeledXlsx() throws {
        let b = XlsBuilder()
        b.sheet("Secret").text(0, 0, "secret")
        XCTAssertThrowsError(try XlsReader.read(b.save(path("locked.xls"), true))) {
            XCTAssertTrue($0.localizedDescription.contains("password"))
        }
        XCTAssertThrowsError(try OdsReader.read(OdsBuilder.sales(path("locked.ods"), true))) {
            XCTAssertTrue($0.localizedDescription.contains("password"))
        }
        let xls = try XlsxBuilder.sales(path("download.xls"))
        XCTAssertEqual(try XlsReader.read(xls).sheets[0].get(1, 0)?.style.fill, "#1F4E79")
        try Data("<html/>".utf8).write(to: URL(fileURLWithPath: path("web.xls")))
        XCTAssertThrowsError(try XlsReader.read(path("web.xls"))) {
            XCTAssertTrue($0.localizedDescription.contains("web page"))
        }
    }
    func testXlsToXlsxAndOdsKeepsValuesAndLayout() async throws {
        let input = try XlsBuilder.sales(path("매출.xls"), 400)
        let source = try XlsReader.read(input)
        for format in ["xlsx", "ods"] {
            let result = try await convert(input, "xls", format)[0]
            let book = try SpreadsheetConverter.read(result, format)
            assertSameCells(source, book)
            XCTAssertEqual(source.sheets[0].merges, book.sheets[0].merges)
            XCTAssertEqual(book.sheets[0].columnWidth(0), 14, accuracy: 0.01)
            XCTAssertEqual(source.sheets[0].hiddenRows, book.sheets[0].hiddenRows)
        }
    }
    func testOdsRepeatsSpansValuesAndStyles() throws {
        let book = try OdsReader.read(OdsBuilder.sales(path("매출.ods")))
        let s = book.sheets[0]
        XCTAssertEqual(book.sheets.map(\.name), ["매출", "색칠"])
        for (r, c, text) in [
            (0, 0, "지점별 매출"), (1, 0, "1,234.50"), (1, 1, "12.8%"), (1, 2, "-₩5,000"), (2, 0, "2026년 10월 1일"),
            (2, 1, "13:30"), (2, 2, "TRUE"), (2, 3, "#DIV/0!"), (6, 0, " 앞 공백  세 칸\t탭\n줄\n둘째 문단"),
        ] { XCTAssertEqual(s.get(r, c)?.text, text) }
        XCTAssertEqual(s.get(1, 0)?.numberFormat, "#,##0.00")
        XCTAssertEqual(s.get(1, 1)?.numberFormat, "0.0%")
        XCTAssertEqual(s.get(2, 0)?.value, 46296)
        XCTAssertEqual(s.get(2, 1)?.value, 0.5625)
        XCTAssertEqual(s.merges, [CellRange(0, 0, 0, 2)])
        XCTAssertEqual(s.hiddenColumns, [3])
        XCTAssertEqual(s.hiddenRows, [5])
        XCTAssertEqual(s.rowHeights, [0: 30])
        XCTAssertEqual(s.frozenRows, 1)
        XCTAssertEqual(s.columnWidth(0), 72 / 5.25, accuracy: 0.0001)
        XCTAssertEqual(s.get(0, 0)?.style.fill, "#1F4E79")
        XCTAssertTrue(s.get(0, 0)?.style.bold == true)
        XCTAssertEqual(s.get(0, 0)?.style.fontSize, 14)
        XCTAssertEqual(s.get(6, 0)?.style.bottom.style, "double")
        XCTAssertTrue(s.get(6, 0)?.style.italic == true)
        XCTAssertEqual(book.sheets[1].usedRange(), CellRange(0, 0, 0, 1))
        XCTAssertEqual(book.sheets[1].rows.count, 1)
    }
    func testOdsToCsvShowsCachedText() async throws {
        let outs = try await convert(OdsBuilder.sales(path("매출보고.ods")), "ods", "csv")
        XCTAssertEqual(outs.count, 2)
        XCTAssertEqual(
            try String(contentsOfFile: outs[0], encoding: .utf8),
            "지점별 매출,,\r\n\"1,234.50\",12.8%,\"-₩5,000\"\r\n2026년 10월 1일,13:30,TRUE\r\n7,7,7\r\n7,7,7\r\n\" 앞 공백  세 칸\t탭\n줄\n둘째 문단\",,\r\n"
        )
    }
    func testXlsxOdsXlsxRoundTrip() async throws {
        let source = try XlsxReader.read(XlsxBuilder.sales(path("매출보고.xlsx")))
        try OdsWriter.write(source, path("out.ods"))
        let archive = try ZipReader(path: path("out.ods"))
        XCTAssertEqual(archive.entries.first?.name, "mimetype")
        XCTAssertEqual(archive.entries.first?.method, 0)
        let ods = try OdsReader.read(path("out.ods"))
        assertSameCells(source, ods)
        try XlsxWriter.write(ods, path("back.xlsx"))
        let result = try XlsxReader.read(path("back.xlsx"))
        assertSameCells(source, result)
        for (want, got) in zip(source.sheets, result.sheets) {
            XCTAssertEqual(want.merges, got.merges)
            XCTAssertEqual(want.frozenRows, got.frozenRows)
            for c in want.columnWidths.keys { XCTAssertEqual(want.columnWidth(c), got.columnWidth(c), accuracy: 0.01) }
        }
    }
    func testTsvRoundTripAndMultipleSheets() async throws {
        let text = "이름\t금액\t메모\r\n김민지\t1,200\t\"줄\n바꿈\"\r\nLee, J\t3.5\t\"\"\"인용\"\"\"\r\n"
        let input = path("명단.tsv")
        try Data(text.utf8).write(to: URL(fileURLWithPath: input))
        let xlsx = try await convert(input, "tsv", "xlsx")[0]
        let sheet = try XlsxReader.read(xlsx).sheets[0]
        XCTAssertEqual(sheet.get(1, 1)?.text, "1,200")
        XCTAssertFalse(sheet.get(1, 1)?.isNumber ?? true)
        XCTAssertEqual(sheet.get(2, 1)?.value, 3.5)
        let out = try await convert(xlsx, "xlsx", "tsv")[0]
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), text)
        let outputs = try await convert(XlsxBuilder.sales(path("sales.xlsx")), "xlsx", "tsv")
        XCTAssertEqual(outputs.count, 3)
    }
    func testEdgesMatchFilee() {
        let converter = SpreadsheetConverter()
        XCTAssertEqual(converter.edges.count, 22)
        XCTAssertFalse(
            converter.edges.contains {
                $0.from == $0.to || $0.to == "xls" || ["xlsm", "xltx"].contains($0.from) && $0.to == "xlsx"
            })
        XCTAssertEqual(converter.edges.first, ConversionEdge("xlsx", "ods"))
        XCTAssertEqual(converter.edges.last, ConversionEdge("tsv", "csv"))
        XCTAssertEqual(
            EngineRegistry.createAll(EngineEnvironment(dataDirectory: folder)).map(\.id),
            ["spreadsheet", "ooxml", "libreoffice"])
    }
    func testEmptyWorkbookAndUnicodeSpacing() throws {
        let book = Workbook()
        let sheet = Worksheet("😀 한글")
        book.sheets = [sheet]
        sheet.set(0, 0, SheetCell("😀  가\t나\n둘째", .default))
        try OdsWriter.write(book, path("unicode.ods"))
        XCTAssertEqual(try OdsReader.read(path("unicode.ods")).sheets[0].get(0, 0)?.text, "😀  가\t나\n둘째")
        try XlsxWriter.write(Workbook(), path("empty.xlsx"))
        XCTAssertEqual(try XlsxReader.read(path("empty.xlsx")).sheets.map(\.name), ["Sheet1"])
    }
}
