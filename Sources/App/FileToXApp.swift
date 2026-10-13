import SwiftUI

@main
struct FileToXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("FileToX", image: "MenuBarIcon") {
            Button(L("FileToX 열기")) { delegate.showConverterWindow() }.keyboardShortcut("o")
            Text(delegate.model.statusMessage)
            Button(delegate.model.isDragEnabled ? L("드래그 호출 일시 정지") : L("드래그 호출 재개")) {
                guard var settings = delegate.model.library?.settings else { return }
                settings["paused"] = .bool(delegate.model.isDragEnabled)
                Task { await delegate.model.saveSettings(settings) }
            }.disabled(!delegate.model.isConnected)
            ForEach(delegate.model.activeJobs, id: \.jobId) { job in
                Button(L("%@ 취소", job.preset?.libraryName ?? job.presetName)) { Task { await delegate.model.cancel(jobID: job.jobId) } }
                    .disabled(delegate.model.cancellingJobIDs.contains(job.jobId))
            }
            Divider()
            Button(L("FileToX 정보")) { delegate.showAbout() }
            Button(L("종료")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
