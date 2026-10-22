import AppKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

struct ExcludedApplication: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

/// Mac-specific preferences are independent of the conversion engine's settings.
@MainActor @Observable
final class ApplicationPreferences {
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    var openWindowAtLogin: Bool { didSet { defaults.set(openWindowAtLogin, forKey: "openWindowAtLogin") } }
    var notifyOnSuccess: Bool { didSet { defaults.set(notifyOnSuccess, forKey: "notifyOnSuccess") } }
    var notifyOnFailure: Bool { didSet { defaults.set(notifyOnFailure, forKey: "notifyOnFailure") } }
    private(set) var excludedApplications: [ExcludedApplication]
    private(set) var loginStatus: SMAppService.Status = .notRegistered
    private(set) var loginError: String?
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var notificationError: String?
    private(set) var isRequestingNotifications = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loginService: any LoginItemService

    init(defaults: UserDefaults = .standard, loginService: any LoginItemService = SystemLoginItemService()) {
        self.defaults = defaults
        self.loginService = loginService
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        openWindowAtLogin = defaults.bool(forKey: "openWindowAtLogin")
        notifyOnSuccess = defaults.bool(forKey: "notifyOnSuccess")
        notifyOnFailure = defaults.bool(forKey: "notifyOnFailure")
        excludedApplications = defaults.data(forKey: "excludedApplications")
            .flatMap { try? JSONDecoder().decode([ExcludedApplication].self, from: $0) } ?? []
        refreshLoginStatus()
    }

    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func refreshLoginStatus() { loginStatus = loginService.status }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        refreshLoginStatus()
        do {
            if enabled, !launchAtLogin { try loginService.register() }
            if !enabled, launchAtLogin { try loginService.unregister() }
        } catch { loginError = error.localizedDescription }
        refreshLoginStatus()
    }

    func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func setNotificationsEnabled(_ enabled: Bool, forFailure: Bool) async {
        guard !isRequestingNotifications else { return }
        notificationError = nil
        if forFailure { notifyOnFailure = enabled } else { notifyOnSuccess = enabled }
        guard enabled else { return }
        isRequestingNotifications = true
        defer { isRequestingNotifications = false }
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
        catch { notificationError = error.localizedDescription }
        await refreshNotificationStatus()
    }

    func excludes(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func addExcludedApplication(_ application: ExcludedApplication) {
        guard !application.bundleIdentifier.isEmpty, !excludes(application.bundleIdentifier) else { return }
        excludedApplications.append(application)
        persistExcludedApplications()
    }

    func removeExcludedApplication(_ bundleIdentifier: String) {
        excludedApplications.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persistExcludedApplications()
    }

    private func persistExcludedApplications() {
        if let data = try? JSONEncoder().encode(excludedApplications) { defaults.set(data, forKey: "excludedApplications") }
    }
}

enum ApplicationLaunch {
    static func shouldOpenWindow(event: NSAppleEventDescriptor?, openWindowAtLogin: Bool) -> Bool {
        let loginLaunch = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        return !loginLaunch || openWindowAtLogin
    }
}
