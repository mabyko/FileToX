import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false
    @State private var targetSearch = ""
    @State private var showAllTargets = false
    @State private var selectedEntryID: String?

    private var motion: Bool { !model.reduceMotion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.selectedFiles.isEmpty { dropZone }
                else { selectedFiles.transition(.blurSwap) }
                HStack(spacing: 10) {
                    Button(action: model.chooseFiles) { Label(L("파일 또는 폴더 선택…"), systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o", modifiers: .command)
                    Spacer()
                    Button { showAllTargets.toggle() } label: {
                        Label(showAllTargets ? L("형식 목록 접기") : L("모든 출력 형식"), systemImage: "chevron.down")
                            .labelStyle(TrailingIconLabel(rotation: showAllTargets ? 180 : 0))
                    }.controlSize(.large)
                }
                if !model.selectedFiles.isEmpty { conversionChoices }
                if showAllTargets { targetList.transition(.blurSwap) }
                ForEach(model.activeJobs, id: \.jobId) { job in JobCard(model: model, job: job).transition(.blurSwap) }
                HStack(alignment: .firstTextBaseline) {
                    Text(L("최근 변환")).font(.title3.weight(.semibold))
                    Spacer()
                    if !model.historyEntries.isEmpty {
                        Button(L("지우기")) { Task { await model.clearHistory() } }.buttonStyle(.borderless)
                    }
                }.padding(.top, 6)
                if model.historyEntries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).foregroundStyle(.tertiary).accessibilityHidden(true)
                        Text(L("변환한 파일이 여기에 표시됩니다.")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28).fileeCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.historyEntries.prefix(40).enumerated()), id: \.element.jobId) { index, entry in
                            if index > 0 { Divider().padding(.leading, 44) }
                            HistoryCard(model: model, entry: entry)
                        }
                    }.fileeCard(padding: 0)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
                .animation(Motion.when(motion, Motion.open), value: showAllTargets)
                .animation(Motion.when(motion, Motion.open), value: model.selectedFiles)
                .animation(Motion.when(motion, Motion.open), value: model.activeJobs.map(\.jobId))
        }
        .onChange(of: model.selectedFiles) { _, _ in selectedEntryID = nil }
        .onChange(of: model.radialMenu) { _, _ in selectedEntryID = nil; showAllTargets = false }
    }

    private var dropZone: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 10) {
            Image(systemName: isTargeted ? "doc.badge.plus" : "arrow.down.doc")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(model.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 64, height: 64)
                .background(model.accentColor.opacity(isTargeted ? 0.2 : 0.12), in: Circle())
                .scaleEffect(isTargeted ? 1.08 : 1)
                .accessibilityHidden(true)
            Text(L("여기에 파일을 놓으세요")).font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Text(model.dragShortcut.displayName).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(L("shortcut.activation.\(model.dragShortcut.activationMode.rawValue).help", model.dragShortcut.displayName))
            }.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .background(model.accentColor.opacity(isTargeted ? 0.1 : 0.035), in: shape)
        .overlay {
            shape.strokeBorder(model.accentColor.opacity(isTargeted ? 0.9 : 0.35),
                               style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: isTargeted ? [] : [6, 5]))
        }
        .scaleEffect(isTargeted ? 1.01 : 1)
        .animation(Motion.when(motion, isTargeted ? Motion.pop : Motion.quick), value: isTargeted)
        .overlay { FileDropTarget(isTargeted: $isTargeted, isEnabled: model.isConnected) { urls in Task { await model.resolve(urls, showRadial: false) } } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("변환할 파일 드롭 영역"))
    }

    private var selectedFiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("선택한 파일 %@개", String(describing: (model.selectedFiles.count)))).font(.headline)
                Spacer()
                Button(L("home.clearSelection")) { model.selectFiles([]) }.buttonStyle(.borderless)
                    .disabled(model.isResolving || model.isStarting)
            }
            ForEach(Array(model.selectedFiles.prefix(5)), id: \.self) { url in
                Label {
                    Text(url.lastPathComponent).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                } icon: {
                    Image(systemName: url.hasDirectoryPath ? "folder" : "doc").foregroundStyle(model.accentColor)
                }.font(.callout).help(url.path)
            }
            if model.selectedFiles.count > 5 {
                DisclosureGroup(L("home.moreFiles", String(model.selectedFiles.count - 5))) {
                    ForEach(Array(model.selectedFiles.dropFirst(5)), id: \.self) { url in
                        Text(url.lastPathComponent).font(.callout).textSelection(.enabled).help(url.path)
                    }
                }
            }
            if let selection = model.selection, !selection.rejected.isEmpty {
                DisclosureGroup(L("처리할 수 없는 입력 %@개", String(describing: (selection.rejected.count)))) {
                    ForEach(selection.rejected, id: \.path) { input in
                        Text("\(URL(fileURLWithPath: input.path).lastPathComponent): \(input.reason)")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.font(.callout)
            }
        }.fileeCard()
    }

    private var chosenEntry: RadialMenuEntry? {
        model.radialEntries.first { $0.id == selectedEntryID && $0.available } ?? model.radialEntries.first { $0.available }
    }

    private var conversionChoices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L("menu.choose"), selection: $model.radialMenu) {
                ForEach(RadialMenuKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 340)
            if model.isResolving {
                ProgressView(L("형식 확인 중…")).padding(.vertical, 12)
            } else if model.radialEntries.isEmpty {
                Text(L("menu.empty")).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 8)], spacing: 8) {
                    ForEach(model.radialEntries) { entry in
                        Button { selectedEntryID = entry.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(entry.title, systemImage: entry.symbol ?? "arrow.triangle.2.circlepath")
                                    .font(.callout.weight(.semibold)).lineLimit(2)
                                if !entry.available || entry.caption.caseInsensitiveCompare(entry.title) != .orderedSame {
                                    Text(entry.available ? entry.caption : entry.reason ?? L("사용할 수 없음"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(10)
                                .background(chosenEntry?.id == entry.id ? model.accentColor.opacity(0.1) : Color.fileeSurface,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(chosenEntry?.id == entry.id ? model.accentColor : Color.primary.opacity(0.1), lineWidth: 1) }
                        }.buttonStyle(.plain).disabled(!entry.available || model.isStarting)
                            .help(entry.reason ?? entry.title).accessibilityAddTraits(chosenEntry?.id == entry.id ? .isSelected : [])
                    }
                }
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    if chosenEntry?.symbol != nil {
                        Text(L("menu.fileAction.description")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label(outputSummary, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("home.sourceProtected")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    guard let entry = chosenEntry else { return }
                    Task { await model.invokeRadialEntry(entry) }
                } label: {
                    Text(chosenEntry.map { L("menu.invoke", $0.title) } ?? L("menu.choose"))
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(chosenEntry == nil || model.isResolving || model.isStarting || !model.isConnected)
            }
            Button(L("home.openRadial")) {
                Task { await model.resolve(model.selectedFiles, clickMode: true) }
            }.buttonStyle(.borderless).disabled(model.isResolving || model.isStarting || !model.isConnected)
        }
    }

    private var outputSummary: String {
        let preset: JSONValue?
        if let entry = chosenEntry, case .preset(let slice) = entry {
            preset = model.library?.presets.first { $0.identity == slice.presetId }
        } else { preset = nil }
        let output = preset?["output"]
        let rule = output?["location"]?.string == "default" || output?["location"] == nil
            ? model.library?.settings["defaultOutput"] : output
        switch rule?["location"]?.string {
        case "customFolder": return rule?["customFolder"]?.string ?? L("지정 폴더")
        case "subfolder": return L("하위 폴더") + " · " + (rule?["subfolderName"]?.string ?? "")
        default: return L("원본 폴더")
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.selectedFiles.isEmpty ? L("전체 출력 형식") : L("선택한 파일 %@개 · 출력 형식", String(describing: (model.selectedFiles.count)))).font(.headline)
                Spacer()
                TextField(L("형식 검색"), text: $targetSearch, prompt: Text(L("형식 검색"))).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            if let selection = model.selection {
                ForEach(selection.rejected, id: \.path) { rejected in Text("\(URL(fileURLWithPath: rejected.path).lastPathComponent): \(rejected.reason)").font(.caption).foregroundStyle(.red) }
                if !selection.unknown.isEmpty { Text(L("확장자를 알 수 없는 파일도 압축 합치기에 사용할 수 있습니다.")).font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach((model.catalog?.formats ?? []).filter { $0.writable && (targetSearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(targetSearch) || $0.id.localizedCaseInsensitiveContains(targetSearch)) }, id: \.id) { format in
                    let target = model.selection?.targets.first { $0.formatId == format.id }
                    Button { Task { await model.start(targetFormat: format.id) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(format.displayName).font(.callout.weight(.semibold))
                            Text(target.map { $0.available ? L("%@개 처리 가능", String(describing: ($0.runnableCount))) : $0.reasonText ?? L("사용할 수 없음") } ?? L("파일을 선택하세요"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.vertical, 6)
                    }.buttonStyle(.bordered).disabled(target?.available != true || model.isStarting || model.isResolving)
                        .help(target?.reasonText ?? format.displayName)
                }
                ForEach((model.selection?.targets ?? []).filter { ["*", "folder"].contains($0.formatId) }, id: \.formatId) { target in
                    Button(target.formatId == "folder" ? L("압축 해제") : L("같은 형식으로 처리")) { Task { await model.start(targetFormat: target.formatId) } }
                        .disabled(!target.available || model.isStarting).help(target.reasonText ?? "")
                }
            }
        }.fileeCard()
    }
}

struct JobCard: View {
    let model: AppModel
    let job: HostJob
    @State private var showFiles = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.preset?.libraryName ?? job.presetName).font(.headline)
                Text(model.cancellingJobIDs.contains(job.jobId) ? L("취소 중…") : AppModel.stateTitle(job.state))
                    .font(.callout).foregroundStyle(.secondary).contentTransition(.opacity)
                Spacer()
                Text("\(Int(job.progress * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: job.progress))
                Button(L("취소")) { Task { await model.cancel(jobID: job.jobId) } }.controlSize(.small).disabled(model.cancellingJobIDs.contains(job.jobId))
            }
            ProgressView(value: min(max(job.progress, 0), 1), total: 1).progressViewStyle(.linear)
                .animation(Motion.when(!model.reduceMotion, .linear(duration: 0.3)), value: job.progress)
            DisclosureGroup(L("파일 %@개 · %@%", String(describing: (job.files.count)), String(describing: (Int(job.progress * 100)))), isExpanded: $showFiles) {
                ForEach(job.files, id: \.source) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.source).lastPathComponent + " · " + AppModel.stateTitle(file.state))
                        if let error = file.errorDetail ?? file.errorKey { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.font(.caption).padding(.vertical, 3)
                }
            }.font(.callout)
        }.fileeCard()
    }
}

