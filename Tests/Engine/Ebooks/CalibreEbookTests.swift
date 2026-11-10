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
        let calibre = ProcessInfo.processInfo.environment["FILETOX_CALIBRE"] ?? FileManager.default.currentDirectoryPath + "/build/optional-engines/osx-arm64/calibre/calibre.app"
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
        let executable = FilePath.combine(bin, "ebook-convert"), debug = FilePath.combine(bin, "calibre-debug")
        try Data("#!/bin/sh\nexit 8\n".utf8).write(to: URL(fileURLWithPath: executable))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        let script = """
        #!/bin/sh
        test "$1" = -e && test "$3" = -- && test "$#" = 5 || exit 10
        test "$CALIBRE_OVERRIDE_LANG" = en || exit 9
        test "$PYTHONIOENCODING" = utf-8 || exit 8
        root=$(pwd -P)
        for folder in "$CALIBRE_CONFIG_DIRECTORY" "$CALIBRE_CACHE_DIRECTORY" "$CALIBRE_TEMP_DIR"; do
          case "$(cd "$folder" && pwd -P)" in "$root"/*) test -d "$folder" || exit 7;; *) exit 6;; esac
        done
        echo '34% Running transforms'
        cp "$4" "$5"
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: debug)); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: debug)
        EngineEnvironment.ownCopies = ["calibre": bin]
        let source = try save("source.oeb", Data("book".utf8)), output = try await convert(source, "oeb", "epub", Preset(), CalibreConverter())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), Data("book".utf8))
        try Data("#!/bin/sh\necho old >&2\necho one >&2\necho two >&2\necho three >&2\nexit 4\n".utf8).write(to: URL(fileURLWithPath: debug))
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
    func testPdbIsReadButNoLongerWritten() {
        // PalmDoc holds only Windows-1252 text, so FileToX reads old PDB books but writes no new ones.
        XCTAssertEqual(FormatRegistry.find(id: "pdb")?.writable, false)
        XCTAssertFalse(CalibreConverter.outputs.contains("pdb"))
        let planner = RoutePlanner(EngineRegistry.createAll(EngineEnvironment(dataDirectory: folder)))
        for source in ["epub", "txt", "docx", "mobi"] { XCTAssertNil(planner.plan(source, "pdb"), source) }
        XCTAssertEqual(planner.plan("pdb", "epub")?.steps.map(\.converter.id), ["calibre"])
        // A preset saved before keeps validating (it shows as unavailable) so the rest of the library can be saved.
        var preset = Preset(); preset.id = "old-pdb"; preset.targetFormat = "pdb"
        XCTAssertNoThrow(try Validation.library([preset], []))
    }

    func testPmlRoundTripKeepsSupportedTextLinksAndCompanionImages() async throws {
        try useCalibre()
        let picture = try GraphicsTestKit.makeImage(folder, "picture.png", width: 640, height: 360)
        let originalPixels = ImagePixels.bitmap(try GraphicsTestKit.decode(picture).frames[0]).pixels
        let html = #"""
        <html><head><title>PML sample</title></head><body><h1>First chapter</h1>
        <p>FileToX café Â α → C:\books 한글 日本語</p><p><a href="#note">Read note</a></p>
        <p><img src="picture.png" /></p><p id="note">The note survives.</p></body></html>
        """#
        let source = try save("source.html", Data(html.utf8))
        let epub = try await convert(source, "html", "epub")
        let pml = try await convert(epub, "epub", "pml", Preset(), CalibreConverter())
        let bytes = try Data(contentsOf: URL(fileURLWithPath: pml))
        XCTAssertFalse(bytes.starts(with: [0x50, 0x4b]), "PML must be text, not a renamed PMLZ archive")
        let images = FilePath.combine(folder, FilePath.fileNameWithoutExtension(pml) + "_img")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: images).isEmpty)
        let back = try await convert(pml, "pml", "epub", Preset(), CalibreConverter())
        try assertEpubImageReferencesExist(back)
        let book = try EpubReader.readBook(back, folder), text = PlainTextWriter.write(book.document)
        for expected in ["First chapter", "FileToX", "café", "Â", "α", "→", #"C:\books"#, "한글", "日本語", "The note survives."] {
            XCTAssertTrue(text.contains(expected), "Missing \(expected): \(text)")
        }
        let recoveredImages = HDocumentWalker.images(book.document)
        XCTAssertFalse(recoveredImages.isEmpty)
        for image in recoveredImages { XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), image.path) }
        let recovered = try XCTUnwrap(recoveredImages.first { ImageSupport.info($0.path).map { $0.width == 640 && $0.height == 360 } == true })
        XCTAssertEqual(ImagePixels.bitmap(try GraphicsTestKit.decode(recovered.path).frames[0]).pixels, originalPixels)
        let all = inlines(book.document)
        let link = try XCTUnwrap(all.compactMap { $0 as? HLink }.first { $0.target.hasPrefix("#") })
        XCTAssertTrue(all.compactMap { $0 as? HBookmark }.contains { "#" + $0.name == link.target })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pml)), bytes)
    }
    func testPmlReadsHandWrittenImageBesideAPathWithBrackets() async throws {
        try useCalibre()
        let source = try save("book.pml", Data(#"A figure follows.\m="fig1.png"After the figure."#.utf8))
        let images = path("book_img")
        try FileManager.default.createDirectoryIfNeeded(images)
        let bytes = try EbookBuilders.picture(70, 40)
        try bytes.write(to: URL(fileURLWithPath: FilePath.combine(images, "fig1.png")))
        let work = path("[pages]"); try FileManager.default.createDirectoryIfNeeded(work)
        let step = ConversionStep(inputPath: source, from: "pml", to: "epub", preset: Preset(), output: EbookTestOutput(path("figures")), workDirectory: work)
        let outputs = try await CalibreConverter().convert(step, progress: nil)
        let output = try XCTUnwrap(outputs.first)
        try assertEpubImageReferencesExist(output)
        let doc = try EpubReader.readBook(output, folder).document
        let pictures = HDocumentWalker.images(doc)
        XCTAssertFalse(pictures.isEmpty)
        for picture in pictures { XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path), picture.path) }
        XCTAssertTrue(pictures.contains { ImageSupport.info($0.path).map { $0.width == 70 && $0.height == 40 } == true })
        XCTAssertTrue(PlainTextWriter.write(doc).contains("After the figure."))
    }
    private func assertEpubImageReferencesExist(_ path: String) throws {
        let zip = try ZipReader(path: path)
        var count = 0
        for entry in zip.entries where entry.name.hasSuffix(".html") || entry.name.hasSuffix(".xhtml") {
            let html = String(decoding: try zip.data(for: entry), as: UTF8.self)
            for match in EbookRegex.matches(#"<img\b[^>]*\bsrc="([^"]+)""#, html) {
                let reference = EbookRegex.group(match, html, 1).removingPercentEncoding ?? ""
                let resolved = URL(fileURLWithPath: "/" + entry.name).deletingLastPathComponent().appendingPathComponent(reference).standardized.path
                XCTAssertNotNil(zip.entry(named: String(resolved.dropFirst())), "Missing image: \(entry.name) → \(reference)")
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0, "The original body image must remain referenced")
    }
    func testPmlImageNamesFollowFilesystemCaseButRequireLowercasePngReferences() async throws {
        try useCalibre()
        let source = try save("case.pml", Data(#"A picture: \m="fig.png""#.utf8))
        let images = path("case_img"); try FileManager.default.createDirectoryIfNeeded(images)
        let bytes = try EbookBuilders.picture(50, 30)
        try bytes.write(to: URL(fileURLWithPath: FilePath.combine(images, "FIG.PNG")))
        if FileManager.default.fileExists(atPath: FilePath.combine(images, "fig.png")) {
            let output = try await convert(source, "pml", "epub", Preset(), CalibreConverter())
            try assertEpubImageReferencesExist(output)
            let doc = try EpubReader.readBook(output, folder).document
            XCTAssertTrue(HDocumentWalker.images(doc).contains { ImageSupport.info($0.path).map { $0.width == 50 && $0.height == 30 } == true })
        } else {
            XCTAssertThrowsError(try PmlPackage.copyInputImages(source, beside: path("case-sensitive.pml")))
        }
        try bytes.write(to: URL(fileURLWithPath: FilePath.combine(images, "a.png")))
        for (index, name) in ["FIG.PNG", ".fig.png", ".png", "fig#1.png", "fig?1.png", "fig%20.png", "fig&1.png", "figure one.png", "그림.png"].enumerated() {
            try bytes.write(to: URL(fileURLWithPath: FilePath.combine(images, name)))
            try Data("An unsupported reference: \\m=\"\(name)\"".utf8).write(to: URL(fileURLWithPath: source))
            let stem = path("invalid-name-\(index)-must-not-publish")
            let step = ConversionStep(inputPath: source, from: "pml", to: "epub", preset: Preset(), output: EbookTestOutput(stem), workDirectory: folder)
            do { _ = try await CalibreConverter().convert(step, progress: nil); XCTFail("Expected portable PNG reference requirement") }
            catch { XCTAssertTrue(error.localizedDescription.contains("lowercase .png"), error.localizedDescription) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: stem + ".epub"))
        }
    }
    func testPmlPreservesAnUnreferencedConventionalCover() async throws {
        try useCalibre()
        let bytes = try EbookBuilders.picture(90, 60)
        for companion in ["book_img", "images"] {
            let base = path("cover-" + companion); try FileManager.default.createDirectoryIfNeeded(base)
            let source = FilePath.combine(base, "book.pml")
            try Data("A body without an inline image.".utf8).write(to: URL(fileURLWithPath: source))
            let images = FilePath.combine(base, companion); try FileManager.default.createDirectoryIfNeeded(images)
            let cover = FilePath.combine(images, "cover.png"); try bytes.write(to: URL(fileURLWithPath: cover))
            let output = try await convert(source, "pml", "epub", Preset(), CalibreConverter())
            let book = try EpubReader.readBook(output, folder)
            let recovered = try XCTUnwrap(book.metadata.coverImage)
            let size = try XCTUnwrap(ImageSupport.info(recovered))
            XCTAssertEqual(size.width, 90); XCTAssertEqual(size.height, 60)
            XCTAssertTrue(PlainTextWriter.write(book.document).contains("A body without an inline image."))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cover)), bytes)
        }
    }
    func testPmlRejectsUnrepresentableTextBeforeAllocatingOutput() async throws {
        try useCalibre()
        let html = try save("non-bmp.html", Data("<html><body><p>A supplementary character: 😀</p></body></html>".utf8))
        let source = try await convert(html, "html", "epub"), stem = path("must-not-be-published")
        let step = ConversionStep(inputPath: source, from: "epub", to: "pml", preset: Preset(), output: EbookTestOutput(stem), workDirectory: folder)
        do { _ = try await CalibreConverter().convert(step, progress: nil); XCTFail("Expected unsupported PML character") }
        catch { XCTAssertTrue(error.localizedDescription.contains("PML cannot represent U+"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stem + ".pml"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stem + "_img"))
    }
    func testPmlPackageRejectsMissingImagesTraversalAndDuplicateNames() throws {
        let cases: [[(String, String)]] = [
            [("index.pml", #"\m="missing.png""#)],
            [("index.pml", "text"), ("../outside.png", "bad")],
            [("index.pml", "text"), ("index_img/../outside.png", "bad")],
            [("index.pml", #"\m="../outside.png""#)],
            [("index.pml", "text"), ("INDEX.PML", "duplicate")],
            [("index_img/pic.png", "no main file")],
        ]
        for (index, entries) in cases.enumerated() {
            let archive = path("bad-\(index).pmlz"), zip = try ZipWriter(path: archive)
            for (name, text) in entries { try zip.add(name, text: text) }
            try zip.close()
            XCTAssertThrowsError(try PmlPackage.unpack(archive, in: folder), "\(entries)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("outside.png")))
    }
    func testPmlCopiesReferencedImagesAndRejectsMissingOrLinkedImages() throws {
        let source = try save("book.pml", Data(#"\m="picture.png" \\m="literal.png""#.utf8))
        let images = path("book_img"), work = path("input")
        try FileManager.default.createDirectoryIfNeeded(images)
        try FileManager.default.createDirectoryIfNeeded(work)
        let picture = FilePath.combine(images, "picture.png")
        let bytes = try EbookBuilders.picture(20, 10)
        try bytes.write(to: URL(fileURLWithPath: picture))
        try Data("unrelated".utf8).write(to: URL(fileURLWithPath: FilePath.combine(images, "unrelated.png")))
        let unused = path("unrelated-assets"); try FileManager.default.createDirectoryIfNeeded(unused)
        try FileManager.default.createSymbolicLink(atPath: path("images"), withDestinationPath: unused)
        try PmlPackage.copyInputImages(source, beside: FilePath.combine(work, "input.pml"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FilePath.combine(work, "input_img")), ["picture.png"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: FilePath.combine(work, "input_img/picture.png"))), bytes)
        try FileManager.default.removeItem(atPath: path("images"))
        try FileManager.default.removeItem(atPath: picture)
        XCTAssertThrowsError(try PmlPackage.copyInputImages(source, beside: path("missing.pml"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("every referenced PNG"), error.localizedDescription)
        }
        try FileManager.default.createSymbolicLink(atPath: picture, withDestinationPath: source)
        XCTAssertThrowsError(try PmlPackage.copyInputImages(source, beside: path("linked.pml"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("every referenced PNG"), error.localizedDescription)
        }
    }
    func testLitKeepsNonSpineNavigationStyles() async throws {
        try useCalibre()
        let epub = try EbookBuilders.epub(folder)
        let lit = try await convert(epub, "epub", "lit", Preset(), CalibreConverter())
        let original = try Data(contentsOf: URL(fileURLWithPath: lit))
        let back = try await convert(lit, "lit", "epub", Preset(), CalibreConverter())
        let extracted = path("navigation-styles")
        try EbookFiles.extract(ZipReader(path: back), extracted)
        let opfPath = try OpfPackage.rootFile(extracted), opf = try XDocument.load(opfPath)
        let toc = try XCTUnwrap(opf.root.descendants().first { $0.name.localName == "reference" && $0.attributeValue("type") == "toc" })
        let tocPath = try XCTUnwrap(EbookFiles.safePath(FilePath.directoryName(opfPath)!, try XCTUnwrap(toc.attributeValue("href"))))
        try assertNavigationStyles(tocPath)
        let package = try OpfPackage.load(opfPath)
        XCTAssertFalse(package.spine.contains { $0.path == tocPath }, "Preserve the input's reading order")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: lit)), original)
        let text = PlainTextWriter.write(try EpubReader.readBook(back, folder).document)
        for expected in ["첫 번째 장", "두 번째 장", "주석 내용입니다."] { XCTAssertTrue(text.contains(expected)) }

        let azw3 = try await convert(back, "epub", "azw3", Preset(), CalibreConverter())
        let kindleFolder = path("kindle-navigation")
        try FileManager.default.createDirectoryIfNeeded(kindleFolder)
        _ = try MobiReader.readBook(azw3, kindleFolder)
        let pages = try FileManager.default.subpathsOfDirectory(atPath: kindleFolder).filter { $0.hasSuffix(".xhtml") }
        let kindleToc = try XCTUnwrap(pages.first { try String(contentsOfFile: FilePath.combine(kindleFolder, $0), encoding: .utf8).contains("calibre_toc_header") })
        try assertNavigationStyles(FilePath.combine(kindleFolder, kindleToc))
    }
    private func assertNavigationStyles(_ tocPath: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let html = try XDocument.load(tocPath)
        let styles = html.root.descendants().filter { $0.name.localName == "link" && $0.attributeValue("rel") == "stylesheet" }
        XCTAssertFalse(styles.isEmpty, file: file, line: line)
        var css = ""
        for style in styles {
            let target = try XCTUnwrap(EbookFiles.safePath(FilePath.directoryName(tocPath)!, try XCTUnwrap(style.attributeValue("href"))))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target), "Missing linked stylesheet: \(target)", file: file, line: line)
            if FileManager.default.fileExists(atPath: target) { css += try String(contentsOfFile: target, encoding: .utf8) }
        }
        // Calibre emits simple class selectors. Resolve the rules used by the actual TOC elements.
        func declarations(_ name: String) throws -> CssDeclarations {
            let element = try XCTUnwrap(html.root.descendants().first { ($0.attributeValue("class") ?? "").split(separator: " ").contains(Substring(name)) })
            let classes = (element.attributeValue("class") ?? "").split(separator: " ").map { "." + $0 }
            var result = CssDeclarations()
            for rule in EbookRegex.matches(#"([^{}]+)\{([^{}]*)\}"#, css) {
                let selectors = EbookRegex.group(rule, css, 1).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if selectors.contains(where: classes.contains) { result.merge(CssDeclarations.parse(EbookRegex.group(rule, css, 2))) }
            }
            result.merge(CssDeclarations.parse(element.attributeValue("style")))
            return result
        }
        XCTAssertEqual(try declarations("calibre_toc_header")["text-align"], "center", file: file, line: line)
        let block = try declarations("calibre_toc_block")
        XCTAssertEqual(block["margin-left"], "1.2em", file: file, line: line)
        XCTAssertEqual(block["text-indent"], "-1.2em", file: file, line: line)
    }
    func testConversionUsesSelectedCompanionAndRejectsIncompleteInstallation() async throws {
        let actual = path("selected"), aliases = path("aliases")
        for directory in [actual, aliases] { try FileManager.default.createDirectoryIfNeeded(directory) }
        let executable = FilePath.combine(actual, "ebook-convert")
        try Data("#!/bin/sh\nexit 8\n".utf8).write(to: URL(fileURLWithPath: executable))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        try FileManager.default.createSymbolicLink(atPath: FilePath.combine(aliases, "ebook-convert"), withDestinationPath: executable)
        let unrelated = FilePath.combine(aliases, "calibre-debug")
        try Data("#!/bin/sh\nprintf wrong-installation > \"$5\"\n".utf8).write(to: URL(fileURLWithPath: unrelated))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unrelated)
        EngineEnvironment.ownCopies = ["calibre": aliases]
        let input = try save("source.lit", Data("selected-installation".utf8))
        for (from, to) in [("lit", "epub"), ("epub", "azw3")] {
            do { _ = try await convert(input, from, to, Preset(), CalibreConverter()); XCTFail("Expected missing selected companion failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains("E-book style preservation requires calibre-debug")) }
        }
        let companion = FilePath.combine(actual, "calibre-debug")
        let script = """
        #!/bin/sh
        test "$1" = -e && test "$3" = -- && test "$#" = 5 || exit 9
        test -f "$2" && test -d "$CALIBRE_CONFIG_DIRECTORY" || exit 7
        cp "$4" "$5"
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: companion))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: companion)
        for (from, to) in [("lit", "epub"), ("epub", "azw3")] {
            let output = try await convert(input, from, to, Preset(), CalibreConverter())
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), Data("selected-installation".utf8))
        }
    }
}
