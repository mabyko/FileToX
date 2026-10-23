// Port of tests/Filee.Engines.Tests/CadTests.cs: DWG / DXF without AutoCAD — DXF ↔ DWG and the built-in renderer
// (PDF, SVG, PNG). Drawings come from CadBuilder; outputs are parsed back (DXF reader, SVG XML, CGPDFDocument,
// pixels). Conversions run the converter directly; tests that need the DWG reader / DXF and DWG writers or the image
// engine skip until those ports are merged.

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FileToXEngineKit

/// A folder for one test's files, removed afterwards.
final class CadTestFolder {
    let path = FilePath.combine(NSTemporaryDirectory(), "ftx-cad-" + UUID().uuidString)
    init() { try! FileManager.default.createDirectoryIfNeeded(path) }
    deinit { try? FileManager.default.removeItem(atPath: path) }
}

/// Hands out `<folder>/<name><suffix>.<ext>`, like the job queue with "next to the source" output.
final class CadTestOutput: OutputAllocator {
    private let folder: String
    private let name: String

    init(_ folder: String, _ name: String) {
        self.folder = folder
        self.name = name
    }

    func allocate(_ extension: String, suffix: String?) throws -> String? {
        FilePath.combine(folder, name + (suffix ?? "") + "." + `extension`)
    }
}

final class CadTests: XCTestCase {
    private var folders: [CadTestFolder] = []

    private func newFolder() -> String {
        let folder = CadTestFolder()
        folders.append(folder)
        return folder.path
    }

    override func tearDown() {
        folders.removeAll()
        super.tearDown()
    }

    /// Converts like the job queue does for one file and returns the single output. Conversions that reach a part
    /// still being ported (image engine, DWG I/O) skip the test.
    private func convert(_ input: String, _ target: String, _ preset: Preset? = nil) async throws -> String {
        var preset = preset ?? Preset()
        if preset.targetFormat != target { preset.targetFormat = target }
        let work = newFolder()
        let step = ConversionStep(inputPath: input, from: FilePath.extension(input).dropFirst().lowercased(), to: target, preset: preset,
                                  output: CadTestOutput(newFolder(), FilePath.fileNameWithoutExtension(input)), workDirectory: work)
        do {
            let outputs = try await CadConverter().convert(step, progress: nil)
            XCTAssertEqual(outputs.count, 1)
            return try XCTUnwrap(outputs.first)
        } catch let error where "\(error)".contains("not ported yet") {
            throw XCTSkip("needs a port that is not merged yet: \(error)")
        }
    }

    private func sampleDxf() throws -> String { try CadBuilder.sample().save(newFolder(), "도면.dxf") }

    // ───────────────────────── Routes ─────────────────────────

    func testCadFormatsAreConvertedByTheCadEngineInOneStep() {
        let converter = CadConverter()
        XCTAssertEqual(converter.id, "cad")
        for (from, to) in [("dwg", "png"), ("dwg", "pdf"), ("dwg", "svg"), ("dwg", "dxf"), ("dxf", "jpg"), ("dxf", "webp")] {
            XCTAssertTrue(converter.edges.contains { $0.from == from && $0.to == to }, "\(from) → \(to)")
        }
    }

    func testDxfToDwgIsConvertedByTheCadEngine() throws {
        let converter = CadConverter()
        guard converter.edges.contains(where: { $0.from == "dxf" && $0.to == "dwg" }) else {
            throw XCTSkip("needs the DWG writer port: the dxf → dwg edge comes back with it")
        }
        XCTAssertEqual(converter.edges.firstIndex { $0.from == "dxf" && $0.to == "dwg" }, 1)
    }

    // ───────────────────────── DXF ↔ DWG ─────────────────────────

