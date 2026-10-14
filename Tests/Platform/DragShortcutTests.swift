import AppKit
import Carbon
import XCTest
@testable import FileToX

final class DragShortcutTests: XCTestCase {
    func testDefaultIsControlAndMatchingRequiresExactModifierCombination() {
        let shortcut = DragShortcut.standard
        XCTAssertEqual(shortcut.displayName, "⌃")
        XCTAssertTrue(shortcut.matches(modifiers: [.control, .capsLock, .function]))
        XCTAssertFalse(shortcut.matches(modifiers: .option))
        XCTAssertFalse(shortcut.matches(modifiers: [.control, .shift]))
        let combination = DragShortcut(modifiers: [.control, .option, .shift, .command])
        XCTAssertEqual(combination.displayName, "⌃⌥⇧⌘")
        XCTAssertTrue(combination.matches(modifiers: [.control, .option, .shift, .command]))
        XCTAssertFalse(combination.matches(modifiers: [.control, .option, .shift]))
    }

    func testAdditionalKeyMustBeHeldAndCanBePressedDuringDrag() {
        let shortcut = DragShortcut(modifiers: [.control, .shift], keyCode: 40)
        var gesture = DragGestureState()
        gesture.mouseDown(at: .zero)
        XCTAssertFalse(gesture.mouseDragged(to: CGPoint(x: 10, y: 0), shortcutPressed: shortcut.matches(modifiers: [.control, .shift])))
        XCTAssertTrue(gesture.flagsChanged(shortcutPressed: shortcut.matches(modifiers: [.control, .shift], keyPressed: true), leftButtonPressed: true))
        XCTAssertEqual(shortcut.displayName, "⌃⇧K")
        XCTAssertFalse(shortcut.matches(modifiers: .control, keyPressed: true))
        var gate = DragPasteboardGate()
        gate.begin(changeCount: 1)
        XCTAssertFalse(gate.accepts(changeCount: 2, hasFileURLs: true, leftButtonPressed: true,
                                    shortcutPressed: shortcut.matches(modifiers: [.control, .shift]), generation: gate.generation))
        gesture.retryTrigger()
        XCTAssertTrue(gesture.flagsChanged(shortcutPressed: shortcut.matches(modifiers: [.control, .shift], keyPressed: true), leftButtonPressed: true))
        XCTAssertTrue(gate.accepts(changeCount: 2, hasFileURLs: true, leftButtonPressed: true,
                                   shortcutPressed: true, generation: gate.generation))
    }

    func testEmptyModifiersAndUnsupportedKeysAreInvalid() {
        XCTAssertFalse(DragShortcut(modifiers: []).isValid)
        XCTAssertFalse(DragShortcut(modifiers: [], keyCode: 40).matches(modifiers: [], keyPressed: true))
        XCTAssertFalse(DragShortcut(modifiers: .control, keyCode: 53).isValid, "Escape is reserved for cancellation")
        XCTAssertFalse(DragShortcut(modifiers: .control, keyCode: 999).isValid)
    }

    func testOnlyEnabledSystemShortcutsWithSameKeyAndCarbonModifiersConflict() {
        let shortcut = DragShortcut(modifiers: [.command, .shift], keyCode: 20)
        let carbon = UInt32(cmdKey | shiftKey)
        XCTAssertTrue(shortcut.conflicts(with: [.init(keyCode: 20, carbonModifiers: carbon, enabled: true)]))
        XCTAssertFalse(shortcut.conflicts(with: [.init(keyCode: 20, carbonModifiers: carbon, enabled: false)]))
        XCTAssertFalse(shortcut.conflicts(with: [.init(keyCode: 21, carbonModifiers: carbon, enabled: true)]))
        XCTAssertFalse(shortcut.conflicts(with: [.init(keyCode: 20, carbonModifiers: UInt32(cmdKey), enabled: true)]))
        XCTAssertFalse(DragShortcut.standard.conflicts(with: [.init(keyCode: 20, carbonModifiers: UInt32(controlKey), enabled: true)]))
        XCTAssertTrue(DragShortcut(modifiers: .control, keyCode: 122).conflicts(with: [
            .init(keyCode: 122, carbonModifiers: UInt32(controlKey | kEventKeyModifierFnMask), enabled: true)
        ]))
        XCTAssertTrue(DragShortcut(modifiers: .shift).conflicts(with: [
            .init(keyCode: UInt16.max, carbonModifiers: UInt32(shiftKey), enabled: true)
        ]))
    }

    func testSavedShortcutSurvivesReloadAndInvalidDataFallsBackToControl() throws {
        let name = "filetox-shortcut-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(DragShortcut.load(from: defaults), .standard)
        let shortcut = DragShortcut(modifiers: [.control, .option], keyCode: 122)
        shortcut.save(to: defaults)
        XCTAssertEqual(DragShortcut.load(from: defaults), shortcut)
        defaults.set(try JSONEncoder().encode(DragShortcut(modifiers: [])), forKey: DragShortcut.defaultsKey)
        XCTAssertEqual(DragShortcut.load(from: defaults), .standard)
        defaults.set(Data("bad json".utf8), forKey: DragShortcut.defaultsKey)
        XCTAssertEqual(DragShortcut.load(from: defaults), .standard)
    }

    @MainActor
    func testSystemShortcutAPIIsReadable() throws {
        XCTAssertFalse(try XCTUnwrap(DragShortcut.systemHotKeys()).isEmpty)
    }
}
