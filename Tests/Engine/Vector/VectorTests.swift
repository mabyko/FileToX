// Port of the vector part of Filee.Engines.Tests/GraphicsTests.cs: SVG → PDF/PNG, SVGZ, Illustrator files and
// Ghostscript (EPS/PS, skipped when Ghostscript is not installed; a stand-in `gs` script checks the arguments).
// Filee's route tests need the route planner of the core; here the engines' direct edges are checked instead.

import CoreGraphics
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
