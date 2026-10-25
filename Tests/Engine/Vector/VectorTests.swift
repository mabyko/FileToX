// Port of the vector part of Filee.Engines.Tests/GraphicsTests.cs: SVG → PDF/PNG, SVGZ, Illustrator files and
// Ghostscript (EPS/PS, skipped when Ghostscript is not installed; a stand-in `gs` script checks the arguments).
// Filee's route tests need the route planner of the core; here the engines' direct edges are checked instead.

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import FileToXEngineKit

final class VectorTests: XCTestCase {
    private let vector = VectorConverter()
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }

    override func tearDown() {
        FileManager.default.removeIfPresent(dir)
        EngineEnvironment.ownCopies = [:]
    }

    private func write(_ name: String, _ text: String) throws -> String {
        let path = FilePath.combine(dir, name)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func preset(_ change: (inout Preset) -> Void) -> Preset {
        var preset = Preset()
        change(&preset)
        return preset
    }

    // ───────────────────────── SVG ─────────────────────────

    func testSvgToPdfIsVector() async throws {
        let svg = try write("drawing.svg", GraphicsBuilders.svg)
        let output = try await GraphicsTestKit.convert(vector, svg, to: "pdf")
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: output[0])))
        XCTAssertEqual(document.pageCount, 1)
        // 400 × 200 CSS px = 300 × 150 pt.
        let box = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 300, accuracy: 0.1)
        XCTAssertEqual(box.height, 150, accuracy: 0.1)

        let page = try XCTUnwrap(document.page(at: 0)?.pageRef)
        var content = ""
        var images: [(Int, Int)] = []
        var fonts = 0
        PdfContent.collect(page, &content, &images, &fonts)
        XCTAssertNotNil(content.range(of: #"\s(c|l|re)\s"#, options: .regularExpression), "path operators: curves, lines, rectangles")
        XCTAssertNotNil(content.range(of: #"\sf\*?\s"#, options: .regularExpression), "fills")
        // Text is drawn as glyph outlines (Filee's OutlinedTextPlayback): no fonts in the file.
        XCTAssertFalse(content.contains("BT"))
        XCTAssertEqual(fonts, 0)
        let size = try FileManager.default.attributesOfItem(atPath: output[0])[.size] as! Int
        XCTAssertLessThan(size, 100_000, "the PDF should be small")
        XCTAssertFalse(images.contains { $0.0 > 64 || $0.1 > 64 }, "no picture of the drawing: \(images)")
    }

    func testSvgToPngIsRenderedLargeEnoughAndKeepsTransparency() async throws {
        let svg = try write("drawing.svg", GraphicsBuilders.svg)
        let png = try await GraphicsTestKit.convert(vector, svg, to: "png")
        let sized = try await GraphicsTestKit.convert(vector, svg, to: "webp", preset: preset {
            $0.image.resize = .longEdge
            $0.image.longEdge = 300
            $0.image.webpLossless = true
        })
        let jpg = try await GraphicsTestKit.convert(vector, svg, to: "jpg")

        let image = try GraphicsTestKit.decode(png[0])
        // At least 1024 px on the long edge (the default 150 dpi would give only 625 px).
        XCTAssertEqual([image.width, image.height], [1024, 512])
        XCTAssertEqual(GraphicsTestKit.pixel(image.frames[0], 3, 3).a, 0)
        let circle = GraphicsTestKit.pixel(image.frames[0], 512, 256)
        XCTAssertTrue(circle.r > 240 && circle.g < 20 && circle.a == 255, "\(circle)")
        let webp = try GraphicsTestKit.decode(sized[0])
        XCTAssertEqual([webp.width, webp.height], [300, 150]) // rendered at exactly that size
        XCTAssertGreaterThan(GraphicsTestKit.pixel(try GraphicsTestKit.decode(jpg[0]).frames[0], 3, 3).r, 245, "JPG gets the preset background")
    }

    func testSvgzRoundTrip() async throws {
        let svg = try write("logo.svg", GraphicsBuilders.svg)
        let packed = try await GraphicsTestKit.convert(vector, svg, to: "svgz")
        XCTAssertEqual(Array(try Data(contentsOf: URL(fileURLWithPath: packed[0])).prefix(2)), [0x1F, 0x8B])

        let unpacked = try await GraphicsTestKit.convert(vector, packed[0], to: "svg", name: "logo_plain")
        var resize = Preset()
        resize.image.resize = .longEdge
        resize.image.longEdge = 200
        let rendered = try await GraphicsTestKit.convert(vector, packed[0], to: "png", preset: resize)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: svg)), try Data(contentsOf: URL(fileURLWithPath: unpacked[0])))
        XCTAssertEqual(try GraphicsTestKit.decode(rendered[0]).width, 200)
    }

    func testFilesThatAreNotSvgFailWithAMessage() async throws {
        let fake = try write("fake.svg", "just text, no drawing")
        do {
            try await GraphicsTestKit.convert(vector, fake, to: "svgz")
            XCTFail("not an SVG")
        } catch {
            XCTAssertTrue("\(error)".contains("not an SVG"), "\(error)")
        }
    }

    func testStyledTextIsLaidOutRunByRun() async throws {
        // Per-tspan styles and the CSS font shorthand, which AppKit's renderer ignores on its own.
        let svg = try write("styled.svg", """
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="60">
              <style>.title { font: bold 20px Helvetica; fill: #00f }</style>
              <text x="10" y="25" font-family="Helvetica" font-size="20">A<tspan fill="#f00" font-weight="bold">B</tspan></text>
              <text class="title" x="10" y="55">C</text>
            </svg>
            """)
        var preset = Preset()
        preset.pdf.renderDpi = 96
        preset.image.resize = .longEdge
        preset.image.longEdge = 200
        let png = try await GraphicsTestKit.convert(vector, svg, to: "png", preset: preset)
        let image = try GraphicsTestKit.decode(png[0]).frames[0]
        var red = 0, blue = 0
        for y in 0..<60 {
            for x in 0..<200 {
                let p = GraphicsTestKit.pixel(image, x, y)
                if p.a > 200 && p.r > 200 && p.b < 60 { red += 1 }
                if p.a > 200 && p.b > 200 && p.r < 60 { blue += 1 }
            }
        }
        XCTAssertGreaterThan(red, 20, "the tspan keeps its own fill")
        XCTAssertGreaterThan(blue, 20, "the class rule (font shorthand) applies")
    }

    func testNetworkReferencesAreDropped() throws {
        let data = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">
              <image xlink:href="https://example.com/pixel.png" width="10" height="10"/>
            </svg>
            """.utf8)
        let normalized = String(decoding: SvgNormalizer.normalize(data, baseDirectory: dir), as: UTF8.self)
        XCTAssertFalse(normalized.contains("example.com"), normalized)
    }

    // ───────────────────────── Illustrator ─────────────────────────

    func testPdfCompatibleIllustratorFilesConvertThroughPdf() async throws {
        let svg = try write("art.svg", GraphicsBuilders.svg)
        let pdf = try await GraphicsTestKit.convert(vector, svg, to: "pdf")[0]
        let ai = FilePath.combine(dir, "artwork.ai")
        try FileManager.default.copyItem(atPath: pdf, toPath: ai)

        let toPdf = try await GraphicsTestKit.convert(vector, ai, to: "pdf")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: ai)), try Data(contentsOf: URL(fileURLWithPath: toPdf[0])))
        // AI → PNG is planned as AI → PDF → PNG.
        var preset = Preset()
        preset.pdf.renderDpi = 96
        let png = try await GraphicsTestKit.convert(PdfiumConverter(), toPdf[0], to: "png", preset: preset)
        let image = try GraphicsTestKit.decode(png[0])
        XCTAssertEqual([image.width, image.height], [400, 200])
    }

    func testPostScriptIllustratorFilesNeedGhostscript() async throws {
        EngineEnvironment.ownCopies = ["ghostscript": FilePath.combine(dir, "nowhere")]
        let ai = try write("old.ai", GraphicsBuilders.eps)
        let garbage = try write("garbage.ai", "not an illustrator file")
        if GhostscriptConverter.locate() == nil {
            do {
                try await GraphicsTestKit.convert(vector, ai, to: "pdf")
                XCTFail("PostScript needs Ghostscript")
            } catch {
                XCTAssertTrue("\(error)".contains("Ghostscript"), "\(error)")
            }
        }
        do {
            try await GraphicsTestKit.convert(vector, garbage, to: "pdf")
            XCTFail("not an AI file")
        } catch {
            XCTAssertTrue("\(error)".contains("not an Adobe Illustrator"), "\(error)")
        }
    }

    func testIllustratorHeadersAreRecognised() throws {
        let pdf = FilePath.combine(dir, "a.ai")
        try Data("%PDF-1.6\n".utf8).write(to: URL(fileURLWithPath: pdf))
        let ps = try write("b.ai", "%!PS-Adobe-3.0\n")
        let dos = FilePath.combine(dir, "c.ai")
        try Data([0xC5, 0xD0, 0xD3, 0xC6, 0, 0, 0, 0]).write(to: URL(fileURLWithPath: dos))
        XCTAssertEqual(try VectorConverter.illustratorKind(pdf), .pdf)
        XCTAssertEqual(try VectorConverter.illustratorKind(ps), .postScript)
        XCTAssertEqual(try VectorConverter.illustratorKind(dos), .postScript)
    }

    func testSvgzDetectionUsesTheGzipSignature() throws {
        XCTAssertTrue(SvgRenderer.isGzip(try Deflate.deflate(Data("<svg/>".utf8), windowBits: 31)))
        XCTAssertFalse(SvgRenderer.isGzip(Data("<svg/>".utf8)))
    }

    // ───────────────────────── Ghostscript ─────────────────────────

    /// A stand-in `gs` that records its arguments and writes the files Ghostscript would.
    private func fakeGhostscript() throws -> String {
        let folder = FilePath.combine(dir, "gs-bin")
        try FileManager.default.createDirectoryIfNeeded(folder)
        let script = FilePath.combine(folder, "gs")
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(folder)/args.txt"
            env | grep '^GS_' >> "\(folder)/args.txt"
            for a in "$@"; do case "$a" in -sOutputFile=*) out="${a#-sOutputFile=}";; esac; done
            case "$out" in
              *%d*) for n in 1 2; do f=$(printf "$out" $n); printf '%%!PS-Adobe-3.0 EPSF-3.0\\n' > "$f"; done;;
              *) printf '%%PDF-1.4 fake\\n' > "$out";;
            esac
            exit 0
            """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        EngineEnvironment.ownCopies = ["ghostscript": script]
        return folder
    }

    func testGhostscriptGetsFileesArgumentsAndOutputs() async throws {
        let folder = try fakeGhostscript()
        let gs = GhostscriptConverter()
        XCTAssertTrue(gs.status().isAvailable)
        let eps = try write("그림 1.eps", GraphicsBuilders.eps)

        let pdf = try await GraphicsTestKit.convert(gs, eps, to: "pdf")
        XCTAssertEqual(pdf.map(FilePath.fileName), ["그림 1.pdf"])
        let args = try String(contentsOfFile: FilePath.combine(folder, "args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(6)), ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=pdfwrite", "-dAutoRotatePages=/None"])
        XCTAssertTrue(args.contains("-dEPSCrop"))
        XCTAssertTrue(args.contains("-f") && args.contains(eps))
        XCTAssertTrue(args.contains { $0.hasPrefix("-sOutputFile=") && $0.hasSuffix("/out.pdf") && !$0.contains("그림") }, "ASCII scratch path")
        XCTAssertTrue(args.contains("GS_LIB=") && args.contains("GS_OPTIONS=") && args.contains("GS_FONTPATH="))

        // PDF → EPS: one file per page, numbered after the pages.
        let source = try await GraphicsTestKit.convert(PdfSharpConverter(), GraphicsTestKit.makeMultiPageTiff(dir, 3), to: "pdf")[0]
        var range = Preset()
        range.pdf.pageRange = "2-3"
        let pages = try await GraphicsTestKit.convert(gs, source, to: "eps", preset: range)
        XCTAssertEqual(pages.map(FilePath.fileName), ["pages_p2.eps", "pages_p3.eps"])
        let epsArgs = try String(contentsOfFile: FilePath.combine(folder, "args.txt"), encoding: .utf8)
        XCTAssertTrue(epsArgs.contains("-sDEVICE=eps2write\n-sPageList=2,3\n"), epsArgs)
    }

    func testEpsConvertsToPdfCroppedAndToPng() async throws {
        let gs = GhostscriptConverter()
        guard gs.status().isAvailable else { throw XCTSkip("Ghostscript is not installed.") }
        let folder = FilePath.combine(dir, "한글 폴더")
        try FileManager.default.createDirectoryIfNeeded(folder)
        let eps = FilePath.combine(folder, "그림 1.eps")
        try Data(GraphicsBuilders.eps.utf8).write(to: URL(fileURLWithPath: eps))

        let pdf = try await GraphicsTestKit.convert(gs, eps, to: "pdf")
        var preset = Preset()
        preset.pdf.renderDpi = 144
        let png = try await GraphicsTestKit.convert(gs, eps, to: "png", preset: preset)
        let box = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf[0]))?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 200, accuracy: 1)
        XCTAssertEqual(box.height, 100, accuracy: 1)
        let image = try GraphicsTestKit.decode(png[0])
        XCTAssertEqual([image.width, image.height], [400, 200])
        let triangle = GraphicsTestKit.pixel(image.frames[0], 360, 170)
        XCTAssertTrue(triangle.b > 150 && triangle.r < 100, "\(triangle)")
        XCTAssertEqual(GraphicsTestKit.pixel(image.frames[0], 2, 2).a, 0) // transparent where the drawing leaves the page empty
    }

    /// Filee's OwnCopyTests / PortableEngineTests for Ghostscript: version output, the bin/gs layout of a copy, and the
    /// user's own copy found before one on the Mac.
    func testGhostscriptCopiesAreFoundAndVersioned() throws {
        XCTAssertTrue(CopyVersions.parseVersion("ghostscript", "10.04.0\r\n").map { $0 == (10, 4) } ?? false)
        let root = FilePath.combine(dir, "gs-copy")
        let bin = FilePath.combine(root, "bin")
        try FileManager.default.createDirectoryIfNeeded(bin)
        try Data("binary".utf8).write(to: URL(fileURLWithPath: FilePath.combine(bin, "gs")))
        XCTAssertEqual(EngineEnvironment.folderWithPrograms("ghostscript", root), bin)
        XCTAssertEqual(EngineEnvironment.folderWithPrograms("ghostscript", FilePath.combine(bin, "gs")), bin)
        EngineEnvironment.ownCopies = ["ghostscript": root]
        XCTAssertEqual(GhostscriptConverter.locate(), FilePath.combine(bin, "gs"))
    }

    // ───────────────────────── Routes ─────────────────────────

    func testGraphicsRoutesUseTheExpectedEngines() {
        let catalog = ConverterCatalog(EngineRegistry.createAll(EngineEnvironment(dataDirectory: FilePath.combine(dir, "data"))))
        catalog.priority = AppSettings().enginePriority
        let planner = catalog.createPlanner(["ghostscript"])
        let expected: [(String, String, String)] = [
            ("svg", "png", "vector"), ("svg", "pdf", "vector"), ("ai", "png", "vector,pdfium"),
            ("eps", "png", "ghostscript"), // straight to PNG: keeps transparency (Filee #39)
            ("svg", "eps", "vector,ghostscript"), ("raw", "jpg", "magick"), ("xcf", "psd", "magick"), ("png", "icns", "icns"),
            ("icns", "webp", "icns"), ("pdf", "icns", "pdfium,icns"), ("psd", "pdf", "pdfsharp"),
        ]
        for (from, to, engines) in expected {
            XCTAssertEqual(planner.plan(from, to)?.steps.map(\.converter.id).joined(separator: ","), engines, "\(from) → \(to)")
        }
    }

    func testGraphicsEnginesOfferFileesDirectEdges() {
        func has(_ converter: Converter, _ from: String, _ to: String) -> Bool { converter.edges.contains { $0.from == from && $0.to == to } }
        XCTAssertTrue(has(vector, "svg", "png") && has(vector, "svg", "pdf") && has(vector, "ai", "pdf") && has(vector, "svgz", "webp"))
        XCTAssertTrue(has(GhostscriptConverter(), "eps", "png") && has(GhostscriptConverter(), "pdf", "eps"))
        XCTAssertTrue(has(MagickImageConverter(), "raw", "jpg") && has(MagickImageConverter(), "xcf", "psd"))
        XCTAssertTrue(has(IcnsConverter(), "png", "icns") && has(IcnsConverter(), "icns", "webp"))
        XCTAssertTrue(has(PdfiumConverter(), "pdf", "png") && has(PdfSharpConverter(), "psd", "pdf"))
        XCTAssertEqual(vector.edges.count, 4 + 2 * ImageEncoder.writable.count + 1)
    }
}

