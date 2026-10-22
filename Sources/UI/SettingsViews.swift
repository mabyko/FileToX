import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let section: String
    var body: some View {
        if let settings = model.library?.settings {
            SettingsJSONEditor(model: model, original: settings, section: section).id(section)
        } else if section == "general" || section == "triggers" {
            Form {
                if section == "general" { ApplicationSettingsSections(preferences: model.applicationPreferences) }
                else { ExcludedApplicationsSection(preferences: model.applicationPreferences) }
            }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -20)
        }
    }
}

struct SettingsJSONEditor: View {
    let model: AppModel
    let section: String
    @State private var draft: JSONValue
    @State private var baseRevision: Int
    @State private var shortcutDraft: DragShortcut
    @State private var toolsShortcutDraft: DragShortcut
    @State private var shortcutMenu: RadialMenuKind = .convert
    private var shortcutBinding: Binding<DragShortcut> { shortcutMenu == .convert ? $shortcutDraft : $toolsShortcutDraft }
    private var shortcutsValid: Bool {
        shortcutDraft.isValid && toolsShortcutDraft.isValid && !shortcutDraft.usesSameKeys(as: toolsShortcutDraft)
    }
    init(model: AppModel, original: JSONValue, section: String) {
        self.model = model; self.section = section
        var settings = original
        if section == "general" { settings["language"] = .string(AppLanguage.supported(original["language"]?.string).rawValue) }
        _draft = State(initialValue: settings); _baseRevision = State(initialValue: model.library?.revision ?? 0)
        _shortcutDraft = State(initialValue: model.dragShortcut)
        _toolsShortcutDraft = State(initialValue: model.toolsDragShortcut)
    }
    var body: some View {
        VStack(spacing: 0) {
            Form { sections }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -20)
            HStack {
                Spacer()
                Button(L("되돌리기")) {
                    if let settings = model.library?.settings { draft = settings; baseRevision = model.library?.revision ?? 0 }
                    shortcutDraft = model.dragShortcut
                    toolsShortcutDraft = model.toolsDragShortcut
                }
                Button(L("저장")) {
                    Task {
                        if await model.saveSettings(draft, baseRevision: baseRevision,
                                                    dragShortcut: section == "triggers" ? shortcutDraft : nil,
                                                    toolsDragShortcut: section == "triggers" ? toolsShortcutDraft : nil) {
                            baseRevision = model.library?.revision ?? baseRevision
                        }
                    }
                }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isConnected || (section == "triggers" && !shortcutsValid))
            }.padding(.vertical, 12)
        }
    }

    @ViewBuilder private var sections: some View {
        switch section {
        case "general":
            ApplicationSettingsSections(preferences: model.applicationPreferences)
            Section {
                Picker(L("Language"), selection: Binding(get: { AppLanguage.supported(draft["language"]?.string).rawValue }, set: { draft["language"] = .string($0) })) {
                    ForEach(AppLanguage.allCases) { language in Text(language.nativeName).tag(language.rawValue) }
                }
                Toggle(L("변환 이력 저장"), isOn: bool("keepHistory", fallback: true))
                Toggle(L("원본 파일 날짜 보존"), isOn: bool("keepFileDates"))
            }
            Section(L("출력")) {
                Picker(L("기본 출력 위치"), selection: text("defaultOutput", "location")) {
                    Text(L("원본 폴더")).tag("sameFolder"); Text(L("하위 폴더")).tag("subfolder"); Text(L("지정 폴더")).tag("customFolder")
                }
                TextField(L("하위 폴더 이름"), text: text("defaultOutput", "subfolderName"))
                LabeledContent(L("지정 폴더")) {
                    HStack {
                        TextField("", text: text("defaultOutput", "customFolder")).labelsHidden()
                        Button(L("찾기…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url { draft.set(.string(url.path), at: ["defaultOutput", "customFolder"]) }
                        }
                    }
                }
            }
            Section { Button(L("최근 변환 지우기"), role: .destructive) { Task { await model.clearHistory() } }.foregroundStyle(.red) }
        case "theme":
            Section {
                Picker(L("모드"), selection: text("theme", "mode")) { Text(L("시스템")).tag("system"); Text(L("라이트")).tag("light"); Text(L("다크")).tag("dark") }
                    .pickerStyle(.segmented)
                LabeledContent(L("Accent color")) {
                    HStack {
                        TextField("", text: text("theme", "accent")).labelsHidden().frame(width: 90).font(.body.monospaced())
                        ColorPicker("", selection: Binding(get: {
                            ThemeAccent.color(hex: draft["theme"]?["accent"]?.string)
                        }, set: { draft.set(.string(ThemeAccent.hex(color: $0)), at: ["theme", "accent"]) }), supportsOpacity: false).labelsHidden()
                    }
                }
                Picker(L("애니메이션"), selection: Binding(get: {
                    draft.field("theme").field("reduceMotion").bool.map { $0 ? 1 : 2 } ?? 0
                }, set: { draft.set($0 == 0 ? .null : .bool($0 == 1), at: ["theme", "reduceMotion"]) })) {
                    Text(L("시스템 설정")).tag(0); Text(L("줄이기")).tag(1); Text(L("모두 사용")).tag(2)
                }
            }
            Section(L("원형 툴바")) {
                slider(L("크기"), number("donut", "outerRadius", fallback: 150), 100...240, "%.0f pt")
                slider(L("중심 구멍"), number("donut", "holeRatio", fallback: 0.42), 0.2...0.7, "%.0f%%", scale: 100)
                slider(L("불투명도"), number("donut", "opacity", fallback: 0.96), 0.5...1, "%.0f%%", scale: 100)
            }
        case "triggers":
            ExcludedApplicationsSection(preferences: model.applicationPreferences)
            Section {
                Toggle(L("shortcut.enable"), isOn: Binding(get: { draft.field("paused").bool != true }, set: { draft["paused"] = .bool(!$0) }))
                LabeledContent(RadialMenuKind.convert.title, value: shortcutDraft.displayName)
                LabeledContent(RadialMenuKind.tools.title, value: toolsShortcutDraft.displayName)
            } footer: {
                Text(L("shortcut.menus.help")).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker(L("menu.choose"), selection: $shortcutMenu) {
                    ForEach(RadialMenuKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if shortcutDraft.usesSameKeys(as: toolsShortcutDraft) {
                    Label(L("shortcut.duplicate"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            DragShortcutEditor(shortcut: shortcutBinding, defaultShortcut: shortcutMenu == .convert ? .standard : .toolsStandard)
            Section {
                Picker(L("shortcut.activation.title"), selection: shortcutBinding.activationMode) {
                    ForEach(DragShortcut.ActivationMode.allCases) { mode in
                        Text(L("shortcut.activation.\(mode.rawValue)")).tag(mode)
                    }
                }.pickerStyle(.radioGroup).labelsHidden()
            } header: {
                Text(L("shortcut.activation.title"))
            } footer: {
                Text(L("shortcut.activation.\(shortcutBinding.wrappedValue.activationMode.rawValue).help", shortcutBinding.wrappedValue.displayName))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button(L("설정 방법 보기"), action: model.showPermissionOnboarding)
                } label: {
                    Label(model.hasAccessibilityPermission ? L("손쉬운 사용 권한 허용됨") : L("드래그 호출이 반응하지 않으면 권한을 확인하세요."),
                          systemImage: model.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.hasAccessibilityPermission ? Color.green : Color.orange)
                }
            }
        case "engineOwnCopies":
            Section {
                ForEach(model.catalog?.engines ?? [], id: \.id) { engine in
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(engine.available ? L("사용 가능") : reason(engine.reasonKey))
                            // Detail is non-localized extra context (e.g. a program path), so it stays secondary.
                            if !engine.available, let detail = engine.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
                    } label: {
                        Label {
                            Text(engine.displayName).foregroundStyle(engine.available ? Color.primary : Color.secondary)
                        } icon: {
                            Image(systemName: engine.available ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(engine.available ? model.accentColor : Color.secondary)
                        }
                    }
                }
            } footer: {
                Button(L("엔진 상태 새로 고침")) { Task { await model.refreshLibrary() } }
            }
            Section {
                ForEach(["ffmpeg", "pandoc", "ghostscript", "calibre", "libreoffice"], id: \.self) { id in
                    LabeledContent(id) {
                        HStack {
                            TextField(L("실행 파일 경로"), text: text("engineOwnCopies", id), prompt: Text(L("실행 파일 경로"))).labelsHidden()
                            Button(L("찾기…")) {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url { draft.set(.string(url.path), at: ["engineOwnCopies", id]) }
                            }
                        }
                    }
                }
            } header: {
                Text(L("외부 엔진 실행 파일"))
            } footer: {
                Text(L("이미 설치한 실행 파일을 선택하면 다음 변환에 해당 엔진을 사용할 수 있습니다.")).font(.callout).foregroundStyle(.secondary)
            }
        default: EmptyView()
        }
    }

    /// Engine reasons arrive as localization keys; unknown keys fall back to the generic text, never the raw key.
    private func reason(_ key: String?) -> String {
        guard let key, case let text = L(key), text != key else { return L("설치되어 있지 않음") }
        return text
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String, scale: Double = 1) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range).labelsHidden()
                Text(String(format: format, value.wrappedValue * scale)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        }
    }
    private func value(_ keys: [String]) -> JSONValue { keys.reduce(draft) { $0.field($1) } }
    private func text(_ keys: String...) -> Binding<String> { Binding(get: { value(keys).string ?? "" }, set: { draft.set(.string($0), at: keys) }) }
    private func bool(_ keys: String..., fallback: Bool = false) -> Binding<Bool> { Binding(get: { value(keys).bool ?? fallback }, set: { draft.set(.bool($0), at: keys) }) }
    private func number(_ keys: String..., fallback: Double) -> Binding<Double> { Binding(get: { value(keys).double ?? fallback }, set: { draft.set(.number($0), at: keys) }) }
}

private struct DragShortcutEditor: View {
    @Binding var shortcut: DragShortcut
    let defaultShortcut: DragShortcut
    @State private var systemHotKeys: [DragShortcut.SystemHotKey]?

    var body: some View {
        Section {
            LabeledContent(L("shortcut.current")) {
                Text(shortcut.isValid ? shortcut.displayName : L("shortcut.required"))
                    .font(.body.monospaced().weight(.semibold))
            }
            HStack {
                modifier("Control ⌃", .control)
                modifier("Option ⌥", .option)
                modifier("Shift ⇧", .shift)
                modifier("Command ⌘", .command)
            }.toggleStyle(.checkbox)
            Picker(L("shortcut.extra.key"), selection: Binding(get: { shortcut.keyCode.map(Int.init) ?? -1 }, set: {
                shortcut.keyCode = $0 == -1 ? nil : UInt16($0)
            })) {
                Text(L("shortcut.key.none")).tag(-1)
                ForEach(DragShortcut.keys) { key in
                    Text(key.name == "Space" ? L("shortcut.key.space") : key.name).tag(Int(key.code))
                }
            }
            Button(L("shortcut.resetMenu")) {
                shortcut = DragShortcut(modifiers: defaultShortcut.modifiers, activationMode: shortcut.activationMode)
            }
            if !shortcut.isValid { warning("shortcut.required") }
            if shortcut.modifiers.contains(.control) {
                warning(shortcut.activationMode == .beforeDrag ? "shortcut.control.before.warning" : "shortcut.control.warning")
            }
            if shortcut.modifiers.contains(.option) {
                warning(shortcut.modifiers.contains(.command) ? "shortcut.alias.warning" : "shortcut.copy.warning")
            } else if shortcut.modifiers.contains(.command) { warning("shortcut.move.warning") }
            if let systemHotKeys {
                if shortcut.conflicts(with: systemHotKeys) {
                    warning("shortcut.system.warning")
                    Button(L("shortcut.system.settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }.buttonStyle(.link)
                }
            } else { warning("shortcut.system.unavailable") }
        } header: {
            Text(L("shortcut.title"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("shortcut.scope"))
                Text(L("shortcut.layout.help"))
                if let key = DragShortcut.keys.first(where: { $0.code == shortcut.keyCode }), key.name.hasPrefix("F"), key.name.count > 1 {
                    Text(L("shortcut.function.help"))
                }
            }.font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { systemHotKeys = DragShortcut.systemHotKeys() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemHotKeys = DragShortcut.systemHotKeys()
        }
    }

    private func modifier(_ title: String, _ flag: NSEvent.ModifierFlags) -> some View {
        Toggle(title, isOn: Binding(get: { shortcut.modifiers.contains(flag) }, set: { enabled in
            if enabled { shortcut.modifiers.insert(flag) } else { shortcut.modifiers.remove(flag) }
        }))
    }

    private func warning(_ key: String) -> some View {
        Label {
            Text(L(key)).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
