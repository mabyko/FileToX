import Darwin
import Foundation
import PDFKit
import XCTest

@testable import FileToXEngineKit

final class LibreOfficeFormatTests: OfficeTestCase {
    private var ownCopies: [String: String] = [:]
    override func setUpWithError() throws {
        try super.setUpWithError()
        ownCopies = EngineEnvironment.ownCopies
    }
    override func tearDownWithError() throws {
        EngineEnvironment.ownCopies = ownCopies
        try super.tearDownWithError()
    }
    func testFiltersFollowApplication() {
        let cases: [(String, String, String?, String)] = [
            ("wpd", "pdf", nil, "pdf:writer_pdf_Export"), ("pages", "docx", nil, "docx:MS Word 2007 XML"),
            ("abw", "odt", nil, "odt"), ("wps", "txt", nil, "txt:Text (encoded):UTF8"),
            ("numbers", "xlsx", nil, "xlsx:Calc MS Excel 2007 XML"),
            ("sdc", "csv", nil, "csv:Text - txt - csv (StarCalc):44,34,76"), ("et", "pdf", nil, "pdf:calc_pdf_Export"),
            ("key", "pptx", nil, "pptx:Impress MS PowerPoint 2007 XML"), ("dps", "odp", nil, "odp"),
            ("sda", "pdf", "sdd", "pdf:impress_pdf_Export"), ("sda", "pdf", "sda", "pdf:draw_pdf_Export"),
            ("cdr", "pdf", nil, "pdf:draw_pdf_Export"), ("vsd", "svg", nil, "svg:draw_svg_Export"),
            ("pub", "png", nil, "png:draw_png_Export"), ("odg", "odg", nil, "odg:draw8"),
            ("cgm", "odg", nil, "odg:impress8_draw"), ("cgm", "svg", nil, "svg:impress_svg_Export"),
            ("emf", "pdf", nil, "pdf:draw_pdf_Export"), ("wmf", "png", nil, "png:draw_png_Export"),
        ]
        for (from, to, ext, want) in cases {
            XCTAssertEqual(LibreOfficeConverter.filterFor(from, to, false, ext), want)
        }
        XCTAssertEqual(
            LibreOfficeConverter.filterFor("docx", "pdf", true),
            "pdf:writer_pdf_Export:{\"SelectPdfVersion\":{\"type\":\"long\",\"value\":\"2\"}}")
    }
    func testEveryEdgeHasMatchingFilterAndCost() {
        let engine = LibreOfficeConverter(EngineEnvironment(dataDirectory: folder))
        for edge in engine.edges {
            let family =
                ["pub", "cdr", "vsd", "odg", "emf", "wmf"].contains(edge.from)
                ? "draw"
                : ["pptx", "ppt", "odp", "key", "dps", "sda", "cgm"].contains(edge.from)
                    ? "impress"
                    : ["xlsx", "xls", "ods", "csv", "et", "numbers", "sdc"].contains(edge.from) ? "calc" : "writer"
            let filter = LibreOfficeConverter.filterFor(edge.from, edge.to, false)
            if ["pdf", "svg", "png"].contains(edge.to) {
                XCTAssertEqual(filter, "\(edge.to):\(family)_\(edge.to)_Export")
            } else if !["odt", "ods", "odp"].contains(edge.to) {
                XCTAssertTrue(filter.contains(":"), filter)
            }
            XCTAssertGreaterThanOrEqual(edge.cost, 25)
        }
        for from in [
            "dot", "wps", "wpd", "lwp", "abw", "pages", "sdw", "et", "numbers", "sdc", "key", "dps", "sda", "pub",
            "cdr", "cgm", "vsd", "odg",
        ] { XCTAssertTrue(engine.edges.contains { $0.from == from && $0.to == "pdf" }) }
    }
    private func fake(_ body: String) throws -> LibreOfficeConverter {
        let bin = path("fake-bin")
        try FileManager.default.createDirectoryIfNeeded(bin)
        let executable = FilePath.combine(bin, "soffice")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: URL(fileURLWithPath: executable))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        EngineEnvironment.ownCopies = ["libreoffice": bin]
        return LibreOfficeConverter(EngineEnvironment(dataDirectory: path("engine-data")))
    }
    private var parseArguments: String {
        #"""
        profile=
        output=
        filter=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -env:UserInstallation=*) profile=${1#*=} ;;
            --convert-to) shift; filter=$1 ;;
            --outdir) shift; output=$1 ;;
          esac
          shift
        done
        """# + "\n"
    }
    func testProcessOutputProfileAndPdfA() async throws {
        let engine = try fake(
            parseArguments + #"""
                printf '%s\n%s\n' "$profile" "$filter" > "$output/arguments.log"
                """#)
        let input = path("input.docx")
        try Data("input".utf8).write(to: URL(fileURLWithPath: input))
        let outs = try await convert(input, "docx", "pdf", engine, true)
        let text = try String(contentsOfFile: outs[0], encoding: .utf8)
        XCTAssertTrue(text.contains("libreoffice-profiles/worker-0"))
        XCTAssertTrue(text.contains("SelectPdfVersion"))
        XCTAssertTrue(text.contains("file:///"))
        XCTAssertEqual(engine.maxParallelism, 2)
        XCTAssertFalse(text.contains("Application%20Support/FileToX"))
    }
    func testHwpFilterDetectionUpdatesEdgesAndStatus() throws {
        let engine = try fake("exit 0\n")
        XCTAssertFalse(engine.edges.contains { $0.from == "hwp" })
        let extensionFolder = path("share/extensions/org.H2Orestart.test")
        try FileManager.default.createDirectoryIfNeeded(extensionFolder)
        XCTAssertEqual(engine.status().version, "H2Orestart")
        XCTAssertEqual(engine.edges.filter { ["hwp", "hwpx"].contains($0.from) }.count, 8)
        try FileManager.default.removeItem(atPath: path("share"))
        XCTAssertNil(engine.status().version)
        XCTAssertFalse(engine.edges.contains { $0.from == "hwp" })
    }
    func testNoOutputErrorText() async throws {
        let engine = try fake("echo 'bad document' >&2\nexit 7\n")
        do {
            _ = try await convert(path("missing.docx"), "docx", "pdf", engine)
            XCTFail("Expected error")
        } catch { XCTAssertEqual(error.localizedDescription, "LibreOffice produced no output (exit 7). bad document") }
    }
    func testCancellationKillsChildAndReturnsProfile() async throws {
        let engine = try fake(
            parseArguments + #"""
                /bin/sleep 120 &
                child=$!
                printf '%s\n' "$child" > "$output/child.pid"
                wait "$child"
                """#)
        let task = Task { try await self.convert(self.path("input.docx"), "docx", "pdf", engine) }
        var child: Int32?
        for _ in 0..<100 {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let dir = files.first(where: { $0.hasPrefix("lo-") }),
                let text = try? String(contentsOfFile: path(dir + "/child.pid"), encoding: .utf8),
                let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                child = pid
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let pid = child else {
            task.cancel()
            _ = try? await task.value
            XCTFail("Child did not start")
            return
        }
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(kill(pid, 0), -1)
        // Two further runs establish that a cancelled conversion returned its permit.
        let exe = EngineEnvironment.ownProgram("libreoffice", "soffice")!
        try Data(("#!/bin/sh\n" + parseArguments + "printf ok > \"$output/done.pdf\"\n").utf8).write(
            to: URL(fileURLWithPath: exe))
        _ = try await convert(path("next.docx"), "docx", "pdf", engine)
        _ = try await convert(path("last.docx"), "docx", "pdf", engine)
    }
    func testConcurrentConversionsUseExclusiveProfiles() async throws {
        let engine = try fake(
            parseArguments + #"""
                path=${profile#file://}
                if ! mkdir "$path/active"; then exit 9; fi
                /bin/sleep 0.08
                printf ok > "$output/done.pdf"
                rmdir "$path/active"
                """#)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask { _ = try await self.convert(self.path("input\(i).docx"), "docx", "pdf", engine) }
            }
            try await group.waitForAll()
        }
    }
    func testLibreOfficeReadsOurOdsAndWeReadItsOdsAndXls() async throws {
        let engine = try libreOffice()
        let input = try XlsxBuilder.sales(path("sales.xlsx"))
        let source = try XlsxReader.read(input)
        try OdsWriter.write(source, path("our.ods"))
        let opened = try await convert(path("our.ods"), "ods", "xlsx", engine)[0]
        let ods = try await convert(input, "xlsx", "ods", engine)[0]
        let xls = try await convert(input, "xlsx", "xls", engine)[0]
        for (file, format) in [(opened, "xlsx"), (ods, "ods"), (xls, "xls")] {
            let book = try SpreadsheetConverter.read(file, format)
            let sales = book.sheets[0]
            XCTAssertEqual(book.sheets.map(\.name), ["매출", "메모", "넓은 표"])
            XCTAssertEqual(sales.get(2, 1)?.text, "1,350,000원")
            XCTAssertEqual(sales.get(2, 3)?.text, "12.8%")
            XCTAssertEqual(sales.get(2, 2)?.value, 46296)
            XCTAssertEqual(sales.merges, [CellRange(0, 0, 0, 3)])
            XCTAssertEqual(sales.get(1, 0)?.style.align, .center)
        }
        let roundTrip = try await convert(xls, "xls", "xlsx", engine)[0]
        XCTAssertEqual(try XlsxReader.read(roundTrip).sheets[0].get(2, 1)?.value, 1_350_000)
    }
    func testRealDocxPdfAndOdtDocxRoutes() async throws {
        let engine = try libreOffice()
        let input = path("hello.txt")
        try Data("Hello FileToX\n한글".utf8).write(to: URL(fileURLWithPath: input))
        let docx = try await convert(input, "txt", "docx", engine)[0]
        let pdf = try await convert(docx, "docx", "pdf", engine, true)[0]
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: pdf)).starts(with: Data("%PDF".utf8)))
        let metadata = String(decoding: try Data(contentsOf: URL(fileURLWithPath: pdf)), as: UTF8.self)
        XCTAssertNotNil(metadata.range(of: #"pdfaid:part(?:=['"]|>)\s*2"#, options: .regularExpression))
        XCTAssertNotNil(metadata.range(of: #"pdfaid:conformance(?:=['"]|>)\s*B"#, options: .regularExpression))
        let odt = try await convert(docx, "docx", "odt", engine)[0]
        let back = try await convert(odt, "odt", "docx", engine)[0]
        XCTAssertNotNil(try ZipReader(path: back).entry(named: "word/document.xml"))
    }
    func testRealAbiWordToPdfAndDocx() async throws {
        let engine = try libreOffice()
        let input = path("note.abw")
        try Data(
            "<abiword template=\"false\" xmlns=\"http://www.abisource.com/awml.dtd\" version=\"3.0.4\" fileformat=\"1.1\"><section><p>Hello AbiWord</p><p>Second paragraph</p></section></abiword>"
                .utf8
        ).write(to: URL(fileURLWithPath: input))
        for target in ["pdf", "docx"] {
            let out = try await convert(input, "abw", target, engine)[0]
            XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: out)).count, 100)
        }
    }
    private func drawing(_ format: String, _ label: String) throws -> String {
        let input = path("drawing." + format)
        let archive = try ZipWriter(path: input)
        let presentation = format == "odp"
        let kind = presentation ? "presentation" : "drawing"
        let mime = "application/vnd.oasis.opendocument." + (presentation ? "presentation" : "graphics")
        try archive.add("mimetype", text: mime, level: .noCompression)
        try archive.add(
            "META-INF/manifest.xml",
            text:
                "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"\(mime)\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
        )
        try archive.add(
            "content.xml",
            text:
                "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:draw=\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\" xmlns:svg=\"urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:\(kind)><draw:page draw:name=\"page1\"><draw:rect svg:x=\"2cm\" svg:y=\"2cm\" svg:width=\"8cm\" svg:height=\"4cm\"><text:p>\(label)</text:p></draw:rect></draw:page></office:\(kind)></office:body></office:document-content>"
        )
        try archive.close()
        return input
    }
    func testRealDrawingToSvgPngAndPdf() async throws {
        let engine = try libreOffice()
        let input = try drawing("odg", "Filee drawing")
        for format in ["svg", "png", "pdf"] {
            let output = try await convert(input, "odg", format, engine)[0]
            let bytes = try Data(contentsOf: URL(fileURLWithPath: output))
            if format == "svg" { XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("<svg")) }
            if format == "png" { XCTAssertTrue(bytes.starts(with: [0x89, 0x50, 0x4e, 0x47])) }
            if format == "pdf" { XCTAssertTrue(PDFDocument(data: bytes)?.string?.contains("Filee drawing") == true) }
        }
    }
    func testRealPptToPdf() async throws {
        let engine = try libreOffice()
        let odp = try drawing("odp", "Filee presentation")
        let ppt = try await convert(odp, "odp", "ppt", engine)[0]
        let pdf = try await convert(ppt, "ppt", "pdf", engine)[0]
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf)))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Filee presentation") == true)
    }
    func testRealWarmUpPreparesBothProfilesOnce() async throws {
        let engine = try libreOffice()
        let first = try await engine.warmUpAsync()
        let second = try await engine.warmUpAsync()
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0)
    }
    func testRealCancellationStopsSoffice() async throws {
        let engine = try libreOffice()
        let input = path("long.txt")
        try Data(String(repeating: "FileToX cancellation input\n", count: 20000).utf8).write(
            to: URL(fileURLWithPath: input))
        let before = Set(ProcessRunner.childProcesses(of: ProcessInfo.processInfo.processIdentifier))
        let task = Task { try await self.convert(input, "txt", "pdf", engine) }
        var process: Int32?
        for _ in 0..<200 {
            if let pid = ProcessRunner.childProcesses(of: ProcessInfo.processInfo.processIdentifier).first(where: {
                !before.contains($0)
            }) {
                process = pid
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let pid = process else {
            task.cancel()
            _ = try? await task.value
            XCTFail("soffice did not start")
            return
        }
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(kill(pid, 0), -1)
    }
    func testRealRoutesMatchCSharpBaseline() async throws {
        let engine = try libreOffice()
        let txt = path("baseline.txt")
        try Data("Hello FileToX\nSecond paragraph\n한글 문서\n".utf8).write(to: URL(fileURLWithPath: txt))
        let docx = try await convert(txt, "txt", "docx", engine)[0]
        let odt = try await convert(docx, "docx", "odt", engine)[0]
        let ppt = try await convert(drawing("odp", "Filee presentation"), "odp", "ppt", engine)[0]
        let xls = try XlsBuilder.sales(path("baseline.xls"))
        let cases = [(docx, "docx", "pdf"), (xls, "xls", "xlsx"), (ppt, "ppt", "pdf"), (odt, "odt", "docx")]
        var actual: [String: Data] = [:]
        for (input, from, to) in cases {
            let key = from + "-" + to
            let output = try await convert(input, from, to, engine)[0]
            actual[key] = try Data(contentsOf: URL(fileURLWithPath: output))
            if let export = ProcessInfo.processInfo.environment["FTX_P5_EXPORT_DIR"] {
                let folder = FilePath.combine(export, "libreoffice-cases", key)
                try FileManager.default.createDirectoryIfNeeded(folder)
                let target = FilePath.combine(folder, "sample." + from)
                if FileManager.default.fileExists(target) { try FileManager.default.removeItem(atPath: target) }
                try FileManager.default.copyItem(atPath: input, toPath: target)
            }
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "Fixtures/libreoffice-baseline.json")
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        for (key, bytes) in actual {
            let baseline = try XCTUnwrap(expected[key].flatMap { Data(base64Encoded: $0) })
            if key.hasSuffix("pdf") {
                let got = try XCTUnwrap(PDFDocument(data: bytes))
                let want = try XCTUnwrap(PDFDocument(data: baseline))
                XCTAssertEqual(got.pageCount, want.pageCount, key)
                XCTAssertEqual(got.string, want.string, key)
            } else {
                let got = path("got-" + key + "." + key.components(separatedBy: "-")[1])
                let want = path("want-" + key + "." + key.components(separatedBy: "-")[1])
                try bytes.write(to: URL(fileURLWithPath: got))
                try baseline.write(to: URL(fileURLWithPath: want))
                if key.hasSuffix("xlsx") {
                    // The C# host chooses its built-in XLS reader here; LibreOffice escapes equivalent format codes.
                    let source = try XlsxReader.read(want)
                    let result = try XlsxReader.read(got)
                    assertSameCells(source, result, compareFormats: false)
                    let formatter = FileToXEngineKit.NumberFormatter()
                    for (a, b) in zip(source.sheets, result.sheets) {
                        for (r, cells) in a.rows {
                            for (c, cell) in cells {
                                if let value = cell.value, cell.isNumber {
                                    XCTAssertEqual(
                                        formatter.format(value, cell.numberFormat),
                                        formatter.format(value, b.get(r, c)?.numberFormat))
                                }
                            }
                        }
                    }
                } else {
                    let ns = XNamespace("http://schemas.openxmlformats.org/wordprocessingml/2006/main")
                    func text(_ file: String) throws -> [String] {
                        try XDocument.load(data: XCTUnwrap(ZipReader(path: file).data(named: "word/document.xml"))).root
                            .descendants(ns + "t").map(\.value)
                    }
                    XCTAssertEqual(try text(got), try text(want), key)
                }
            }
        }
    }

}
