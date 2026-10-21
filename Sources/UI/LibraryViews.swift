import AppKit
import SwiftUI

struct PresetsView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var selectedID: String?
    @State private var draft: JSONValue = .object([:])
    @State private var deleteConfirmation = false
    @State private var baseRevision = 0

    private var presets: [JSONValue] { model.library?.presets ?? [] }
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(L("추가")) { add(duplicate: false) }
                    Button { add(duplicate: true) } label: { Image(systemName: "doc.on.doc") }.help(L("복제"))
                    Button { deleteConfirmation = true } label: { Image(systemName: "trash") }.help(L("삭제")).disabled(selectedID == nil)
                }
                TextField(L("검색"), text: $search).textFieldStyle(.roundedBorder)
                List(selection: $selectedID) {
                    ForEach(presets.filter { search.isEmpty || $0.libraryName.localizedCaseInsensitiveContains(search) }, id: \.identity) { preset in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.libraryName).fontWeight(.semibold)
                            Text(preset.field("targetFormat").string.map { $0 == "*" ? L("같은 형식") : $0.uppercased() } ?? "").font(.caption).foregroundStyle(.secondary)
                        }.tag(preset.identity)
                    }
                }
            }.frame(width: 210)
            if selectedID != nil {
                VStack(spacing: 12) {
                    ScrollView { PresetDraftEditor(model: model, draft: $draft) }
                    HStack {
                        Spacer()
                        Button(L("되돌리기")) { load() }
                        Button(L("저장")) { Task { if await model.savePreset(draft, baseRevision: baseRevision) { baseRevision = model.library?.revision ?? baseRevision } } }.buttonStyle(.borderedProminent)
                    }
                }.frame(maxWidth: .infinity)
            } else { Text(L("프리셋을 선택하세요.")).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
        .onChange(of: selectedID) { _, _ in load() }
        .onChange(of: model.editingPresetID) { _, id in if let id { selectedID = id } }
        .onAppear { selectedID = model.editingPresetID ?? presets.first?.identity; load() }
        .confirmationDialog(L("이 프리셋을 삭제할까요?"), isPresented: $deleteConfirmation) {
            Button(L("삭제"), role: .destructive) { if let id = selectedID { Task { await model.deletePreset(id); selectedID = presets.first?.identity } } }
        }
    }
    private func load() { if let preset = presets.first(where: { $0.identity == selectedID }) { draft = preset; baseRevision = model.library?.revision ?? 0 } }
    private func add(duplicate: Bool) {
        guard var item = duplicate ? presets.first(where: { $0.identity == selectedID }) : presets.first else { return }
        item["id"] = .string(String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)))
        item["name"] = .string(duplicate ? item.libraryName + " 2" : L("새 프리셋"))
        item["nameKey"] = .null
        Task { if await model.savePreset(item) { selectedID = item.identity; draft = item; baseRevision = model.library?.revision ?? 0 } }
    }
}

