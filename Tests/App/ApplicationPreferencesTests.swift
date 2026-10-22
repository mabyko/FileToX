import AppKit
import ServiceManagement
import XCTest
@testable import FileToX

final class ApplicationPreferencesTests: XCTestCase {
    @MainActor
    func testDefaultsPersistenceAndExcludedApplicationIdentity() throws {
        let suite = "filetox-application-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TestLoginItemService()
        let preferences = ApplicationPreferences(defaults: defaults, loginService: service)
        XCTAssertTrue(preferences.showMenuBarIcon)
        XCTAssertFalse(preferences.openWindowAtLogin)
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertFalse(preferences.notifyOnSuccess)
        XCTAssertFalse(preferences.notifyOnFailure)

        preferences.showMenuBarIcon = false
        preferences.openWindowAtLogin = true
        preferences.notifyOnSuccess = true
        preferences.notifyOnFailure = true
        preferences.addExcludedApplication(.init(bundleIdentifier: "com.apple.finder", name: "Finder"))
        preferences.addExcludedApplication(.init(bundleIdentifier: "com.apple.finder", name: "Renamed Finder"))
        preferences.addExcludedApplication(.init(bundleIdentifier: "", name: "Invalid"))
        let restored = ApplicationPreferences(defaults: defaults, loginService: service)
        XCTAssertFalse(restored.showMenuBarIcon)
        XCTAssertTrue(restored.openWindowAtLogin)
        XCTAssertTrue(restored.notifyOnSuccess)
        XCTAssertTrue(restored.notifyOnFailure)
        XCTAssertEqual(restored.excludedApplications.count, 1)
        XCTAssertTrue(restored.excludes("com.apple.finder"))
        XCTAssertFalse(restored.excludes("com.apple.TextEdit"))
        XCTAssertFalse(restored.excludes(nil))
        restored.removeExcludedApplication("com.apple.finder")
        XCTAssertTrue(ApplicationPreferences(defaults: defaults, loginService: service).excludedApplications.isEmpty)
    }

    @MainActor
    func testLoginRegistrationApprovalFailureAndExternalChanges() throws {
        let suite = "filetox-login-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TestLoginItemService()
        let preferences = ApplicationPreferences(defaults: defaults, loginService: service)
        preferences.setLaunchAtLogin(true)
        XCTAssertEqual(preferences.loginStatus, .requiresApproval)
        XCTAssertTrue(preferences.launchAtLogin)
        XCTAssertEqual(service.registrations, 1)
        preferences.setLaunchAtLogin(true)
        XCTAssertEqual(service.registrations, 1, "Do not register an already registered service")
        service.status = .enabled
        preferences.refreshLoginStatus()
        XCTAssertEqual(preferences.loginStatus, .enabled)
        service.shouldFail = true
        preferences.setLaunchAtLogin(false)
        XCTAssertTrue(preferences.launchAtLogin, "A failed unregister must preserve the actual OS state")
        XCTAssertNotNil(preferences.loginError)
        service.shouldFail = false
        preferences.setLaunchAtLogin(false)
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertNil(preferences.loginError)
        service.shouldFail = true
        preferences.setLaunchAtLogin(true)
        XCTAssertFalse(preferences.launchAtLogin, "A failed register must not pretend the service is enabled")
    }

    func testOnlyLoginLaunchesRespectOpenWindowPreference() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertTrue(ApplicationLaunch.shouldOpenWindow(event: nil, openWindowAtLogin: false))
        XCTAssertTrue(ApplicationLaunch.shouldOpenWindow(event: event, openWindowAtLogin: false))
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        XCTAssertFalse(ApplicationLaunch.shouldOpenWindow(event: event, openWindowAtLogin: false))
        XCTAssertTrue(ApplicationLaunch.shouldOpenWindow(event: event, openWindowAtLogin: true))
    }
}

@MainActor
private final class TestLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var shouldFail = false
    var registrations = 0
    func register() throws {
        if shouldFail { throw NSError(domain: "test", code: 1) }
        registrations += 1
        status = .requiresApproval
    }
    func unregister() throws {
        if shouldFail { throw NSError(domain: "test", code: 2) }
        status = .notRegistered
    }
}
