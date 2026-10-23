import Foundation
import XCTest
@testable import FileToXEngineKit

final class FormatRegistryTests: XCTestCase {
    func testRegistryMatchesFileeCatalog() {
        XCTAssertEqual(FormatRegistry.known.count, 172)
        XCTAssertEqual(FormatRegistry.known.filter { !$0.writable }.count, 58)
        XCTAssertEqual(FormatRegistry.known.first?.id, "png")
        XCTAssertEqual(FormatRegistry.known.last?.id, "eot")
        let extensions = FormatRegistry.known.flatMap(\.extensions).filter { !$0.isEmpty }
        XCTAssertEqual(extensions.count, 257)
        XCTAssertEqual(Set(extensions).count, 257)
    }

    func testRegistryMatchesBundledAppCatalog() throws {
        // The app's static catalog (Resources/FileeFormats.json) and the engine must list the same formats.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/FileeFormats.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let formats = try XCTUnwrap(root["formats"] as? [[String: Any]])
        XCTAssertEqual(formats.map { $0["id"] as? String }, FormatRegistry.known.map(\.id))
        for (json, format) in zip(formats, FormatRegistry.known) {
            XCTAssertEqual(json["extensions"] as? [String], format.extensions, format.id)
            XCTAssertEqual(json["writable"] as? Bool, format.writable, format.id)
            XCTAssertEqual(json["category"] as? String, format.category.rawValue, format.id)
            XCTAssertEqual(json["displayName"] as? String, format.displayName, format.id)
        }
    }

    func testDetectionUsesCompoundAndCaseInsensitiveExtensions() {
        XCTAssertEqual(FormatRegistry.detect("/a/b/backup.TAR.GZ")?.id, "tgz")
        XCTAssertEqual(FormatRegistry.extensionOf("/a/b/backup.TAR.GZ"), "TAR.GZ")
        XCTAssertEqual(FormatRegistry.nameWithoutExtension("/x/backup.tar.gz"), "backup")
        XCTAssertEqual(FormatRegistry.detect("photo.JPEG")?.id, "jpg")
        XCTAssertEqual(FormatRegistry.detect("/x/.tar.gz")?.id, "gz", "the name must be longer than the compound extension")
        XCTAssertNil(FormatRegistry.detect("/x/README"))
        XCTAssertEqual(FormatRegistry.find(id: "PNG")?.id, "png")
        XCTAssertEqual(FormatRegistry.find(extension: ".dvr-ms")?.id, "wtv")
    }
}

final class FilePathTests: XCTestCase {
    func testDotNetPathSemantics() {
        XCTAssertEqual(FilePath.extension("/a/b.c/file"), "")
        XCTAssertEqual(FilePath.extension("/a/file.tar.gz"), ".gz")
        XCTAssertEqual(FilePath.extension("/a/file."), "")
        XCTAssertEqual(FilePath.extension(".bashrc"), ".bashrc")
        XCTAssertEqual(FilePath.fileNameWithoutExtension("/a/x.y.z"), "x.y")
        XCTAssertEqual(FilePath.directoryName("/a/b"), "/a")
        XCTAssertEqual(FilePath.directoryName("/a"), "/")
        XCTAssertNil(FilePath.directoryName("/"))
        XCTAssertEqual(FilePath.directoryName("name"), "")
        XCTAssertEqual(FilePath.combine("/a", "b", "/c", "d"), "/c/d")
        XCTAssertEqual(FilePath.changeExtension("/a/x.png", "jpg"), "/a/x.jpg")
        XCTAssertEqual(FilePath.changeExtension("/a/x", ".jpg"), "/a/x.jpg")
        XCTAssertEqual(FilePath.fullPath("/a/./b/../c"), "/a/c")
    }
}

final class PageRangeTests: XCTestCase {
    func testParsesLikeFilee() {
        XCTAssertEqual(PageRange.parse("", pageCount: 3), [0, 1, 2])
        XCTAssertEqual(PageRange.parse("2-", pageCount: 4), [1, 2, 3])
        XCTAssertEqual(PageRange.parse("-2, 4", pageCount: 5), [0, 1, 3])
        XCTAssertEqual(PageRange.parse("5-3", pageCount: 9), [2, 3, 4])
        XCTAssertEqual(PageRange.parse("x, 99", pageCount: 3), [0, 1, 2], "nothing valid means every page")
        XCTAssertEqual(PageRange.parse("1", pageCount: 0), [])
    }
}

