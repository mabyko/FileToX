import AppKit
import XCTest
@testable import FileToX

final class DragMenuGestureStateTests: XCTestCase {
    private let shortcuts: [RadialMenuKind: DragShortcut] = [.convert: .standard, .tools: .toolsStandard]

    func testExtraKeyShortcutTakesPriorityForOpeningAndSwitchingEitherMenu() {
        for keyedMenu in RadialMenuKind.allCases {
            let modifierMenu: RadialMenuKind = keyedMenu == .convert ? .tools : .convert
            let configured: [RadialMenuKind: DragShortcut] = [
                modifierMenu: .standard, keyedMenu: DragShortcut(modifiers: .control, keyCode: 40)
            ]
            let modifiersOnly = DragMenuGestureState.matchingMenu(shortcuts: configured, modifiers: .control) { _ in false }
            let extraKey = DragMenuGestureState.matchingMenu(shortcuts: configured, modifiers: .control) { $0 == 40 }
            XCTAssertEqual(modifiersOnly, modifierMenu)
            XCTAssertEqual(extraKey, keyedMenu)
            var state = DragMenuGestureState()
            state.mouseDown(at: .zero)
            XCTAssertEqual(state.update(point: CGPoint(x: 10, y: 0), pressed: extraKey,
                                        leftButtonPressed: true, shortcuts: configured), keyedMenu)
            XCTAssertEqual(state.update(pressed: modifiersOnly, leftButtonPressed: true, shortcuts: configured), modifierMenu)
            XCTAssertEqual(state.update(pressed: extraKey, leftButtonPressed: true, shortcuts: configured), keyedMenu)
        }
    }

    func testMenuMatchingKeepsExactModifiersAndHandlesNoMatch() {
        XCTAssertEqual(DragMenuGestureState.matchingMenu(shortcuts: shortcuts, modifiers: .control) { _ in false }, .convert)
        XCTAssertEqual(DragMenuGestureState.matchingMenu(shortcuts: shortcuts, modifiers: [.control, .shift]) { _ in false }, .tools)
        XCTAssertNil(DragMenuGestureState.matchingMenu(shortcuts: shortcuts, modifiers: .option) { _ in true })
        XCTAssertNil(DragMenuGestureState.matchingMenu(shortcuts: [:], modifiers: .control) { _ in true })
    }

    func testSwitchingWithShiftKeepsMenuAfterKeyReleaseAndCanSwitchBack() {
        var state = DragMenuGestureState()
        state.mouseDown(at: .zero)
        XCTAssertNil(state.update(point: CGPoint(x: 3, y: 0), pressed: .convert, leftButtonPressed: true, shortcuts: shortcuts))
        XCTAssertEqual(state.update(point: CGPoint(x: 10, y: 0), pressed: .convert, leftButtonPressed: true, shortcuts: shortcuts), .convert)
        XCTAssertNil(state.update(pressed: .convert, leftButtonPressed: true, shortcuts: shortcuts))
        XCTAssertEqual(state.update(pressed: .tools, leftButtonPressed: true, shortcuts: shortcuts), .tools)
        XCTAssertNil(state.update(pressed: nil, leftButtonPressed: true, shortcuts: shortcuts))
        XCTAssertEqual(state.activeMenu, .tools)
        XCTAssertEqual(state.update(pressed: .convert, leftButtonPressed: true, shortcuts: shortcuts), .convert)
        XCTAssertTrue(state.finish())
        XCTAssertNil(state.activeMenu)
    }

    func testBothKeysPressedTogetherOpenOnlyToolsAndNeedDragging() {
        var state = DragMenuGestureState()
        state.mouseDown(at: .zero)
        XCTAssertNil(state.update(pressed: .tools, leftButtonPressed: true, shortcuts: shortcuts))
        XCTAssertEqual(state.update(point: CGPoint(x: 12, y: 0), pressed: .tools, leftButtonPressed: true, shortcuts: shortcuts), .tools)
        XCTAssertNil(state.update(pressed: .convert, leftButtonPressed: false, shortcuts: shortcuts))
    }

    func testCancellationBlocksBothMenusUntilNextDrag() {
        var state = DragMenuGestureState()
        XCTAssertEqual(state.update(point: .zero, pressed: .tools, leftButtonPressed: true, shortcuts: shortcuts), .tools)
        XCTAssertTrue(state.cancel())
        state.retryTrigger()
        XCTAssertNil(state.update(pressed: .convert, leftButtonPressed: true, shortcuts: shortcuts))
        XCTAssertNil(state.update(point: CGPoint(x: 20, y: 0), pressed: .tools, leftButtonPressed: true, shortcuts: shortcuts))
        _ = state.finish()
        state.mouseDown(at: .zero)
        XCTAssertEqual(state.update(point: CGPoint(x: 12, y: 0), pressed: .convert, leftButtonPressed: true, shortcuts: shortcuts), .convert)
    }

    func testInitialActivationOrderIsTrackedSeparatelyForEachMenu() {
        for kind in RadialMenuKind.allCases {
            for mode in DragShortcut.ActivationMode.allCases {
                var configured = shortcuts
                configured[kind]?.activationMode = mode
                var state = DragMenuGestureState()
                state.mouseDown(at: .zero)
                XCTAssertEqual(state.update(point: CGPoint(x: 10, y: 0), pressed: kind, leftButtonPressed: true, shortcuts: configured),
                               mode == .duringDrag ? nil : kind)
                if mode == .duringDrag {
                    XCTAssertNil(state.update(pressed: nil, leftButtonPressed: true, shortcuts: configured))
                    XCTAssertEqual(state.update(pressed: kind, leftButtonPressed: true, shortcuts: configured), kind)
                }
            }
        }
    }

    func testPendingPayloadCanRetryWithTheOtherShortcut() {
        var state = DragMenuGestureState()
        state.mouseDown(at: .zero)
        XCTAssertEqual(state.update(point: CGPoint(x: 10, y: 0), pressed: .convert, leftButtonPressed: true, shortcuts: shortcuts), .convert)
        state.retryTrigger()
        XCTAssertEqual(state.update(pressed: .tools, leftButtonPressed: true, shortcuts: shortcuts), .tools)
    }
}
