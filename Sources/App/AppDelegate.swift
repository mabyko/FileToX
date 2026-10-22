import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var converterWindow: NSWindow?
    private var panel: ConversionPanelController?
    private var dragMonitor: GlobalDragMonitor?
    private var progressToast: ProgressToastController?
    private var presetWindow: NSWindow?
    private let notifications = ConversionNotifications()
    private var needsDragMonitorRestart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        notifications.start()
        notifications.onOpen = { [weak self] paths in
            guard let self else { return }
            let existing = ConversionNotification.existingOutputs(paths)
            if existing.isEmpty {
                model.selectedPage = "home"
                showConverterWindow()
            } else { model.reveal(existing) }
        }
        notifications.onError = { [weak self] error in
            self?.model.statusMessage = L("notifications.delivery.error", error)
        }
        model.onJobFinished = { [weak self] job in
            Task { [weak self] in
                guard let self else { return }
                await notifications.send(job, preferences: model.applicationPreferences)
            }
        }
        panel = ConversionPanelController(model: model)
        model.onShowRadial = { [weak self] point, clickMode in self?.panel?.show(at: point, clickMode: clickMode) }
        model.onCloseRadial = { [weak self] in self?.panel?.hide() }
        progressToast = ProgressToastController(model: model)
        model.onLongJob = { [weak self] in self?.progressToast?.show() }
        model.onEditPreset = { [weak self] id in self?.showPresetEditor(id) }
        let monitor = GlobalDragMonitor()
        monitor.isApplicationExcluded = { [weak self] in self?.model.applicationPreferences.excludes($0) ?? false }
        monitor.shortcuts = { [weak self] in self?.model.dragShortcuts ?? [.convert: .standard, .tools: .toolsStandard] }
        monitor.onTrigger = { [weak self] point, menu in
            guard let self, model.isDragEnabled else { return }
            model.prepareForDrag(menu: menu)
            panel?.show(at: point)
        }
        monitor.onSwitch = { [weak self] menu in self?.model.switchRadialMenu(menu) }
        monitor.onEnd = { [weak self] in
            self?.panel?.scheduleDragEnd()
            self?.restartDragMonitorIfNeeded()
        }
        monitor.start()
        dragMonitor = monitor
        model.onAccessibilityPermissionGranted = { [weak self] in
            self?.needsDragMonitorRestart = true
            self?.restartDragMonitorIfNeeded()
        }
        if ApplicationLaunch.shouldOpenWindow(event: NSAppleEventManager.shared().currentAppleEvent,
                                               openWindowAtLogin: model.applicationPreferences.openWindowAtLogin) {
            showConverterWindow()
        }
        Task {
            await model.connect()
            model.refreshPermission()
            model.beginPermissionOnboarding()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermission()
        model.applicationPreferences.refreshLoginStatus()
        Task { await model.applicationPreferences.refreshNotificationStatus() }
    }

    func showSettings() {
        model.selectedPage = "general"
        showConverterWindow()
    }

    func showConverterWindow() {
        if converterWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FileToX"
            window.contentView = NSHostingView(rootView: ConverterView(model: model))
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.isReleasedWhenClosed = false
            window.center()
            converterWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        converterWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConverterWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.permissionOnboarding.fileOpenStarted()
        showConverterWindow()
        Task {
            await model.connect()
            await model.resolve(urls)
            model.permissionOnboarding.fileOpenFinished()
            model.presentInitialPermissionOnboardingIfNeeded()
        }
    }

    private func restartDragMonitorIfNeeded() {
        guard needsDragMonitorRestart, NSEvent.pressedMouseButtons == 0 else { return }
        needsDragMonitorRestart = false
        dragMonitor?.stop()
        dragMonitor?.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isConverting {
            let alert = NSAlert()
            alert.messageText = L("진행 중인 변환을 취소하고 종료할까요?")
            alert.informativeText = L("이미 완료된 결과와 원본 파일은 그대로 유지됩니다.")
            alert.addButton(withTitle: L("계속 변환"))
            alert.addButton(withTitle: L("취소하고 종료"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor?.stop()
        panel?.hide()
    }

    private func showPresetEditor(_ id: String) {
        guard let preset = model.library?.presets.first(where: { $0.identity == id }) else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("프리셋 편집")
        window.contentMinSize = NSSize(width: 500, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PresetEditorPopup(model: model, preset: preset) { [weak window] in window?.close() })
        window.center()
        presetWindow?.close()
        presetWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        let copyright = "Filee · MIT License"
        let license = Bundle.main.url(forResource: "Filee", withExtension: "LICENSE")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? copyright
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "FileToX",
            .credits: NSAttributedString(string: L("about.description") + "\n\n" + license)
        ])
    }
}
