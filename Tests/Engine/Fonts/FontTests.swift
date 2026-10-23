// Port of Filee.Engines.Tests/FontTests.cs. CoreText/CoreGraphics replace Skia's loading and outline checks.
// This foundation checkout has no Swift job queue yet, so conversions exercise the Converter contract directly.
import Foundation
import CoreText
import CoreGraphics
import XCTest
@testable import FileToXEngineKit

final class FontTests: XCTestCase {
    private let trueType = "FileeTest-TrueType.ttf", cidKeyed = "FileeTest-CID.otf", nameKeyed = "FileeTest-NameKeyed.otf", googleWoff2 = "FileeTest-TrueType.google.woff2"
    private var folder: URL!
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ftx-font-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func sample(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
    private func load(_ path: URL) throws -> SfntFont { try FontFile.load(Data(contentsOf: path)) }
    private func convert(_ input: URL, _ target: String) async throws -> URL {
        let out = folder.appendingPathComponent(UUID().uuidString + "." + target)
        let outputs = try await FontConverter().convert(ConversionStep(inputPath: input.path, from: input.pathExtension, to: target, preset: Preset(), output: FontTestOutput(out.path), workDirectory: folder.path), progress: nil)
        XCTAssertEqual(outputs, [out.path]); XCTAssertEqual(out.pathExtension, target); return out
    }
    private func roundTrip(_ name: String, _ via: String) async throws -> SfntFont {
        try await load(convert(convert(sample(name), via), sample(name).pathExtension))
    }
    func testEveryFontFormatConvertsToEveryOtherInOneStep() {
        let converter = FontConverter(), edges = FontFile.formats.flatMap { from in FontFile.formats.filter { $0 != from }.map { ConversionEdge(from, $0) } }
        XCTAssertEqual(converter.edges, edges); XCTAssertEqual(converter.edges.count, 20)
        XCTAssertEqual(converter.id, "font"); XCTAssertEqual(converter.displayName, "Fonts (built-in)"); XCTAssertEqual(converter.maxParallelism, 0)
        XCTAssertEqual(converter.status(), .available(detail: "TTF, OTF, WOFF, WOFF2, EOT", version: EngineVersions.builtIn))
        XCTAssertTrue(EngineRegistry.createAll(EngineEnvironment(dataDirectory: folder.path)).contains { $0.id == "font" })
    }
    func testFontConvertsAndTheResultLoadsInCoreText() async throws {
        for name in [trueType, cidKeyed, nameKeyed] {
            let source = try load(sample(name))
            for target in FontFile.formats where target != sample(name).pathExtension {
                let output = try await convert(sample(name), target), bytes = try Data(contentsOf: output), result = try FontFile.load(bytes)
                XCTAssertEqual(try source.glyphCount, try result.glyphCount, "\(name) -> \(target)")
                XCTAssertEqual(target == "ttf" || target == "eot" || !source.hasCffOutlines, !result.hasCffOutlines)
                let font = try face(target == "ttf" || target == "otf" ? bytes : result.write())
                XCTAssertEqual(CTFontGetGlyphCount(font), try source.glyphCount)
                let chars = Array((name == nameKeyed ? "Aae" : "Filee").utf16)
                var glyphs = [CGGlyph](repeating: 0, count: chars.count), advances = [CGSize](repeating: .zero, count: chars.count)
                XCTAssertTrue(CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)); XCTAssertFalse(glyphs.contains(0))
                XCTAssertGreaterThan(CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count), 48)
                XCTAssertFalse(try XCTUnwrap(CTFontCreatePathForGlyph(font, glyphs[0], nil)).isEmpty)
            }
        }
    }
    func testEveryDirectionFromEveryContainer() throws {
        for name in [trueType, cidKeyed, nameKeyed] {
            let original = try load(sample(name))
            for from in FontFile.formats {
                let input = try FontFile.load(FontFile.save(original, from))
                for to in FontFile.formats where to != from {
                    let output = try FontFile.save(input, to), decoded = try FontFile.load(output)
                    XCTAssertEqual(try decoded.glyphCount, try input.glyphCount)
                    XCTAssertEqual(try FontFile.save(input, to), output, "deterministic \(name) \(from) -> \(to)")
                    _ = try face(decoded.write())
                }
            }
        }
    }
    func testRoundTripKeepsEveryTable() async throws {
        for (name, via) in [(trueType, "woff"), (trueType, "eot"), (trueType, "otf"), (cidKeyed, "woff"), (cidKeyed, "woff2"), (nameKeyed, "woff2")] {
            try assertSameTables(load(sample(name)), await roundTrip(name, via))
        }
    }
    func testTtfToWoff2AndBackKeepsGlyphOutlinesAndTables() async throws {
        let source = try load(sample(trueType)), back = try await roundTrip(trueType, "woff2")
        try assertSameTables(source, back, except: ["glyf", "loca"]); try assertSameGlyphs(source, back)
        XCTAssertEqual(try FontBigEndianReader(back.require("head"), 16).u16() & (1 << 11), 1 << 11)
    }
    func testWoff2UsesGlyfAndHmtxTransforms() async throws {
        let woff2 = try Data(contentsOf: await convert(sample(trueType), "woff2")), woff = try Data(contentsOf: await convert(sample(trueType), "woff")), google = try Data(contentsOf: sample(googleWoff2))
        let directory = try woff2Directory(woff2)
        for tag in ["glyf", "loca"] { XCTAssertEqual(directory[tag]?.0, 0); XCTAssertEqual(directory[tag]?.1, true) }
        XCTAssertEqual(directory["hmtx"]?.0, 1); XCTAssertEqual(directory["hmtx"]?.1, true); XCTAssertEqual(directory["cmap"]?.0, 0); XCTAssertEqual(directory["cmap"]?.1, false)
        XCTAssertEqual(woff2.count % 4, 0); XCTAssertEqual(Int(BinaryPrimitives.readUInt32BigEndian(woff2, 8)), woff2.count)
        // Apple exposes Brotli level 2, versus .NET quality 11; Filee's 0.8/1.05 size thresholds cannot apply.
        XCTAssertLessThan(woff2.count, woff.count)
        print("FONT_BROTLI_SIZE apple=\(woff2.count) woff=\(woff.count) google=\(google.count)")
    }
    func testWoff2FromGoogleReferenceEncoderDecodesToSource() async throws {
        let source = try load(sample(trueType)), google = try Data(contentsOf: sample(googleWoff2)), decoded = try FontFile.load(google)
        XCTAssertEqual(try woff2Directory(google)["glyf"]?.0, 0)
        try assertSameTables(source, decoded, except: ["glyf", "loca"]); try assertSameGlyphs(source, decoded, overlapBitmap: false)
        try await assertSameGlyphs(source, load(convert(sample(googleWoff2), "ttf")), overlapBitmap: false)
    }
    func testWoff2CollectionYieldsFirstFont() throws {
        let source = try load(sample(trueType)), second = try load(sample(nameKeyed))
        var tables: [(String, Data)] = [], directories: [(UInt32, [Int])] = []
        for font in [source, second] {
            var indices: [Int] = []
            for tag in font.tables.keys.sorted() { indices.append(tables.count); tables.append((tag, font.tables[tag]!)) }; directories.append((font.flavor, indices))
        }
        let compressed = try Woff2.compress(tables.reduce(into: Data()) { $0.append($1.1) }), w = FontBigEndianWriter()
        w.u32(Woff2.signature); w.u32(SfntFont.collectionTag); w.u32(0); w.u16(tables.count); w.u16(0); w.u32(0); w.u32(UInt32(compressed.count)); w.zeros(24)
        for (tag, data) in tables { w.u8(tag == "glyf" || tag == "loca" ? 63 | 3 << 6 : 63); w.u32(SfntFont.tagValue(tag)); w.uintBase128(UInt32(data.count)) }
        w.u32(0x00010000); w.write255UInt16(directories.count)
        for (flavor, indices) in directories { w.write255UInt16(indices.count); w.u32(flavor); for index in indices { w.write255UInt16(index) } }
        w.bytes(compressed)
        let decoded = try FontFile.load(w.written); XCTAssertEqual(decoded.flavor, SfntFont.trueTypeFlavor); try assertSameTables(source, decoded)
    }
    func testCffToTtfKeepsGlyphsMetricsAndOutlines() async throws {
        for name in [cidKeyed, nameKeyed] {
            let source = try load(sample(name)), output = try await convert(sample(name), "ttf"), ttf = try load(output)
            XCTAssertEqual(ttf.flavor, SfntFont.trueTypeFlavor); XCTAssertNil(ttf["CFF "]); XCTAssertNil(ttf["VORG"])
            XCTAssertEqual(try source.glyphCount, try ttf.glyphCount); XCTAssertEqual(try ttf.require("maxp").count, 32)
            for tag in ["cmap", "name", "OS/2", "GSUB", "GPOS", "BASE"] where source[tag] != nil { XCTAssertEqual(source[tag], ttf[tag], tag) }
            let glyphs = try GlyfTable.readAll(ttf), (advances, lsbs) = try metrics(ttf, "hhea", "hmtx")
            XCTAssertEqual(try metrics(source, "hhea", "hmtx").0, advances)
            let cffFace = try face(Data(contentsOf: sample(name))), ttfFace = try face(Data(contentsOf: output))
            for i in glyphs.indices {
                XCTAssertEqual(glyphs[i]?.xMin ?? 0, lsbs[i])
                if let glyph = glyphs[i] {
                    let bounds = glyph.computeBounds(); XCTAssertTrue(bounds == (glyph.xMin, glyph.yMin, glyph.xMax, glyph.yMax))
                    let areas = contours(glyph).map(signedArea); XCTAssertLessThan(try XCTUnwrap(areas.max(by: { abs($0) < abs($1) })), 0)
                }
                let expected = CTFontCreatePathForGlyph(cffFace, CGGlyph(i), nil), actual = CTFontCreatePathForGlyph(ttfFace, CGGlyph(i), nil)
                XCTAssertEqual(expected?.isEmpty ?? true, actual?.isEmpty ?? true)
                guard let e = expected, !e.isEmpty, let a = actual else { continue }
                let eb = e.boundingBoxOfPath, ab = a.boundingBoxOfPath
                for (x, y) in [(eb.minX, ab.minX), (eb.minY, ab.minY), (eb.maxX, ab.maxX), (eb.maxY, ab.maxY)] { XCTAssertLessThanOrEqual(abs(x - y), 1.6, "\(name) glyph \(i)") }
                let (different, covered) = compareCoverage(e, a)
                XCTAssertLessThanOrEqual(different, max(8, covered / 100), "\(name) glyph \(i): \(different) of \(covered)")
            }
        }
    }
    func testCffGlyphNamesBecomePostFormat2() async throws {
        let ttf = try await load(convert(sample(nameKeyed), "ttf"))
        XCTAssertEqual(try postNames(ttf), [".notdef", "space", "A", "a", "e", "acute", "Aacute", "flexbar", "box"])
        let cid = try await load(convert(sample(cidKeyed), "ttf"))
        XCTAssertEqual(try FontBigEndianReader(cid.require("post")).u32(), 0x00030000)
        XCTAssertEqual(try load(sample(cidKeyed)).require("post").subdata(in: 4..<32), try cid.require("post").subdata(in: 4..<32))
    }
    func testSeacAccentFlexAndSubroutinesAreDrawn() async throws {
        let glyphs = try await GlyfTable.readAll(load(convert(sample(nameKeyed), "ttf")))
        let a = try XCTUnwrap(glyphs[2]), acute = try XCTUnwrap(glyphs[5]), aacute = try XCTUnwrap(glyphs[6]), flexbar = try XCTUnwrap(glyphs[7]), box = try XCTUnwrap(glyphs[8])
        XCTAssertEqual(a.numberOfContours + acute.numberOfContours, aacute.numberOfContours)
        XCTAssertEqual(a.points + acute.points.map { GlyphPoint(x: $0.x + 170, y: $0.y + 190, onCurve: $0.onCurve) }, aacute.points)
        XCTAssertTrue((flexbar.xMin, flexbar.yMin, flexbar.xMax, flexbar.yMax) == (100, 0, 600, 530)); XCTAssertTrue(flexbar.points.contains(GlyphPoint(x: 350, y: 530, onCurve: true)))
        XCTAssertEqual(box.numberOfContours, 2); XCTAssertTrue((box.xMin, box.yMin, box.xMax, box.yMax) == (50, 0, 550, 500))
        XCTAssertEqual(contours(box).map(signedArea), [-250000, 90000])
    }
    func testCffToTtfMovesVorgOriginsIntoVmtx() async throws {
        let source = try load(sample(cidKeyed)), ttf = try await load(convert(sample(cidKeyed), "ttf")), defaultOrigin = try FontBigEndianReader(source.require("VORG"), 4).i16()
        let glyphs = try GlyfTable.readAll(ttf), (heights, tsbs) = try metrics(ttf, "vhea", "vmtx")
        XCTAssertEqual(try metrics(source, "vhea", "vmtx").0, heights)
        for i in glyphs.indices { if let glyph = glyphs[i] { XCTAssertEqual(defaultOrigin - glyph.yMax, tsbs[i]) } }
    }
    func testCffFontToEotCarriesTrueTypeOutlinesAndNames() async throws {
        let eot = try Data(contentsOf: await convert(sample(nameKeyed), "eot"))
        XCTAssertEqual(Int(BinaryPrimitives.readUInt32LittleEndian(eot)), eot.count); XCTAssertEqual(BinaryPrimitives.readUInt32LittleEndian(eot, 8), 0x00020001)
        XCTAssertEqual(BinaryPrimitives.readUInt32LittleEndian(eot, 12), 0); XCTAssertEqual(BinaryPrimitives.readUInt16LittleEndian(eot, 34), 0x504C)
        let size = Int(BinaryPrimitives.readUInt16LittleEndian(eot, 82))
        XCTAssertEqual(String(data: eot.subdata(in: 84..<84 + size), encoding: .utf16LittleEndian), "Filee Test NameKeyed")
        let font = try FontFile.load(eot); XCTAssertNotNil(font["glyf"]); XCTAssertNil(font["CFF "])
    }
    func testCompressedEotFailsWithClearMessage() async throws {
        var eot = try FontFile.save(load(sample(trueType)), "eot"); eot[12] |= 4
        try await assertFailure(eot, "eot", "MicroType Express")
    }
    func testCff2ToTtfFailsWithClearMessage() async throws {
        let font = try load(sample(cidKeyed)); font.tables["CFF2"] = font.tables.removeValue(forKey: "CFF ")
        try await assertFailure(font.write(), "otf", "CFF2")
    }
    func testNonFontFailsWithClearMessage() async throws { try await assertFailure(Data("this is not a font".utf8), "woff2", "not a font") }
    func testProgressSkipAndCancellation() async throws {
        let box = FontTestProgress(), output = FontTestOutput(nil)
        let step = ConversionStep(inputPath: sample(trueType).path, from: "ttf", to: "otf", preset: Preset(), output: output, workDirectory: folder.path)
        let outputs = try await FontConverter().convert(step, progress: { box.add($0) })
        XCTAssertEqual(outputs, []); XCTAssertEqual(box.values, [0.2, 0.9]); XCTAssertEqual(output.requested, ["otf"])
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await FontConverter().convert(step, progress: nil) }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let font = try load(sample(cidKeyed)), progress = FontTestProgress()
        _ = try FontFile.save(font, "ttf", { progress.add($0) }); XCTAssertEqual(progress.values.first, 0); XCTAssertEqual(progress.values.last, 1)
    }
    func testUtf16NamesAndXorEot() throws {
        let value = "Family 한글 😀", data = value.data(using: .utf16BigEndian)!, w = FontBigEndianWriter()
        w.u16(0); w.u16(1); w.u16(18); w.u16(3); w.u16(1); w.u16(0x409); w.u16(1); w.u16(data.count); w.u16(0); w.bytes(data)
        let font = try load(sample(trueType)); font.tables["name"] = w.written
        var eot = try Eot.encode(font); XCTAssertEqual(Int(BinaryPrimitives.readUInt16LittleEndian(eot, 82)), value.utf16.count * 2)
        XCTAssertEqual(String(data: eot.subdata(in: 84..<84 + value.utf16.count * 2), encoding: .utf16LittleEndian), value)
        eot[15] |= 0x10; let size = Int(BinaryPrimitives.readUInt32LittleEndian(eot, 4))
        for i in eot.count - size..<eot.count { eot[i] ^= 0x50 }
        try assertSameTables(font, Eot.decode(eot))
    }
    func testDamagedInputsThrowInsteadOfTrapping() throws {
        let woff2 = try FontFile.save(load(sample(trueType)), "woff2")
        for size in [0, 3, 12, 47, 48, woff2.count / 2] { XCTAssertThrowsError(try FontFile.load(Data(woff2.prefix(size)))) }
        XCTAssertThrowsError(try FontBigEndianReader(Data([0x80])).uintBase128())
        XCTAssertThrowsError(try FontBigEndianReader(Data([255, 255, 255, 255, 255])).uintBase128())
        XCTAssertThrowsError(try Woff2.decompress(Data([0, 1, 2]), 3))
    }
    private func assertFailure(_ data: Data, _ ext: String, _ contains: String) async throws {
        let path = folder.appendingPathComponent("bad." + ext); try data.write(to: path)
        do { _ = try await convert(path, "ttf"); XCTFail("expected failure") } catch { XCTAssertTrue(error.localizedDescription.contains(contains), error.localizedDescription) }
    }
    private func face(_ data: Data) throws -> CTFont {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData)), cg = try XCTUnwrap(CGFont(provider))
        return CTFontCreateWithGraphicsFont(cg, 1000, nil, nil)
    }
    private func assertSameTables(_ expected: SfntFont, _ actual: SfntFont, except: Set<String> = []) throws {
        XCTAssertEqual(expected.flavor, actual.flavor)
        XCTAssertEqual(expected.tables.keys.filter { !except.contains($0) && $0 != "DSIG" }.sorted(), actual.tables.keys.filter { !except.contains($0) }.sorted())
        for tag in expected.tables.keys where !except.contains(tag) && tag != "DSIG" {
            let e = expected.tables[tag]!, a = try actual.require(tag)
            XCTAssertEqual(tag == "head" ? normalizeHead(e) : e, tag == "head" ? normalizeHead(a) : a, "table '\(tag)' differs")
        }
    }
    private func normalizeHead(_ data: Data) -> Data { var copy = data; copy.replaceSubrange(8..<12, with: [0, 0, 0, 0]); copy[16] &= 0xF7; return copy }
    private func assertSameGlyphs(_ expected: SfntFont, _ actual: SfntFont, overlapBitmap: Bool = true) throws {
        let a = try GlyfTable.readAll(expected), b = try GlyfTable.readAll(actual)
        XCTAssertEqual(a.count, b.count); XCTAssertTrue(a.contains { $0?.isComposite == true }); XCTAssertTrue(a.contains { $0?.overlapSimple == true })
        for i in a.indices {
            guard let e = a[i], e.numberOfContours != 0 else { XCTAssertTrue(b[i] == nil || b[i]?.numberOfContours == 0); continue }
            let g = try XCTUnwrap(b[i]); XCTAssertTrue((e.numberOfContours, e.xMin, e.yMin, e.xMax, e.yMax) == (g.numberOfContours, g.xMin, g.yMin, g.xMax, g.yMax))
            XCTAssertEqual(e.endPoints, g.endPoints); XCTAssertEqual(e.points, g.points); XCTAssertEqual(e.instructions, g.instructions); XCTAssertEqual(e.overlapSimple && overlapBitmap, g.overlapSimple); XCTAssertEqual(e.components, g.components)
        }
    }
    private func woff2Directory(_ data: Data) throws -> [String: (Int, Bool)] {
        let r = FontBigEndianReader(data, 12), count = try r.u16(); r.position = 48
        var result: [String: (Int, Bool)] = [:]
        for _ in 0..<count {
            let flags = try r.u8(), tag = flags & 63 == 63 ? SfntFont.tagName(try r.u32()) : Woff2.knownTags[flags & 63], version = flags >> 6
            _ = try r.uintBase128(); let transformed = tag == "glyf" || tag == "loca" ? version != 3 : version != 0
            if transformed { _ = try r.uintBase128() }; result[tag] = (version, transformed)
        }
        return result
    }
    private func metrics(_ font: SfntFont, _ header: String, _ table: String) throws -> ([Int], [Int]) {
        let count = try FontTables.numberOfMetrics(font.require(header)), r = try FontBigEndianReader(font.require(table)), glyphCount = try font.glyphCount
        var advances: [Int] = [], bearings: [Int] = []
        for i in 0..<glyphCount { advances.append(i < count ? try r.u16() : advances[i - 1]); bearings.append(try r.i16()) }; return (advances, bearings)
    }
    private func postNames(_ font: SfntFont) throws -> [String] {
        let r = try FontBigEndianReader(font.require("post")); XCTAssertEqual(try r.u32(), 0x00020000); r.position = 32
        let indices = try (0..<r.u16()).map { _ in try r.u16() }; var extra: [String] = []
        while r.remaining > 0 { extra.append(String(decoding: try r.bytes(r.u8()), as: UTF8.self)) }
        return indices.map { $0 < 258 ? CffStandardData.macGlyphNames[$0] : extra[$0 - 258] }
    }
    private func contours(_ glyph: TrueTypeGlyph) -> [[GlyphPoint]] {
        var start = 0; return glyph.endPoints.map { end in defer { start = end + 1 }; return Array(glyph.points[start...end]) }
    }
    private func signedArea(_ points: [GlyphPoint]) -> Int { points.indices.reduce(0) { sum, i in let p = points[i], q = points[(i + 1) % points.count]; return sum + p.x * q.y - q.x * p.y } / 2 }
    private func compareCoverage(_ expected: CGPath, _ actual: CGPath) -> (Int, Int) {
        let bounds = expected.boundingBoxOfPath.union(actual.boundingBoxOfPath), width = Int(ceil(bounds.width / 4)) + 4, height = Int(ceil(bounds.height / 4)) + 4
        func render(_ path: CGPath) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.scaleBy(x: 0.25, y: 0.25); context.translateBy(x: -bounds.minX + 8, y: -bounds.minY + 8); context.setFillColor(gray: 1, alpha: 1); context.addPath(path); context.fillPath()
            }; return bytes
        }
        let e = render(expected), a = render(actual); return (zip(e, a).filter { abs(Int($0) - Int($1)) > 128 }.count, e.filter { $0 > 128 }.count)
    }
}

private final class FontTestOutput: OutputAllocator {
    let path: String?; var requested: [String] = []
    init(_ path: String?) { self.path = path }
    func allocate(_ ext: String, suffix: String?) throws -> String? { requested.append(ext); return path }
}
private final class FontTestProgress: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Double] = []
    func add(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}
