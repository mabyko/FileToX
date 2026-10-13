import Foundation
import XCTest
@testable import FileToX

final class PermissionOnboardingTests: XCTestCase {
    func testFirstLaunchShowsIntroAndAlreadyGrantedShowsSuccess() {
        for granted in [false, true] {
            var onboarding = PermissionOnboarding()
            onboarding.begin(hasCompleted: false)
            onboarding.presentIfNeeded(hasPermission: granted, isBusy: false)
            XCTAssertEqual(onboarding.step, granted ? .success : .intro)
            XCTAssertFalse(onboarding.pendingInitialPresentation)
        }
    }

    func testRequestWaitsForActualGrantAndRevocationUpdatesOpenSheet() {
        var onboarding = PermissionOnboarding()
        onboarding.present(hasPermission: false)
        onboarding.settingsRequested()
        onboarding.updatePermission(false)
        XCTAssertEqual(onboarding.step, .waiting)
        onboarding.settingsOpenFailed = true
        onboarding.updatePermission(true)
        XCTAssertEqual(onboarding.step, .success)
        XCTAssertFalse(onboarding.settingsOpenFailed)
        onboarding.updatePermission(false)
        XCTAssertEqual(onboarding.step, .waiting)
    }

    func testCompletedOnboardingStaysClosedUntilExplicitlyOpened() {
        var onboarding = PermissionOnboarding()
        onboarding.begin(hasCompleted: false)
        onboarding.presentIfNeeded(hasPermission: false, isBusy: false)
        onboarding.complete()
        onboarding.updatePermission(true)
        onboarding.presentIfNeeded(hasPermission: true, isBusy: false)
        XCTAssertNil(onboarding.step)
        onboarding.begin(hasCompleted: true)
        onboarding.presentIfNeeded(hasPermission: false, isBusy: false)
        XCTAssertNil(onboarding.step)
        onboarding.present(hasPermission: false)
        XCTAssertEqual(onboarding.step, .intro)
    }

    func testFileOpenDefersInitialSheetUntilAllFilesAndConversionAreDone() {
        var onboarding = PermissionOnboarding()
        onboarding.fileOpenStarted()
        onboarding.fileOpenStarted()
        onboarding.begin(hasCompleted: false)
        onboarding.presentIfNeeded(hasPermission: false, isBusy: false)
        XCTAssertNil(onboarding.step)
        onboarding.fileOpenFinished()
        onboarding.presentIfNeeded(hasPermission: false, isBusy: false)
        XCTAssertNil(onboarding.step)
        onboarding.fileOpenFinished()
        onboarding.presentIfNeeded(hasPermission: false, isBusy: true)
        XCTAssertNil(onboarding.step)
        XCTAssertTrue(onboarding.pendingInitialPresentation)
        onboarding.presentIfNeeded(hasPermission: false, isBusy: false)
        XCTAssertEqual(onboarding.step, .intro)
    }

    func testLateFileOpenHidesInitialSheetWithoutCompletingIt() {
        var onboarding = PermissionOnboarding()
        onboarding.begin(hasCompleted: false)
        onboarding.presentIfNeeded(hasPermission: false, isBusy: false)
        onboarding.fileOpenStarted()
        XCTAssertNil(onboarding.step)
        XCTAssertTrue(onboarding.pendingInitialPresentation)
        onboarding.fileOpenFinished()
        onboarding.presentIfNeeded(hasPermission: true, isBusy: false)
        XCTAssertEqual(onboarding.step, .success)
    }

    @MainActor
    func testOnlyExplicitCompletionIsPersistedAndSurvivesRelaunch() throws {
        let suite = "FileToX-permission-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.hasAccessibilityPermission = false
        model.beginPermissionOnboarding()
        XCTAssertEqual(model.permissionOnboarding.step, .intro)
        XCTAssertFalse(defaults.bool(forKey: "hasCompletedPermissionOnboarding"))
        model.permissionOnboarding.settingsRequested()
        XCTAssertFalse(defaults.bool(forKey: "hasCompletedPermissionOnboarding"))
        model.completePermissionOnboarding()
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedPermissionOnboarding"))
        let relaunched = AppModel(defaults: defaults)
        relaunched.beginPermissionOnboarding()
        XCTAssertNil(relaunched.permissionOnboarding.step)
    }
}
