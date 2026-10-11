import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var isTargeted = false
    @State private var targetSearch = ""
    @State private var showAllTargets = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.up.to.line").font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(model.accentColor).padding(18)
                        .background(model.accentColor.opacity(0.18), in: Circle()).accessibilityHidden(true)
                    Text(L("여기에 파일을 놓으세요")).font(.headline)
                    Text(L("Finder에서 Option 키를 누른 채 파일을 드래그하면 커서 위치에 원형 툴바가 열립니다."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: 220)
                    .background(model.accentColor.opacity(isTargeted ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).stroke(model.accentColor.opacity(isTargeted ? 1 : 0.2), lineWidth: 2) }
                    .overlay { FileDropTarget(isTargeted: $isTargeted, isEnabled: model.isConnected) { urls in Task { await model.resolve(urls) } } }
                    .accessibilityLabel(L("변환할 파일 드롭 영역"))
                HStack {
                    Button(L("파일 또는 폴더 선택…"), action: model.chooseFiles).keyboardShortcut("o", modifiers: .command)
                    Spacer()
                    Button(showAllTargets ? L("형식 목록 접기") : L("모든 출력 형식")) { showAllTargets.toggle() }
                }
                if !model.selectedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("선택한 파일 %@개", String(describing: (model.selectedFiles.count)))).font(.callout.weight(.semibold))
                        Text(model.selectedFiles.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        if let selection = model.selection, !selection.rejected.isEmpty {
                            DisclosureGroup(L("처리할 수 없는 입력 %@개", String(describing: (selection.rejected.count)))) {
                                ForEach(selection.rejected, id: \.path) { input in
                                    Text("\(URL(fileURLWithPath: input.path).lastPathComponent): \(input.reason)")
                                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                if showAllTargets { targetList }
                ForEach(model.activeJobs, id: \.jobId) { job in JobCard(model: model, job: job) }
                HStack {
                    Text(L("최근 변환")).font(.headline)
                    Spacer()
                    Button(L("지우기")) { Task { await model.clearHistory() } }.buttonStyle(.plain)
                }
                if model.historyEntries.isEmpty { Text(L("변환한 파일이 여기에 표시됩니다.")).foregroundStyle(.secondary) }
                ForEach(Array(model.historyEntries.prefix(40)), id: \.jobId) { entry in HistoryCard(model: model, entry: entry) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedFiles.isEmpty ? L("전체 출력 형식") : L("선택한 파일 %@개 · 출력 형식", String(describing: (model.selectedFiles.count)))).font(.headline)
            TextField(L("형식 검색"), text: $targetSearch).textFieldStyle(.roundedBorder)
            if let selection = model.selection {
                ForEach(selection.rejected, id: \.path) { rejected in Text("\(URL(fileURLWithPath: rejected.path).lastPathComponent): \(rejected.reason)").font(.caption).foregroundStyle(.red) }
                if !selection.unknown.isEmpty { Text(L("확장자를 알 수 없는 파일도 압축 합치기에 사용할 수 있습니다.")).font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach((model.catalog?.formats ?? []).filter { $0.writable && (targetSearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(targetSearch) || $0.id.localizedCaseInsensitiveContains(targetSearch)) }, id: \.id) { format in
                    let target = model.selection?.targets.first { $0.formatId == format.id }
                    Button { Task { await model.start(targetFormat: format.id) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(format.displayName).font(.callout.weight(.semibold))
                            Text(target.map { $0.available ? L("%@개 처리 가능", String(describing: ($0.runnableCount))) : $0.reasonText ?? L("사용할 수 없음") } ?? L("파일을 선택하세요"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
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
            HStack {
                Text(job.preset?.libraryName ?? job.presetName).font(.headline)
                Spacer()
                Text(model.cancellingJobIDs.contains(job.jobId) ? L("취소 중…") : AppModel.stateTitle(job.state)).foregroundStyle(.secondary)
                Button(L("취소")) { Task { await model.cancel(jobID: job.jobId) } }.disabled(model.cancellingJobIDs.contains(job.jobId))
            }
            ProgressView(value: min(max(job.progress, 0), 1), total: 1)
            DisclosureGroup(L("파일 %@개 · %@%", String(describing: (job.files.count)), String(describing: (Int(job.progress * 100)))), isExpanded: $showFiles) {
                ForEach(job.files, id: \.source) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.source).lastPathComponent + " · " + AppModel.stateTitle(file.state))
                        if let error = file.errorDetail ?? file.errorKey { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.font(.caption).padding(.vertical, 3)
                }
            }
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
                Image(systemName: entry.state == "completed" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(entry.state == "completed" ? model.accentColor : Color.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.preset?.libraryName ?? entry.presetName).font(.callout.weight(.semibold))
                    Text(L("%@개 파일 · %@ · %@", String(describing: (entry.sources.count)), String(describing: (AppModel.stateTitle(entry.state))), entry.finishedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: model.language.rawValue)))))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !entry.outputs.isEmpty { Button(L("폴더 열기")) { model.reveal(entry.outputs) } }
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
        }.fileeCard()
    }
}
