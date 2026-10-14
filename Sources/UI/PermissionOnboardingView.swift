import AppKit
import SwiftUI

struct PermissionOnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showHelp = false

    private var step: PermissionOnboarding.Step { model.permissionOnboarding.step ?? .intro }
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FileToX"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                if step == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40)).foregroundStyle(.green)
                        .frame(width: 56, height: 56).accessibilityHidden(true)
                } else {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                }
                Text(title).font(.system(size: 22, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            Text(message).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if step != .success {
                VStack(alignment: .leading, spacing: 12) {
                    instruction(1, L("permission.step.settings"))
                    instruction(2, L("permission.step.enable", appName))
                    instruction(3, L("permission.step.return", appName))
                }
                if step == .intro {
                    Divider()
                    Text(L("permission.optional")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if step != .intro {
                Label(status, systemImage: step == .success ? "checkmark.circle" : "clock")
                    .font(.callout).foregroundStyle(step == .success ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .fileeCard(padding: 12).accessibilityIdentifier("permission.status")
            }
            if model.permissionOnboarding.settingsOpenFailed {
                Text(L("permission.settings.failed", appName)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step != .success {
                VStack(alignment: .leading, spacing: 10) {
                    if step == .waiting {
                        Button(L("permission.settings.reopen"), action: model.requestAccessibilityPermission)
                            .buttonStyle(.link)
                    }
                    DisclosureGroup(L("permission.help.title"), isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("permission.help.add", appName))
                            Text(Bundle.main.bundleURL.path).textSelection(.enabled)
                            Text(L("permission.help.restart"))
                        }.font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }.font(.caption)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                if step != .success {
                    Button(L("permission.later"), action: finish).keyboardShortcut(.cancelAction)
                }
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("permission.primary")
            }.controlSize(.large)
        }
        .padding(24).frame(width: 500)
        .tint(model.accentColor).preferredColorScheme(model.themeColorScheme)
        .environment(\.locale, Locale(identifier: model.language.rawValue))
        .animation(Motion.when(!model.reduceMotion, Motion.quick), value: step)
        .onExitCommand(perform: finish)
    }

    private var title: String {
        switch step {
        case .intro: L("permission.intro.title")
        case .waiting: L("permission.waiting.title", appName)
        case .success: L("permission.success.title")
        }
    }

    private var message: String {
        switch step {
        case .intro: L("permission.intro.message", model.dragShortcut.displayName)
        case .waiting: L("permission.waiting.message")
        case .success: L("permission.success.message", model.dragShortcut.displayName)
        }
    }

    private var status: String {
        if step == .success { return L("손쉬운 사용 권한 허용됨") }
        return model.permissionOnboarding.didCheckPermission ? L("permission.waiting.unconfirmed", appName) : L("permission.waiting.status")
    }

    private var primaryTitle: String {
        switch step {
        case .intro: L("permission.settings.open")
        case .waiting: L("permission.check")
        case .success: L("permission.start")
        }
    }

    private func primaryAction() {
        switch step {
        case .intro: model.requestAccessibilityPermission()
        case .waiting:
            model.permissionOnboarding.didCheckPermission = true
            model.refreshPermission()
        case .success: finish()
        }
    }

    private func finish() {
        model.completePermissionOnboarding()
        dismiss()
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(number)).font(.caption.weight(.semibold)).frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.07), in: Circle()).accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