struct PresetDraftEditor: View {
    let model: AppModel
    @Binding var draft: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField(L("이름"), text: text("name"))
                Picker(L("변환 형식"), selection: text("targetFormat")) {
                    Text(L("같은 형식")).tag("*")
                    Text(L("압축 해제")).tag("folder")
                    ForEach((model.catalog?.formats ?? []).filter(\.writable), id: \.id) { Text($0.displayName).tag($0.id) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(L("이미지")).font(.headline)
                HStack { Text(L("품질")); Slider(value: number("image", "quality", fallback: 90), in: 1...100, step: 1); Text("\(draft.field("image").field("quality").int ?? 90)") }
                Picker(L("크기 조정"), selection: text("image", "resize")) {
                    Text(L("원본 크기")).tag("none"); Text(L("비율")).tag("percent"); Text(L("긴 변")).tag("longEdge")
                }
                if draft.field("image").field("resize").string == "percent" { numberField(L("비율 (%)"), "image", "resizePercent", fallback: 50) }
                if draft.field("image").field("resize").string == "longEdge" { numberField(L("긴 변 (px)"), "image", "longEdge", fallback: 1920) }
                HStack {
                    Toggle(L("DPI 지정"), isOn: Binding(get: { draft.field("image").field("dpi").int != nil }, set: { draft.set($0 ? .number(300) : .null, at: ["image", "dpi"]) }))
                    TextField("DPI", value: number("image", "dpi", fallback: 300), format: .number)
                        .disabled(draft.field("image").field("dpi") == .null)
                }
                Toggle(L("메타데이터(EXIF) 유지"), isOn: boolean("image", "keepMetadata", fallback: true))
                Toggle(L("색 프로필(ICC) 유지"), isOn: boolean("image", "keepColorProfile", fallback: true))
                Toggle(L("흑백으로"), isOn: boolean("image", "grayscale"))
                TextField(L("투명 영역 배경색"), text: text("image", "background"))
                Toggle(L("여러 이미지를 한 TIFF로 병합"), isOn: boolean("image", "multiPageTiff"))
                Toggle(L("WEBP 무손실"), isOn: boolean("image", "webpLossless"))
                Picker(L("TIFF 압축"), selection: text("image", "tiffCompression")) { Text(L("무압축")).tag("none"); Text("LZW").tag("lzw"); Text("ZIP").tag("zip") }
                Text(L("ICO 크기: ") + (draft.field("image").field("icoSizes").array?.compactMap(\.int).map(String.init).joined(separator: ", ") ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }.fileeCard()
            VStack(alignment: .leading, spacing: 10) {
                Text("PDF").font(.headline)
                Toggle(L("하나의 PDF로 병합"), isOn: boolean("pdf", "mergeIntoSingle"))
                Toggle(L("페이지별로 분할"), isOn: boolean("pdf", "splitPages"))
                numberField(L("렌더링 DPI"), "pdf", "renderDpi", fallback: 150)
                TextField(L("페이지 (예: 1-3,5)"), text: text("pdf", "pageRange"))
                Picker(L("용지"), selection: text("pdf", "pageSize")) { Text(L("이미지에 맞춤")).tag("fitImage"); Text("A4").tag("a4"); Text("Letter").tag("letter") }
                numberField(L("여백 (mm)"), "pdf", "marginMm", fallback: 0)
                Toggle(L("문서를 PDF/A로 저장"), isOn: boolean("document", "pdfA"))
            }.fileeCard()
            VStack(alignment: .leading, spacing: 10) {
                Text(L("영상 · 오디오")).font(.headline)
                Picker(L("품질"), selection: text("media", "quality")) { Text(L("높음")).tag("high"); Text(L("균형")).tag("balanced"); Text(L("작은 파일")).tag("small") }
                numberField(L("최대 높이 (0: 원본)"), "media", "maxHeight", fallback: 0)
                numberField(L("오디오 비트레이트"), "media", "audioBitrateKbps", fallback: 0)
                Toggle(L("오디오 제거"), isOn: boolean("media", "removeAudio"))
                numberField(L("오디오 채널 (0: 원본)"), "media", "audioChannels", fallback: 0)
                numberField(L("샘플 레이트 (0: 원본)"), "media", "audioSampleRate", fallback: 0)
                Picker(L("WAV 형식"), selection: text("media", "wavFormat")) {
                    Text("PCM 8bit").tag("pcm8"); Text("PCM 16bit").tag("pcm16"); Text("PCM 24bit").tag("pcm24"); Text("PCM 32bit").tag("pcm32"); Text("Float 32bit").tag("float32")
                }
            }.fileeCard()
            VStack(alignment: .leading, spacing: 10) {
                Text(L("압축")).font(.headline)
                Toggle(L("선택한 파일을 하나로 합치기"), isOn: boolean("archive", "combineIntoOne"))
                Picker(L("압축 수준"), selection: text("archive", "level")) { Text(L("무압축")).tag("store"); Text(L("빠르게")).tag("fast"); Text(L("보통")).tag("normal"); Text(L("최대")).tag("maximum") }
            }.fileeCard()
            VStack(alignment: .leading, spacing: 10) {
                Text(L("출력")).font(.headline)
                Picker(L("저장 위치"), selection: text("output", "location")) {
                    Text(L("기본 설정")).tag("default"); Text(L("원본 폴더")).tag("sameFolder"); Text(L("하위 폴더")).tag("subfolder"); Text(L("지정 폴더")).tag("customFolder")
                }
                TextField(L("하위 폴더 이름"), text: text("output", "subfolderName"))
                HStack {
                    TextField(L("지정 폴더"), text: text("output", "customFolder"))
                    Button(L("찾기…")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { set(.string(url.path), "output", "customFolder") }
                    }
                }
                TextField(L("파일명 패턴"), text: text("output", "fileNamePattern"))
                Text("{name} · {ext} · {preset} · {date} · {time} · {index}").font(.caption).foregroundStyle(.secondary)
                Picker(L("이름 충돌"), selection: text("output", "conflict")) {
                    Text(L("새 이름으로 저장")).tag("rename"); Text(L("건너뛰기")).tag("skip"); Text(L("기존 결과 덮어쓰기")).tag("overwrite")
                }
                Toggle(L("원본 파일 날짜 보존"), isOn: boolean("output", "keepDates"))
                if let renames = draft.field("output").field("renames").array, !renames.isEmpty {
                    Text(L("파일명 변경 규칙 %@개는 그대로 유지됩니다.", String(describing: (renames.count)))).font(.caption).foregroundStyle(.secondary)
                }
            }.fileeCard()
        }.textFieldStyle(.roundedBorder)
    }
    private func value(_ keys: [String]) -> JSONValue { keys.reduce(draft) { $0.field($1) } }
    private func set(_ value: JSONValue, _ keys: String...) { draft.set(value, at: keys) }
    private func text(_ keys: String...) -> Binding<String> { Binding(get: { value(keys).string ?? "" }, set: { draft.set(.string($0), at: keys) }) }
    private func boolean(_ keys: String..., fallback: Bool = false) -> Binding<Bool> { Binding(get: { value(keys).bool ?? fallback }, set: { draft.set(.bool($0), at: keys) }) }
    private func number(_ keys: String..., fallback: Double) -> Binding<Double> { Binding(get: { value(keys).double ?? fallback }, set: { draft.set(.number($0), at: keys) }) }
    private func numberField(_ label: String, _ group: String, _ key: String, fallback: Double) -> some View {
        TextField(label, value: number(group, key, fallback: fallback), format: .number)
    }
}

struct ToolbarProfilesView: View {
    let model: AppModel
    @State private var menu: RadialMenuKind = .convert
    @State private var selectedID: String?
    @State private var draft: JSONValue = .object([:])
    @State private var search = ""
    @State private var paletteSearch = ""
    @State private var baseRevision = 0
    @State private var activeIndex: Int?
    private var profiles: [JSONValue] { model.library?.profiles ?? [] }
    private var presets: [JSONValue] { model.library?.presets ?? [] }
    private var ids: [String] { draft.field("presetIds").array?.compactMap(\.string) ?? [] }
    private var items: [RadialItem] {
        ids.compactMap { id in presets.first { $0.identity == id }.map { RadialItem(id: id, title: $0.libraryName, caption: $0.field("targetFormat").string.map { $0 == "*" ? L("같은 형식") : $0.uppercased() } ?? "", available: true, reason: nil) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("menu.choose"), selection: $menu) {
                ForEach(RadialMenuKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 340)
            if menu == .tools {
                ToolsMenuEditor(model: model)
            } else {
                profilesEditor
            }
        }
    }
    private var profilesEditor: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("1. 프로필 선택")).font(.caption).foregroundStyle(.secondary)
                TextField(L("검색"), text: $search).textFieldStyle(.roundedBorder)
                List(selection: $selectedID) {
                    ForEach(profiles.filter { search.isEmpty || $0.libraryName.localizedCaseInsensitiveContains(search) }, id: \.identity) { profile in
                        HStack { Text(profile.libraryName); Spacer(); Text("\(profile.field("presetIds").array?.count ?? 0)").foregroundStyle(.secondary) }.tag(profile.identity)
                    }
                }
            }.frame(width: 155)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("2. 프리셋 배치")).font(.caption).foregroundStyle(.secondary)
                    DonutView(items: items, title: draft.libraryName, subtitle: "\(ids.count) / 12", radius: 132, holeRatio: model.holeRatio, accent: model.accentColor,
                              activeIndex: activeIndex, onHover: { activeIndex = $0 }, onInvoke: { model.editingPresetID = ids[$0]; model.selectedPage = "presets" })
                        .frame(maxWidth: .infinity).fileeCard()
                    TextField(L("이름"), text: Binding(get: { draft.field("name").string ?? "" }, set: { draft["name"] = .string($0) })).textFieldStyle(.roundedBorder)
                    Toggle(L("여러 형식이 섞인 선택에 사용"), isOn: Binding(get: { draft.field("isFallback").bool ?? false }, set: { draft["isFallback"] = .bool($0) }))
                    TextField(L("적용 확장자 (쉼표로 구분)"), text: Binding(get: { draft.field("extensions").array?.compactMap(\.string).joined(separator: ", ") ?? "" }, set: {
                        draft["extensions"] = .array($0.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()) })
                    })).textFieldStyle(.roundedBorder)
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text(presets.first { $0.identity == id }?.libraryName ?? id)
                            Spacer()
                            Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help(L("앞으로 이동"))
                            Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.disabled(index == ids.count - 1).help(L("뒤로 이동"))
                            Button { var next = ids; next.remove(at: index); draft["presetIds"] = .array(next.map(JSONValue.string)) } label: { Image(systemName: "minus.circle") }.help(L("도넛에서 제거"))
                        }
                    }
                    Button(L("프로필 저장")) { Task { if await model.saveProfile(draft, baseRevision: baseRevision) { baseRevision = model.library?.revision ?? baseRevision } } }.buttonStyle(.borderedProminent).disabled(selectedID == nil)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L("사용 가능한 프리셋")).font(.caption).foregroundStyle(.secondary)
                TextField(L("검색"), text: $paletteSearch).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(presets.filter { !ids.contains($0.identity) && (paletteSearch.isEmpty || $0.libraryName.localizedCaseInsensitiveContains(paletteSearch)) }, id: \.identity) { preset in
                            Button(preset.libraryName) { draft["presetIds"] = .array((ids + [preset.identity]).map(JSONValue.string)) }
                                .disabled(ids.count >= 12 || selectedID == nil)
                        }
                    }
                }
            }.frame(width: 150)
        }
        .onChange(of: selectedID) { _, _ in load() }
        .onAppear { selectedID = profiles.first?.identity; load() }
    }
    private func load() { if let profile = profiles.first(where: { $0.identity == selectedID }) { draft = profile; baseRevision = model.library?.revision ?? 0 } }
    private func move(_ index: Int, _ offset: Int) { var next = ids; next.swapAt(index, index + offset); draft["presetIds"] = .array(next.map(JSONValue.string)) }
}