final class ZipTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ftx-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testRoundTripAndPythonCanReadIt() throws {
        let path = folder.appendingPathComponent("t.zip").path
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) })
        let source = folder.appendingPathComponent("big.bin").path
        try big.write(to: URL(fileURLWithPath: source))
        let writer = try ZipWriter(path: path)
        try writer.add("mimetype", text: "application/epub+zip", level: .noCompression)
        try writer.addDirectory("한글 폴더")
        try writer.add("한글 폴더/문서.txt", text: "안녕하세요")
        try writer.add("big.bin", contentsOf: source, level: .smallestSize)
        try writer.close()

        let reader = try ZipReader(path: path)
        XCTAssertEqual(reader.entries.map(\.name), ["mimetype", "한글 폴더/", "한글 폴더/문서.txt", "big.bin"])
        XCTAssertEqual(reader.entries[0].method, 0)
        XCTAssertEqual(try reader.string(named: "한글 폴더/문서.txt"), "안녕하세요")
        XCTAssertEqual(try reader.data(named: "big.bin"), big)
        // EPUB readers want the mimetype bytes right after the first local header.
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(String(decoding: raw[38..<58], as: UTF8.self), "application/epub+zip")

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        check.arguments = ["-I", "-c", "import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);assert z.testzip() is None;print(len(z.namelist()))", path]
        let pipe = Pipe()
        check.standardOutput = pipe
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "4")
    }

    func testReadsArchiveMadeByDitto() throws {
        let content = folder.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: content.appendingPathComponent("a.txt"))
        let archive = folder.appendingPathComponent("d.zip").path
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", content.path, archive]
        try ditto.run()
        ditto.waitUntilExit()
        let reader = try ZipReader(path: archive)
        XCTAssertEqual(try reader.string(named: "a.txt"), "hello")
    }

    func testDamagedEntryFailsItsCheck() throws {
        let path = folder.appendingPathComponent("c.zip").path
        let writer = try ZipWriter(path: path)
        try writer.add("a.txt", data: Data(repeating: 65, count: 1000), level: .noCompression)
        try writer.close()
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        bytes[40] ^= 0xFF
        let reader = try ZipReader(data: bytes)
        XCTAssertThrowsError(try reader.data(named: "a.txt"))
        XCTAssertThrowsError(try ZipReader(data: Data("not a zip at all, definitely not".utf8)))
    }
}

