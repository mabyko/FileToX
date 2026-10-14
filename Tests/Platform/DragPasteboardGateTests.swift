import XCTest
@testable import FileToX

final class DragPasteboardGateTests: XCTestCase {
    func testOnlyNewFilePayloadCanShowPanel() {
        var gate = DragPasteboardGate()
        gate.begin(changeCount: 40)
        let generation = gate.generation
        XCTAssertFalse(gate.accepts(changeCount: 40, hasFileURLs: true, leftButtonPressed: true, shortcutPressed: true, generation: generation), "A previous drag's file URLs must not trigger the panel")
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: false, leftButtonPressed: true, shortcutPressed: true, generation: generation), "Text drags must stay with their source")
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: false, shortcutPressed: true, generation: generation))
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: true, shortcutPressed: false, generation: generation))
        XCTAssertTrue(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: true, shortcutPressed: true, generation: generation))
    }

    func testReleaseAndNewGestureInvalidatePendingPayload() {
        var gate = DragPasteboardGate()
        gate.begin(changeCount: 40)
        let oldGeneration = gate.generation
        gate.end()
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: true, shortcutPressed: true, generation: oldGeneration))
        gate.begin(changeCount: 41)
        XCTAssertFalse(gate.accepts(changeCount: 42, hasFileURLs: true, leftButtonPressed: true, shortcutPressed: true, generation: oldGeneration))
        XCTAssertTrue(gate.accepts(changeCount: 42, hasFileURLs: true, leftButtonPressed: true, shortcutPressed: true, generation: gate.generation))
    }
}
