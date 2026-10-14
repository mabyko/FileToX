import CoreGraphics

// Drag gesture state machine; third-party notice: Resources/Filee.LICENSE.
struct DragGestureState {
    private var origin: CGPoint?
    private var hasDragged = false
    private var didTrigger = false
    private var cancelled = false

    mutating func mouseDown(at point: CGPoint) {
        self = DragGestureState()
        origin = point
    }

    mutating func mouseDragged(to point: CGPoint, shortcutPressed: Bool) -> Bool {
        if let origin {
            hasDragged = hasDragged || abs(point.x - origin.x) > 4 || abs(point.y - origin.y) > 4
        } else {
            hasDragged = true
        }
        return triggerIfNeeded(shortcutPressed: shortcutPressed)
    }

    mutating func flagsChanged(shortcutPressed: Bool, leftButtonPressed: Bool) -> Bool {
        guard leftButtonPressed else { return false }
        return triggerIfNeeded(shortcutPressed: shortcutPressed)
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

    private mutating func triggerIfNeeded(shortcutPressed: Bool) -> Bool {
        guard hasDragged, shortcutPressed, !didTrigger, !cancelled else { return false }
        didTrigger = true
        return true
    }
}
