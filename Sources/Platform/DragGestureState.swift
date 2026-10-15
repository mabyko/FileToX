import CoreGraphics

// Drag gesture state machine; third-party notice: Resources/Filee.LICENSE.
struct DragGestureState {
    private var origin: CGPoint?
    private var hasDragged = false
    private var shortcutPressedAtDragStart: Bool?
    private var shortcutReleasedDuringDrag = false
    private var didTrigger = false
    private var cancelled = false

    mutating func mouseDown(at point: CGPoint) {
        self = DragGestureState()
        origin = point
    }

    mutating func mouseDragged(to point: CGPoint, shortcutPressed: Bool, activationMode: DragShortcut.ActivationMode = .either) -> Bool {
        if let origin {
            hasDragged = hasDragged || abs(point.x - origin.x) > 4 || abs(point.y - origin.y) > 4
        } else {
            hasDragged = true
        }
        if hasDragged, shortcutPressedAtDragStart == nil { shortcutPressedAtDragStart = shortcutPressed }
        return triggerIfNeeded(shortcutPressed: shortcutPressed, activationMode: activationMode)
    }

    mutating func flagsChanged(shortcutPressed: Bool, leftButtonPressed: Bool, activationMode: DragShortcut.ActivationMode = .either) -> Bool {
        guard leftButtonPressed else { return false }
        return triggerIfNeeded(shortcutPressed: shortcutPressed, activationMode: activationMode)
    }

    mutating func cancel() -> Bool {
        let wasTriggered = didTrigger
        didTrigger = false
        cancelled = true
        return wasTriggered
    }

    // A shortcut released before Finder publishes the file payload can be pressed again.
    mutating func retryTrigger() { didTrigger = false }

    @discardableResult
    mutating func finish() -> Bool {
        let wasTriggered = didTrigger
        self = DragGestureState()
        return wasTriggered
    }

    private mutating func triggerIfNeeded(shortcutPressed: Bool, activationMode: DragShortcut.ActivationMode) -> Bool {
        guard hasDragged else { return false }
        if !shortcutPressed { shortcutReleasedDuringDrag = true }
        guard shortcutPressed, !didTrigger, !cancelled else { return false }
        switch activationMode {
        case .beforeDrag:
            guard shortcutPressedAtDragStart == true else { return false }
        case .duringDrag:
            guard shortcutPressedAtDragStart == false || shortcutReleasedDuringDrag else { return false }
        case .either:
            break
        }
        didTrigger = true
        return true
    }
}