    func testDxfToDwgAndBackKeepsEveryEntity() async throws {
        let source = try sampleDxf()
        let expected = CadBuilder.census(try CadFile.read(source, "dxf"))

        let dwg = try await convert(source, "dwg")
        XCTAssertEqual(Array(try Data(contentsOf: URL(fileURLWithPath: dwg)).prefix(6)), Array("AC1032".utf8))
        let fromDwg = try CadFile.read(dwg, "dwg")
        XCTAssertEqual(CadBuilder.census(fromDwg), expected)

        let dxf = try await convert(dwg, "dxf")
        let back = try CadFile.read(dxf, "dxf")
        XCTAssertEqual(back.header.version, .ac1032)
        XCTAssertEqual(CadBuilder.census(back), expected)

        // Content survives, not just the count: Korean text (UTF-8 in 2018 DXF), blocks, attributes, layer states.
        XCTAssertTrue(back.entities.contains { ($0 as? ACad.TextEntity)?.value == CadBuilder.koreanText })
        let bolt = try XCTUnwrap(back.entities.compactMap { $0 as? ACad.Insert }.first { !$0.attributes.isEmpty })
        XCTAssertEqual(bolt.block?.name, "BOLT")
        XCTAssertEqual(bolt.block?.entities.filter { $0 is ACad.Circle || $0 is ACad.Line }.count, 2)
        XCTAssertEqual(fromDwg.entities.compactMap { $0 as? ACad.Insert }.flatMap { $0.attributes.map { "\($0.tag)=\($0.value)" } }, ["ID=B1", "ID=B2"])
        XCTAssertEqual(bolt.attributes.map { "\($0.tag)=\($0.value)" }, ["ID=B1"])
        XCTAssertFalse(try XCTUnwrap(back.layers["Off"]).isOn)
        XCTAssertTrue(try XCTUnwrap(back.layers["Frozen"]).isFrozen)
    }

    func testBinaryDxfIsRead() async throws {
        let folder = newFolder()
        let binary = try CadBuilder.sample().save(folder, "binary.dxf", binary: true)
        let ascii = try CadBuilder.sample().save(folder, "ascii.dxf")
        XCTAssertTrue(ACad.DxfReader.isBinary(try Data(contentsOf: URL(fileURLWithPath: binary))))
        XCTAssertEqual(CadBuilder.census(try CadFile.read(binary, "dxf")), CadBuilder.census(try CadFile.read(ascii, "dxf")))

        let dwg = try await convert(binary, "dwg")
        XCTAssertEqual(CadBuilder.census(try CadFile.read(binary, "dxf")), CadBuilder.census(try CadFile.read(dwg, "dwg")))
    }

    func testKoreanTextInPre2007DxfIsDecoded() throws {
        // Before AutoCAD 2007, text is stored in the drawing's code page (CP949 for Korean). Korean AutoCAD names it
        // ANSI_949 in DXF, which ACadSharp does not know by that name.
        var builder = CadBuilder()
        builder.version = "AC1018"
        builder.codePage = "ANSI_949"
        builder.entities.append(CadBuilder.text("0", CadBuilder.koreanText, [0, 0], 2.5))
        let path = FilePath.combine(newFolder(), "old.dxf")
        try builder.dxf(encoding: try XCTUnwrap(TextEncodings.encoding(codePage: 949))).write(to: URL(fileURLWithPath: path))

        func text(_ document: ACad.Document) -> String? { document.entities.compactMap { $0 as? ACad.TextEntity }.first?.value }
        // The reader alone garbles it; when this starts to pass, CadFile's workaround can go.
        let plain = try ACad.DxfReader(data: try Data(contentsOf: URL(fileURLWithPath: path)), createDefaults: true).read()
        XCTAssertNotEqual(text(plain), CadBuilder.koreanText)
        XCTAssertEqual(text(try CadFile.read(path, "dxf")), CadBuilder.koreanText)
    }

    func testKoreanTextInPre2007DwgIsDecoded() throws {
        // Filee writes this drawing with ACadSharp's DwgWriter (AC1018, code page kcs5601); the Swift writer only writes
        // AC1032 like CadFile, so the DWG is a fixture made by the C# baseline.
        let dwg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/korean_AC1018.dwg").path
        XCTAssertEqual(try CadFile.read(dwg, "dwg").entities.compactMap { $0 as? ACad.TextEntity }.map(\.value), [CadBuilder.koreanText])
    }

