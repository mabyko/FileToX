import Foundation
import XCTest

@testable import FileToXEngineKit

final class NumberFormatTests: XCTestCase {
    struct Baseline: Decodable {
        let format: String
        let value: Double
        let text: String
    }
    func testCSharpBaselineFormattedTexts() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/number-format-baseline.json")
        let examples = try JSONDecoder().decode([Baseline].self, from: Data(contentsOf: url))
        let formatter = FileToXEngineKit.NumberFormatter()
        var mismatches: [String] = []
        for e in examples {
            let got = formatter.format(e.value, e.format)
            if got != e.text {
                mismatches.append(
                    "\(e.value) [\(e.format)] expected \(String(reflecting:e.text)), got \(String(reflecting:got))")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "\(mismatches.count)/\(examples.count) mismatches:\n" + mismatches.prefix(80).joined(separator: "\n"))
    }
    func testExcelFormatsSurviveOdfStyles() throws {
        let codes: [(String, String)] = [
            ("0", "float"), ("0.00", "float"), ("#,##0", "float"), ("#,##0.00", "float"), ("0.0##", "float"),
            ("#,##0,", "float"), ("#,##0\"원\"", "float"), ("$#,##0.00", "float"), ("#,##0;[Red]-#,##0", "float"),
            ("#,##0.00;(#,##0.00);-", "float"), ("0%", "percentage"), ("0.0%", "percentage"), ("0.00E+00", "float"),
            ("yyyy-mm-dd", "date"), ("d-mmm-yy", "date"), ("yyyy-mm-dd h:mm", "date"), ("dddd, mmmm d", "date"),
            ("h:mm AM/PM", "time"), ("mm:ss", "time"), ("mmss.0", "time"), ("[h]:mm:ss", "time"),
        ]
        for (code, type) in codes {
            let output = try XCTUnwrap(OdsNumberStyles.toOdf(code, "N1"), code)
            XCTAssertEqual(output.valueType, type, code)
            let styles = try XElement.parse(
                "<styles \(OdsBuilder.namespaces)>\(output.xml)</styles>", preserveWhitespace: true
            ).elements()
            let main = try XCTUnwrap(styles.first { $0.attributeValue(OdsNumberStyles.style + "name") == "N1" })
            XCTAssertEqual(
                OdsNumberStyles.toExcel(main) { name in
                    styles.first { $0.attributeValue(OdsNumberStyles.style + "name") == name }
                }, code, code)
        }
    }
    func testUnsupportedOdfStylesStayPlain() {
        for code: String? in [nil, "General", "@", "[>=100]0;0.0", "# ?/?", "000-0000"] {
            XCTAssertNil(OdsNumberStyles.toOdf(code, "N1"), code ?? "nil")
        }
    }
    func testSerialDatesAndGeneral() throws {
        for (iso, serial) in [("1900-01-01", 1.0), ("1900-02-28", 59.0), ("1900-03-01", 61.0), ("2026-10-01", 46296.0)]
        {
            let date = try XCTUnwrap(SheetXML.date(iso))
            XCTAssertEqual(FileToXEngineKit.NumberFormatter.toSerial(date), serial)
            XCTAssertEqual(FileToXEngineKit.NumberFormatter.fromSerial(serial), date)
        }
        XCTAssertEqual(FileToXEngineKit.NumberFormatter().format(60, "yyyy-mm-dd"), "1900-02-29")
        XCTAssertEqual(FileToXEngineKit.NumberFormatter().format(0, "yyyy-mm-dd"), "1900-01-00")
        XCTAssertEqual(FileToXEngineKit.NumberFormatter(true).format(0, "yyyy-mm-dd"), "1904-01-01")
        XCTAssertTrue(FileToXEngineKit.NumberFormatter().isDate("h:mm"))
        XCTAssertFalse(FileToXEngineKit.NumberFormatter().isDate("[h]:mm"))
        XCTAssertEqual(FileToXEngineKit.NumberFormatter.general(1_234_567_890_123), "1.23457E+12")
    }
}
