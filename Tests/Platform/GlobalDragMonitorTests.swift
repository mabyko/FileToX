import AppKit
import XCTest
@testable import FileToX

final class GlobalDragMonitorTests: XCTestCase {
    @MainActor
    func testDragUsesEventTargetRatherThanAnUnrelatedFrontmostApp() throws {
        let monitor = GlobalDragMonitor()
        var sourceIdentifier: String?
        monitor.isApplicationExcluded = { sourceIdentifier = $0; return true }
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: event)))
        XCTAssertEqual(sourceIdentifier, try XCTUnwrap(NSRunningApplication.current.bundleIdentifier))
        monitor.stop()
    }

    @MainActor
    func testExcludedDragStaysExcludedUntilReleaseAndDoesNotBlockNextDrag() throws {
        let monitor = GlobalDragMonitor()
        var excluded = true
        var exclusionChecks = 0
        var shortcutChecks = 0
        monitor.isApplicationExcluded = { _ in exclusionChecks += 1; return excluded }
        monitor.shortcuts = { shortcutChecks += 1; return [:] }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        monitor.handle(try event(.leftMouseDown))
        XCTAssertEqual(exclusionChecks, 1)
        XCTAssertEqual(shortcutChecks, 0)
        excluded = false // A focus or settings change during the drag must not open the menu.
        monitor.handle(try event(.leftMouseDragged))
        monitor.handle(try event(.leftMouseUp))
        XCTAssertEqual(exclusionChecks, 1)
        XCTAssertEqual(shortcutChecks, 0)
        monitor.handle(try event(.leftMouseDown))
        XCTAssertEqual(exclusionChecks, 2)
        XCTAssertEqual(shortcutChecks, 1)
        monitor.handle(try event(.leftMouseDragged))
        XCTAssertEqual(shortcutChecks, 2)
        monitor.stop()
    }
}
