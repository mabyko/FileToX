import Foundation
import XCTest

@testable import FileToXEngineKit

final class OfficeTests: OfficeTestCase {
    func testXlsxValuesAndStyles() throws {
        let book = try XlsxReader.read(XlsxBuilder.sales(path("매출보고.xlsx")))
        XCTAssertEqual(book.sheets.map(\.name), ["매출", "메모", "넓은 표"])
        let sales = book.sheets[0]
        for (r, c, text) in [
            (2, 1, "1,350,000원"), (2, 2, "2026-10-01"), (2, 3, "12.8%"), (4, 1, "2,220,000원"), (4, 2, "TRUE"),
            (4, 3, "메모, \"따옴표\""),
        ] { XCTAssertEqual(sales.get(r, c)?.text, text) }
        let header = try XCTUnwrap(sales.get(1, 0)?.style)
        XCTAssertTrue(header.bold)
        XCTAssertEqual(header.color, "#FFFFFF")
        XCTAssertEqual(header.fill, "#1F4E79")
        XCTAssertEqual(header.align, .center)
        XCTAssertEqual(header.bottom.style, "thin")
        XCTAssertEqual(sales.get(4, 1)?.style.color, "#C00000")
        XCTAssertTrue(sales.get(4, 1)?.style.top.isVisible == true)
        XCTAssertEqual(sales.merges, [CellRange(0, 0, 0, 3)])
        XCTAssertEqual(sales.frozenRows, 2)
        XCTAssertEqual(sales.columnWidth(0), 14)
        XCTAssertEqual(sales.columnWidth(3), 12)
        XCTAssertEqual(book.sheets[1].get(0, 0)?.text, "첫 줄\n둘째 줄")
        XCTAssertEqual(book.sheets[1].get(1, 0)?.text, "3.5")
    }
    func testXlsxToCsvOneFilePerSheet() async throws {
        let input = try XlsxBuilder.sales(path("매출보고.xlsx"))
        let outputs = try await convert(input, "xlsx", "csv")
        XCTAssertEqual(outputs.map(FilePath.fileName), ["매출보고-out_매출.csv", "매출보고-out_메모.csv", "매출보고-out_넓은 표.csv"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outputs[0])).prefix(3), Data([0xef, 0xbb, 0xbf]))
        XCTAssertEqual(
            try String(contentsOfFile: outputs[0], encoding: .utf8),
            "지점별 매출,,,\r\n지점,매출,일자,성장률\r\n서울 강남,\"1,350,000원\",2026-10-01,12.8%\r\n부산 서면,\"870,000원\",2026-10-02,9.0%\r\n합계,\"2,220,000원\",TRUE,\"메모, \"\"따옴표\"\"\"\r\n"
        )
    }
    func testCsvRoundTrip() async throws {
        let csv = "이름,금액,메모\r\n김민지,1200,\"줄\n바꿈\"\r\n\"Lee, J\",3.5,\"\"\"인용\"\"\"\r\n"
        let input = path("명단.csv")
        try Data(csv.utf8).write(to: URL(fileURLWithPath: input))
        let xlsx = try await convert(input, "csv", "xlsx")[0]
        let book = try XlsxReader.read(xlsx)
        XCTAssertEqual(book.sheets[0].get(1, 1)?.value, 1200)
        XCTAssertEqual(book.sheets[0].get(1, 2)?.text, "줄\n바꿈")
        let result = try await convert(xlsx, "xlsx", "csv")[0]
        XCTAssertEqual(try String(contentsOfFile: result, encoding: .utf8), csv)
    }
    func testKoreanExcelCsvEncodingAndDelimiter() throws {
        let text = "이름;점수\r\n홍길동;90\r\n"
        let encoding = try XCTUnwrap(TextEncodings.encoding(codePage: 949))
        try TextEncodings.encode(text, encoding: encoding).write(to: URL(fileURLWithPath: path("점수.csv")))
        let sheet = try CsvFormat.read(path("점수.csv")).sheets[0]
        XCTAssertEqual(sheet.get(1, 0)?.text, "홍길동")
        XCTAssertEqual(sheet.get(1, 1)?.value, 90)
    }
    func test1904DatesAndISODateCells() throws {
        let b = XlsxBuilder()
        b.workbookProperties = "<workbookPr date1904=\"1\"/>"
        b.sheet(
            "Date",
            XlsxBuilder.row(
                1, XlsxBuilder.number("A1", 44834, 3), "<c r=\"B1\" s=\"3\" t=\"d\"><v>2026-10-01</v></c>",
                XlsxBuilder.number("C1", 0.5)))
        let book = try XlsxReader.read(b.save(path("date.xlsx")))
        XCTAssertEqual(book.sheets[0].get(0, 0)?.text, "2026-10-01")
        XCTAssertEqual(book.sheets[0].get(0, 0)?.value, 46296)
        XCTAssertEqual(book.sheets[0].get(0, 1)?.value, 46296)
        XCTAssertEqual(book.sheets[0].get(0, 2)?.value, 0.5)
    }
    func testNamesAndDeterministicXml() throws {
        XCTAssertEqual(
            XlsxWriter.uniqueNames([
                "a/b", "AB", "'   '", String(repeating: "가", count: 40), String(repeating: "가", count: 40),
            ]),
            ["ab", "AB (2)", "Sheet3", String(repeating: "가", count: 31), String(repeating: "가", count: 27) + " (2)"])
        let source = try XlsxReader.read(XlsxBuilder.sales(path("sales.xlsx")))
        try XlsxWriter.write(source, path("a.xlsx"))
        try XlsxWriter.write(source, path("b.xlsx"))
        let a = try ZipReader(path: path("a.xlsx"))
        let b = try ZipReader(path: path("b.xlsx"))
        for entry in a.entries { XCTAssertEqual(try a.data(for: entry), try b.data(named: entry.name)) }
    }
    func testCsvParsersAndWidth() {
        XCTAssertEqual(CsvFormat.parse("a,\"b,\"\"c\"\"\nline\"\r\n,\r\n", ","), [["a", "b,\"c\"\nline"], ["", ""]])
        XCTAssertEqual(CsvFormat.detectDelimiter("a;b;\"x,y\"\n1;2;3"), ";")
        XCTAssertEqual(CsvFormat.detectDelimiter("a;b,c\td"), ",")
        for v in ["007", "-007", "1,234", ""] { XCTAssertFalse(CsvFormat.isNumber(v), v) }
        for v in ["0", "-3.5", "1e3", "0.2"] { XCTAssertTrue(CsvFormat.isNumber(v), v) }
        XCTAssertEqual(CsvFormat.displayWidth("한글a\nabc"), 5)
    }
}