/// Content streams, image sizes and font count of a PDF page, its form XObjects included.
enum PdfContent {
    static func collect(_ page: CGPDFPage, _ content: inout String, _ images: inout [(Int, Int)], _ fonts: inout Int) {
        guard let dictionary = page.dictionary else { return }
        var stream: CGPDFStreamRef?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream {
            content += text(stream)
        } else if CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array {
            for i in 0..<CGPDFArrayGetCount(array) {
                var part: CGPDFStreamRef?
                if CGPDFArrayGetStream(array, i, &part), let part { content += text(part) }
            }
        }
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources { collect(resources, &content, &images, &fonts, 0) }
    }

    private static func text(_ stream: CGPDFStreamRef) -> String {
        var format = CGPDFDataFormat.raw
        return (CGPDFStreamCopyData(stream, &format) as Data?).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func collect(_ resources: CGPDFDictionaryRef, _ content: inout String, _ images: inout [(Int, Int)], _ fonts: inout Int, _ depth: Int) {
        guard depth <= 5 else { return }
        var fontDictionary: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fontDictionary), let fontDictionary { fonts += CGPDFDictionaryGetCount(fontDictionary) }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        final class Found { var streams: [CGPDFStreamRef] = [] }
        let found = Found()
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { found.streams.append(stream) }
            return true
        }, nil)
        for stream in found.streams {
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { continue }
            if String(cString: subtype) == "Image" {
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                images.append((width, height))
            } else {
                content += text(stream)
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner { collect(inner, &content, &images, &fonts, depth + 1) }
            }
        }
    }
}

