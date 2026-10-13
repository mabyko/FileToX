import AppKit
import SwiftUI

struct ConverterView: View {
    @Bindable var model: AppModel
    private var pages: [(String, String, String)] { [
        ("home", L("홈"), "arrow.down.doc"), ("general", L("일반"), "gearshape"),
        ("triggers", L("호출 키"), "keyboard"), ("toolbar", L("원형 툴바"), "circle.circle"),
        ("presets", L("프리셋"), "slider.horizontal.3"), ("theme", L("테마"), "paintpalette"),
        ("engines", L("변환 엔진"), "cpu"), ("about", L("정보"), "info.circle")
    ] }

    @Namespace private var sidebar
    /// Multi-column editors need the room; forms and Home read better at a fixed measure.
    private var wide: Bool { ["presets", "toolbar"].contains(model.selectedPage) }
    private var title: String { pages.first { $0.0 == model.selectedPage }?.1 ?? L("홈") }

    var body: some View {
        HStack(spacing: 0) {
            // Custom sidebar: List selection always paints the system accent, which clashes with the app accent.
            VStack(alignment: .leading, spacing: 2) {
                row(pages[0])
                Text(L("설정")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
                ForEach(pages[1..<7], id: \.0) { row($0) }
                Spacer().frame(height: 14)
                row(pages[7])
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 22)
            .frame(width: 228).frame(maxHeight: .infinity)
            .background(SidebarMaterial().ignoresSafeArea())
            .animation(Motion.when(!model.reduceMotion, Motion.open), value: model.selectedPage)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .bold)).contentTransition(.opacity)
                    if model.selectedPage == "home" {
                        Text(L("끌어서 놓으면, 변환 끝.")).font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 18)
                if !model.isConnected {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(model.statusMessage).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button(model.isConnecting ? L("연결 중…") : L("다시 연결")) { Task { await model.connect() } }.disabled(model.isConnecting)
                    }.fileeCard(padding: 12).padding(.horizontal, 32).padding(.bottom, 14)
                }
                ZStack(alignment: .topLeading) {
                    page.id(model.selectedPage).transition(.blurSwap)
                }.padding(.horizontal, 32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(maxWidth: wide ? 1200 : 760).frame(maxWidth: .infinity)  // 760 ≤ grouped Form max width, so forms align with titles
                Divider()
                Text(model.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    .padding(.horizontal, 32).padding(.vertical, 9)
                    .frame(maxWidth: wide ? 1200 : 760, alignment: .leading).frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.fileePage)
            .animation(Motion.when(!model.reduceMotion, Motion.open), value: model.selectedPage)
        }
        .tint(model.accentColor).preferredColorScheme(model.themeColorScheme).frame(minWidth: 820, minHeight: 560)
            .environment(\.locale, Locale(identifier: model.language.rawValue))
            .onAppear { model.refreshPermission() }
            .onChange(of: model.editingPresetID) { _, id in if id != nil { model.selectedPage = "presets" } }
    }

    private func row(_ page: (String, String, String)) -> some View {
        let selected = model.selectedPage == page.0
        return Button { model.selectedPage = page.0 } label: {
            Label {
                Text(page.1).foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
            } icon: {
                Image(systemName: page.2).font(.system(size: 14)).foregroundStyle(model.accentColor).frame(width: 20)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                // One indicator that slides between rows (transitions.dev "tabs sliding").
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(model.accentColor.opacity(0.18))
                        .matchedGeometryEffect(id: "sidebar.selection", in: sidebar)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var page: some View {
        switch model.selectedPage {
        case "home": HomeView(model: model)
        case "presets": PresetsView(model: model).padding(.bottom, 20)
        case "toolbar": ToolbarProfilesView(model: model).padding(.bottom, 20)
        case "engines": EnginesView(model: model)
        case "general", "theme", "triggers": SettingsView(model: model, section: model.selectedPage)
        default: AboutView()
        }
    }
}

struct EnginesView: View {
    let model: AppModel
    var body: some View {
        if let settings = model.library?.settings { SettingsJSONEditor(model: model, original: settings, section: "engineOwnCopies") }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("about.description")).font(.body).lineSpacing(3)
                Text("Filee · MIT License").font(.headline)
                Text(Bundle.main.url(forResource: "Filee", withExtension: "LICENSE").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? L("라이선스 파일을 찾을 수 없습니다."))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }.fileeCard().padding(.bottom, 20)
        }
    }
}

extension View {
    /// One quiet surface level: subtle fill + hairline, no shadow. Nest content directly, not more cards.
    func fileeCard(padding: CGFloat = 16) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fileeSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