final class XmlTests: XCTestCase {
    func testWhitespaceRulesMatchLinqToXml() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="urn:w" xmlns:r="urn:r" zeta="1" alpha="2">
          <w:p r:id="x" w:val="y"><w:t xml:space="preserve"> </w:t><w:t> </w:t><w:t>a &amp; b</w:t><![CDATA[<c>]]></w:p>
          <x xmlns="urn:d" b="1"/>
        </w:document>
        """
        let document = try XDocument.parse(xml)
        let w = XNamespace("urn:w")
        XCTAssertEqual(document.declaration?.standalone, "yes")
        let root = document.root
        XCTAssertEqual(root.name, w + "document")
        XCTAssertEqual(root.attributes.filter { !$0.isNamespaceDeclaration }.map(\.name.localName), ["zeta", "alpha"])
        let runs = root.descendants(w + "t")
        XCTAssertEqual(runs.map(\.value), [" ", "", "a & b"])
        XCTAssertTrue(root.firstDescendant(w + "t") { $0.value.isEmpty } === runs[1]) // document order, first match
        XCTAssertTrue(root.firstDescendant(w + "t") === runs[0])
        XCTAssertNil(root.firstDescendant(w + "t") { $0.value == "zzz" })
        XCTAssertEqual(root.element(w + "p")?.attributeValue(XNamespace("urn:r") + "id"), "x")
        XCTAssertEqual(root.element(w + "p")?.value, " a & b<c>")
        XCTAssertEqual(root.element(XNamespace("urn:d") + "x")?.attributeValue("b"), "1")
        XCTAssertEqual(try XDocument.parse(xml, preserveWhitespace: true).root.descendants(w + "t")[1].value, " ")
    }

    func testSerializationRoundTripsNamespacesAndEscapes() throws {
        let w = XNamespace("urn:w")
        let root = XElement(w + "document",
                            XAttribute(XNamespace.xmlns + "w", w.namespaceName),
                            XElement(w + "p", XElement(w + "t", XAttribute(XNamespace.xml + "space", "preserve"), " a<&>\"b\" ")),
                            XElement("plain", XAttribute("v", "x\ty\"z"), 12),
                            XElement(XNamespace("urn:other") + "o", XAttribute(XNamespace("urn:attr") + "k", "1")))
        let text = String(decoding: try XDocument(root: root).data(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<w:document xmlns:w=\"urn:w\">"), text)
        XCTAssertTrue(text.contains("<w:t xml:space=\"preserve\"> a&lt;&amp;&gt;\"b\" </w:t>"), text)
        XCTAssertTrue(text.contains("<plain v=\"x&#x9;y&quot;z\">12</plain>"), text)
        let reparsed = try XDocument.parse(text).root
        XCTAssertEqual(reparsed.descendants(w + "t").first?.value, " a<&>\"b\" ")
        XCTAssertEqual(reparsed.element(XNamespace("urn:other") + "o")?.attributeValue(XNamespace("urn:attr") + "k"), "1")
        XCTAssertThrowsError(try XElement("bad", "\u{1}").toString())
        XCTAssertThrowsError(try XDocument.parse("<a><b></a>"))
    }

    func testExternalEntitiesAreNotLoaded() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("ftx-secret-\(UUID().uuidString).txt")
        try Data("TOPSECRET".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        let xml = "<!DOCTYPE a [<!ENTITY x SYSTEM \"\(secret.absoluteString)\">]><a>&x;</a>"
        let value = (try? XDocument.parse(xml))?.root.value ?? ""
        XCTAssertFalse(value.contains("TOPSECRET"))
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testCollectsOutputLinesAndExitCode() async throws {
        let lines = LineBox()
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "printf 'a\\r\\nb\\rc\\n'; echo err >&2; exit 3"], timeout: 10,
                                                 onOutput: { lines.add($0) })
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardOutput, "a\nb\nc\n")
        XCTAssertEqual(result.standardError, "err\n")
        XCTAssertEqual(Set(lines.values), ["a", "b", "c", "err"])
    }

    func testStdinIsEmptyAndNoExtraDescriptorLeaks() async throws {
        let result = try await ProcessRunner.run("/usr/bin/python3", ["-I", "-c", "import os,sys;sys.stdin.read();print(sorted(os.listdir('/dev/fd')))"], timeout: 10)
        // 0, 1, 2 and the descriptor listdir itself opens for /dev/fd.
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "['0', '1', '2', '3']")
    }

    func testTimeoutKillsTheWholeTree() async throws {
        let started = Date()
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "(/bin/sleep 41.75; true) & /bin/sleep 42.75"], timeout: 1)
            XCTFail("expected a timeout")
        } catch is ProcessTimeoutError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        try await Task.sleep(nanoseconds: 300_000_000)
        let processes = try await ProcessRunner.run("/bin/ps", ["-axo", "command="], timeout: 10).standardOutput
        let survivors = processes.split(separator: "\n").filter { $0.hasPrefix("/bin/sleep 41.75") || $0.hasPrefix("/bin/sleep 42.75") }
        XCTAssertEqual(survivors, [])
    }

    func testCancellationStopsTheProcess() async throws {
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["30"], timeout: 60) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    func testBlockingRun() throws {
        XCTAssertEqual(try ProcessRunner.runBlocking("/bin/echo", ["hi"], timeout: 5).standardOutput, "hi\n")
        XCTAssertThrowsError(try ProcessRunner.runBlocking("/bin/sleep", ["5"], timeout: 0.5))
    }
}

final class TextEncodingTests: XCTestCase {
    func testDecodeTextFallsBackToCp949() throws {
        let cp949 = try XCTUnwrap(TextEncodings.encoding(codePage: 949))
        let bytes = try XCTUnwrap("안녕하세요".data(using: cp949))
        XCTAssertEqual(TextEncodings.decodeText(bytes), "안녕하세요")
        XCTAssertEqual(TextEncodings.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data("abc".utf8)), "abc")
        XCTAssertEqual(TextEncodings.decodeText(Data([0xFF, 0xFE, 0x41, 0x00])), "A")
        XCTAssertEqual(TextEncodings.decode(Data([0x41, 0xFF, 0x42]), encoding: .ascii).count, 3, "invalid bytes become U+FFFD")
        XCTAssertNotNil(TextEncodings.encoding(name: "euc-kr"))
        XCTAssertNotNil(TextEncodings.encoding(name: "windows-1252"))
    }
}

final class EngineEnvironmentTests: XCTestCase {
    func testFindsProgramsInBinAndAppBundles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ftx-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("ffmpeg/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["ffmpeg", "ffprobe"] { FileManager.default.createFile(atPath: bin.appendingPathComponent(name).path, contents: Data()) }
        XCTAssertEqual(EngineEnvironment.folderWithPrograms("ffmpeg", root.appendingPathComponent("ffmpeg").path), bin.path)
        XCTAssertEqual(EngineEnvironment.folderWithPrograms("ffmpeg", bin.appendingPathComponent("ffmpeg").path), bin.path)
        let macos = root.appendingPathComponent("lo/LibreOffice.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: macos.appendingPathComponent("soffice").path, contents: Data())
        XCTAssertEqual(EngineEnvironment.folderWithPrograms("libreoffice", root.appendingPathComponent("lo").path), macos.path)
        XCTAssertNil(EngineEnvironment.folderWithPrograms("pandoc", root.path))
    }

    func testEngineDownloadsReadPinnedList() {
        XCTAssertEqual(EngineDownloads.components["rhwp"]?.version, "0.8.6")
        XCTAssertNotNil(EngineDownloads.components["7zip"])
        let ffmpeg = EngineDownloads.packages.first { $0.id == "ffmpeg" }!
        XCTAssertFalse(EngineDownloads.canDownload(ffmpeg), "FFmpeg has no macOS download")
        XCTAssertNotNil(CopyVersions.expected("ffmpeg"))
        XCTAssertEqual(CopyVersions.parseVersion("pandoc", "pandoc 3.12\nFeatures")?.0, 3)
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.withLock { storage.append(line) } }
    var values: [String] { lock.withLock { storage } }
}

final class CodecLibraryTests: XCTestCase {
    func testEncoderLibrariesAreLinked() {
        XCTAssertEqual(CodecLibraries.webpVersion, "1.6.0")
        XCTAssertTrue(CodecLibraries.jxlVersion.hasPrefix("0.10."), CodecLibraries.jxlVersion)
    }
}