extension VectorTests {
    func testTextInsideAClipPathBecomesClipShapes() throws {
        let data = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="40">
              <clipPath id="c"><text x="5" y="30" font-size="30" transform="translate(1 0)">Hi</text></clipPath>
              <rect width="100" height="40" fill="red" clip-path="url(#c)"/>
            </svg>
            """.utf8)
        let root = try XDocument.load(data: SvgNormalizer.normalize(data, baseDirectory: dir)).root
        let clip = try XCTUnwrap(root.descendants().first { $0.name.localName == "clipPath" })
        XCTAssertEqual(clip.elements().map(\.name.localName), ["path"])
        XCTAssertEqual(clip.elements().first?.attributeValue("transform"), "translate(1 0)")
    }
}

extension VectorTests {
    func testPdfConvertsToEpsPerPageAndToPostScript() async throws {
        let gs = GhostscriptConverter()
        guard gs.status().isAvailable else { throw XCTSkip("Ghostscript is not installed.") }
        let pdf = try await GraphicsTestKit.convert(PdfSharpConverter(), GraphicsTestKit.makeMultiPageTiff(dir, 3), to: "pdf")[0]
        var range = Preset()
        range.pdf.pageRange = "2-3"
        let eps = try await GraphicsTestKit.convert(gs, pdf, to: "eps", preset: range)
        let ps = try await GraphicsTestKit.convert(gs, pdf, to: "ps")
        XCTAssertEqual(eps.map(FilePath.fileName).sorted(), ["pages_p2.eps", "pages_p3.eps"])
        for file in eps { XCTAssertTrue(try String(contentsOfFile: file, encoding: .isoLatin1).hasPrefix("%!PS-Adobe-3.0 EPSF-3.0")) }
        let postScript = try String(contentsOfFile: ps[0], encoding: .isoLatin1)
        XCTAssertTrue(postScript.hasPrefix("%!PS-Adobe-3.0"))
        XCTAssertEqual(postScript.components(separatedBy: "%%Page:").count - 1, 3)
    }

    func testSvgConvertsToEpsThroughPdf() async throws {
        let gs = GhostscriptConverter()
        guard gs.status().isAvailable else { throw XCTSkip("Ghostscript is not installed.") }
        let pdf = try await GraphicsTestKit.convert(vector, try write("logo.svg", GraphicsBuilders.svg), to: "pdf")[0]
        let eps = try String(contentsOfFile: try await GraphicsTestKit.convert(gs, pdf, to: "eps")[0], encoding: .isoLatin1)
        XCTAssertTrue(eps.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"))
        // eps2write crops to the drawn content, which lies inside the 300 × 150 pt page.
        let box = try XCTUnwrap(eps.range(of: #"%%BoundingBox: (\d+) (\d+) (\d+) (\d+)"#, options: .regularExpression)).lowerBound
        let numbers = eps[box...].split(separator: "\n")[0].split(separator: " ").dropFirst().compactMap { Int($0) }
        XCTAssertTrue((0...30).contains(numbers[0]) && (0...40).contains(numbers[1]) && (250...300).contains(numbers[2]) && (120...150).contains(numbers[3]), "\(numbers)")
    }
}

extension VectorTests {
    func testSvg2HrefWinsBeforeReferenceSanitization() throws {
        let xlink = XNamespace("http://www.w3.org/1999/xlink")
        for href in ["#new", "", "https://example.invalid/image.png", "data:image/png;base64,AA=="] {
            let source = Data("""
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:legacy="http://www.w3.org/1999/xlink" width="20" height="20">
                  <image href="\(href)" legacy:href="#old" width="20" height="20"/>
                </svg>
                """.utf8)
            let normalized = SvgNormalizer.normalize(source, baseDirectory: dir)
            let root = try XDocument.load(data: normalized).root
            let image = try XCTUnwrap(root.elements().first)
            XCTAssertNil(image.attributeValue("href"))
            let expected = href.isEmpty || href.hasPrefix("https:") ? nil : href
            XCTAssertEqual(image.attributeValue(xlink + "href"), expected)
            XCTAssertFalse(String(decoding: normalized, as: UTF8.self).contains("#old"))
            if expected != nil {
                XCTAssertTrue(String(decoding: normalized, as: UTF8.self).contains("xlink:href="))
            }
            let repeated = try XDocument.load(data: SvgNormalizer.normalize(normalized, baseDirectory: dir)).root
            XCTAssertEqual(repeated.elements().first?.attributeValue(xlink + "href"), expected)
            XCTAssertNil(repeated.elements().first?.attributeValue("href"))
        }
    }

    func testSvg2FragmentReferencesAndXlinkAliasesRenderLikeLegacyReferences() async throws {
        let bodies = [
            "<defs><path id='s' d='M0 0L30 0L15 25Z'/></defs><use REF='#s' x='10' y='5' fill='red'/>",
            "<defs><linearGradient id='p'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient><linearGradient id='q' REF='#p'/></defs><rect width='60' height='40' fill='url(#q)'/>",
            "<defs><pattern id='p' width='10' height='10' patternUnits='userSpaceOnUse'><circle cx='5' cy='5' r='3' fill='red'/></pattern><pattern id='q' REF='#p'/></defs><rect width='60' height='40' fill='url(#q)'/>",
            "<defs><path id='p' d='M0 30L60 30'/></defs><text font-family='Helvetica' font-size='12'><textPath REF='#p'>Curve</textPath></text>",
        ]
        for (index, body) in bodies.enumerated() {
            var reference: [UInt8]?
            for spelling in ["xlink:href", "href", "legacy:href"] {
                let source = try write("ref-\(index)-\(spelling.replacingOccurrences(of: ":", with: "-")).svg", """
                    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:legacy="http://www.w3.org/1999/xlink" width="60" height="40">
                    \(body.replacingOccurrences(of: "REF", with: spelling))
                    </svg>
                    """)
                let output = try await GraphicsTestKit.convert(vector, source, to: "png")[0]
                let bitmap = ImagePixels.bitmap(try GraphicsTestKit.decode(output).frames[0])
                XCTAssertTrue(stride(from: 3, to: bitmap.pixels.count, by: 4).contains { bitmap.pixels[$0] > 0 })
                if let reference { XCTAssertEqual(bitmap.pixels, reference, "fixture \(index), \(spelling)") }
                else { reference = bitmap.pixels }
            }
        }
    }

    func testSvg2LocalImagesAreEmbeddedAndBlockedHrefDoesNotRestoreLegacyImage() async throws {
        _ = try GraphicsTestKit.makeImage(dir, "local image.png", width: 20, height: 20)
        let xlink = XNamespace("http://www.w3.org/1999/xlink")
        for href in ["local%20image.png", "data:image/png;base64,AA==", "https://example.invalid/image.png"] {
            let source = Data("""
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="20" height="20">
                  <image href="\(href)" xlink:href="local%20image.png" width="20" height="20"/>
                </svg>
                """.utf8)
            let root = try XDocument.load(data: SvgNormalizer.normalize(source, baseDirectory: dir)).root
            let image = try XCTUnwrap(root.elements().first)
            if href.hasPrefix("https:") { XCTAssertNil(image.attributeValue(xlink + "href")) }
            else { XCTAssertTrue(image.attributeValue(xlink + "href")?.hasPrefix("data:image/png;base64,") == true) }
        }
    }
}

extension VectorTests {
    func testXlinkCanonicalizationPreservesForeignNamespaces() throws {
        let source = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="urn:other" xmlns:ref="http://www.w3.org/1999/xlink" xmlns:f="urn:foreign" width="20" height="20">
              <g xlink:custom="keep"/>
              <use ref:href="#shape"/>
              <f:item href="#foreign"/>
            </svg>
            """.utf8)
        let root = try XDocument.load(data: SvgNormalizer.normalize(source, baseDirectory: dir)).root
        XCTAssertEqual(root.elements()[0].attributeValue(XNamespace("urn:other") + "custom"), "keep")
        XCTAssertEqual(root.elements()[1].attributeValue(XNamespace("http://www.w3.org/1999/xlink") + "href"), "#shape")
        XCTAssertEqual(root.elements()[2].attributeValue("href"), "#foreign")
        XCTAssertNil(root.elements()[2].attributeValue(XNamespace("http://www.w3.org/1999/xlink") + "href"))
    }
}

