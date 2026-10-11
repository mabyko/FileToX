import XCTest
import CoreGraphics
@testable import FileToX

final class PanelPlacementTests: XCTestCase {
    func testDonutIsCenteredAtCursorWhenThereIsRoom() {
        let frame = PanelPlacement.frame(near: CGPoint(x: 500, y: 400), size: CGSize(width: 342, height: 342), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(frame.midX, 500)
        XCTAssertEqual(frame.midY, 400)
    }

    func testPlacementClampsToScreenAtEveryCorner() {
        let screen = CGRect(x: -1440, y: 30, width: 1440, height: 870)
        let size = CGSize(width: 340, height: 200)
        for point in [CGPoint(x: -1440, y: 30), CGPoint(x: 0, y: 30), CGPoint(x: -1440, y: 900), CGPoint(x: 0, y: 900)] {
            XCTAssertTrue(screen.contains(PanelPlacement.frame(near: point, size: size, visibleFrame: screen)))
        }
    }

    func testPanelSizeIsLimitedOnSmallScreens() {
        let screen = CGRect(x: 100, y: 100, width: 200, height: 120)
        let frame = PanelPlacement.frame(near: CGPoint(x: 200, y: 160), size: CGSize(width: 400, height: 300), visibleFrame: screen)
        XCTAssertEqual(frame, screen)
    }
}
