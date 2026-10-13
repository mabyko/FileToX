import Foundation

struct PermissionOnboarding {
    enum Step { case intro, waiting, success }

    private(set) var step: Step?
    private(set) var pendingInitialPresentation = false
    private var isInitialPresentation = false
    private var pendingFileOpens = 0
    var didCheckPermission = false
    var settingsOpenFailed = false

    mutating func begin(hasCompleted: Bool) {
        pendingInitialPresentation = !hasCompleted
    }

    mutating func presentIfNeeded(hasPermission: Bool, isBusy: Bool) {
        guard pendingInitialPresentation, pendingFileOpens == 0, !isBusy, step == nil else { return }
        present(hasPermission: hasPermission)
        pendingInitialPresentation = false
        isInitialPresentation = true
    }

    mutating func present(hasPermission: Bool) {
        step = hasPermission ? .success : .intro
        isInitialPresentation = false
        didCheckPermission = false
        settingsOpenFailed = false
    }

    mutating func fileOpenStarted() {
        pendingFileOpens += 1
        if isInitialPresentation {
            step = nil
            pendingInitialPresentation = true
            isInitialPresentation = false
        }
    }

    mutating func fileOpenFinished() { pendingFileOpens = max(0, pendingFileOpens - 1) }

    mutating func settingsRequested() {
        step = .waiting
        didCheckPermission = false
        settingsOpenFailed = false
    }

    mutating func updatePermission(_ granted: Bool) {
        guard step != nil else { return }
        if granted { step = .success; settingsOpenFailed = false }
        else if step == .success { step = .waiting }
    }

    mutating func complete() {
        step = nil
        pendingInitialPresentation = false
        isInitialPresentation = false
    }
}