extension VectorTests {
    func testNativeSvgCapabilityUsesTheWholeDomAndConservativeAttributes() throws {
        func data(_ body: String, attributes: String = "") -> Data {
            Data("<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40' \(attributes)>\(body)</svg>".utf8)
        }
        XCTAssertTrue(NativeSvgRasterizer.supports(data("<g fill='#fff'><rect width='40' height='40'/><path id='writing-mode' fill='none' stroke='black' stroke-width='.5' stroke-linecap='round' d='M0 0L40 40'/></g>")))
        for body in [
            "<g><text writing-mode='tb'>Vertical</text></g>",
            "<style>.v { writing-mode:tb }</style><text class='v'>Vertical</text>",
            "<g style='writing-mode:tb'><text>Vertical</text></g>",
            "<use href='#symbol'/>", "<defs><symbol id='symbol'/></defs>",
            "<image href='data:image/svg+xml;base64,PHN2Zy8+'/>",
            "<svg width='10' height='10'><rect width='10' height='10'/></svg>",
            "<rect width='10' height='10' transform='rotate(30)'/>",
            "<rect width='10' height='10' fill='url(#g)'/>",
            "<path d='M0 0L10 10' filter='url(#blur)'/>",
            "<rect width='10' height='10' fill='transparent'/>",
            "<rect width='10' height='10' fill='RED'/>",
            "<rect width='10' height='10' stroke-miterlimit='.5'/>",
            "<foreignObject/>", "<f:path xmlns:f='urn:foreign' d='M0 0L10 10'/>",
        ] { XCTAssertFalse(NativeSvgRasterizer.supports(data(body)), body) }
        for attributes in ["viewBox='0 0 40 40 garbage'", "viewBox='0 0 nan 40'", "height='1e30'"] {
            XCTAssertFalse(NativeSvgRasterizer.supports(data("<path d='M0 0L10 10'/>", attributes: attributes)))
        }
    }

