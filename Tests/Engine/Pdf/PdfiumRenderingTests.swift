import Foundation
import XCTest
@testable import FileToXEngineKit

final class PdfiumRenderingTests: XCTestCase {
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }

    func testPageCountCropRotationAndFractionalDpi() throws {
        let document = try PdfiumDocument(fixtures.appendingPathComponent("pdfium.pdf").path)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(try document.pageSize(0), CGSize(width: 60.5, height: 40.5))
        XCTAssertEqual(try document.pageSize(1), CGSize(width: 40.5, height: 60.5))
        let first = try document.render(0, dpi: 101), second = try document.render(1, dpi: 101)
        XCTAssertEqual([first.width, first.height, second.width, second.height], [84, 56, 56, 84])
        XCTAssertThrowsError(try document.render(2, dpi: 101))
        let missing = fixtures.appendingPathComponent("missing.pdf").path
        XCTAssertThrowsError(try PdfiumDocument(missing)) {
            XCTAssertEqual(String(describing: $0), "missing.pdf is not a PDF file that can be read.")
        }
        XCTAssertThrowsError(try PdfiumDocument(missing, unreadableMessage: "The PDF could not be opened.")) {
            XCTAssertEqual(String(describing: $0), "The PDF could not be opened.")
        }
    }

    func testPixelsMatchCSharpPDFtoImageIncludingFormsAndAnnotations() throws {
        let document = try PdfiumDocument(fixtures.appendingPathComponent("pdfium.pdf").path)
        for index in 0..<document.pageCount {
            let expected = try GraphicsTestKit.decode(fixtures.appendingPathComponent("pdfium_p\(index + 1).png").path).frames[0]
            let actual = try document.render(index, dpi: 101)
            XCTAssertEqual(ImagePixels.bitmap(actual).pixels, ImagePixels.bitmap(expected).pixels, "page \(index + 1)")
        }
    }

    func testConcurrentDocumentLifetimesAndRenderingUseTheGlobalLock() throws {
        let path = fixtures.appendingPathComponent("pdfium.pdf").path
        let expected = ImagePixels.bitmap(try GraphicsTestKit.decode(fixtures.appendingPathComponent("pdfium_p1.png").path).frames[0]).pixels
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                let pixels = ImagePixels.bitmap(try PdfiumDocument(path).render(0, dpi: 101)).pixels
                if pixels != expected { lock.withLock { failures.append("pixels changed") } }
            } catch { lock.withLock { failures.append(String(describing: error)) } }
        }
        XCTAssertEqual(failures, [])
    }

    func testCancelledRenderThrowsCancellationError() async throws {
        let path = fixtures.appendingPathComponent("pdfium.pdf").path
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PdfiumDocument(path).render(0, dpi: 101)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}