private struct ToolsMenuEditor: View {
    let model: AppModel
    @State private var automatic = true
    @State private var ids: [String] = []
    @State private var search = ""
    @State private var saveFailed = false

    private var choices: [(id: String, name: String)] {
        FileMenuAction.allCases.map { (id: $0.id, name: $0.title) } +
        (model.library?.presets ?? []).map { (id: "preset:" + $0.identity, name: $0.libraryName) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(L("menu.tools.automatic"), isOn: $automatic)
                Text(L("menu.tools.description")).font(.callout).foregroundStyle(.secondary)
                if !automatic {
                    HStack {
                        Text(L("menu.items")).font(.headline)
                        Spacer()
                        Text("\(ids.count) / 12").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        HStack {
                            Text(choices.first { $0.id == id }?.name ?? L("menu.missingPreset"))
                            Spacer()
                            Button { ids.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).help(L("앞으로 이동")).accessibilityLabel(L("앞으로 이동"))
                            Button { ids.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == ids.count - 1).help(L("뒤로 이동")).accessibilityLabel(L("뒤로 이동"))
                            Button { ids.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .help(L("도넛에서 제거")).accessibilityLabel(L("도넛에서 제거"))
                        }.padding(.vertical, 3)
                    }
                    Divider()
                    TextField(L("검색"), text: $search).textFieldStyle(.roundedBorder)
                    ForEach(choices.filter { !ids.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }, id: \.id) { item in
                        Button { ids.append(item.id) } label: { Label(item.name, systemImage: "plus.circle") }
                            .buttonStyle(.borderless).disabled(ids.count >= 12)
                    }
                }
                HStack {
                    Button(L("되돌리기"), action: load)
                    Spacer()
                    Button(L("저장")) { saveFailed = !model.saveToolsMenu(automatic ? nil : ids) }
                        .buttonStyle(.borderedProminent).disabled(!automatic && ids.isEmpty)
                }
                if saveFailed { Text(L("menu.saveFailed")).foregroundStyle(.red) }
            }.fileeCard().padding(.bottom, 20)
        }.onAppear(perform: load)
    }
    private func load() {
        automatic = model.toolsMenuItems == nil
        ids = model.toolsMenuItems ?? FileMenuAction.allCases.map(\.id)
        saveFailed = false
    }
}