    func testPrefixedSvgWithDifferentDefaultNamespaceKeepsCoreSvg() throws {
        for source in [
            "<svg xmlns='http://www.w3.org/2000/svg' xmlns:s='http://www.w3.org/2000/svg' width='20' height='20'><s:rect xmlns='urn:other' width='20' height='20' fill='red'/></svg>",
            "<s:svg xmlns:s='http://www.w3.org/2000/svg' width='20' height='20'><s:rect width='20' height='20' fill='red'/></s:svg>",
        ] {
            XCTAssertFalse(NativeSvgRasterizer.supports(Data(source.utf8)))
            let path = try write("prefixed.svg", source)
            let drawing = try SvgRenderer.load(path)
            XCTAssertNil(drawing.nativeData)
            let image = try SvgRenderer.rasterize(drawing, scale: 1).image
            let pixel = GraphicsTestKit.pixel(image, 10, 10)
            XCTAssertEqual(pixel.r, 255)
            XCTAssertEqual(pixel.g, 0)
            XCTAssertEqual(pixel.b, 0)
            XCTAssertEqual(pixel.a, 255)
        }
    }

    func testNativeSvgBridgeWritesRgbaAndRejectsInvalidInput() throws {
        let source = Data("<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2' fill='red'/></svg>".utf8)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        XCTAssertFalse(try NativeSvgRasterizer.render(Data("not XML".utf8), bounds: CGRect(x: 0, y: 0, width: 2, height: 2), scale: 1, into: context))
        XCTAssertFalse(try NativeSvgRasterizer.render(source, bounds: CGRect(x: 0, y: 0, width: 2, height: 2), scale: .nan, into: context))
        XCTAssertTrue(try NativeSvgRasterizer.render(source, bounds: CGRect(x: 0, y: 0, width: 2, height: 2), scale: 1, into: context))
        let bitmap = ImagePixels.bitmap(try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(bitmap.pixels, Array(repeating: [UInt8(255), 0, 0, 255], count: 4).flatMap { $0 })
    }

    func testNativePrimitiveRasterKeepsImageLifetimeAndPdfVectors() throws {
        let source = try write("native.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect fill='red' width='40' height='20'/><path stroke='blue' d='M0 0L40 20'/></svg>")
        let drawing = try SvgRenderer.load(source)
        XCTAssertNotNil(drawing.nativeData)
        let frame = try autoreleasepool { try SvgRenderer.rasterize(drawing, scale: 1) }
        XCTAssertEqual(GraphicsTestKit.pixel(frame.image, 30, 5).r, 255)
        XCTAssertEqual(frame.dpi?.0, 96)
        let pdf = FilePath.combine(dir, "native.pdf")
        try SvgRenderer.writePdf(drawing, pdf, title: "native", pdfA: false)
        let page = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf))?.page(at: 0)?.pageRef)
        var content = "", images: [(Int, Int)] = [], fonts = 0
        PdfContent.collect(page, &content, &images, &fonts)
        XCTAssertTrue(images.isEmpty)
        XCTAssertNotNil(content.range(of: #"\s(c|l|re)\s"#, options: .regularExpression))
        // A native parser failure preserves the existing CoreSVG drawing.
        let fallback = SvgRenderer.Drawing(image: drawing.image, nativeData: Data("bad XML".utf8), bounds: drawing.bounds)
        XCTAssertEqual(GraphicsTestKit.pixel(try SvgRenderer.rasterize(fallback, scale: 1).image, 30, 5).r, 255)
    }

    func testCancelledNativeSvgDoesNotWriteAnOutput() async throws {
        let source = try write("cancel.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect fill='red' width='40' height='20'/></svg>")
        let task = Task { try await GraphicsTestKit.convert(vector, source, to: "png") }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled native render succeeded") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: FilePath.combine(dir, "cancel.png")))
    }
}

