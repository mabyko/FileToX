import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationSettingsSections: View {
    @Bindable var preferences: ApplicationPreferences

    var body: some View {
        Section {
            Toggle(L("settings.launchAtLogin"), isOn: Binding(get: { preferences.launchAtLogin }, set: preferences.setLaunchAtLogin))
            if preferences.loginStatus == .requiresApproval {
                Label(L("settings.login.approval"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button(L("settings.login.open")) { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = preferences.loginError {
                Text(L("settings.login.error", error)).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Toggle(L("settings.showMenuBar"), isOn: $preferences.showMenuBarIcon)
            Toggle(L("settings.openWindowAtLogin"), isOn: $preferences.openWindowAtLogin)
        } header: {
            Text(L("settings.application"))
        } footer: {
            Text(L("settings.application.help"))
        }
        Section {
            Toggle(L("notifications.success"), isOn: notificationBinding(forFailure: false))
            Toggle(L("notifications.failure"), isOn: notificationBinding(forFailure: true))
            if preferences.notificationStatus == .denied && (preferences.notifyOnSuccess || preferences.notifyOnFailure) {
                Label(L("notifications.denied"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button(L("notifications.openSettings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            if let error = preferences.notificationError {
                Text(L("notifications.permission.error", error)).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text(L("notifications.section"))
        } footer: {
            Text(L("notifications.help"))
        }
        .disabled(preferences.isRequestingNotifications)
        .task {
            preferences.refreshLoginStatus()
            await preferences.refreshNotificationStatus()
        }
    }

    private func notificationBinding(forFailure: Bool) -> Binding<Bool> {
        Binding(get: { forFailure ? preferences.notifyOnFailure : preferences.notifyOnSuccess }, set: { enabled in
            Task { await preferences.setNotificationsEnabled(enabled, forFailure: forFailure) }
        })
    }
}

struct ExcludedApplicationsSection: View {
    let preferences: ApplicationPreferences
    @State private var selectionError: String?

    var body: some View {
        Section {
            if preferences.excludedApplications.isEmpty {
                Text(L("settings.excluded.empty")).foregroundStyle(.secondary)
            }
            ForEach(preferences.excludedApplications) { application in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(application.name)
                        Text(application.bundleIdentifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        preferences.removeExcludedApplication(application.bundleIdentifier)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("settings.excluded.remove", application.name))
                    .help(L("settings.excluded.remove", application.name))
                }
            }
            Button(L("settings.excluded.add"), action: chooseApplication)
            if let selectionError {
                Text(selectionError).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text(L("settings.excluded.title"))
        } footer: {
            Text(L("settings.excluded.help"))
        }
    }

    private func chooseApplication() {
        selectionError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.title = L("settings.excluded.add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            selectionError = L("settings.excluded.invalid")
            return
        }
        preferences.addExcludedApplication(ExcludedApplication(bundleIdentifier: identifier,
            name: FileManager.default.displayName(atPath: url.path)))
    }
}
