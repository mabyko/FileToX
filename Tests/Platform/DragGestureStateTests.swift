import XCTest
import CoreGraphics
@testable import FileToX

final class DragGestureStateTests: XCTestCase {
    func testShortcutDragTriggersOnlyOnceAfterThreshold() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 4, y: 4), shortcutPressed: true))
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 5, y: 4), shortcutPressed: true))
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 8, y: 4), shortcutPressed: true))
        XCTAssertTrue(gesture.finish())
        XCTAssertFalse(gesture.finish())
    }

    func testShortcutCanBePressedDuringDrag() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), shortcutPressed: false))
        XCTAssertTrue(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true))
        XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true))
    }

    func testShortcutWithoutDraggingDoesNotTrigger() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true))
        XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: false))
        XCTAssertFalse(gesture.finish())
    }

    func testCancelBlocksRetriggerUntilNextDrag() {
        var gesture = DragGestureState()
        XCTAssertTrue(gesture.mouseDragged(to: .zero, shortcutPressed: true))
        XCTAssertTrue(gesture.cancel())
        gesture.retryTrigger()
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), shortcutPressed: true))
        gesture.finish()
        gesture.mouseDown(at: .zero)
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: true))
    }

    func testMouseEventModifiersWorkWithoutFlagsChanged() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: false))
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), shortcutPressed: true))
    }
}