extension VectorTests {
    func testNativeSvgzKeepsViewportResizeAndDpi() throws {
        let source = Data("<svg xmlns='http://www.w3.org/2000/svg' width='100' height='50'><rect fill='white' width='100' height='50'/><path d='M0 0L100 50' fill='none' stroke='black' stroke-width='.7'/></svg>".utf8)
        let path = FilePath.combine(dir, "native.svgz")
        try Deflate.deflate(source, windowBits: 31).write(to: URL(fileURLWithPath: path))
        let drawing = try SvgRenderer.load(path)
        XCTAssertNotNil(drawing.nativeData)
        XCTAssertEqual(drawing.bounds.size, CGSize(width: 100, height: 50))
        var preset = Preset()
        preset.image.resize = .longEdge
        preset.image.longEdge = 300
        let scale = SvgRenderer.rasterScale(drawing.bounds, preset.image, preset.pdf)
        XCTAssertEqual(scale, 3)
        let frame = try SvgRenderer.rasterize(drawing, scale: scale)
        XCTAssertEqual([frame.image.width, frame.image.height], [300, 150])
        XCTAssertEqual(frame.dpi?.0, 288)
        preset.image.resize = .percent
        preset.image.resizePercent = 50
        XCTAssertEqual(SvgRenderer.rasterScale(drawing.bounds, preset.image, preset.pdf), 5.12, accuracy: 0.00001)
        XCTAssertFalse(NativeSvgRasterizer.supports(Data(repeating: 0, count: 8 * 1024 * 1024 + 1)))
    }
}

extension VectorTests {
    func testNativeSvgRendersConcurrentlyWithIndependentBuffers() async throws {
        let path = try write("parallel.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect fill='red' width='40' height='20'/></svg>")
        let drawing = try SvgRenderer.load(path)
        XCTAssertNotNil(drawing.nativeData)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for scale in 1...8 {
                group.addTask {
                    let image = try SvgRenderer.rasterize(drawing, scale: Float(scale)).image
                    let pixel = GraphicsTestKit.pixel(image, image.width / 2, image.height / 2)
                    return image.width == 40 * scale && image.height == 20 * scale && pixel.r == 255 && pixel.a == 255
                }
            }
            for try await valid in group { XCTAssertTrue(valid) }
        }
    }
}