extension JSONValue {
    func field(_ key: String) -> JSONValue { self[key] ?? .null }
    var identity: String { field("id").string ?? "" }
    @MainActor var libraryName: String { Localization.libraryName(self, language: Localization.shared.language) }
    mutating func set(_ value: JSONValue, at path: [String]) {
        guard let first = path.first else { self = value; return }
        var child = field(first)
        child.set(value, at: Array(path.dropFirst()))
        self[first] = child
    }
}

struct PresetEditorPopup: View {
    let model: AppModel
    let onClose: () -> Void
    @State private var draft: JSONValue
    @State private var baseRevision: Int
    init(model: AppModel, preset: JSONValue, onClose: @escaping () -> Void) {
        self.model = model; self.onClose = onClose
        _draft = State(initialValue: preset); _baseRevision = State(initialValue: model.library?.revision ?? 0)
    }
    var body: some View {
        VStack(spacing: 14) {
            ScrollView { PresetDraftEditor(model: model, draft: $draft).padding(20) }
            HStack {
                Text(model.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(L("취소"), action: onClose).keyboardShortcut(.cancelAction)
                Button(L("저장")) { Task { if await model.savePreset(draft, baseRevision: baseRevision) { onClose() } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(16)
        }.tint(model.accentColor).preferredColorScheme(model.themeColorScheme)
            .environment(\.locale, Locale(identifier: model.language.rawValue))
    }
}
