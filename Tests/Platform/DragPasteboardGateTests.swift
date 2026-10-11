import XCTest
@testable import FileToX

final class DragPasteboardGateTests: XCTestCase {
    func testOnlyNewFilePayloadCanShowPanel() {
        var gate = DragPasteboardGate()
        gate.begin(changeCount: 40)
        let generation = gate.generation
        XCTAssertFalse(gate.accepts(changeCount: 40, hasFileURLs: true, leftButtonPressed: true, optionPressed: true, generation: generation), "A previous drag's file URLs must not trigger the panel")
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: false, leftButtonPressed: true, optionPressed: true, generation: generation), "Text drags must stay with their source")
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: false, optionPressed: true, generation: generation))
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: true, optionPressed: false, generation: generation))
        XCTAssertTrue(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: true, optionPressed: true, generation: generation))
    }

    func testReleaseAndNewGestureInvalidatePendingPayload() {
        var gate = DragPasteboardGate()
        gate.begin(changeCount: 40)
        let oldGeneration = gate.generation
        gate.end()
        XCTAssertFalse(gate.accepts(changeCount: 41, hasFileURLs: true, leftButtonPressed: true, optionPressed: true, generation: oldGeneration))
        gate.begin(changeCount: 41)
        XCTAssertFalse(gate.accepts(changeCount: 42, hasFileURLs: true, leftButtonPressed: true, optionPressed: true, generation: oldGeneration))
        XCTAssertTrue(gate.accepts(changeCount: 42, hasFileURLs: true, leftButtonPressed: true, optionPressed: true, generation: gate.generation))
    }
}
