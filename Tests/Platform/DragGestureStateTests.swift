import XCTest
import CoreGraphics
@testable import FileToX

final class DragGestureStateTests: XCTestCase {
    func testPreheldShortcutOnlyOpensInBeforeDragAndEitherModes() {
        for mode in DragShortcut.ActivationMode.allCases {
            var gesture = DragGestureState()
            gesture.mouseDown(at: .zero)
            XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 4, y: 4), shortcutPressed: true, activationMode: mode))
            XCTAssertEqual(gesture.mouseDragged(to: CGPoint(x: 5, y: 4), shortcutPressed: true, activationMode: mode),
                           mode != .duringDrag, mode.rawValue)
            XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 20, y: 4), shortcutPressed: true, activationMode: mode))
        }
    }

    func testLateShortcutOnlyOpensInDuringDragAndEitherModes() {
        for mode in DragShortcut.ActivationMode.allCases {
            var gesture = DragGestureState()
            gesture.mouseDown(at: .zero)
            XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), shortcutPressed: false, activationMode: mode))
            XCTAssertEqual(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true, activationMode: mode),
                           mode != .beforeDrag, mode.rawValue)
            XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 30, y: 0), shortcutPressed: true, activationMode: mode))
        }
    }

    func testLateShortcutInMouseEventsRespectsModeWithoutFlagsChanged() {
        for mode in DragShortcut.ActivationMode.allCases {
            var gesture = DragGestureState()
            gesture.mouseDown(at: .zero)
            XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: false, activationMode: mode))
            XCTAssertEqual(gesture.mouseDragged(to: CGPoint(x: 20, y: 0), shortcutPressed: true, activationMode: mode),
                           mode != .beforeDrag, mode.rawValue)
        }
    }

    func testDuringDragModeRequiresRepressWhenShortcutWasAlreadyHeld() {
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: true, activationMode: .duringDrag))
        XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true, activationMode: .duringDrag))
        XCTAssertFalse(gesture.flagsChanged(shortcutPressed: false, leftButtonPressed: true, activationMode: .duringDrag))
        XCTAssertTrue(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true, activationMode: .duringDrag))
        XCTAssertTrue(gesture.cancel())
        gesture.retryTrigger()
        XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true, activationMode: .duringDrag))
        gesture.finish()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: true, activationMode: .duringDrag))
    }

    func testActivationModesRequireDraggingAndResetForTheNextDrag() {
        for mode in DragShortcut.ActivationMode.allCases {
            var gesture = DragGestureState()
            gesture.mouseDown(at: .zero)
            XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true, activationMode: mode))
            XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 3, y: 3), shortcutPressed: false, activationMode: mode))
            XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true, activationMode: mode))
            XCTAssertEqual(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: true, activationMode: mode), mode != .duringDrag)
            gesture.finish()
            gesture.mouseDown(at: .zero)
            XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: false, activationMode: mode))
            XCTAssertFalse(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: false, activationMode: mode))
            XCTAssertEqual(gesture.flagsChanged(shortcutPressed: true, leftButtonPressed: true, activationMode: mode), mode != .beforeDrag)
        }
    }

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
