import AppKit
import SwiftUI

@MainActor
final class ProgressToastController {
    private let panel: NSPanel
    init(model: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 210), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("FileToX 변환 진행")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ProgressToastView(model: model) { [weak self] in self?.panel.orderOut(nil) })
    }
    func show() {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 20, y: screen.visibleFrame.minY + 20))
        }
        panel.orderFrontRegardless()
    }
}

private struct ProgressToastView: View {
    let model: AppModel
    let onEmpty: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.activeJobs, id: \.jobId) { job in JobCard(model: model, job: job) }
            }.padding(12)
        }.frame(width: 420)
            .onChange(of: model.activeJobs.count) { _, count in if count == 0 { onEmpty() } }
    }
}
