import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    let section: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let settings = model.library?.settings {
                    SettingsJSONEditor(model: model, original: settings, section: section).id(section)
                }
                if section == "triggers" {
                    HStack {
                        Text(model.hasAccessibilityPermission ? L("손쉬운 사용 권한 허용됨") : L("드래그 호출이 반응하지 않으면 권한을 확인하세요.")).font(.callout)
                        Spacer()
                        if !model.hasAccessibilityPermission { Button(L("권한 설정"), action: model.requestAccessibilityPermission) }
                    }.fileeCard()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsJSONEditor: View {
    let model: AppModel
    let section: String
    @State private var draft: JSONValue
    @State private var baseRevision: Int
    init(model: AppModel, original: JSONValue, section: String) {
        self.model = model; self.section = section
        var settings = original
        if section == "general" { settings["language"] = .string(AppLanguage.supported(original["language"]?.string).rawValue) }
        _draft = State(initialValue: settings); _baseRevision = State(initialValue: model.library?.revision ?? 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch section {
            case "general":
                Picker(L("Language"), selection: Binding(get: { AppLanguage.supported(draft["language"]?.string).rawValue }, set: { draft["language"] = .string($0) })) {
                    ForEach(AppLanguage.allCases) { language in Text(language.nativeName).tag(language.rawValue) }
                }
                Toggle(L("변환 이력 저장"), isOn: bool("keepHistory", fallback: true))
                Toggle(L("원본 파일 날짜 보존"), isOn: bool("keepFileDates"))
                Picker(L("기본 출력 위치"), selection: text("defaultOutput", "location")) {
                    Text(L("원본 폴더")).tag("sameFolder"); Text(L("하위 폴더")).tag("subfolder"); Text(L("지정 폴더")).tag("customFolder")
                }
                TextField(L("하위 폴더 이름"), text: text("defaultOutput", "subfolderName"))
                HStack {
                    TextField(L("지정 폴더"), text: text("defaultOutput", "customFolder"))
                    Button(L("찾기…")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { draft.set(.string(url.path), at: ["defaultOutput", "customFolder"]) }
                    }
                }
                Button(L("최근 변환 지우기")) { Task { await model.clearHistory() } }
            case "theme":
                Picker(L("모드"), selection: text("theme", "mode")) { Text(L("시스템")).tag("system"); Text(L("라이트")).tag("light"); Text(L("다크")).tag("dark") }
                HStack {
                    ColorPicker(L("Accent color"), selection: Binding(get: {
                        ThemeAccent.color(hex: draft["theme"]?["accent"]?.string)
                    }, set: { draft.set(.string(ThemeAccent.hex(color: $0)), at: ["theme", "accent"]) }), supportsOpacity: false)
                    TextField(L("HEX color"), text: text("theme", "accent")).frame(width: 110)
                }
                Picker(L("애니메이션"), selection: Binding(get: {
                    draft.field("theme").field("reduceMotion").bool.map { $0 ? 1 : 2 } ?? 0
                }, set: { draft.set($0 == 0 ? .null : .bool($0 == 1), at: ["theme", "reduceMotion"]) })) {
                    Text(L("시스템 설정")).tag(0); Text(L("줄이기")).tag(1); Text(L("모두 사용")).tag(2)
                }
                Text(L("원형 툴바")).font(.headline)
                HStack { Text(L("크기")); Slider(value: number("donut", "outerRadius", fallback: 150), in: 100...240) }
                HStack { Text(L("중심 구멍")); Slider(value: number("donut", "holeRatio", fallback: 0.42), in: 0.2...0.7) }
                HStack { Text(L("불투명도")); Slider(value: number("donut", "opacity", fallback: 0.96), in: 0.5...1) }
            case "triggers":
                Toggle(L("Option + 드래그 호출 사용"), isOn: Binding(get: { draft.field("paused").bool != true }, set: { draft["paused"] = .bool(!$0) }))
                Text(L("Finder에서 파일을 드래그하기 전이나 드래그 도중 Option 키를 누르세요.")).font(.callout).foregroundStyle(.secondary)
            case "engineOwnCopies":
                Text(L("외부 엔진 실행 파일")).font(.headline)
                Text(L("이미 설치한 실행 파일을 선택하면 다음 변환에 해당 엔진을 사용할 수 있습니다.")).font(.caption).foregroundStyle(.secondary)
                ForEach(["ffmpeg", "pandoc", "ghostscript", "calibre", "libreoffice"], id: \.self) { id in
                    HStack {
                        Text(id).frame(width: 85, alignment: .leading)
                        TextField(L("실행 파일 경로"), text: text("engineOwnCopies", id))
                        Button(L("찾기…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { draft.set(.string(url.path), at: ["engineOwnCopies", id]) }
                        }
                    }
                }
            default: EmptyView()
            }
            HStack {
                Spacer()
                Button(L("되돌리기")) { if let settings = model.library?.settings { draft = settings; baseRevision = model.library?.revision ?? 0 } }
                Button(L("저장")) { Task { if await model.saveSettings(draft, baseRevision: baseRevision) { baseRevision = model.library?.revision ?? baseRevision } } }.buttonStyle(.borderedProminent).disabled(!model.isConnected)
            }
        }.textFieldStyle(.roundedBorder).fileeCard()
    }
    private func value(_ keys: [String]) -> JSONValue { keys.reduce(draft) { $0.field($1) } }
    private func text(_ keys: String...) -> Binding<String> { Binding(get: { value(keys).string ?? "" }, set: { draft.set(.string($0), at: keys) }) }
    private func bool(_ keys: String..., fallback: Bool = false) -> Binding<Bool> { Binding(get: { value(keys).bool ?? fallback }, set: { draft.set(.bool($0), at: keys) }) }
    private func number(_ keys: String..., fallback: Double) -> Binding<Double> { Binding(get: { value(keys).double ?? fallback }, set: { draft.set(.number($0), at: keys) }) }
}
