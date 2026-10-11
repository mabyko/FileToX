import AppKit
import XCTest
@testable import FileToX

final class FileDropTests: XCTestCase {
    @MainActor
    func testDropAcceptsLocalFilesOnlyWhenCopyIsAllowed() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let source = URL(fileURLWithPath: "/tmp/이미지 테스트.png")
        XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))

        XCTAssertEqual(FileDropNSView.fileURLs(from: pasteboard, sourceOperationMask: .copy), [source])
        XCTAssertEqual(FileDropNSView.fileURLs(from: pasteboard, sourceOperationMask: [.copy, .move]), [source])
        XCTAssertTrue(FileDropNSView.fileURLs(from: pasteboard, sourceOperationMask: .move).isEmpty)
        XCTAssertTrue(FileDropNSView.fileURLs(from: pasteboard, sourceOperationMask: []).isEmpty)
    }

    @MainActor
    func testDropRejectsWebRemoteAndEmptyPasteboards() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for value in ["https://example.com/image.png", "file://remote-server/shared/image.png"] {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([URL(string: value)! as NSURL]))
            XCTAssertTrue(FileDropNSView.fileURLs(from: pasteboard, sourceOperationMask: .copy).isEmpty)
        }
        pasteboard.clearContents()
        XCTAssertTrue(FileDropNSView.fileURLs(from: pasteboard, sourceOperationMask: .copy).isEmpty)
    }
}
