import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false
    @State private var targetSearch = ""
    @State private var showAllTargets = false

    private var motion: Bool { !model.reduceMotion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dropZone
                HStack(spacing: 10) {
                    Button(action: model.chooseFiles) { Label(L("파일 또는 폴더 선택…"), systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o", modifiers: .command)
                    Spacer()
                    Button { showAllTargets.toggle() } label: {
                        Label(showAllTargets ? L("형식 목록 접기") : L("모든 출력 형식"), systemImage: "chevron.down")
                            .labelStyle(TrailingIconLabel(rotation: showAllTargets ? 180 : 0))
                    }.controlSize(.large)
                }
                if !model.selectedFiles.isEmpty { selectedFiles.transition(.blurSwap) }
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
                Text("⌥").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(L("Finder에서 Option 키를 누른 채 파일을 드래그하면 커서 위치에 원형 툴바가 열립니다."))
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
        .overlay { FileDropTarget(isTargeted: $isTargeted, isEnabled: model.isConnected) { urls in Task { await model.resolve(urls) } } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("변환할 파일 드롭 영역"))
    }

    private var selectedFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("선택한 파일 %@개", String(describing: (model.selectedFiles.count)))).font(.callout.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.selectedFiles, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc")
                            .font(.caption).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .help(url.path)
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
