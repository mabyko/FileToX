import CoreGraphics
import XCTest
@testable import FileToX

final class DonutGeometryTests: XCTestCase {
    func testClockwiseSlicesStartAtTwelveAndRejectCenterAndOutside() {
        let center = CGPoint(x: 150, y: 150)
        func hit(_ x: Double, _ y: Double, count: Int = 8) -> Int? {
            DonutGeometry.segment(at: CGPoint(x: x, y: y), center: center, innerRadius: 63, outerRadius: 150, count: count)
        }
        XCTAssertEqual(hit(150, 40), 0)
        XCTAssertEqual(hit(260, 150), 2)
        XCTAssertEqual(hit(150, 260), 4)
        XCTAssertEqual(hit(40, 150), 6)
        XCTAssertNil(hit(150, 150))
        XCTAssertNil(hit(150, -1))
        XCTAssertNil(hit(150, 40, count: 0))
        XCTAssertEqual(hit(150, 40, count: 1), 0)
    }
    func testBoundaryWrapsAroundFirstSlice() {
        let radius = 100.0
        func hit(_ angle: Double) -> Int? {
            DonutGeometry.segment(at: CGPoint(x: 150 + radius * sin(angle), y: 150 - radius * cos(angle)), center: CGPoint(x: 150, y: 150), innerRadius: 63, outerRadius: 150, count: 8)
        }
        XCTAssertEqual(hit(-0.1), 0)
        XCTAssertEqual(hit(.pi / 8 + 0.001), 1)
        XCTAssertEqual(hit(-.pi / 8 - 0.001), 7)
    }
}
