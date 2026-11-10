// The ACadSharp 3.8.0 DXF writer port: a drawing read and written again as AC1032 (Filee's CadFile.Write) gives the
// bytes ACadSharp writes, and the draw-order table is sorted with .NET's unstable List<T>.Sort like ACadSharp's.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class CadDxfWriterTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// korean_AC1018.dxf is ACadSharp's AC1018 DXF of a drawing with Korean text (code page 949);
    /// korean_AC1018.acadsharp.dxf is what Filee's CadFile.Write (ACadSharp 3.8.0) makes of it.
    func testWritesTheBytesACadSharpWrites() throws {
        let input = try Data(contentsOf: Self.fixtures.appendingPathComponent("korean_AC1018.dxf"))
        let expected = try Data(contentsOf: Self.fixtures.appendingPathComponent("korean_AC1018.acadsharp.dxf"))
        let document = try ACad.DxfReader(data: input, createDefaults: true).read()
        document.header.version = .ac1032

        let written = try ACad.DxfWriter(document: document).write()

        let lines = { (data: Data) in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") }
        let (actualLines, expectedLines) = (lines(written), lines(expected))
        let first = zip(actualLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }
        XCTAssertNil(first.map { "line \($0.offset + 1): \($0.element.0) ≠ \($0.element.1)" })
        XCTAssertEqual(written, expected)
    }

    /// Expected orders from .NET 10's List<T>.Sort on the same keys: equal keys move, and sorting again moves them again.
    func testSortsLikeDotNetListSort() {
        let keys: [UInt64] = [0, 0, 2, 2, 1, 1, 0, 0, 0, 2, 1, 2, 2, 1, 2, 0, 2]
        var items = keys.enumerated().map { (key: $0.element, index: $0.offset) }

        netIntroSort(&items) { $0.key < $1.key }
        XCTAssertEqual(items.map(\.index), [0, 15, 7, 6, 8, 1, 5, 10, 13, 4, 3, 2, 9, 11, 12, 14, 16])
        netIntroSort(&items) { $0.key < $1.key }
        XCTAssertEqual(items.map(\.index), [0, 15, 7, 6, 8, 1, 4, 13, 5, 10, 14, 3, 2, 9, 11, 12, 16])
    }
}
