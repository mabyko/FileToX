import AppKit
import UserNotifications

struct ConversionNotification {
    let title: String
    let body: String
    let outputs: [String]

    @MainActor
    init?(job: HostJob, preferences: ApplicationPreferences) {
        let failed: Bool
        switch job.state.lowercased() {
        case "completed": failed = false
        case "completedwitherrors", "failed": failed = true
        default: return nil
        }
        guard failed ? preferences.notifyOnFailure : preferences.notifyOnSuccess else { return nil }
        title = L(failed ? "notifications.failed.title" : "notifications.completed.title")
        body = "\(job.preset?.libraryName ?? job.presetName) · \(AppModel.stateTitle(job.state))"
        outputs = NSOrderedSet(array: job.outputs.map(\.path) + (job.historyEntry?.outputs ?? [])).array
            .compactMap { $0 as? String }
    }
}

@MainActor
final class ConversionNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (([String]) -> Void)?
    var onError: ((String) -> Void)?

    func start() { UNUserNotificationCenter.current().delegate = self }

    func send(_ job: HostJob, preferences: ApplicationPreferences) async {
        guard let payload = ConversionNotification(job: job, preferences: preferences) else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.userInfo = ["outputs": payload.outputs]
        do { try await center.add(UNNotificationRequest(identifier: "conversion-" + job.jobId, content: content, trigger: nil)) }
        catch { onError?(error.localizedDescription) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let paths = response.notification.request.content.userInfo["outputs"] as? [String] ?? []
        await MainActor.run { onOpen?(paths) }
    }
}
