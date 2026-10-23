// Port of the PDF part of Filee.Engines.Tests/ImageAndPdfTests.cs: images → PDF (pages, sizes, JPEG kept as DCT),
// PDF → images (render size, multi-page TIFF), merging and splitting.

import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import FileToXEngineKit

final class PdfEngineTests: XCTestCase {
    private let pages = PdfSharpConverter()
    private let render = PdfiumConverter()
    private var dir = ""

    override func setUp() { dir = GraphicsTestKit.folder() }
    override func tearDown() { FileManager.default.removeIfPresent(dir) }

    private func preset(_ change: (inout Preset) -> Void) -> Preset {
        var preset = Preset()
        change(&preset)
        return preset
    }

    private func pageCount(_ path: String) throws -> Int { try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path))).pageCount }

    private func mediaBox(_ path: String, _ index: Int = 0) throws -> CGRect {
        try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path))?.page(at: index)).bounds(for: .mediaBox)
    }

    func testImagesToPdfAndBack() async throws {
        let tiff = try GraphicsTestKit.makeMultiPageTiff(dir, 2)
        let pdf = try await GraphicsTestKit.convert(pages, tiff, to: "pdf")
        XCTAssertEqual(try pageCount(pdf[0]), 2)
        let png = try await GraphicsTestKit.convert(render, pdf[0], to: "png", preset: preset { $0.pdf.renderDpi = 72 }, name: "pages_render")
        XCTAssertEqual(png.map(FilePath.fileName), ["pages_render_p1.png", "pages_render_p2.png"])
        // 120 × 80 px at 96 dpi = 90 × 60 pt, rendered at 72 dpi.
        let first = try GraphicsTestKit.decode(png[0])
        XCTAssertEqual([first.width, first.height], [90, 60])
    }

    func testPdfToMultiPageTiff() async throws {
        let pdf = try await GraphicsTestKit.convert(pages, GraphicsTestKit.makeMultiPageTiff(dir, 3), to: "pdf")[0]
        let tiff = try await GraphicsTestKit.convert(render, pdf, to: "tiff", preset: preset { $0.pdf.renderDpi = 72 }, name: "pages_back")
        XCTAssertEqual(tiff.count, 1)
        XCTAssertEqual(try GraphicsTestKit.decode(tiff[0]).frames.count, 3)
    }

    func testMergeImagesIntoOnePdf() async throws {
        let a = try GraphicsTestKit.makeImage(dir, "1.jpg")
        let b = try GraphicsTestKit.makeImage(dir, "2.png")
        let c = try GraphicsTestKit.makeMultiPageTiff(dir, 2)
        let options = preset {
            $0.pdf.mergeIntoSingle = true
            $0.pdf.pageSize = .a4
            $0.pdf.marginMm = 10
        }
        // The queue converts every file to PDF in its work folder, then merges them.
        var parts: [String] = []
        for source in [a, b, c] { parts += try await GraphicsTestKit.convert(pages, source, to: "pdf", preset: options, name: "part-\(parts.count)") }
        let output = FilePath.combine(dir, "1_merged.pdf")
        try await pages.merge(parts, into: output)
        XCTAssertEqual(try pageCount(output), 4)
        // Landscape pictures on landscape A4 pages.
        let box = try mediaBox(output)
        XCTAssertEqual(box.width, 841.89, accuracy: 0.01)
        XCTAssertEqual(box.height, 595.28, accuracy: 0.01)
    }

    func testSplitPdfByPageRange() async throws {
        let pdf = try await GraphicsTestKit.convert(pages, GraphicsTestKit.makeMultiPageTiff(dir, 4), to: "pdf")[0]
        let output = try await GraphicsTestKit.convert(pages, pdf, to: "pdf", preset: preset {
            $0.pdf.splitPages = true
            $0.pdf.pageRange = "2-3"
        })
        XCTAssertEqual(output.map(FilePath.fileName).sorted(), ["pages_p2.pdf", "pages_p3.pdf"])
        XCTAssertEqual(try pageCount(output[0]), 1)

        let extract = try await GraphicsTestKit.convert(pages, pdf, to: "pdf", preset: preset { $0.pdf.pageRange = "3-" }, name: "tail")
        XCTAssertEqual(try pageCount(extract[0]), 2)
    }

    func testPageSizeFollowsTheStoredResolutionAndJpegStaysJpeg() async throws {
        // PNG without resolution: 96 dpi (320 × 200 px = 240 × 150 pt), embedded losslessly.
        let png = try GraphicsTestKit.makeImage(dir, "a.png")
        let fromPng = try await GraphicsTestKit.convert(pages, png, to: "pdf")[0]
        let box = try mediaBox(fromPng)
        XCTAssertEqual([box.width, box.height], [240, 150])
        // JPEG with 300 dpi stored in JFIF: 320 × 200 px = 76.8 × 48 pt, the JPEG data passed through as DCT.
        let jpg = FilePath.combine(dir, "b.jpg")
        try ImageEncoder.save([ImageFrame(image: GraphicsTestKit.solid(320, 200, (10, 120, 200, 255)), dpi: (300, 300))], to: jpg, format: "jpg")
        let fromJpg = try await GraphicsTestKit.convert(pages, jpg, to: "pdf")[0]
        let jpgBox = try mediaBox(fromJpg)
        XCTAssertEqual(jpgBox.width, 76.8, accuracy: 0.01)
        XCTAssertEqual(jpgBox.height, 48, accuracy: 0.01)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fromJpg))
        XCTAssertNotNil(bytes.range(of: Data("/DCTDecode".utf8)), "JPEG data passes through")
    }

    func testRenderSizeMatchesPdfiumRounding() async throws {
        // 240 × 150 pt at 150 dpi: PDFtoImage computes 240 × (150 / 72) in single precision = 499.99998 → 499 px.
        let pdf = try await GraphicsTestKit.convert(pages, GraphicsTestKit.makeImage(dir, "a.png"), to: "pdf")[0]
        let png = try await GraphicsTestKit.convert(render, pdf, to: "png", name: "a_render")
        let result = try GraphicsTestKit.decode(png[0])
        XCTAssertEqual([result.width, result.height], [499, 312])
        XCTAssertEqual(result.properties[0][kCGImagePropertyDPIWidth] as? Int, 150)
        XCTAssertGreaterThan(GraphicsTestKit.pixel(result.frames[0], 5, 5).r, 250, "transparent picture areas render on white")
    }

    func testRotatedPagesRenderTurned() async throws {
        let pdf = try await GraphicsTestKit.convert(pages, GraphicsTestKit.makeImage(dir, "a.png"), to: "pdf")[0]
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf)))
        document.page(at: 0)!.rotation = 90
        let turned = FilePath.combine(dir, "turned.pdf")
        XCTAssertTrue(document.write(to: URL(fileURLWithPath: turned)))
        let png = try await GraphicsTestKit.convert(render, turned, to: "png", preset: preset { $0.pdf.renderDpi = 72 })
        let result = try GraphicsTestKit.decode(png[0])
        XCTAssertEqual([result.width, result.height], [150, 240])
        // The transparent (now white) top-left corner of the picture is at the top right after turning clockwise.
        XCTAssertGreaterThan(GraphicsTestKit.pixel(result.frames[0], 145, 5).g, 250)
        XCTAssertLessThan(GraphicsTestKit.pixel(result.frames[0], 5, 5).g, 200)
    }

    func testPasswordProtectedPdfsFailWithAClearMessage() async throws {
        let pdf = try await GraphicsTestKit.convert(pages, GraphicsTestKit.makeImage(dir, "a.png"), to: "pdf")[0]
        let locked = FilePath.combine(dir, "locked.pdf")
        let document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf)))
        XCTAssertTrue(document.write(to: URL(fileURLWithPath: locked), withOptions: [.userPasswordOption: "1234", .ownerPasswordOption: "1234-owner"]))
        for converter in [pages, render] as [Converter] {
            do {
                try await GraphicsTestKit.convert(converter, locked, to: converter === pages ? "pdf" : "png", name: "out-\(converter.id)")
                XCTFail(converter.id)
            } catch {
                XCTAssertTrue("\(error)".contains("password"), "\(error)")
            }
        }
    }
}
