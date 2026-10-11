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

    mutating func mouseDragged(to point: CGPoint, optionPressed: Bool) -> Bool {
        if let origin {
            hasDragged = hasDragged || abs(point.x - origin.x) > 4 || abs(point.y - origin.y) > 4
        } else {
            hasDragged = true
        }
        return triggerIfNeeded(optionPressed: optionPressed)
    }

    mutating func flagsChanged(optionPressed: Bool, leftButtonPressed: Bool) -> Bool {
        guard leftButtonPressed else { return false }
        return triggerIfNeeded(optionPressed: optionPressed)
    }

    mutating func cancel() -> Bool {
        let wasTriggered = didTrigger
        didTrigger = false
        cancelled = true
        return wasTriggered
    }

    @discardableResult
    mutating func finish() -> Bool {
        let wasTriggered = didTrigger
        self = DragGestureState()
        return wasTriggered
    }

    private mutating func triggerIfNeeded(optionPressed: Bool) -> Bool {
        guard hasDragged, optionPressed, !didTrigger, !cancelled else { return false }
        didTrigger = true
        return true
    }
}