    func testDamagedFilesFailWithAClearMessage() async throws {
        for (name, message) in [("broken.dwg", "not a DWG drawing"), ("broken.dxf", "not a valid DXF drawing")] {
            let path = FilePath.combine(newFolder(), name)
            try Data("This is not a drawing.\n0\nSECTION\n".utf8).write(to: URL(fileURLWithPath: path))
            var preset = Preset()
            preset.targetFormat = "pdf"
            let step = ConversionStep(inputPath: path, from: String(name.split(separator: ".")[1]), to: "pdf", preset: preset,
                                      output: CadTestOutput(newFolder(), "broken"), workDirectory: newFolder())
            do {
                _ = try await CadConverter().convert(step, progress: nil)
                XCTFail("\(name) was converted")
            } catch {
                XCTAssertTrue(CadFile.message(error).lowercased().contains(message.lowercased()), "\(name): \(error)")
            }
        }
    }

    // ───────────────────────── Rendering ─────────────────────────

    func testDxfToSvgHasPathsAndText() async throws {
        let svg = try XDocument.load(try await convert(try sampleDxf(), "svg"))
        let ns = XNamespace("http://www.w3.org/2000/svg")

        let root = svg.root
        XCTAssertEqual(root.name, ns + "svg")
        let width = try XCTUnwrap(Double(root.attributeValue("width") ?? ""))
        let height = try XCTUnwrap(Double(root.attributeValue("height") ?? ""))
        XCTAssertTrue((1500...1600).contains(width), "\(width)") // 420 mm at 96 dpi on the long edge
        XCTAssertTrue(height < width, "a wide drawing gives a landscape page")

        let paths = root.descendants(ns + "path")
        XCTAssertGreaterThanOrEqual(paths.count, 5)
        XCTAssertTrue(paths.contains { $0.attributeValue("stroke") == "blue" })
        let text = root.descendants(ns + "text").map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        XCTAssertTrue(text.contains("MTEXT"))
        XCTAssertTrue(text.contains("B1")) // the block attribute
        XCTAssertTrue(text.contains("1/2")) // stacked fraction
        XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains(CadBuilder.koreanText.replacingOccurrences(of: " ", with: "")))
        // Entities on the OFF and frozen layers are red: nothing red may appear.
        XCTAssertFalse(root.descendantsAndSelf().contains { $0.attributeValue("stroke") == "red" || $0.attributeValue("fill") == "red" })
    }

    func testDxfToPdfIsOneVectorPage() async throws {
        let pdf = try await convert(try sampleDxf(), "pdf")

        let document = try XCTUnwrap(CGPDFDocument(URL(fileURLWithPath: pdf) as CFURL))
        XCTAssertEqual(document.numberOfPages, 1)
        let page = try XCTUnwrap(document.page(at: 1))
        // A3 landscape: 420 × 297 mm.
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(Double(box.width), 420 / 25.4 * 72, accuracy: 0.5)
        XCTAssertEqual(Double(box.height), 297 / 25.4 * 72, accuracy: 0.5)

        let operators = CadPdfOperators.of(page)
        XCTAssertTrue(operators.contains("l")) // lines
        XCTAssertTrue(operators.contains("c")) // curves (circle, arc, bulge)
        XCTAssertTrue(operators.contains("f") || operators.contains("f*"), "the solid hatch is a filled path")
        XCTAssertTrue(operators.contains("Tj") || operators.contains("TJ"), "text is real text")
        XCTAssertFalse(operators.contains("BI")) // no inline raster images
    }

    func testDxfToPngDrawsTheVisibleLayersOnly() async throws {
        let png = try await convert(try sampleDxf(), "png")

        let image = try XCTUnwrap(CadPixels.load(png))
        XCTAssertEqual(max(image.width, image.height), 2480) // A3 long edge at 150 dpi
        let counts = CadPixels.count(image)
        XCTAssertGreaterThan(counts.ink, 5000)
        XCTAssertGreaterThan(counts.blue, 1000)
        XCTAssertEqual(counts.red, 0)
    }

    /// The pixels the PNG conversion encodes (renderer output at the default 150 dpi), checked without the image engine.
    func testRenderedBitmapDrawsTheVisibleLayersOnly() throws {
        let scene = try CadSceneBuilder.build(try CadFile.read(try sampleDxf(), "dxf"))
        let image = try CadRenderer.renderBitmap(scene, 150)
        XCTAssertEqual(max(image.width, image.height), 2480)
        let counts = CadPixels.count(image)
        XCTAssertGreaterThan(counts.ink, 5000)
        XCTAssertGreaterThan(counts.blue, 1000)
        XCTAssertEqual(counts.red, 0)
    }

    func testADrawingFarFromTheOriginStillFillsThePage() async throws {
        // The header claims the drawing spans (0,0)-(10,10); the page must be fitted to the real entities.
        let source = try CadBuilder.farFromOrigin().save(newFolder(), "far.dxf")
        var preset = Preset()
        preset.targetFormat = "png"
        preset.pdf.renderDpi = 50

        let png = try await convert(source, "png", preset)

        try assertFillsThePage(try XCTUnwrap(CadPixels.load(png)))
    }

    func testARenderedDrawingFarFromTheOriginStillFillsThePage() throws {
        let scene = try CadSceneBuilder.build(try CadFile.read(try CadBuilder.farFromOrigin().save(newFolder(), "far.dxf"), "dxf"))
        try assertFillsThePage(try CadRenderer.renderBitmap(scene, 50))
    }

    private func assertFillsThePage(_ image: CGImage) throws {
        let box = CadPixels.count(image).box
        XCTAssertGreaterThan(Double(box.width), Double(image.width) * 0.9, "drawing spans \(box.width) of \(image.width) px")
        XCTAssertGreaterThan(Double(box.height), Double(image.height) * 0.8, "drawing spans \(box.height) of \(image.height) px")
        XCTAssertTrue((1.8...2.2).contains(Double(image.width) / Double(image.height))) // the page has the drawing's 2:1 aspect
    }

    func testDxfToOtherImageFormatsAppliesImageOptions() async throws {
        var preset = Preset()
        preset.targetFormat = "jpg"
        preset.image.resize = .longEdge
        preset.image.longEdge = 800
        preset.image.quality = 80
        let jpg = try await convert(try sampleDxf(), "jpg", preset)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: jpg) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 800)
    }

    // ───────────────────────── Scene details ─────────────────────────

    func testLayerZeroInABlockFollowsTheInsertLayer() throws {
        // AutoCAD: an insert on an OFF layer hides the block's layer-0 entities, but entities on their own (visible)
        // layer stay; an insert on a frozen layer hides everything.
        var builder = CadBuilder()
        builder.layers = [.init(name: "Off", isOn: false), .init(name: "Frozen", isFrozen: true), .init(name: "Own", color: CadBuilder.visible)]
        builder.blocks.append(("B", [0, 0, 0], [CadBuilder.line("0", [0, 0], [10, 0]), CadBuilder.line("Own", [0, 5], [10, 5])]))
        builder.entities.append(CadBuilder.insert("Off", "B", [0, 0]))
        builder.entities.append(CadBuilder.insert("Frozen", "B", [0, 100]))

        let scene = try CadSceneBuilder.build(try CadFile.read(try builder.save(newFolder(), "layers.dxf"), "dxf"))

        XCTAssertEqual(scene.items.count, 1)
        let stroke = try XCTUnwrap(scene.items.first as? CadStrokePrimitive)
        XCTAssertEqual(stroke.color, CadColor(r: 0, g: 0, b: 255))
        XCTAssertEqual(stroke.figures.first?.start.y ?? 0, 5, accuracy: 1e-9)
    }

    func testInsertsApplyBasePointScaleRotationAndArrays() throws {
        var builder = CadBuilder()
        builder.blocks.append(("Square", [1, 1, 0], [CadBuilder.lwPolyline("0", [(1, 1, 0), (2, 1, 0), (2, 2, 0), (1, 2, 0)], closed: true)]))
        // Base point (1,1) lands on (10,10); scaled ×2 and turned 90°, the unit square covers x 8..10, y 10..12 ...
        builder.entities.append(CadBuilder.insert("0", "Square", [10, 10], scale: 2, rotation: 90))
        // ... and a 2 × 3 array (column spacing 10, row spacing 20) of the plain square from (100,0).
        builder.entities.append(CadBuilder.insert("0", "Square", [100, 0], columns: 3, rows: 2, columnSpacing: 10, rowSpacing: 20))

        let scene = try CadSceneBuilder.build(try CadFile.read(try builder.save(newFolder(), "inserts.dxf"), "dxf"))

        XCTAssertEqual(scene.items.count, 7, "skipped: \(scene.skipped)")
        guard scene.items.count == 7 else { return }
        let first = try bounds(scene.items[0])
        XCTAssertEqual([first.minX, first.minY, first.maxX, first.maxY].map { ($0 * 1e9).rounded() / 1e9 }, [8, 10, 10, 12])
        XCTAssertEqual(scene.extents.minX, 8, accuracy: 1e-9)
        XCTAssertEqual(scene.extents.maxX, 121, accuracy: 1e-9) // last column at 100 + 2·10, one unit wide
        XCTAssertEqual(scene.extents.maxY, 21, accuracy: 1e-9) // second row at 20
    }

    func testDimensionsDrawTheirBlockWithTheMeasurement() throws {
        let scene = try CadSceneBuilder.build(try CadFile.read(try sampleDxf(), "dxf"))

        let texts = scene.items.compactMap { ($0 as? CadTextPrimitive)?.text }
        XCTAssertTrue(texts.contains { $0.contains("100") }) // the aligned dimension's value
        XCTAssertGreaterThanOrEqual(scene.items.filter { $0 is CadFillPrimitive }.count, 3, "the solid hatch and two arrowheads")
        XCTAssertTrue(scene.skipped.isEmpty, "\(scene.skipped)")
        XCTAssertFalse(scene.truncated)
    }

    func testLineTypesAndPatternHatchesAreDrawn() throws {
        let scene = try CadSceneBuilder.build(try CadFile.read(try sampleDxf(), "dxf"))

        let dashed = scene.items.compactMap { $0 as? CadStrokePrimitive }.filter { $0.dashes != nil }
        XCTAssertEqual(dashed.count, 1)
        XCTAssertEqual(dashed.first?.dashes, [5.0, -2.5])

        // 45° lines 2 units apart across a 20 × 20 square (28.3 units across its diagonal): about 15 lines, generated
        // over the bounding box and clipped to the boundary when drawn.
        let hatches = scene.items.compactMap { $0 as? CadHatchLinesPrimitive }
        XCTAssertEqual(hatches.count, 1)
        XCTAssertTrue((14...18).contains(hatches[0].lines.count), "\(hatches[0].lines.count) lines")
        XCTAssertEqual(hatches[0].boundary.count, 1)

        // The clamped spline runs from its first to its last control point and stays inside their hull (lowest point
        // of this Bézier at y ≈ -22.89); the ellipse arc runs three quarters from its major axis end.
        let figures = scene.items.compactMap { $0 as? CadStrokePrimitive }.flatMap(\.figures)
        let splines = figures.filter { $0.start == CadVec2(0, -20) }
        XCTAssertEqual(splines.count, 1)
        let spline = try XCTUnwrap(splines.first)
        XCTAssertEqual(spline.end.x, 60, accuracy: 1e-9)
        XCTAssertEqual(spline.end.y, -20, accuracy: 1e-9)
        var splineBox = CadBox2.empty
        spline.add(to: &splineBox)
        XCTAssertTrue((-22.89 ... -22.85).contains(splineBox.minY), "\(splineBox.minY)")
        let ellipses = figures.filter { $0.start == CadVec2(97, -20) }
        XCTAssertEqual(ellipses.count, 1)
        XCTAssertEqual(ellipses[0].end.x, 85, accuracy: 1e-9)
        XCTAssertEqual(ellipses[0].end.y, -26, accuracy: 1e-9)
    }

    func testMtextFormattingCodesAreDecoded() {
        let format = CadMTextFormat(height: 2, colorIndex: nil, trueColor: nil, fontFamily: nil, bold: false, italic: false, widthFactor: 1, obliqueDegrees: 0)

        let paragraphs = CadTextCodes.parseMText("{\\fArial|b1|i0;Bold} \\H3x;Big\\Pline \\S1/2; %%d \\U+AC00\\~end", format)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0][0].text, "Bold")
        XCTAssertTrue(paragraphs[0][0].format.bold)
        XCTAssertEqual(paragraphs[0][0].format.fontFamily, "Arial")
        XCTAssertEqual(paragraphs[0].last?.format.height, 6) // \H3x of 2
        XCTAssertEqual(paragraphs[1].map(\.text).joined(), "line 1/2 ° 가\u{00A0}end")
        XCTAssertEqual(CadTextCodes.decodeText("%%c25 %%p0.1 45%%d"), "Ø25 ±0.1 45°")
    }

    func testRationalSplineReproducesACircle() {
        // A quarter circle as a rational quadratic B-spline (weights 1, √2/2, 1).
        let points = CadCurves.sampleNurbs(2, [CadVec3(1, 0, 0), CadVec3(1, 1, 0), CadVec3(0, 1, 0)], [0, 0, 0, 1, 1, 1], [1, 0.5.squareRoot(), 1])

        XCTAssertGreaterThan(points.count, 5)
        for p in points { XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 1, accuracy: 1e-9) }
        XCTAssertEqual(points.last, CadVec3(0, 1, 0))
    }

    func testBulgeArcsFollowTheAutocadConvention() {
        // Bulge 1 = counter-clockwise half circle; the centre lies halfway.
        let arc = CadCurves.bulgeArc(CadVec2(0, 0), CadVec2(10, 0), 1)

        XCTAssertEqual(arc.center.x, 5, accuracy: 1e-9)
        XCTAssertEqual(arc.center.y, 0, accuracy: 1e-9)
        XCTAssertEqual(arc.radius, 5, accuracy: 1e-9)
        XCTAssertEqual(abs(arc.startAngle), Double.pi, accuracy: 1e-9)
        XCTAssertEqual(arc.sweep, Double.pi, accuracy: 1e-9)
    }

    func testKoreanTextUsesAFontWithHangul() throws {
        let primary = CadFonts.resolve(nil, false, false)
        let runs = CadFonts.layout("도면 ABC", primary)
        let hangul = try XCTUnwrap(runs.first { $0.text.contains("도") })
        try XCTSkipUnless(hangul.typeface.containsGlyph(UInt32(("도" as Unicode.Scalar).value)), "no font with Hangul on this machine")

        XCTAssertGreaterThan(hangul.advance, 0)
        XCTAssertTrue(runs.contains { $0.text.contains("A") && $0.typeface.containsGlyph(0x41) })
    }

    // ───────────────────────── Helpers ─────────────────────────

    private func bounds(_ primitive: CadScenePrimitive) throws -> CadBox2 {
        var box = CadBox2.empty
        for figure in try XCTUnwrap(primitive as? CadStrokePrimitive).figures { figure.add(to: &box) }
        return box
    }
}