extension VectorTests {
    private func verticalSource(_ body: String) -> Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='120' height='180' font-family='Helvetica' font-size='16'>\(body)</svg>".utf8)
    }

    private func verticalPaths(_ body: String) throws -> [String] {
        let root = try XDocument.load(data: SvgNormalizer.normalize(verticalSource(body), baseDirectory: dir)).root
        return root.descendants().filter { $0.name.localName == "path" }.compactMap { $0.attributeValue("d") }
    }

    private func verticalImage(_ body: String) throws -> CGImage {
        let input = FilePath.combine(dir, "vertical.svg")
        try verticalSource(body).write(to: URL(fileURLWithPath: input))
        return try SvgRenderer.rasterize(SvgRenderer.load(input), scale: 4).image
    }

    private func verticalInkBounds(_ image: CGImage, channel: Int? = nil) -> CGRect {
        let bitmap = ImagePixels.bitmap(image)
        var bounds = CGRect.null
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let i = (y * bitmap.width + x) * 4
                guard bitmap.pixels[i + 3] > 160 else { continue }
                if let channel, !(0..<3).allSatisfy({ $0 == channel || Int(bitmap.pixels[i + channel]) > Int(bitmap.pixels[i + $0]) + 50 }) { continue }
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        XCTAssertFalse(bounds.isNull)
        return bounds
    }

    func testVerticalTextRotatesLatinAndKeepsCjkUpright() throws {
        let image = try verticalImage("<text x='60' y='15' writing-mode='vertical-rl'><tspan fill='red'>F</tspan><tspan fill='blue'>한</tspan><tspan fill='lime'>글</tspan></text>")
        let latin = verticalInkBounds(image, channel: 0)
        let first = verticalInkBounds(image, channel: 2), second = verticalInkBounds(image, channel: 1)
        XCTAssertGreaterThan(latin.width, latin.height, "Latin glyphs rotate clockwise in mixed vertical text")
        XCTAssertGreaterThan(first.minY, latin.maxY)
        XCTAssertGreaterThan(second.minY, first.maxY)
        XCTAssertEqual(first.midX, second.midX, accuracy: 4)
        XCTAssertEqual(first.midX, 240, accuracy: 8)
        let upright = try verticalImage("<text x='60' y='15' writing-mode='vertical-rl' text-orientation='upright'>F</text>")
        let bounds = verticalInkBounds(upright)
        XCTAssertGreaterThan(bounds.height, bounds.width)
    }

    func testVerticalTextPositionsAndAnchorsUseTheInlineAxis() throws {
        let positioned = try verticalPaths("<text x='40' y='30' writing-mode='tb'>A<tspan x='80' y='70' dx='3' dy='5'>B</tspan></text>")
        let separate = try verticalPaths("<text x='40' y='30' writing-mode='tb'>A</text><text x='83' y='75' writing-mode='tb'>B</text>")
        XCTAssertEqual(positioned.count, 2)
        XCTAssertEqual(positioned, separate)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "AB", attributes: [.init(kCTFontAttributeName as String): font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        for (anchor, shift) in [("middle", width / 2), ("end", width)] {
            XCTAssertEqual(try verticalPaths("<text x='60' y='100' writing-mode='tb' text-anchor='\(anchor)'>AB</text>"),
                           try verticalPaths("<text x='60' y='\(100 - shift)' writing-mode='tb'>AB</text>"))
        }
        XCTAssertEqual(try verticalPaths("<text x='60' y='100' writing-mode='vertical-lr' direction='rtl'>AB</text>"),
                       try verticalPaths("<text x='60' y='\(100 - width)' writing-mode='tb'>AB</text>"))
    }

    func testVerticalAliasesInheritanceAndOrientationKeepTheirGeometry() throws {
        let reference = try verticalPaths("<text x='60' y='15' writing-mode='tb'>e&#x301; 한글</text>")
        XCTAssertFalse(reference.isEmpty)
        for mode in ["tb-rl", "vertical-rl", "vertical-lr"] {
            XCTAssertEqual(reference, try verticalPaths("<g style='writing-mode:\(mode)'><text x='60' y='15'>e&#x301; 한글</text></g>"))
        }
        for (legacy, modern) in [("0", "upright"), ("90", "sideways")] {
            XCTAssertEqual(try verticalPaths("<text x='60' y='15' writing-mode='tb' glyph-orientation-vertical='\(legacy)'>AB한</text>"),
                           try verticalPaths("<text x='60' y='15' writing-mode='tb' style='text-orientation:\(modern)'>AB한</text>"))
        }
        let horizontal = "<text x='10' y='30'>A<tspan font-weight='bold'>B</tspan>C</text>"
        XCTAssertEqual(try verticalPaths(horizontal), try verticalPaths(horizontal.replacingOccurrences(of: "<tspan", with: "<tspan writing-mode='vertical-rl'")),
                       "The new vertical path does not change existing horizontal-root layout")
    }

    func testVerticalColorGlyphsRemainPositionedAndTextPdfStaysVector() throws {
        let normalized = SvgNormalizer.normalize(verticalSource("<text x='60' y='15' writing-mode='tb'>😀😺</text>"), baseDirectory: dir)
        let text = try XDocument.load(data: normalized).root.descendants().filter { $0.name.localName == "text" }
        XCTAssertEqual(text.count, 2)
        XCTAssertTrue(text.allSatisfy { $0.attributeValue("writing-mode") == "horizontal-tb" })
        XCTAssertEqual(Set(text.compactMap { $0.attributeValue("transform") }).count, 2)
        let source = FilePath.combine(dir, "vertical-pdf.svg"), output = FilePath.combine(dir, "vertical.pdf")
        try verticalSource("<text x='60' y='15' writing-mode='tb'>Vertical 한글</text>").write(to: URL(fileURLWithPath: source))
        try SvgRenderer.writePdf(SvgRenderer.load(source), output, title: "vertical", pdfA: false)
        let page = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: output))?.page(at: 0)?.pageRef)
        var content = "", images: [(Int, Int)] = [], fonts = 0
        PdfContent.collect(page, &content, &images, &fonts)
        XCTAssertTrue(images.isEmpty)
        XCTAssertEqual(fonts, 0)
        XCTAssertNotNil(content.range(of: #"\s(c|l|re)\s"#, options: .regularExpression))
    }

    func testUprightVerticalCursiveTextUsesIsolatedGraphemes() throws {
        let letters = "سلام"
        let source = "<text x='60' y='15' writing-mode='tb' text-orientation='upright'>\(letters)</text>"
        let paths = try verticalPaths(source)
        XCTAssertEqual(paths.count, letters.count, "Upright Arabic uses isolated forms instead of joining letters")
        XCTAssertEqual(paths, try verticalPaths(source.replacingOccurrences(of: "writing-mode='tb'", with: "writing-mode='tb' direction='rtl'")))
        let combined = try verticalPaths("<text x='60' y='15' writing-mode='tb' text-orientation='upright'>e&#x301;한</text>")
        XCTAssertEqual(combined.count, 2, "Combining marks stay with their base character")
    }

    func testRelativeFontWeightsUseComputedAncestorsAfterTheCascade() throws {
        // CSS Fonts 4 §2.2.1, including interval boundaries and weights outside 100...900.
        let weights = [(1, 400, 1), (99, 400, 99), (100, 400, 100), (349, 400, 100),
                       (350, 700, 100), (549, 700, 100), (550, 900, 400), (749, 900, 400),
                       (750, 900, 700), (899, 900, 700), (900, 900, 700), (1000, 1000, 700)]
        for (parent, bolder, lighter) in weights {
            for (relative, expected) in [("bolder", bolder), ("lighter", lighter), ("inherit", parent), ("initial", 400), ("unset", parent)] {
                for declaration in ["font-weight='\(relative)'", "style='font-weight:\(relative)'",
                                    "class='relative'"] {
                    let source = Data("""
                        <svg xmlns='http://www.w3.org/2000/svg' width='200' height='60'>
                          <style>.parent {font-weight:\(parent)} .relative {font-weight:\(relative)}</style>
                          <g class='parent'><g><g id='probe' \(declaration)/></g></g>
                        </svg>
                        """.utf8)
                    let root = try XDocument.load(data: SvgNormalizer.normalize(source, baseDirectory: dir)).root
                    let probe = try XCTUnwrap(root.descendants().first { $0.attributeValue("id") == "probe" })
                    XCTAssertEqual(probe.attributeValue("font-weight"), String(expected), "\(parent), \(declaration)")
                }
            }
        }
    }

    func testRelativeWeightsRespectTheCascadeAcrossRelativeAncestors() throws {
        let source = Data("""
            <svg xmlns='http://www.w3.org/2000/svg' width='200' height='60' font-weight='200'>
              <style>g {font-weight:bolder} #probe {font-weight:lighter !important}</style>
              <g><g><g id='probe' style='font-weight:bolder'/></g></g>
            </svg>
            """.utf8)
        let root = try XDocument.load(data: SvgNormalizer.normalize(source, baseDirectory: dir)).root
        XCTAssertEqual(root.descendants().map { $0.attributeValue("font-weight") }, ["400", "700", "400"])
    }

    func testRelativeWeightsKeepMixedAndVerticalTextSemantics() throws {
        let bodies = [
            "<text x='100' y='40' text-anchor='middle' font-weight='bolder'>A&#x301;<tspan font-weight='lighter'>bc</tspan>Def</text>",
            "<style>g {writing-mode:tb} text {font-weight:bolder}</style><text x='100' y='5'>A&#x301;<tspan font-weight='lighter'>bc</tspan></text>",
            "<text x='10' y='40' style='font:bolder 30px Helvetica'>A&#x301;<tspan style='font:italic lighter 30px Helvetica'>bc</tspan></text>",
        ]
        for body in bodies {
            func normalize(_ content: String) -> Data {
                SvgNormalizer.normalize(Data("<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><g font-weight='200'>\(content)</g></svg>".utf8), baseDirectory: dir)
            }
            let absolute = body.replacingOccurrences(of: "bolder", with: "400").replacingOccurrences(of: "lighter", with: "100")
            let relative = normalize(body)
            XCTAssertEqual(relative, normalize(absolute))
            let root = try XDocument.load(data: relative).root
            XCTAssertFalse(root.descendants().contains { $0.name.localName == "text" })
            XCTAssertTrue(root.descendants().contains { $0.name.localName == "path" })
        }
    }

    func testRelativeWeightTextKeepsVectorPdfOutput() throws {
        for (name, weight) in [("longhand", "font-size='40' font-family='Helvetica' font-weight='bolder'"),
                               ("shorthand", "style='font:bolder 40px Helvetica'")] {
            let source = try write("relative-weight-\(name).svg", """
                <svg xmlns='http://www.w3.org/2000/svg' width='200' height='80'>
                  <g font-weight='200'><text x='10' y='50' \(weight)>Abc</text></g>
                </svg>
                """)
            let drawing = try SvgRenderer.load(source)
            XCTAssertNil(drawing.nativeData)
            let pdf = FilePath.combine(dir, "relative-weight-\(name).pdf")
            try SvgRenderer.writePdf(drawing, pdf, title: "relative weight", pdfA: false)
            let page = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf))?.page(at: 0)?.pageRef)
            var content = "", images: [(Int, Int)] = [], fonts = 0
            PdfContent.collect(page, &content, &images, &fonts)
            XCTAssertTrue(images.isEmpty, name)
            XCTAssertEqual(fonts, 0, name)
            XCTAssertNotNil(content.range(of: #"\s(c|l|re)\s"#, options: .regularExpression), name)
        }
    }

    func testFontShorthandRelativeWeightsUseTheComputedParent() throws {
        // CSS Fonts 4 allows bolder and lighter in the shorthand; they compute like the longhand.
        for (parent, bolder, lighter) in [(200, 400, 100), (400, 700, 100), (700, 900, 400), (900, 900, 700)] {
            for (relative, expected) in [("bolder", bolder), ("lighter", lighter)] {
                for declaration in ["style='font:\(relative) 12px Helvetica'", "font='\(relative) 12px Helvetica'", "class='relative'"] {
                    let source = Data("""
                        <svg xmlns='http://www.w3.org/2000/svg' width='200' height='60'>
                          <style>.parent {font:\(parent) 12px Helvetica} .relative {font:italic \(relative) 12px Helvetica}</style>
                          <g class='parent'><g><g id='probe' \(declaration)/></g></g>
                        </svg>
                        """.utf8)
                    let root = try XDocument.load(data: SvgNormalizer.normalize(source, baseDirectory: dir)).root
                    let probe = try XCTUnwrap(root.descendants().first { $0.attributeValue("id") == "probe" })
                    XCTAssertEqual(probe.attributeValue("font-weight"), String(expected), "\(parent), \(declaration)")
                    XCTAssertEqual(probe.attributeValue("font-style"), declaration.hasPrefix("class") ? "italic" : "normal")
                }
            }
        }
    }
}
