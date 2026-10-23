// Port of tests/Filee.Engines.Tests/ArchiveTests.cs (and the archive parts of PortableEngineTests.cs): conversions
// between archive formats (names incl. Korean, folders, contents and times survive), Extract to a folder, "Compress into
// one archive", Filee's own ALZ / EGG / lzip / bzip2 readers, and the safety checks (zip slip, links, passwords). Tests
// that need the bundled 7-Zip skip when it is missing (set FILETOX_BUNDLED_ENGINES to a folder with 7zip/7zz).

import Foundation
import XCTest
@testable import FileToXEngineKit

final class ArchiveTests: XCTestCase {
    private typealias B = ArchiveBuilders
    private var root = ""
    private let converter = ArchiveConverter()

    override func setUpWithError() throws {
        root = FilePath.combine(NSTemporaryDirectory(), "filetox-archive-tests", ArchiveFiles.guid().prefix(8).description)
        try FileManager.default.createDirectoryIfNeeded(root)
    }

    override func tearDownWithError() throws {
        FileManager.default.removeIfPresent(root)
    }

    private func newFolder() throws -> String {
        let dir = FilePath.combine(root, String(ArchiveFiles.guid().prefix(6)))
        try FileManager.default.createDirectoryIfNeeded(dir)
        return dir
    }

    private func skipWithout7Zip() throws {
        try XCTSkipUnless(converter.status().isAvailable, "7-Zip not found (set FILETOX_BUNDLED_ENGINES)")
    }

    /// Converts like a job: the step's work folder is fresh, the outputs are returned.
    private func convert(_ source: String, _ preset: Preset) async throws -> [String] {
        try await B.convert(converter, source, preset, work: try newFolder())
    }

    private func convertOne(_ source: String, _ preset: Preset) async throws -> String {
        let outputs = try await convert(source, preset)
        XCTAssertEqual(outputs.count, 1)
        return try XCTUnwrap(outputs.first)
    }

