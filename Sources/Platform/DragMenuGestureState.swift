import AppKit

enum RadialMenuKind: String, CaseIterable, Identifiable {
    case convert, tools
    var id: String { rawValue }
    @MainActor var title: String { L(self == .convert ? "menu.convert" : "menu.tools") }
}

/// Activation order applies to opening; an open menu can switch without restarting the drag.
struct DragMenuGestureState {
    private var gestures: [RadialMenuKind: DragGestureState] = [:]
    private(set) var activeMenu: RadialMenuKind?
    private var cancelled = false

    mutating func mouseDown(at point: CGPoint) {
        self = Self()
        for kind in RadialMenuKind.allCases {
            var gesture = DragGestureState()
            gesture.mouseDown(at: point)
            gestures[kind] = gesture
        }
    }

    mutating func update(point: CGPoint? = nil, pressed: RadialMenuKind?, leftButtonPressed: Bool,
                         shortcuts: [RadialMenuKind: DragShortcut]) -> RadialMenuKind? {
        guard leftButtonPressed, !cancelled else { return nil }
        if let activeMenu {
            guard let pressed, pressed != activeMenu else { return nil }
            self.activeMenu = pressed
            return pressed
        }
        var triggered: RadialMenuKind?
        for kind in RadialMenuKind.allCases {
            var gesture = gestures[kind] ?? DragGestureState()
            let mode = shortcuts[kind]?.activationMode ?? .either
            let opens: Bool
            if let point {
                opens = gesture.mouseDragged(to: point, shortcutPressed: pressed == kind, activationMode: mode)
            } else {
                opens = gesture.flagsChanged(shortcutPressed: pressed == kind, leftButtonPressed: true, activationMode: mode)
            }
            gestures[kind] = gesture
            if opens { triggered = kind }
        }
        activeMenu = triggered
        return triggered
    }

    mutating func retryTrigger() {
        activeMenu = nil
        for kind in RadialMenuKind.allCases { gestures[kind]?.retryTrigger() }
    }

    mutating func cancel() -> Bool {
        let hadMenu = activeMenu != nil
        cancelled = true
        activeMenu = nil
        return hadMenu
    }

    mutating func finish() -> Bool {
        let hadMenu = activeMenu != nil
        self = Self()
        return hadMenu
    }
}
