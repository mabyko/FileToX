import Foundation
import XCTest

@testable import FileToXEngineKit

final class XlsRecordTests: OfficeTestCase {
    private func input(_ globals: [(Int, [UInt8])], _ cells: [(Int, [UInt8])], _ biff8: Bool = true) throws -> String {
        let bof = biff8 ? XlsBuilder.bof(5) : [0, 5, 5, 0, 0, 0, 0, 0]
        var bytes = XlsBuilder.record(0x0809, bof)
        for (id, data) in globals { bytes += XlsBuilder.record(id, data) }
        let bound = bytes.count + 4
        bytes += XlsBuilder.record(
            0x0085, [0, 0, 0, 0, 0, 0] + (biff8 ? XlsBuilder.unicode("Sheet1", true) : [6] + Array("Sheet1".utf8)))
        bytes += XlsBuilder.record(0x000a, [])
        bytes.replaceSubrange(bound..<bound + 4, with: XlsBuilder.u32(bytes.count))
        bytes += XlsBuilder.record(0x0809, biff8 ? XlsBuilder.bof(0x10) : [0, 5, 0x10, 0, 0, 0, 0, 0])
        for (id, data) in cells { bytes += XlsBuilder.record(id, data) }
        bytes += XlsBuilder.record(0x000a, [])
        try XlsBuilder.compound(path("records.xls"), bytes)
        return path("records.xls")
    }
    private func cell(_ col: Int, _ data: [UInt8], _ xf: Int = 0) -> [UInt8] {
        [0, 0] + XlsBuilder.u16(col) + XlsBuilder.u16(xf) + data
    }
    func testSstContinuesWithCompressionChangeRichRunsAndExtensionData() throws {
        let first =
            XlsBuilder.u32(2) + XlsBuilder.u32(2) + XlsBuilder.u16(4) + [0x0d] + XlsBuilder.u16(1) + XlsBuilder.u32(3)
            + "한글".utf16.flatMap { XlsBuilder.u16(Int($0)) }
        let next: [UInt8] = [0, 65, 66, 0, 0]
        let last: [UInt8] = [0, 0, 1, 2, 3] + XlsBuilder.unicode("😀")
        let file = try input(
            [(0x00fc, first), (0x003c, next), (0x003c, last)],
            [(0x00fd, cell(0, XlsBuilder.u32(0))), (0x00fd, cell(1, XlsBuilder.u32(1)))])
        let sheet = try XlsReader.read(file).sheets[0]
        XCTAssertEqual(sheet.get(0, 0)?.text, "한글AB")
        XCTAssertEqual(sheet.get(0, 1)?.text, "😀")
    }
    func testRkMulRkAndFormulaCachedTypes() throws {
        let rkInt = XlsBuilder.u32((123 << 2) | 2)
        let rkDecimal = XlsBuilder.u32((12345 << 2) | 3)
        let mul = [0, 0, 2, 0] + [0, 0] + rkInt + [0, 0] + rkDecimal + [3, 0]
        let formulaString = cell(4, [0, 0, 0, 0, 0, 0, 255, 255] + [0, 0, 0, 0, 0, 0, 0, 0])
        let file = try input(
            [],
            [
                (0x027e, cell(0, rkInt)), (0x027e, cell(1, rkDecimal)), (0x00bd, mul), (0x0006, formulaString),
                (0x0207, XlsBuilder.unicode("계산됨")),
                (0x0006, cell(5, XlsBuilder.f64(12.5) + Array(repeating: 0, count: 8))),
                (0x0006, cell(6, [1, 0, 1, 0, 0, 0, 255, 255] + Array(repeating: 0, count: 8))),
                (0x0006, cell(7, [2, 0, 7, 0, 0, 0, 255, 255] + Array(repeating: 0, count: 8))),
            ])
        let s = try XlsReader.read(file).sheets[0]
        for (c, value) in [(0, 123.0), (1, 123.45), (2, 123.0), (3, 123.45), (5, 12.5)] {
            XCTAssertEqual(s.get(0, c)?.value, value)
        }
        XCTAssertEqual(s.get(0, 4)?.text, "계산됨")
        XCTAssertEqual(s.get(0, 6)?.text, "TRUE")
        XCTAssertEqual(s.get(0, 7)?.text, "#DIV/0!")
    }
    func testBiff5KoreanCodePageStrings() throws {
        let encoded = Array(try TextEncodings.encode("한글", encoding: XCTUnwrap(TextEncodings.encoding(codePage: 949))))
        let file = try input(
            [(0x0042, XlsBuilder.u16(949))], [(0x0204, cell(0, XlsBuilder.u16(encoded.count) + encoded))], false)
        XCTAssertEqual(try XlsReader.read(file).sheets[0].get(0, 0)?.text, "한글")
    }
    func test1904WorkbookNumbersNormalizeDates() throws {
        let b = XlsBuilder()
        b.date1904 = true
        b.sheet("Dates").number(0, 0, 44834, 3).number(0, 1, 0.5, 5)
        let s = try XlsReader.read(b.save(path("1904.xls"))).sheets[0]
        XCTAssertEqual(s.get(0, 0)?.value, 46296)
        XCTAssertEqual(s.get(0, 0)?.text, "2026-10-01")
        // ExcelDataReader turns formatted times into DateTime too, matching the C# reader's 1904 normalization.
        XCTAssertEqual(s.get(0, 1)?.value, 1462.5)
    }
    func testMalformedCompoundChainAndTruncatedRecordFail() throws {
        let b = XlsBuilder()
        b.sheet("A").text(0, 0, "x")
        let file = try b.save(path("broken.xls"))
        var bytes = Array(try Data(contentsOf: URL(fileURLWithPath: file)))
        bytes.replaceSubrange(48..<52, with: XlsBuilder.u32(999999))
        try Data(bytes).write(to: URL(fileURLWithPath: file))
        XCTAssertThrowsError(try XlsReader.read(file))
        let truncated = path("truncated.xls")
        try Data([9, 8, 255, 255, 0, 6]).write(to: URL(fileURLWithPath: truncated))
        XCTAssertThrowsError(try XlsReader.read(truncated))
    }
    func testBuiltinXlsFormatsAndDateSystemsMatchCSharpBaseline() throws {
        struct Payload: Decodable {
            let csv: String
            let entries: [String: String]
        }
        var payloads: [String: (String, [String: String])] = [:]
        for mode in [false, true] {
            var globals: [(Int, [UInt8])] = [(0x0022, XlsBuilder.u16(mode ? 1 : 0))]
            for id in 0...81 {
                globals.append(
                    (0x00e0, [0, 0] + XlsBuilder.u16(id) + [1, 0, 0x20, 0, 0, 0xfc] + Array(repeating: 0, count: 10)))
            }
            let values = [-0.5, 0, 0.5, 1, 59, 60, 61, 46296.5625]
            var cells: [(Int, [UInt8])] = []
            for (r, value) in values.enumerated() {
                for c in 0...81 {
                    cells.append(
                        (0x0203, XlsBuilder.u16(r) + XlsBuilder.u16(c) + XlsBuilder.u16(c) + XlsBuilder.f64(value)))
                }
            }
            let input = try input(globals, cells)
            let key = mode ? "builtins-1904" : "builtins-1900"
            let book = try XlsReader.read(input)
            let csv = path("formats.csv")
            let xlsx = path("formats.xlsx")
            try CsvFormat.write(book.sheets[0], csv)
            try XlsxWriter.write(book, xlsx)
            var entries: [String: String] = [:]
            let archive = try ZipReader(path: xlsx)
            for entry in archive.entries { entries[entry.name] = try archive.data(for: entry).base64EncodedString() }
            payloads[key] = (try Data(contentsOf: URL(fileURLWithPath: csv)).base64EncodedString(), entries)
            if let export = ProcessInfo.processInfo.environment["FTX_P5_EXPORT_DIR"] {
                let folder = FilePath.combine(export, "xls-record-cases", key)
                try FileManager.default.createDirectoryIfNeeded(folder)
                let target = FilePath.combine(folder, "sample.xls")
                if FileManager.default.fileExists(target) { try FileManager.default.removeItem(atPath: target) }
                try FileManager.default.copyItem(atPath: input, toPath: target)
            }
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/xls-record-baseline.json")
        let expected = try JSONDecoder().decode([String: Payload].self, from: Data(contentsOf: url))
        for (key, (csv, entries)) in payloads {
            let want = try XCTUnwrap(expected[key])
            XCTAssertEqual(csv, want.csv, key)
            for (part, data) in entries { XCTAssertEqual(data, want.entries[part], key + "/" + part) }
        }
    }

}
