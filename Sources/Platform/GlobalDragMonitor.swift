import AppKit

@MainActor
final class GlobalDragMonitor {
    var onTrigger: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?

    var isMonitoring: Bool { globalMonitor != nil && localMonitor != nil }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var releaseTimer: Timer?
    private var gesture = DragGestureState()
    private var pasteboardGate = DragPasteboardGate()
    private var pendingTrigger: Task<Void, Never>?

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events.union(.keyDown)) { [weak self] event in
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
        case .keyDown where event.keyCode == 53:
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

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let optionPressed = event.modifierFlags.contains(.option)
        var triggered = false
        switch event.type {
        case .leftMouseDown:
            endDrag()
            pasteboardGate.begin(changeCount: NSPasteboard(name: .drag).changeCount)
            gesture.mouseDown(at: point)
        case .leftMouseDragged:
            triggered = gesture.mouseDragged(to: point, optionPressed: optionPressed)
        case .flagsChanged:
            let leftButtonPressed = NSEvent.pressedMouseButtons & 1 != 0
            if !leftButtonPressed { endDrag() }
            if !optionPressed { cancelPendingTrigger() }
            triggered = gesture.flagsChanged(optionPressed: optionPressed, leftButtonPressed: leftButtonPressed)
        case .leftMouseUp:
            endDrag()
        case .keyDown where event.keyCode == 53:
            if gesture.cancel() { onEnd?() }
            cancelPendingTrigger()
            releaseTimer?.invalidate()
            releaseTimer = nil
        default:
            break
        }
        if triggered {
            watchForRelease()
            waitForFileDrag(at: point)
        }
    }

    private func waitForFileDrag(at point: NSPoint) {
        pendingTrigger?.cancel()
        let generation = pasteboardGate.generation
        pendingTrigger = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let leftButtonPressed = NSEvent.pressedMouseButtons & 1 != 0
                let optionPressed = NSEvent.modifierFlags.contains(.option)
                guard leftButtonPressed, optionPressed else { cancelPendingTrigger(); return }
                let pasteboard = NSPasteboard(name: .drag)
                let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
                let hasFiles = objects.compactMap { $0 as? URL }.contains {
                    $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
                }
                if pasteboardGate.accepts(changeCount: pasteboard.changeCount, hasFileURLs: hasFiles,
                                          leftButtonPressed: leftButtonPressed, optionPressed: optionPressed, generation: generation) {
                    pendingTrigger = nil
                    onTrigger?(point)
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
        pasteboardGate.end()
    }

    private func watchForRelease() {
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
        releaseTimer?.invalidate()
        releaseTimer = nil
        if gesture.finish() { onEnd?() }
    }

    isolated deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        releaseTimer?.invalidate()
        pendingTrigger?.cancel()
    }
}
