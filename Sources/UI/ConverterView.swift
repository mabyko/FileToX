import SwiftUI

struct ConverterView: View {
    @Bindable var model: AppModel
    private var pages: [(String, String, String)] { [
        ("home", L("홈"), "house.fill"), ("general", L("일반"), "gearshape.fill"),
        ("triggers", L("호출 키"), "keyboard"), ("toolbar", L("원형 툴바"), "circle.circle"),
        ("presets", L("프리셋"), "slider.horizontal.3"), ("theme", L("테마"), "paintpalette"),
        ("engines", L("변환 엔진"), "cpu"), ("about", L("정보"), "info.circle.fill")
    ] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FileToX").font(.system(size: 18, weight: .bold))
                    Text(L("끌어서 놓으면, 변환 끝.")).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 12)
                ForEach(pages, id: \.0) { id, title, icon in
                    Button { model.selectedPage = id } label: {
                        Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .foregroundStyle(model.selectedPage == id ? model.accentColor : Color.primary)
                            .background(model.selectedPage == id ? model.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("Filee · MIT License").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }.padding(14).frame(width: 230).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(pages.first { $0.0 == model.selectedPage }?.1 ?? L("홈")).font(.system(size: 24, weight: .semibold))
                if !model.isConnected {
                    HStack {
                        Text(model.statusMessage).textSelection(.enabled)
                        Spacer()
                        Button(model.isConnecting ? L("연결 중…") : L("다시 연결")) { Task { await model.connect() } }.disabled(model.isConnecting)
                    }.fileeCard()
                }
                switch model.selectedPage {
                case "home": HomeView(model: model)
                case "presets": PresetsView(model: model)
                case "toolbar": ToolbarProfilesView(model: model)
                case "engines": EnginesView(model: model)
                case "general", "theme", "triggers": SettingsView(model: model, section: model.selectedPage)
                default: AboutView()
                }
                Text(model.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color.fileePage)
        }.tint(model.accentColor).preferredColorScheme(model.themeColorScheme).frame(minWidth: 820, minHeight: 560)
            .environment(\.locale, Locale(identifier: model.language.rawValue))
            .onAppear { model.refreshPermission() }
            .onChange(of: model.editingPresetID) { _, id in if id != nil { model.selectedPage = "presets" } }
    }
}

struct EnginesView: View {
    let model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.catalog?.engines ?? [], id: \.id) { engine in
                    HStack(alignment: .top) {
                        Image(systemName: engine.available ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(engine.available ? model.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(engine.displayName).font(.headline)
                            Text(engine.available ? L("사용 가능") : engine.detail ?? engine.reasonKey ?? L("설치되어 있지 않음")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                    }.fileeCard()
                }
                Button(L("엔진 상태 새로 고침")) { Task { await model.refreshLibrary() } }
                if let settings = model.library?.settings { SettingsJSONEditor(model: model, original: settings, section: "engineOwnCopies") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("about.description"))
                Text("Filee · MIT License").font(.caption)
                Text(Bundle.main.url(forResource: "Filee", withExtension: "LICENSE").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? L("라이선스 파일을 찾을 수 없습니다.")).font(.caption).textSelection(.enabled)
            }.fileeCard()
        }
    }
}

extension View {
    func fileeCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1) }
    }
}
