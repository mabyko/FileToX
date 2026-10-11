import AppKit
import SwiftUI

@MainActor
final class ConversionPanelController {
    private let panel: ConversionPanel
    private let model: AppModel
    private var pendingHide: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        panel = ConversionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        // A fully transparent waiting window is excluded from native drag hit testing.
        panel.backgroundColor = NSColor.black.withAlphaComponent(1 / 255)
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: FormatDropView(model: model))
    }

    func show(at point: NSPoint, clickMode: Bool = false) {
        pendingHide?.cancel()
        pendingHide = nil
        panel.allowsKey = clickMode
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let side = model.radialOuterRadius * 2 + 42
        panel.setFrame(PanelPlacement.frame(near: point, size: NSSize(width: side, height: side), visibleFrame: screen.visibleFrame), display: true)
        if clickMode { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
    }

    func scheduleDragEnd() {
        pendingHide?.cancel()
        // AppKit may deliver performDragOperation after the global mouse-up event.
        pendingHide = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, model.radialJobID == nil, !model.isStarting, !model.radialClickMode else { return }
            model.closeRadial()
        }
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        panel.orderOut(nil)
    }
}

private final class ConversionPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
