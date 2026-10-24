// E-book cases from EbookTests, PortableEngineTests and OwnCopyTests.
import Foundation
import XCTest
@testable import FileToXEngineKit

final class CalibreEbookTests: EbookTestCase {
    private var copies: [String: String] = [:]
    private var searchSystem = true
    override func setUpWithError() throws { try super.setUpWithError(); copies = EngineEnvironment.ownCopies; searchSystem = EngineEnvironment.searchSystem; EngineEnvironment.searchSystem = false }
    override func tearDownWithError() throws { EngineEnvironment.ownCopies = copies; EngineEnvironment.searchSystem = searchSystem; try super.tearDownWithError() }
    private func useCalibre() throws {
        let calibre = ProcessInfo.processInfo.environment["FILETOX_CALIBRE"] ?? "build/optional-engines/osx-arm64/calibre/calibre.app"
        guard FileManager.default.fileExists(atPath: calibre) else { throw XCTSkip("Calibre development copy not found; set FILETOX_CALIBRE") }
        EngineEnvironment.ownCopies = ["calibre": calibre]
        XCTAssertTrue(CalibreConverter().status().isAvailable)
    }
    func testOwnCopyAndPortableAppBundle() throws {
        let bin = path("calibre.app/Contents/MacOS"); try FileManager.default.createDirectoryIfNeeded(bin)
        let executable = FilePath.combine(bin, "ebook-convert"); FileManager.default.createFile(atPath: executable, contents: Data())
        EngineEnvironment.ownCopies = ["calibre": path("calibre.app")]
        XCTAssertEqual(CalibreConverter.locate(), executable)
        XCTAssertEqual(EngineEnvironment.folderWithPrograms("calibre", path("calibre.app")), bin)
        XCTAssertEqual(EngineEnvironment.folderWithPrograms("calibre", executable), bin)
        XCTAssertNotNil(EngineDownloads.components["calibre"])
        XCTAssertEqual(CopyVersions.parseVersion("calibre", "ebook-convert.exe (calibre 8.5.0)\nCreated by: Kovid Goyal")?.0, 8)
        XCTAssertEqual(CopyVersions.parseVersion("calibre", "ebook-convert.exe (calibre 8.5.0)")?.1, 5)
    }
    func testWrapperIsolatesSettingsAndKeepsArgumentsProgressAndErrorTail() async throws {
        let bin = path("fake-calibre"); try FileManager.default.createDirectoryIfNeeded(bin)
        let executable = FilePath.combine(bin, "ebook-convert")
        let script = """
        #!/bin/sh
        test "$CALIBRE_OVERRIDE_LANG" = en || exit 9
        test "$PYTHONIOENCODING" = utf-8 || exit 8
        root=$(pwd -P)
        for folder in "$CALIBRE_CONFIG_DIRECTORY" "$CALIBRE_CACHE_DIRECTORY" "$CALIBRE_TEMP_DIR"; do
          case "$(cd "$folder" && pwd -P)" in "$root"/*) test -d "$folder" || exit 7;; *) exit 6;; esac
        done
        echo '34% Running transforms'
        cp "$1" "$2"
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: executable)); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        EngineEnvironment.ownCopies = ["calibre": bin]
        let source = try save("source.oeb", Data("book".utf8)), output = try await convert(source, "oeb", "epub", Preset(), CalibreConverter())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), Data("book".utf8))
        try Data("#!/bin/sh\necho old >&2\necho one >&2\necho two >&2\necho three >&2\nexit 4\n".utf8).write(to: URL(fileURLWithPath: executable))
        do { _ = try await convert(source, "oeb", "epub", Preset(), CalibreConverter()); XCTFail("expected Calibre failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Calibre failed (exit 4). one two three") }
    }
    func testTcrUsesCompanionAndCommitsOnlyCompressedCapturedText() async throws {
        let bin = path("fake-calibre"); try FileManager.default.createDirectoryIfNeeded(bin)
        let convert = FilePath.combine(bin, "ebook-convert"), debug = FilePath.combine(bin, "calibre-debug")
        try Data("#!/bin/sh\nexit 8\n".utf8).write(to: URL(fileURLWithPath: convert))
        let script = """
        #!/bin/sh
        test "$1" = -e && test "$3" = -- && test "$#" = 6 || exit 9
        test "$CALIBRE_OVERRIDE_LANG" = en && test "$PYTHONIOENCODING" = utf-8 || exit 8
        test -f "$2" && test -d "$CALIBRE_CONFIG_DIRECTORY" || exit 7
        cp "$4" "$6"
        : > "$5"
        echo '67% Running TCR Output plugin'
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: debug))
        for file in [convert, debug] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file) }
        EngineEnvironment.ownCopies = ["calibre": bin]
        let source = Data("안녕하세요\nFileToX\n".utf8)
        let input = try save("source.epub", source)
        let output = try await self.convert(input, "epub", "tcr", Preset(), CalibreConverter())
        XCTAssertEqual(try TcrWriterTests.decode(Data(contentsOf: URL(fileURLWithPath: output))), source)
        try FileManager.default.removeItem(atPath: debug)
        do { _ = try await self.convert(input, "epub", "tcr", Preset(), CalibreConverter()); XCTFail("Expected missing companion failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("complete Calibre installation")) }
    }
    func testSafeTcrRoundTripsThroughCalibre() async throws {
        try useCalibre()
        let epub = try EbookBuilders.epub(folder)
        let tcr = try await convert(epub, "epub", "tcr", Preset(), CalibreConverter())
        let raw = try TcrWriterTests.decode(Data(contentsOf: URL(fileURLWithPath: tcr)))
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
        XCTAssertTrue(text.contains("밤하늘에 별이 반짝였다."))
        XCTAssertTrue(text.contains("주석 내용입니다."))
        let back = try await convert(tcr, "tcr", "epub", Preset(), CalibreConverter())
        XCTAssertTrue(PlainTextWriter.write(try EpubReader.readBook(back, folder).document).contains("밤하늘에 별이 반짝였다."))
    }
    func testTcrCompanionFollowsSelectedExecutableSymlink() async throws {
        let actual = path("selected"), aliases = path("aliases")
        for directory in [actual, aliases] { try FileManager.default.createDirectoryIfNeeded(directory) }
        let executable = FilePath.combine(actual, "ebook-convert")
        try Data("#!/bin/sh\nexit 8\n".utf8).write(to: URL(fileURLWithPath: executable))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        try FileManager.default.createSymbolicLink(atPath: FilePath.combine(aliases, "ebook-convert"), withDestinationPath: executable)
        let unrelated = FilePath.combine(aliases, "calibre-debug")
        try Data("#!/bin/sh\nprintf wrong-installation > \"$6\"\n: > \"$5\"\n".utf8).write(to: URL(fileURLWithPath: unrelated))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unrelated)
        EngineEnvironment.ownCopies = ["calibre": aliases]
        let input = try save("source.epub", Data("selected-installation".utf8))
        do { _ = try await convert(input, "epub", "tcr", Preset(), CalibreConverter()); XCTFail("Must not run the unrelated installation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("complete Calibre installation")) }
        let companion = FilePath.combine(actual, "calibre-debug")
        try Data("#!/bin/sh\ncp \"$4\" \"$6\"\n: > \"$5\"\n".utf8).write(to: URL(fileURLWithPath: companion))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: companion)
        let output = try await convert(input, "epub", "tcr", Preset(), CalibreConverter())
        XCTAssertEqual(try TcrWriterTests.decode(Data(contentsOf: URL(fileURLWithPath: output))), Data("selected-installation".utf8))
    }
    func testCalibreWritesKindleBooksAndBuiltInReaderReadsBack() async throws {
        try useCalibre()
        let epub = try EbookBuilders.epub(folder)
        for format in ["azw3", "mobi"] {
            let kindle = try await convert(epub, "epub", format, Preset(), CalibreConverter())
            XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: kindle)).count, 1000)
            let book = try MobiReader.readBook(kindle, folder), text = PlainTextWriter.write(book.document)
            XCTAssertEqual(book.metadata.title, "별빛 이야기"); XCTAssertTrue(book.metadata.authors.contains("김작가"))
            for expected in ["첫 번째 장", "밤하늘에 별이 반짝였다.", "두 번째 장", "주석 내용입니다.", "목록 둘"] { XCTAssertTrue(text.contains(expected), "\(format): \(expected)") }
            XCTAssertFalse(HDocumentWalker.images(book.document).isEmpty)
            let all = inlines(book.document), link = try XCTUnwrap(all.compactMap { $0 as? HLink }.first { $0.target.hasPrefix("#") })
            XCTAssertTrue(all.compactMap { $0 as? HBookmark }.contains { "#" + $0.name == link.target })
        }
    }
    func testCalibreJointMobiUsesItsKf8HalfAndSharedPictures() async throws {
        try useCalibre()
        let executable = try XCTUnwrap(CalibreConverter.locate()), epub = try EbookBuilders.epub(folder), output = path("joint.mobi")
        var environment = ["CALIBRE_OVERRIDE_LANG": "en", "PYTHONIOENCODING": "utf-8"]
        for (key, name) in [("CALIBRE_CONFIG_DIRECTORY", "config"), ("CALIBRE_CACHE_DIRECTORY", "cache"), ("CALIBRE_TEMP_DIR", "temp")] {
            let directory = path(name); try FileManager.default.createDirectoryIfNeeded(directory); environment[key] = directory
        }
        let result = try await ProcessRunner.run(executable, [epub, output, "--mobi-file-type", "both"], timeout: 120, workingDirectory: folder, environment: environment)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let database = try PalmDatabase.open(Data(contentsOf: URL(fileURLWithPath: output))), header = try MobiHeader.parse(database, 0)
        XCTAssertLessThan(header.version, 8); XCTAssertNotNil(header.kf8Boundary)
        let book = try MobiReader.readBook(output, folder), text = PlainTextWriter.write(book.document)
        for expected in ["첫 번째 장", "두 번째 장", "주석 내용입니다.", "목록 둘"] { XCTAssertTrue(text.contains(expected), expected) }
        XCTAssertFalse(HDocumentWalker.images(book.document).isEmpty)
        let all = inlines(book.document), link = try XCTUnwrap(all.compactMap { $0 as? HLink }.first { $0.target.hasPrefix("#") })
        XCTAssertTrue(all.compactMap { $0 as? HBookmark }.contains { "#" + $0.name == link.target })
    }
    func testCalibreReadsAndWritesRareFormats() async throws {
        try useCalibre()
        let epub = try EbookBuilders.epub(folder), lit = try await convert(epub, "epub", "lit", Preset(), CalibreConverter())
        let back = try await convert(lit, "lit", "epub", Preset(), CalibreConverter()), book = try EpubReader.readBook(back, folder), text = PlainTextWriter.write(book.document)
        XCTAssertTrue(text.contains("밤하늘에")); XCTAssertTrue(text.contains("주석 내용입니다."))
    }
}