struct HistoryCard: View {
    let model: AppModel
    let entry: HostHistory
    @State private var showFailures = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: entry.state == "completed" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 17)).foregroundStyle(entry.state == "completed" ? model.accentColor : Color.red)
                    .frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.preset?.libraryName ?? entry.presetName).font(.callout.weight(.semibold))
                    Text(L("%@개 파일 · %@ · %@", String(describing: (entry.sources.count)), String(describing: (AppModel.stateTitle(entry.state))), entry.finishedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: model.language.rawValue)))))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !entry.outputs.isEmpty {
                    Button { model.reveal(entry.outputs) } label: { Label(L("폴더 열기"), systemImage: "folder") }.controlSize(.small)
                }
            }
            if !entry.failures.isEmpty || entry.state == "failed" {
                HStack {
                    Button(showFailures ? L("실패 목록 접기") : L("실패 %@개 확인", String(describing: (entry.failures.count)))) { showFailures.toggle() }.buttonStyle(.plain).foregroundStyle(.red)
                    Spacer()
                    if entry.preset != nil { Button(L("재시도")) { Task { await model.retry(entry) } }.disabled(!model.isConnected || model.isStarting) }
                }
                if showFailures {
                    ForEach(entry.failures, id: \.source) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: failure.source).lastPathComponent).fontWeight(.semibold)
                            Text(failure.errorDetail ?? failure.errorKey ?? L("변환하지 못했습니다.")).foregroundStyle(.red)
                        }.font(.caption).textSelection(.enabled)
                    }
                    if entry.failures.isEmpty { Text(L("작업 단계에서 실패했습니다. 원래 입력과 당시 프리셋으로 재시도합니다.")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if entry.outputs.count > 1 {
                DisclosureGroup(L("결과 %@개", String(describing: (entry.outputs.count)))) {
                    ForEach(entry.outputs, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { model.reveal([path]) }.buttonStyle(.link) }
                }.font(.caption)
            }
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// Title then icon, with the icon rotating (disclosure chevron).
private struct TrailingIconLabel: LabelStyle {
    let rotation: Double
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon.font(.caption.weight(.semibold)).rotationEffect(.degrees(rotation))
        }
    }
}
