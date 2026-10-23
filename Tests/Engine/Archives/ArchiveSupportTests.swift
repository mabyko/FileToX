// Shared helpers the archive engine relies on: .NET path semantics per code point, zlib input of any size, ZipWriter
// entries with a given mode and per-chunk progress (Filee's ZIPs give every entry rw-r--r--), DOS times that stay
// Gregorian whatever calendar the user prefers, and created names that keep their composed form (FileManager would
// store "폴더" decomposed, NFD, unlike .NET).

import Foundation
import XCTest
@testable import FileToXEngineKit

final class ArchiveSupportTests: XCTestCase {
    private var dir = ""

    override func setUpWithError() throws {
        dir = FilePath.combine(NSTemporaryDirectory(), "filetox-zip-" + UUID().uuidString)
        try FileManager.default.createDirectoryIfNeeded(dir)
    }

    override func tearDownWithError() throws { FileManager.default.removeIfPresent(dir) }

    func testStreamedEntriesTakeTheGivenModeAndReportEveryChunk() throws {
        let tool = FilePath.combine(dir, "tool.sh")
        try Data(repeating: 0x41, count: 3_000_000).write(to: URL(fileURLWithPath: tool))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)

        let zip = FilePath.combine(dir, "out.zip")
        let writer = try ZipWriter(path: zip)
        var chunks: [Int] = []
        try writer.add("tool.sh", contentsOf: tool, unixMode: 0o644, progress: { chunks.append($0) })
        try writer.add("kept.sh", contentsOf: tool)
        try writer.close()

        XCTAssertEqual(chunks, [1 << 20, 1 << 20, 3_000_000 - 2 << 20])
        XCTAssertEqual(try ZipReader(path: zip).entries.map { $0.unixMode.map { $0 & 0o7777 } }, [0o644, 0o755])
    }

    func testDosTimesAreGregorianLocalTime() throws {
        XCTAssertEqual(ZipReader.dosCalendar.identifier, .gregorian)
        let time = try XCTUnwrap(ZipReader.dosCalendar.date(from: DateComponents(year: 2021, month: 5, day: 6, hour: 7, minute: 8, second: 10)))
        let (dosTime, dosDate) = ZipWriter.dosDateTime(time)
        XCTAssertEqual(Int(dosDate >> 9) + 1980, 2021)
        XCTAssertEqual(dosTime >> 11, 7)
        XCTAssertEqual(ZipReader.dosDate(date: dosDate, time: dosTime), time)
    }

    func testCreatedFoldersAndArchivesKeepComposedNames() throws {
        let name = "폴더".precomposedStringWithCanonicalMapping
        try FileManager.default.createDirectoryIfNeeded(FilePath.combine(dir, name, "하위"))
        let writer = try ZipWriter(path: FilePath.combine(dir, name + ".zip"))
        try writer.add("a.txt", text: "a")
        try writer.close()
        let reader = try ZipReader(path: FilePath.combine(dir, name + ".zip"))
        try reader.extract(reader.entries[0], to: FilePath.combine(dir, name, "가.txt".precomposedStringWithCanonicalMapping))

        let stored = Set(try FileManager.default.contentsOfDirectory(atPath: dir).map { Array($0.utf8) })
        XCTAssertEqual(stored, [Array(name.utf8), Array((name + ".zip").utf8)])
        let inner = Set(try FileManager.default.contentsOfDirectory(atPath: FilePath.combine(dir, name)).map { Array($0.utf8) })
        XCTAssertEqual(inner, [Array("하위".precomposedStringWithCanonicalMapping.utf8), Array("가.txt".precomposedStringWithCanonicalMapping.utf8)])
        XCTAssertThrowsError(try FileManager.default.createDirectoryIfNeeded(FilePath.combine(dir, name + ".zip", "x")))
    }

    /// .NET looks for "/" and "." per char; Swift Characters would merge them with a following combining mark.
    func testPathsAreSplitPerCodePointLikeDotNet() {
        func same(_ a: String?, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(a.map { Array($0.unicodeScalars) }, Array(b.unicodeScalars), file: file, line: line)
        }
        same(FilePath.fileName("/x/dir/\u{301}b.txt"), "\u{301}b.txt")
        same(FilePath.directoryName("/x/dir/\u{301}b.txt"), "/x/dir")
        same(FilePath.extension("/x/a.\u{301}b"), ".\u{301}b")
        same(FilePath.fileNameWithoutExtension("/x/a.\u{301}b"), "a")
        same(FilePath.changeExtension("/x/a.\u{301}b", "png"), "/x/a.png")
        same(FilePath.fullPath("/x/a/../\u{301}b"), "/x/\u{301}b")
        same(FilePath.combine("/x", "/\u{301}b"), "/\u{301}b")
        same(FilePath.trimEndingSeparator("/x/\u{301}/"), "/x/\u{301}")
    }

    /// zlib takes at most 4 GiB per call; bigger inputs are handed over in slices (made tiny here to exercise it).
    func testDeflateAndInflateHandInputInSlices() throws {
        let data = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 * 31 / 7) })
        Deflate.inputSlice = 7
        defer { Deflate.inputSlice = 1 << 30 }
        let packed = try Deflate.deflate(data, level: 6)
        XCTAssertEqual(try Deflate.inflate(packed), data)
        let gzip = try Deflate.Compressor(level: 1, windowBits: 31)
        let streamed = try gzip.compress(data.prefix(50_000), finish: false) + gzip.compress(data.suffix(50_000), finish: true)
        XCTAssertEqual(try Deflate.inflate(streamed, windowBits: 31), data)
        XCTAssertThrowsError(try Deflate.inflate(packed.prefix(packed.count / 2)))
    }
}
