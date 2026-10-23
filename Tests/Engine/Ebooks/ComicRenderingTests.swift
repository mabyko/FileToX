import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import FileToXEngineKit

final class ComicRenderingTests: XCTestCase {
    func testComicPagesUseRasterCropRotationAndTruncatedDimensions() throws {
        let folder = GraphicsTestKit.folder()
        defer { FileManager.default.removeIfPresent(folder) }
        let path = FilePath.combine(folder, "fractional.pdf")
        var rect = CGRect(x: 0, y: 0, width: 120.5, height: 90.5)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = PDFDocument(data: data as Data)!
        let page = document.page(at: 0)!
        page.setBounds(CGRect(x: 10, y: 15, width: 60.5, height: 40.5), for: .cropBox)
        page.rotation = 90
        try FileManager.default.writeFile(path, document.dataRepresentation()!)
        var preset = Preset(); preset.pdf.renderDpi = 101
        let step = ConversionStep(inputPath: path, from: "pdf", to: "cbz", preset: preset,
                                  output: GraphicsTestOutput(folder: folder, name: "comic"), workDirectory: folder)
        let pages = try ComicBook.renderPdf(path, step, folder, nil)
        let expected = try PdfiumConverter.render(PDFDocument(url: URL(fileURLWithPath: path))!.page(at: 0)!, dpi: 101)
        let image = try GraphicsTestKit.decode(pages[0])
        XCTAssertEqual([image.width, image.height], [expected.width, expected.height])
        XCTAssertEqual([image.width, image.height], [56, 84])
    }

    func testComicAndEpubCopyExistingJpegBytes() throws {
        let folder = GraphicsTestKit.folder()
        defer { FileManager.default.removeIfPresent(folder) }
        let bytes = try EbookBuilders.picture(20, 10, true)
        let path = FilePath.combine(folder, "한글.jpg")
        try FileManager.default.writeFile(path, bytes)
        let cbz = FilePath.combine(folder, "comic.cbz")
        try ComicBook.toCbz([path], cbz)
        XCTAssertEqual(try ZipReader(path: cbz).data(named: "001.jpg"), bytes)
        let epub = FilePath.combine(folder, "comic.epub")
        try EpubWriter.writeFixedLayout("comic", [path], epub, folder)
        let zip = try ZipReader(path: epub)
        let picture = try XCTUnwrap(zip.entries.first { $0.name.hasSuffix(".jpg") })
        XCTAssertEqual(try zip.data(for: picture), bytes)
    }
}
