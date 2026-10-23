import Foundation
import XCTest

@testable import FileToXEngineKit

final class OfficeComparisonTests: OfficeTestCase {
    struct Output: Codable {
        let suffix: String
        let entries: [String: String]?
        let bytes: String?
    }
    func testCSharpBaselineConversionPayloads() async throws {
        let csv = path("table.csv")
        let tsv = path("table.tsv")
        try Data("이름,금액,메모\r\n김민지,1200,\"줄\n바꿈\"\r\n\"Lee, J\",3.5,\"\"\"인용\"\"\"\r\n".utf8).write(
            to: URL(fileURLWithPath: csv))
        try Data("이름\t금액\t메모\r\n김민지\t1,200\t\"줄\n바꿈\"\r\nLee, J\t3.5\t\"\"\"인용\"\"\"\r\n".utf8).write(
            to: URL(fileURLWithPath: tsv))
        let inputs = [
            ("csv", csv), ("tsv", tsv), ("xlsx", try XlsxBuilder.sales(path("sales.xlsx"))),
            ("ods", try OdsBuilder.sales(path("sales.ods"))), ("xls", try XlsBuilder.sales(path("sales.xls"))),
        ]
        var actual: [String: [Output]] = [:]
        for (from, input) in inputs {
            for to in ["xlsx", "ods", "csv", "tsv"] where from != to {
                let key = from + "-" + to
                let outDir = path(key)
                try FileManager.default.createDirectoryIfNeeded(outDir)
                let result = try await SpreadsheetConverter().convert(
                    ConversionStep(
                        inputPath: input, from: from, to: to, preset: Preset(),
                        output: OfficeOutput(outDir, FilePath.fileNameWithoutExtension(input)), workDirectory: outDir),
                    progress: nil)
                actual[key] = try result.map { file in
                    let suffix = String(
                        FilePath.fileName(file).dropFirst(FilePath.fileNameWithoutExtension(input).count))
                    if ["xlsx", "ods"].contains(to) {
                        let zip = try ZipReader(path: file)
                        var entries: [String: String] = [:]
                        for entry in zip.entries {
                            entries[entry.name] = try zip.data(for: entry).base64EncodedString()
                        }
                        return Output(suffix: suffix, entries: entries, bytes: nil)
                    }
                    return Output(
                        suffix: suffix, entries: nil,
                        bytes: try Data(contentsOf: URL(fileURLWithPath: file)).base64EncodedString())
                }
            }
        }
        // Optional input/payload export allows the comparison capture script to refresh the baseline in isolation.
        if let export = ProcessInfo.processInfo.environment["FTX_P5_EXPORT_DIR"] {
            try FileManager.default.createDirectoryIfNeeded(export)
            for (_, input) in inputs {
                let target = FilePath.combine(export, FilePath.fileName(input))
                if FileManager.default.fileExists(target) { try FileManager.default.removeItem(atPath: target) }
                try FileManager.default.copyItem(atPath: input, toPath: target)
            }
            try JSONEncoder().encode(actual).write(
                to: URL(fileURLWithPath: FilePath.combine(export, "swift-payloads.json")))
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/conversion-baseline.json")
        let expected = try JSONDecoder().decode([String: [Output]].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(actual.keys), Set(expected.keys))
        for (key, outputs) in actual {
            let baseline = try XCTUnwrap(expected[key])
            XCTAssertEqual(outputs.map(\.suffix), baseline.map(\.suffix), key)
            for (got, want) in zip(outputs, baseline) {
                XCTAssertEqual(got.bytes, want.bytes, key + got.suffix)
                XCTAssertEqual(got.entries?.keys.sorted(), want.entries?.keys.sorted(), key)
                for (part, bytes) in got.entries ?? [:] {
                    XCTAssertEqual(bytes, want.entries?[part], key + " / " + part)
                }
            }
        }
    }
}
