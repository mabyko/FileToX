import AppKit

@MainActor
final class GlobalDragMonitor {
    var onTrigger: ((NSPoint, RadialMenuKind) -> Void)?
    var onSwitch: ((RadialMenuKind) -> Void)?
    var onEnd: (() -> Void)?
    var shortcuts: () -> [RadialMenuKind: DragShortcut] = { [.convert: .standard, .tools: .toolsStandard] }
    var isApplicationExcluded: (String?) -> Bool = { _ in false }

    var isMonitoring: Bool { globalMonitor != nil && localMonitor != nil }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var releaseTimer: Timer?
    private var gesture = DragMenuGestureState()
    private var pasteboardGate = DragPasteboardGate()
    private var pendingTrigger: Task<Void, Never>?
    private var presented = false
    private var excludedDrag = false

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocal(event) }
            return event
        }
        if !isMonitoring { stop() }
    }

    private func handleLocal(_ event: NSEvent) {
        // Local events only clean up external drags; the monitor ignores the app's own process.
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            endDrag()
        case .flagsChanged where NSEvent.pressedMouseButtons & 1 == 0:
            endDrag()
        case .keyDown, .keyUp:
            handle(event)
        default:
            break
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        endDrag()
    }

    func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            endDrag()
            // The event target also identifies clicks in a window that wasn't frontmost yet.
            let targetPID = event.cgEvent?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0
            let source = targetPID > 0 ? NSRunningApplication(processIdentifier: pid_t(targetPID)) : nil
            excludedDrag = isApplicationExcluded(source?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        if excludedDrag {
            if event.type == .leftMouseUp { endDrag() }
            return
        }
        let point = NSEvent.mouseLocation
        let configured = shortcuts()
        let pressed = DragMenuGestureState.matchingMenu(shortcuts: configured, modifiers: event.modifierFlags) { code in
            (event.type == .keyDown || event.type == .keyUp) && event.keyCode == code
                ? event.type == .keyDown : CGEventSource.keyState(.combinedSessionState, key: code)
        }
        if pressed != gesture.activeMenu, pendingTrigger != nil {
            cancelPendingTrigger()
            gesture.retryTrigger()
        }
        var triggered: RadialMenuKind?
        switch event.type {
        case .leftMouseDown:
            pasteboardGate.begin(changeCount: NSPasteboard(name: .drag).changeCount)
            gesture.mouseDown(at: point)
        case .leftMouseDragged:
            triggered = gesture.update(point: point, pressed: pressed, leftButtonPressed: true, shortcuts: configured)
        case .flagsChanged:
            let leftButtonPressed = NSEvent.pressedMouseButtons & 1 != 0
            if !leftButtonPressed { endDrag() }
            triggered = gesture.update(pressed: pressed, leftButtonPressed: leftButtonPressed, shortcuts: configured)
        case .leftMouseUp:
            endDrag()
        case .keyDown where event.keyCode == 53:
            if gesture.cancel() { onEnd?() }
            cancelPendingTrigger()
            pasteboardGate.end()
            releaseTimer?.invalidate()
            releaseTimer = nil
        case .keyDown, .keyUp:
            guard configured.values.contains(where: { $0.keyCode == event.keyCode }) else { return }
            triggered = gesture.update(pressed: pressed, leftButtonPressed: NSEvent.pressedMouseButtons & 1 != 0, shortcuts: configured)
        default:
            break
        }
        if let triggered {
            if presented { onSwitch?(triggered); return }
            watchForRelease()
            waitForFileDrag(at: point, menu: triggered)
        }
    }

    private func waitForFileDrag(at point: NSPoint, menu: RadialMenuKind) {
        pendingTrigger?.cancel()
        let generation = pasteboardGate.generation
        pendingTrigger = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let leftButtonPressed = NSEvent.pressedMouseButtons & 1 != 0
                guard let configuredShortcut = shortcuts()[menu] else { cancelPendingTrigger(); gesture.retryTrigger(); return }
                let keyPressed = configuredShortcut.keyCode.map { CGEventSource.keyState(.combinedSessionState, key: $0) } ?? false
                let shortcutPressed = configuredShortcut.matches(modifiers: NSEvent.modifierFlags, keyPressed: keyPressed)
                guard leftButtonPressed else { endDrag(); return }
                guard shortcutPressed else { cancelPendingTrigger(); gesture.retryTrigger(); return }
                let pasteboard = NSPasteboard(name: .drag)
                let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
                let hasFiles = objects.compactMap { $0 as? URL }.contains {
                    $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
                }
                if pasteboardGate.accepts(changeCount: pasteboard.changeCount, hasFileURLs: hasFiles,
                                          leftButtonPressed: leftButtonPressed, shortcutPressed: shortcutPressed, generation: generation) {
                    pendingTrigger = nil
                    presented = true
                    onTrigger?(point, menu)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return }
            }
        }
    }

    private func cancelPendingTrigger() {
        pendingTrigger?.cancel()
        pendingTrigger = nil
    }

    private func watchForRelease() {
        releaseTimer?.invalidate()
        // AppKit drag tracking can consume mouse-up before an event monitor sees it.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag() }
            }
        }
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endDrag() {
        cancelPendingTrigger()
        pasteboardGate.end()
        releaseTimer?.invalidate()
        releaseTimer = nil
        if gesture.finish() { onEnd?() }
        presented = false
        excludedDrag = false
    }

    isolated deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        releaseTimer?.invalidate()
        pendingTrigger?.cancel()
    }
}