    private func assertFails(_ source: String, _ preset: Preset, containing text: String, file: StaticString = #filePath,
                             line: UInt = #line) async throws {
        do {
            _ = try await convert(source, preset)
            XCTFail("\(FilePath.fileName(source)) converted", file: file, line: line)
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains(text), "\(error.localizedDescription)", file: file, line: line)
        }
    }

    // ───────── Routes ─────────

    func testEveryReadableArchiveConvertsInOneStep() {
        let sources = ["zip", "jar", "7z", "rar", "tgz", "tbz2", "txz", "tar7z", "tz", "iso", "dmg", "cab", "rpm", "deb", "lha", "arj",
                       "alz", "egg", "lz", "tlz"]
        for from in sources {
            for to in ["zip", "7z", "tar", "tgz", "tbz2", "txz", FormatRegistry.folder] {
                XCTAssertEqual(B.route(from, to, converter.edges)?.count, 1, "\(from) → \(to)")
            }
        }
    }

    func testSingleFileCompressorsConvertAmongEachOtherButArchivesDoNotShrinkToThem() {
        XCTAssertEqual(B.route("gz", "xz", converter.edges)?.count, 1)
        XCTAssertEqual(B.route("lzma", "bz2", converter.edges)?.count, 1)
        XCTAssertEqual(B.route("lz", "gz", converter.edges)?.count, 1)
        XCTAssertNil(B.route("zip", "gz", converter.edges)) // several files do not fit into one .gz
        XCTAssertNil(B.route("zip", "rar", converter.edges)) // RAR cannot be written
        XCTAssertNil(B.route("lzo", "zip", converter.edges)) // no LZO reader
        // Every format the edges name exists in the registry.
        for edge in converter.edges {
            XCTAssertNotNil(FormatRegistry.find(id: edge.from), edge.from)
            XCTAssertNotNil(FormatRegistry.find(id: edge.to), edge.to)
        }
        XCTAssertEqual(converter.edges.count, 28 * 7 + 6 * 3)
        XCTAssertEqual(converter.edges.first, ConversionEdge("zip", "zip"))
        XCTAssertEqual(converter.edges.last, ConversionEdge("lz", "xz"))
    }

    // ───────── Archive → archive ─────────

    func testZip7zTgzTarZipRoundTripKeepsNamesFoldersContentsAndTimes() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let tree = try B.makeTree(dir, "프로젝트")
        let expected = try B.snapshot(tree)
        let zip = FilePath.combine(dir, "프로젝트.zip")
        try B.zipDirectory(tree, zip, includeBaseDirectory: true)

        var current = zip
        for target in ["7z", "tgz", "tar", "tbz2", "txz", "zip"] {
            current = try await convertOne(current, B.preset(target))
            XCTAssertTrue(current.hasSuffix("." + FormatRegistry.get(target).primaryExtension), current)
        }

        // The last ZIP read by the foundation reader: same tree below the "프로젝트" folder, UTF-8 names flagged.
        let check = FilePath.combine(dir, "check")
        try B.unzip(current, check)
        XCTAssertEqual(try B.snapshot(FilePath.combine(check, "프로젝트")), expected)
        XCTAssertTrue(try ZipReader(path: current).entries.filter { $0.name.utf8.contains { $0 >= 0x80 } }.allSatisfy { $0.flags & 0x800 != 0 })
        let time = try XCTUnwrap(ArchiveFiles.modificationDate(FilePath.combine(check, "프로젝트", "readme.txt")))
        XCTAssertLessThanOrEqual(abs(time.timeIntervalSince(B.knownTime)), 2, "time \(time) instead of \(B.knownTime)")
    }

    func testStoreAndMaximumLevelsAreApplied() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let text = FilePath.combine(dir, "big.txt")
        try B.words(300_000).write(to: URL(fileURLWithPath: text))
        let source = FilePath.combine(dir, "source.zip")
        let zip = try ZipWriter(path: source)
        try zip.add("big.txt", contentsOf: text)
        try zip.close()

        let stored = try await convertOne(source, B.preset("7z", level: .store, pattern: "{name}_store"))
        let max = try await convertOne(source, B.preset("7z", level: .maximum, pattern: "{name}_max"))
        XCTAssertGreaterThan(ArchiveFiles.fileLength(stored), 300_000)
        XCTAssertLessThan(ArchiveFiles.fileLength(max), 100_000)
    }

    func testSingleFileStreamsConvertGzXzBz2() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let data = B.words(50_000)
        let csv = FilePath.combine(dir, "data.csv")
        try data.write(to: URL(fileURLWithPath: csv))
        let gz = FilePath.combine(dir, "data.csv.gz")
        try await B.run7z("a", "-tgzip", gz, csv)
        try FileManager.default.removeItem(atPath: csv)

        let xz = try await convertOne(gz, B.preset("xz"))
        let bz2 = try await convertOne(xz, B.preset("bz2"))
        XCTAssertTrue(bz2.hasSuffix("data.csv.bz2"), bz2)

        let folder = try await convertOne(bz2, B.extract)
        XCTAssertEqual(try B.read(FilePath.combine(folder, "data.csv")), data)
    }

    // ───────── Extract ─────────

    func testExtractDoesNotNestASingleTopFolderAndRenamesOnConflict() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let tree = try B.makeTree(dir, "photos")
        let expected = try B.snapshot(tree)
        let zip = FilePath.combine(dir, "사진.zip")
        try B.zipDirectory(tree, zip, level: .fastest, includeBaseDirectory: true)
        try FileManager.default.removeItem(atPath: tree)

        let folder = try await convertOne(zip, B.extract)
        XCTAssertEqual(folder, FilePath.combine(dir, "사진"))
        XCTAssertEqual(try B.snapshot(folder), expected) // photos/… became 사진/…, not 사진/photos/…

        let second = try await convertOne(zip, B.extract)
        XCTAssertEqual(second, FilePath.combine(dir, "사진 (2)"))
        XCTAssertEqual(try B.snapshot(second), expected)

        // Nothing else was left next to the archive (no staging folders).
        XCTAssertEqual(try B.entries(dir), ["사진", "사진 (2)", "사진.zip"])
    }

    func testExtractKeepsSeveralTopEntriesInAFolderNamedAfterTheArchiveAndUnpacksTarGzFully() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let tree = try B.makeTree(dir, "tree")
        let tgz = FilePath.combine(dir, "backup.tar.gz")
        try B.gzip(try B.tar(directory: tree)).write(to: URL(fileURLWithPath: tgz))

        let folder = try await convertOne(tgz, B.extract)
        XCTAssertEqual(folder, FilePath.combine(dir, "backup"))
        XCTAssertEqual(try B.snapshot(folder), try B.snapshot(tree)) // files, not a lone backup.tar
    }

    func testExtractWithOverwriteMergesIntoTheExistingFolderAndSkipLeavesItAlone() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let tree = try B.makeTree(dir, "data")
        let zip = FilePath.combine(dir, "data.zip")
        try B.zipDirectory(tree, zip, level: .fastest, includeBaseDirectory: false)
        try FileManager.default.removeItem(atPath: tree)
        let target = FilePath.combine(dir, "data")
        try FileManager.default.createDirectoryIfNeeded(target)
        try B.write(FilePath.combine(target, "readme.txt"), "old")
        try B.write(FilePath.combine(target, "mine.txt"), "keep")

        var overwrite = B.extract
        overwrite.output.conflict = .overwrite
        let merged = try await convertOne(zip, overwrite)
        XCTAssertEqual(merged, target)
        XCTAssertEqual(try B.readText(FilePath.combine(target, "readme.txt")), "Filee archive test\n")
        XCTAssertEqual(try B.readText(FilePath.combine(target, "mine.txt")), "keep")
        XCTAssertTrue(FileManager.default.fileExists(FilePath.combine(target, "docs", "보고서", "data.csv")))

        var skip = B.extract
        skip.output.conflict = .skip
        let skipped = try await convert(zip, skip)
        XCTAssertEqual(skipped, [])
    }

    func testTarSymbolicLinksAreNotUnpacked() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let tar = FilePath.combine(dir, "links.tar")
        try B.tar([
            B.TarItem(name: "real.txt", data: Data("real".utf8)),
            B.TarItem(name: "escape", type: "2", link: "../../../../Windows/win.ini"),
            B.TarItem(name: "inside", type: "2", link: "real.txt"),
        ]).write(to: URL(fileURLWithPath: tar))

        let folder = try await convertOne(tar, B.extract)
        XCTAssertEqual(try B.entries(folder), ["real.txt"])
    }

    func testZipSlipEntriesAreRejected() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let inner = FilePath.combine(dir, "inner")
        try FileManager.default.createDirectoryIfNeeded(inner)
        let zip = FilePath.combine(inner, "evil.zip")
        let writer = try ZipWriter(path: zip)
        try writer.add("good.txt", text: "good")
        try writer.add("../../evil.txt", text: "evil")
        try writer.close()

        try await assertFails(zip, B.extract, containing: "outside the target folder")
        XCTAssertFalse(ArchiveFiles.exists(FilePath.combine(dir, "evil.txt")))
        XCTAssertEqual(try B.entries(inner), ["evil.zip"]) // no half-extracted folder
    }

    func testPasswordProtectedArchivesFailWithAClearMessage() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let secret = FilePath.combine(dir, "secret.txt")
        try B.write(secret, "secret")
        let zip = FilePath.combine(dir, "locked.zip")
        let sevenZip = FilePath.combine(dir, "locked.7z")
        try await B.run7z("a", "-tzip", "-ppassword", zip, secret)
        try await B.run7z("a", "-t7z", "-ppassword", "-mhe=on", sevenZip, secret)

        for archive in [zip, sevenZip] {
            try await assertFails(archive, B.preset("tgz"), containing: "password-protected")
        }
    }

    func testDamagedAndFakeArchivesFailCleanly() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let fake = FilePath.combine(dir, "fake.zip")
        try B.write(fake, "this is not a zip")

        try await assertFails(fake, B.extract, containing: "not a valid archive")
        XCTAssertEqual(try B.entries(dir), ["fake.zip"])
    }

    // ───────── Compress into one archive ─────────

    func testZipAllPacksAnyFilesAsTheyAre() async throws {
        let dir = try newFolder()
        let a = FilePath.combine(dir, "a"), b = FilePath.combine(dir, "b")
        try FileManager.default.createDirectoryIfNeeded(a)
        try FileManager.default.createDirectoryIfNeeded(b)
        let report = FilePath.combine(a, "보고서.txt")
        try B.write(report, "보고서")
        let unknown = FilePath.combine(a, "data.xyz")
        try B.noise(1000, 1).write(to: URL(fileURLWithPath: unknown))
        let image = try B.png(a, "photo.png")
        let sameName = FilePath.combine(b, "보고서.txt")
        try B.write(sameName, "다른 보고서")

        let output = try await B.combine(converter, [report, unknown, image, sameName], B.zipAll, work: try newFolder())

        XCTAssertEqual(output, FilePath.combine(a, "보고서_files.zip"))
        let zip = try ZipReader(path: output)
        XCTAssertEqual(zip.entries.map(\.name).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) },
                       ["data.xyz", "photo.png", "보고서 (2).txt", "보고서.txt"])
        XCTAssertEqual(try zip.string(named: "보고서 (2).txt"), "다른 보고서")
        XCTAssertEqual(try zip.data(named: "photo.png"), try B.read(image))
        XCTAssertTrue(FileManager.default.fileExists(report)) // sources untouched
    }

    func testZipAllWorksForASingleFileAndHonoursTheLevel() async throws {
        let dir = try newFolder()
        let text = FilePath.combine(dir, "notes.md")
        try B.words(100_000).write(to: URL(fileURLWithPath: text))
        var preset = B.zipAll
        preset.archive.level = .store

        let output = try await B.combine(converter, [text], preset, work: try newFolder())

        let entries = try ZipReader(path: output).entries
        XCTAssertEqual(entries.map(\.name), ["notes.md"])
        XCTAssertEqual(entries[0].uncompressedSize, entries[0].compressedSize)
    }

    func testZipAllPacksAFolderFromTheCommandLineWithItsContent() async throws {
        let dir = try newFolder()
        let tree = try B.makeTree(dir, "tree")

        let output = try await B.combine(converter, [tree], B.zipAll, work: try newFolder())

        XCTAssertEqual(output, FilePath.combine(dir, "tree_files.zip"))
        let check = FilePath.combine(dir, "check")
        try B.unzip(output, check)
        XCTAssertEqual(try B.snapshot(FilePath.combine(check, "tree")), try B.snapshot(tree))
    }

    func testCombineIntoOtherArchiveFormats() async throws {
        try skipWithout7Zip()
        for format in ["7z", "tgz", "txz"] {
            let dir = try newFolder()
            let one = FilePath.combine(dir, "하나.txt")
            let sub = FilePath.combine(dir, "sub")
            try FileManager.default.createDirectoryIfNeeded(sub)
            let two = FilePath.combine(sub, "하나.txt")
            try B.write(one, "1")
            try B.write(two, "2")
            var preset = B.preset(format)
            preset.archive.combineIntoOne = true

            let output = try await B.combine(converter, [one, two], preset, work: try newFolder())

            let folder = try await convertOne(output, B.extract)
            XCTAssertEqual(try B.readText(FilePath.combine(folder, "하나.txt")), "1", format)
            XCTAssertEqual(try B.readText(FilePath.combine(folder, "하나 (2).txt")), "2", format)
        }
    }

    // ───────── Filee's own readers ─────────

    func testAlzWithStoredDeflatedAndBzip2EntriesAndKoreanNames() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let big = B.words(2_000_000) // three 900k bzip2 blocks
        let small = Data("알집 테스트 ALZ".utf8)
        let alz = FilePath.combine(dir, "알집.alz")
        try B.writeAlz(alz, [
            B.AlzItem(name: "폴더\\", data: nil),
            B.AlzItem(name: "폴더\\저장.txt", data: small, method: 0),
            B.AlzItem(name: "압축.txt", data: B.words(10_000), method: 2),
            B.AlzItem(name: "큰 파일.txt", data: big, method: 1, packed: try B.toAlzBzip2(try await B.bzip2(big, dir))),
        ])

        let folder = try await convertOne(alz, B.extract)

        XCTAssertEqual(try B.read(FilePath.combine(folder, "폴더", "저장.txt")), small)
        XCTAssertEqual(try B.read(FilePath.combine(folder, "압축.txt")), B.words(10_000))
        XCTAssertEqual(try B.read(FilePath.combine(folder, "큰 파일.txt")), big)
        XCTAssertEqual(ArchiveFiles.modificationDate(FilePath.combine(folder, "압축.txt")), B.knownTime)
        // Created names keep their composed form (NFC), as .NET writes them; FileManager would store them decomposed.
        func stored(_ name: String, in folder: String) throws -> Bool {
            try FileManager.default.contentsOfDirectory(atPath: folder).contains { $0.utf8.elementsEqual(name.precomposedStringWithCanonicalMapping.utf8) }
        }
        XCTAssertTrue(try stored("알집", in: dir))
        XCTAssertTrue(try stored("폴더", in: folder))

        let zip = try await convertOne(alz, B.preset("zip"))
        XCTAssertTrue(try ZipReader(path: zip).entries.contains { $0.name == "폴더/저장.txt" })
    }

    func testAlzReaderRefusesEscapingAndEncryptedEntriesWithoutWritingOutside() throws {
        let dir = try newFolder()
        let target = FilePath.combine(dir, "out")
        try FileManager.default.createDirectoryIfNeeded(target)
        let slip = FilePath.combine(dir, "slip.alz")
        try B.writeAlz(slip, [B.AlzItem(name: "ok.txt", data: Data([1])), B.AlzItem(name: "..\\..\\evil.txt", data: Data([2]))])
        let locked = FilePath.combine(dir, "locked.alz")
        try B.writeAlz(locked, [B.AlzItem(name: "secret.txt", data: Data([3]), encrypted: true)])

        XCTAssertThrowsError(try AlzReader.extract(slip, target)) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the target folder"), error.localizedDescription)
        }
        XCTAssertFalse(ArchiveFiles.exists(FilePath.combine(dir, "evil.txt")))
        XCTAssertThrowsError(try AlzReader.extract(locked, target)) { error in
            XCTAssertTrue(error.localizedDescription.contains("password-protected"), error.localizedDescription)
        }
    }

    func testEggWithStoreDeflateBzip2LzmaAndMultiBlockEntries() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let text = B.words(30_000)
        let part1 = B.words(5_000)
        let part2 = B.noise(7_000, 3)
        let egg = FilePath.combine(dir, "에그.egg")
        try B.writeEgg(egg, [
            B.EggItem(name: "문서/", folder: true),
            B.EggItem(name: "문서/stored.txt", folder: false, blocks: [B.EggBlock(data: text, method: 0)]),
            B.EggItem(name: "deflate.txt", folder: false, blocks: [B.EggBlock(data: text, method: 1)]),
            B.EggItem(name: "bzip2.txt", folder: false, blocks: [B.EggBlock(data: text, method: 2, packed: try await B.bzip2(text, dir))]),
            B.EggItem(name: "lzma.txt", folder: false,
                      blocks: [B.EggBlock(data: text, method: 4, packed: B.eggLzma(try await B.rawLzma(text, endMarker: false, dir)))]),
            B.EggItem(name: "두 블록.bin", folder: false, blocks: [B.EggBlock(data: part1, method: 1), B.EggBlock(data: part2, method: 0)]),
        ])

        let folder = try await convertOne(egg, B.extract)

        for name in ["문서/stored.txt", "deflate.txt", "bzip2.txt", "lzma.txt"] {
            XCTAssertEqual(try B.read(FilePath.combine(folder, name)), text, name)
        }
        XCTAssertEqual(try B.read(FilePath.combine(folder, "두 블록.bin")), part1 + part2)
        XCTAssertEqual(ArchiveFiles.modificationDate(FilePath.combine(folder, "deflate.txt")), B.knownTime)
    }

    func testSolidEggArchivesFailWithAClearMessage() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let egg = FilePath.combine(dir, "solid.egg")
        try B.writeEgg(egg, [B.EggItem(name: "a.txt", folder: false, blocks: [B.EggBlock(data: Data([1, 2, 3]), method: 0)])], solid: true)

        try await assertFails(egg, B.extract, containing: "solid")
    }

    func testLzipFilesAndTarLzAreUnpacked() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let first = B.words(40_000)
        let second = B.noise(3_000, 9)
        let lz = FilePath.combine(dir, "log.txt.lz")
        // Two members, as written by plzip or "cat a.lz b.lz".
        try (try await B.lzip(first, dir) + (try await B.lzip(second, dir))).write(to: URL(fileURLWithPath: lz))

        let folder = try await convertOne(lz, B.extract)
        XCTAssertEqual(try B.read(FilePath.combine(folder, "log.txt")), first + second)

        let tree = try B.makeTree(dir, "tree")
        let tarLz = FilePath.combine(dir, "backup.tar.lz")
        try (try await B.lzip(try B.tar(directory: tree), dir)).write(to: URL(fileURLWithPath: tarLz))

        let unpacked = try await convertOne(tarLz, B.extract)
        XCTAssertEqual(try B.snapshot(unpacked), try B.snapshot(tree))
        let zip = try await convertOne(tarLz, B.preset("zip"))
        XCTAssertTrue(zip.hasSuffix("backup.zip"), zip)
    }

    func testBzip2DecoderReadsStandardMultiBlockStreams() async throws {
        try XCTSkipUnless(B.sevenZipExe != nil, "7-Zip not found")
        let dir = try newFolder()
        let data = B.words(2_500_000)
        var bz2 = try await B.bzip2(data, dir)

        var output = Data()
        try Bzip2Decoder.decompress(bz2, { output.append($0) }, alzFraming: false, maxOutput: .max)
        XCTAssertEqual(output, data)

        // A flipped bit is caught by the block checksum instead of producing wrong data.
        bz2[bz2.count / 2] ^= 0x10
        XCTAssertThrowsError(try Bzip2Decoder.decompress(bz2, { _ in }, alzFraming: false, maxOutput: .max))
    }

    // ───────── PortableEngineTests (tar parts, on the archive engine: Filee's EngineInstaller is not ported) ─────────

    func testTarArchivesPreserveProgramLayoutContentsAndUnixExecutableMode() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let tgz = FilePath.combine(dir, "tool.tar.gz")
        try B.gzip(B.tar([B.TarItem(name: "tool/bin/tool", data: Data("#!/bin/sh\necho ready\n".utf8), mode: 0o700)]))
            .write(to: URL(fileURLWithPath: tgz))

        let folder = try await convertOne(tgz, B.extract)
        let program = FilePath.combine(folder, "bin", "tool")
        XCTAssertTrue(try B.readText(program).contains("echo ready"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: program))
    }

    func testTarEntriesCannotEscapeTheTargetFolder() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let inner = FilePath.combine(dir, "inner")
        try FileManager.default.createDirectoryIfNeeded(inner)
        let tgz = FilePath.combine(inner, "escape.tar.gz")
        try B.gzip(B.tar([B.TarItem(name: "../escaped", data: Data([1]))])).write(to: URL(fileURLWithPath: tgz))

        try await assertFails(tgz, B.extract, containing: "outside the target folder")
        XCTAssertFalse(ArchiveFiles.exists(FilePath.combine(dir, "escaped")))
        XCTAssertEqual(try B.entries(inner), ["escape.tar.gz"])
    }

    func testTarSymbolicLinksCannotWriteOutsideTheTargetFolder() async throws {
        try skipWithout7Zip()
        let dir = try newFolder()
        let outside = FilePath.combine(dir, "outside")
        try FileManager.default.createDirectoryIfNeeded(outside)
        let inner = FilePath.combine(dir, "inner")
        try FileManager.default.createDirectoryIfNeeded(inner)
        let tgz = FilePath.combine(inner, "links.tar.gz")
        try B.gzip(B.tar([
            B.TarItem(name: "link", type: "2", link: "../../outside"),
            B.TarItem(name: "link/escaped", data: Data([1])),
        ])).write(to: URL(fileURLWithPath: tgz))

        _ = try? await convert(tgz, B.extract)
        XCTAssertFalse(ArchiveFiles.exists(FilePath.combine(outside, "escaped")))
    }

    // ───────── Helpers ─────────

    func testUnsafeEntryPathsAreRecognised() {
        let cases: [(String, Bool)] = [
            ("../evil.txt", true), ("a/../../evil.txt", true), ("..\\evil.txt", true), ("/etc/passwd", true), ("\\abs.txt", true),
            ("C:\\drive.txt", true), ("a/b/c.txt", false), ("한글/파일..txt", false),
        ]
        for (path, unsafe) in cases { XCTAssertEqual(ArchiveSafety.isUnsafePath(path), unsafe, path) }
    }

    func testEntryNamesAreMadeValidWindowsNamesInsideTheRoot() throws {
        let root = try newFolder()
        XCTAssertEqual(try ArchiveSafety.resolveEntryPath(root, "폴더\\파일.txt", "x.alz"), FilePath.combine(root, "폴더", "파일.txt"))
        XCTAssertEqual(try ArchiveSafety.resolveEntryPath(root, "a|b/CON.txt", "x.alz"), FilePath.combine(root, "a_b", "_CON.txt"))
        XCTAssertEqual(try ArchiveSafety.resolveEntryPath(root, "file.txt:stream", "x.alz"), FilePath.combine(root, "file.txt_stream")) // no NTFS streams
        XCTAssertEqual(try ArchiveSafety.resolveEntryPath(root, "./dir//file?", "x.alz"), FilePath.combine(root, "dir", "file_"))
    }

    func testListingParserReads7ZipTechnicalOutput() {
        let output = """
            7-Zip 26.03 (x64)

            Listing archive: x.tar

            --
            Path = x.tar
            Type = tar

            ----------
            Path = dir\\file.txt
            Folder = -
            Size = 7
            Mode = -rw-r--r--
            Symbolic Link =
            Hard Link =

            Path = dir\\link
            Folder = -
            Size = 27
            Mode = lrw-r--r--
            Symbolic Link = ../../x
            Hard Link =

            Path = dir
            Folder = +
            Size = 0
            Encrypted = +

            """
        let entries = SevenZip.parseListing(output)
        XCTAssertEqual(entries.map(\.path), ["dir\\file.txt", "dir\\link", "dir"])
        XCTAssertFalse(entries[0].isSymbolicLink)
        XCTAssertTrue(entries[1].isSymbolicLink)
        XCTAssertTrue(entries[2].isFolder)
        XCTAssertTrue(entries[2].isEncrypted)
        XCTAssertEqual(entries[0].size, 7)
    }

    func testClashingNamesInOneArchiveAreNumbered() {
        let items = ArchiveConverter.uniqueEntries(["/tmp/a/x.txt", "/tmp/b/X.txt", "/tmp/c/x.txt", "/tmp/d/y"])
        XCTAssertEqual(items.map(\.entryName), ["x.txt", "X (2).txt", "x (3).txt", "y"])
    }

    func testLzipDictionarySizes() {
        XCTAssertEqual(LzipReader.dictionarySize(0x14), 1 << 20)
        XCTAssertEqual(LzipReader.dictionarySize(0xD3), (1 << 19) - 6 * (1 << 15)) // 2^19 minus 6/16
        XCTAssertEqual(LzipReader.dictionarySize(0x0C), 4096)
    }

    func testSizesInMessagesLookLikeFilees() {
        XCTAssertEqual(ArchiveSafety.formatSize(512), "512 bytes")
        XCTAssertEqual(ArchiveSafety.formatSize(1280), "1.3 KB") // 1.25 rounds away from zero
        XCTAssertEqual(ArchiveSafety.formatSize(1_503_238_554), "1.4 GB")
        XCTAssertEqual(ArchiveSafety.formatSize(50 * 1024 * 1024), "50 MB")
    }
}