/// The content stream operators of a PDF page.
enum CadPdfOperators {
    private final class Collector { var names = Set<String>() }

    static func of(_ page: CGPDFPage) -> Set<String> {
        let collector = Collector()
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "l") { _, info in CadPdfOperators.record(info, "l") }
        CGPDFOperatorTableSetCallback(table, "c") { _, info in CadPdfOperators.record(info, "c") }
        CGPDFOperatorTableSetCallback(table, "f") { _, info in CadPdfOperators.record(info, "f") }
        CGPDFOperatorTableSetCallback(table, "f*") { _, info in CadPdfOperators.record(info, "f*") }
        CGPDFOperatorTableSetCallback(table, "Tj") { _, info in CadPdfOperators.record(info, "Tj") }
        CGPDFOperatorTableSetCallback(table, "TJ") { _, info in CadPdfOperators.record(info, "TJ") }
        CGPDFOperatorTableSetCallback(table, "BI") { _, info in CadPdfOperators.record(info, "BI") }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(collector).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        return collector.names
    }

    fileprivate static func record(_ info: UnsafeMutableRawPointer?, _ name: String) {
        Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue().names.insert(name)
    }
}

/// Pixel statistics of rendered drawings.
enum CadPixels {
    static func load(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Drawn (not white), blue and red pixels plus the bounding box of everything drawn.
    static func count(_ image: CGImage) -> (ink: Int, blue: Int, red: Int, box: (width: Int, height: Int)) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var ink = 0, blue = 0, red = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            if r > 240 && g > 240 && b > 240 { continue }
            let x = i / 4 % width, y = i / 4 / width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
            ink += 1
            if b > 150 && r < 100 && g < 100 { blue += 1 }
            if r > 150 && g < 100 && b < 100 { red += 1 }
        }
        return (ink, blue, red, maxX < 0 ? (0, 0) : (maxX - minX + 1, maxY - minY + 1))
    }
}
