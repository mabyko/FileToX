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
        let calibre = "build/optional-engines/osx-arm64/calibre/calibre.app"
        guard FileManager.default.directoryExists(calibre) else { throw XCTSkip("Calibre development copy not found") }
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
    func testCalibreReadsAndWritesRareFormats() async throws {
        try useCalibre()
        let epub = try EbookBuilders.epub(folder), lit = try await convert(epub, "epub", "lit", Preset(), CalibreConverter())
        let back = try await convert(lit, "lit", "epub", Preset(), CalibreConverter()), book = try EpubReader.readBook(back, folder), text = PlainTextWriter.write(book.document)
        XCTAssertTrue(text.contains("밤하늘에")); XCTAssertTrue(text.contains("주석 내용입니다."))
    }
}
