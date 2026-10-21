import AppKit
import XCTest
@testable import FileToX

final class DragMenuGestureStateTests: XCTestCase {
    private let shortcuts: [RadialMenuKind: DragShortcut] = [.convert: .standard, .tools: .toolsStandard]

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
