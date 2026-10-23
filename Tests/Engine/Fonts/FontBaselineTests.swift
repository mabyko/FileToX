// Optional differential integration check. See compare_baseline.py; inputs and both outputs stay in a temp folder.
import Foundation
import XCTest
@testable import FileToXEngineKit

final class FontBaselineTests: XCTestCase {
    func testInstalledCSharpBaselineInEveryDirection() throws {
        guard let path = ProcessInfo.processInfo.environment["FILETOX_FONT_BASELINE"] else { throw XCTSkip("Set FILETOX_FONT_BASELINE to compare_baseline.py's output directory.") }
        let root = URL(fileURLWithPath: path)
        struct Entry: Decodable { let family: String; let sourceFormat: String; let target: String; let input: String; let expected: String; let swift: String }
        let manifest = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        var comparisons: [[String: Any]] = []
        for entry in manifest {
            let input = try Data(contentsOf: URL(fileURLWithPath: entry.input)), expected = try Data(contentsOf: URL(fileURLWithPath: entry.expected))
            let actual = try FontFile.save(FontFile.load(input), entry.target)
            try actual.write(to: URL(fileURLWithPath: entry.swift))
            let e = try FontFile.load(expected), a = try FontFile.load(actual)
            let differing = Set(e.tables.keys).union(a.tables.keys).sorted().filter { e.tables[$0] != a.tables[$0] }
            let context = "\(entry.family) \(entry.sourceFormat)->\(entry.target)"
            XCTAssertEqual(differing, [], context); XCTAssertEqual(e.flavor, a.flavor, context)
            // Platform zlib and Brotli streams differ; their decoded tables must still match exactly.
            if ["ttf", "otf", "eot"].contains(entry.target) { XCTAssertEqual(actual, expected, "byte equality: \(context)") }
            comparisons.append(["family": entry.family, "from": entry.sourceFormat, "to": entry.target, "expectedBytes": expected.count, "swiftBytes": actual.count, "byteEqual": actual == expected, "differingTables": differing, "swiftFile": URL(fileURLWithPath: entry.swift).lastPathComponent])
        }
        try JSONSerialization.data(withJSONObject: comparisons, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("comparisons.json"))
        print("FONT_BASELINE \(manifest.count) directions, \(comparisons.filter { $0["byteEqual"] as? Bool == true }.count) byte-equal, \(comparisons.filter { ($0["differingTables"] as? [String])?.isEmpty == true }.count) table-equal")
    }
}
