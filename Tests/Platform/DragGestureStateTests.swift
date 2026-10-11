import XCTest
import CoreGraphics
@testable import FileToX

final class DragGestureStateTests: XCTestCase {
    func testOptionDragTriggersOnlyOnceAfterThreshold() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 4, y: 4), optionPressed: true))
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 5, y: 4), optionPressed: true))
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 8, y: 4), optionPressed: true))
        XCTAssertTrue(gesture.finish())
        XCTAssertFalse(gesture.finish())
    }

    func testOptionCanBePressedDuringDrag() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), optionPressed: false))
        XCTAssertTrue(gesture.flagsChanged(optionPressed: true, leftButtonPressed: true))
        XCTAssertFalse(gesture.flagsChanged(optionPressed: true, leftButtonPressed: true))
    }

    func testOptionWithoutDraggingDoesNotTrigger() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.flagsChanged(optionPressed: true, leftButtonPressed: true))
        XCTAssertFalse(gesture.flagsChanged(optionPressed: true, leftButtonPressed: false))
        XCTAssertFalse(gesture.finish())
    }

    func testCancelBlocksRetriggerUntilNextDrag() {
        var gesture = DragGestureState()
        XCTAssertTrue(gesture.mouseDragged(to: .zero, optionPressed: true))
        XCTAssertTrue(gesture.cancel())
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), optionPressed: true))
        gesture.finish()
        gesture.mouseDown(at: .zero)
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), optionPressed: true))
    }

    func testMouseEventModifiersWorkWithoutFlagsChanged() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), optionPressed: false))
        XCTAssertTrue(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), optionPressed: true))
    }
}
