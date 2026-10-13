import AppKit
@preconcurrency import ApplicationServices
import Observation

@MainActor @Observable
final class AppModel {
    let host: EngineHost
    private(set) var catalog: HostCatalog?
    private(set) var library: HostLibrary? {
        didSet { Localization.shared.language = AppLanguage.supported(library?.settings["language"]?.string) }
    }
    private(set) var selection: HostSelection?
    private(set) var selectedFiles: [URL] = []
    private(set) var jobs: [HostJob] = []
    private(set) var historyEntries: [HostHistory] = []
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isResolving = false
    private(set) var isStarting = false
    private(set) var cancellingJobIDs: Set<String> = []
    private(set) var interruptedJobIDs: Set<String> = []
    private(set) var pendingJobIDs: Set<String> = []
    private(set) var isShuttingDown = false
    var statusMessage = L("변환 엔진을 연결하는 중…")
    var hasAccessibilityPermission = AXIsProcessTrusted()
    var permissionOnboarding = PermissionOnboarding()
    var radialVisible = false
    var radialClickMode = false
    var radialJobID: String?
    private(set) var radialOuterRadius = 150.0
    private(set) var radialHoleRatio = 0.42
    private(set) var radialOpacity = 0.96
    var selectedPage = "home"
    var editingPresetID: String?
    @ObservationIgnored var onShowRadial: ((NSPoint, Bool) -> Void)?
    @ObservationIgnored var onCloseRadial: (() -> Void)?
    @ObservationIgnored var onLongJob: (() -> Void)?
    @ObservationIgnored var onEditPreset: ((String) -> Void)?
    @ObservationIgnored private var radialHandOffTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var completedRadialTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onAccessibilityPermissionGranted: (() -> Void)?

    init(host: EngineHost = EngineHost(), defaults: UserDefaults = .standard) {
        self.host = host
        self.defaults = defaults
    }
    var language: AppLanguage { Localization.shared.language }

    var activeJobs: [HostJob] {
        jobs.filter { !Self.isFinished($0.state) && !interruptedJobIDs.contains($0.jobId) }
    }
    var isConverting: Bool { isStarting || !pendingJobIDs.isEmpty || !activeJobs.isEmpty }
    var radialJob: HostJob? { jobs.first { $0.jobId == radialJobID } }
    var outerRadius: Double { min(max(library?.settings["donut"]?["outerRadius"]?.double ?? 150, 100), 240) }
    var holeRatio: Double { min(max(library?.settings["donut"]?["holeRatio"]?.double ?? 0.42, 0.2), 0.7) }
    var sliceOpacity: Double { min(max(library?.settings["donut"]?["opacity"]?.double ?? 0.96, 0.5), 1) }
    var reduceMotion: Bool { library?.settings["theme"]?["reduceMotion"]?.bool ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var isDragEnabled: Bool { isConnected && library?.settings["paused"]?.bool != true }

    static func isFinished(_ state: String) -> Bool {
        ["completed", "completedwitherrors", "failed", "cancelled", "interrupted"].contains(state.lowercased())
    }

    func connect() async {
        if isConnecting {
            // File-open callbacks can arrive while launch is still loading metadata.
            while isConnecting {
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return }
            }
            return
        }
        guard !isConnected else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            if eventTask == nil {
                let events = await host.events()
                eventTask = Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { return }
                        self?.consume(event)
                    }
                }
            }
            _ = try await host.start()
            async let fetchedCatalog = host.catalog()
            async let fetchedLibrary = host.library()
            async let fetchedHistory = host.history()
            catalog = try await fetchedCatalog
            library = try await fetchedLibrary
            historyEntries = Array(try await fetchedHistory.prefix(200))
            isConnected = true
            statusMessage = L("파일을 놓으면 원형 툴바에서 변환을 선택할 수 있습니다.")
        } catch { report(error) }
    }

    func selectFiles(_ urls: [URL]) {
        selectionGeneration += 1
        var seen = Set<URL>()
        selectedFiles = urls.filter {
            $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && seen.insert($0).inserted
        }
        selection = nil
        isResolving = false
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L("이미지, 문서, 영상, 압축 파일과 폴더를 선택할 수 있습니다.")
        panel.title = L("파일 또는 폴더 선택…")
        panel.prompt = L("Select")
        if panel.runModal() == .OK {
            Task { await resolve(panel.urls, clickMode: true) }
        }
    }

    private func captureRadialAppearance() {
        radialOuterRadius = outerRadius
        radialHoleRatio = holeRatio
        radialOpacity = sliceOpacity
    }

    func prepareForDrag() {
        if let job = radialJob, !Self.isFinished(job.state) { onLongJob?() }
        captureRadialAppearance()
        completedRadialTask?.cancel()
        selectFiles([])
        radialJobID = nil
        radialClickMode = false
        radialVisible = false
    }

    func resolve(_ urls: [URL], clickMode: Bool = true, showRadial: Bool = true) async {
        let local = urls.filter { $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }
        if selectedFiles == local && (selection != nil || isResolving) {
            if clickMode, !isResolving {
                completedRadialTask?.cancel()
                if let job = radialJob, !Self.isFinished(job.state) { onLongJob?() }
                radialJobID = nil
                captureRadialAppearance()
                radialClickMode = true
                radialVisible = true
                if showRadial { onShowRadial?(NSEvent.mouseLocation, true) }
            }
            return
        }
        selectFiles(local)
        guard !selectedFiles.isEmpty, isConnected else { return }
        completedRadialTask?.cancel()
        if let job = radialJob, !Self.isFinished(job.state) { onLongJob?() }
        radialJobID = nil
        if clickMode { captureRadialAppearance() }
        radialClickMode = clickMode
        radialVisible = true
        if showRadial { onShowRadial?(NSEvent.mouseLocation, clickMode) }
        let generation = selectionGeneration
        let paths = selectedFiles.map(\.path)
        isResolving = true
        do {
            let response = try await host.resolve(paths: paths)
            guard generation == selectionGeneration else { return }
            selection = response
            isResolving = false
            statusMessage = L("파일 %@개 · 변환할 프리셋 또는 출력 형식을 선택하세요.", String(describing: (paths.count)))
        } catch {
            guard generation == selectionGeneration else { return }
            isResolving = false
            report(error)
        }
    }

    func start(presetID: String) async {
        guard selection?.slices.contains(where: { $0.presetId == presetID && $0.available }) == true else { return }
        await startJob(presetID: presetID)
    }

    func start(targetFormat: String) async {
        guard selection?.targets.contains(where: { $0.formatId == targetFormat && $0.available }) == true else { return }
        await startJob(targetFormat: targetFormat)
    }

    private func startJob(presetID: String? = nil, targetFormat: String? = nil, paths: [String]? = nil, preset: JSONValue? = nil) async {
        guard isConnected, !isResolving, !isStarting, !isShuttingDown else { return }
        let sources = paths ?? selectedFiles.map(\.path)
        guard !sources.isEmpty else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            radialJobID = try await host.startJob(paths: sources, presetId: presetID, targetFormat: targetFormat, preset: preset)
            if let id = radialJobID, !jobs.contains(where: { $0.jobId == id }) { pendingJobIDs.insert(id) }
            radialVisible = true
            statusMessage = L("변환 중…")
            if let job = radialJob, Self.isFinished(job.state) { scheduleRadialClose(job) }
            else { scheduleHandOff() }
        } catch { report(error) }
    }

    func cancel(jobID: String) async {
        guard cancellingJobIDs.insert(jobID).inserted else { return }
        do { try await host.cancel(jobId: jobID) }
        catch { cancellingJobIDs.remove(jobID); report(error) }
    }

    func cancelAll() async {
        let ids = Set(activeJobs.map(\.jobId)).union(pendingJobIDs)
        for id in ids { await cancel(jobID: id) }
    }

    func shutDown() async {
        isShuttingDown = true
        while isStarting { try? await Task.sleep(for: .milliseconds(50)) }
        await cancelAll()
        while isConverting { try? await Task.sleep(for: .milliseconds(50)) }
        await host.shutdown()
    }

    func retry(_ entry: HostHistory) async {
        guard let preset = entry.preset else { return }
        let paths = entry.failures.isEmpty ? entry.sources : entry.failures.map(\.source)
        await startJob(paths: paths, preset: preset)
    }

    func consume(_ event: HostEvent) {
        switch event {
        case .hello:
            if !isConnected && !isConnecting { Task { await connect() } }
        case .updated(let job): record(job)
        case .finished(let job):
            record(job)
            cancellingJobIDs.remove(job.jobId)
            if let history = job.historyEntry {
                historyEntries.removeAll { $0.jobId == history.jobId }
                historyEntries.insert(history, at: 0)
                historyEntries = Array(historyEntries.prefix(200))
            }
            statusMessage = "\(job.preset?.libraryName ?? job.presetName) · \(Self.stateTitle(job.state))"
            if radialJobID == job.jobId { scheduleRadialClose(job) }
        case .fatal(let message), .interrupted(let message):
            interruptedJobIDs.formUnion(activeJobs.map(\.jobId))
            cancellingJobIDs = []
            pendingJobIDs = []
            trimCompletedJobs()
            isConnected = false
            statusMessage = L("변환 엔진 연결이 끊겼습니다. %@", L(message))
            closeRadial()
        }
    }

    private func scheduleRadialClose(_ job: HostJob) {
        radialHandOffTask?.cancel()
        completedRadialTask?.cancel()
        completedRadialTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(job.state == "failed" ? 1400 : 900))
            guard !Task.isCancelled, self?.radialJobID == job.jobId else { return }
            self?.closeRadial()
        }
    }

    private func scheduleHandOff() {
        radialHandOffTask?.cancel()
        let id = radialJobID
        radialHandOffTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, radialJobID == id,
                  let job = radialJob, !Self.isFinished(job.state) else { return }
            closeRadial()
            onLongJob?()
        }
    }

    func editPreset(_ id: String) { editingPresetID = id; onEditPreset?(id) }

    private func record(_ job: HostJob) {
        pendingJobIDs.remove(job.jobId)
        if let index = jobs.firstIndex(where: { $0.jobId == job.jobId }) { jobs[index] = job }
        else { jobs.insert(job, at: 0) }
        trimCompletedJobs()
    }

    private func trimCompletedJobs() {
        var completedCount = 0
        jobs.removeAll { job in
            guard !pendingJobIDs.contains(job.jobId),
                  Self.isFinished(job.state) || interruptedJobIDs.contains(job.jobId) else { return false }
            completedCount += 1
            return completedCount > 200
        }
        interruptedJobIDs.formIntersection(jobs.map(\.jobId))
    }

    func closeRadial() { radialVisible = false; onCloseRadial?() }

    func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func refreshLibrary() async {
        do { library = try await host.library(); catalog = try await host.catalog() }
        catch { report(error) }
    }

    @discardableResult
    func savePreset(_ draft: JSONValue, baseRevision: Int? = nil) async -> Bool {
        guard let library else { return false }
        var presets = library.presets
        if let index = presets.firstIndex(where: { $0["id"]?.string == draft["id"]?.string }) { presets[index] = draft }
        else { presets.append(draft) }
        return await saveLibrary(presets: presets, profiles: library.profiles, baseRevision: baseRevision)
    }

    func deletePreset(_ id: String) async {
        guard let library else { return }
        let profiles = library.profiles.map { profile -> JSONValue in
            var changed = profile
            changed["presetIds"] = .array((profile["presetIds"]?.array ?? []).filter { $0.string != id })
            return changed
        }
        await saveLibrary(presets: library.presets.filter { $0["id"]?.string != id }, profiles: profiles)
    }

    @discardableResult
    func saveProfile(_ draft: JSONValue, baseRevision: Int? = nil) async -> Bool {
        guard let library else { return false }
        var profiles = library.profiles
        if let index = profiles.firstIndex(where: { $0["id"]?.string == draft["id"]?.string }) { profiles[index] = draft }
        else { profiles.append(draft) }
        return await saveLibrary(presets: library.presets, profiles: profiles, baseRevision: baseRevision)
    }

    @discardableResult
    private func saveLibrary(presets: [JSONValue], profiles: [JSONValue], baseRevision: Int? = nil) async -> Bool {
        guard let current = library else { return false }
        do {
            library = try await host.saveLibrary(baseRevision: baseRevision ?? current.revision, presets: presets, profiles: profiles)
            statusMessage = L("저장했습니다.")
            return true
        } catch { report(error); return false }
    }

    @discardableResult
    func saveSettings(_ settings: JSONValue, baseRevision: Int? = nil) async -> Bool {
        guard let current = library else { return false }
        do {
            let previousLanguage = language
            let previousLanguageIdentifier = current.settings["language"]?.string
            library = try await host.saveSettings(baseRevision: baseRevision ?? current.revision, settings: settings)
            statusMessage = L("설정을 저장했습니다.")
            do { catalog = try await host.catalog() }
            catch { statusMessage = L("설정은 저장했지만 엔진 상태를 갱신하지 못했습니다. %@", L(error.localizedDescription)) }
            if language != previousLanguage || library?.settings["language"]?.string != previousLanguageIdentifier { await refreshSelectionLanguage() }
            return true
        } catch { report(error); return false }
    }

    private func refreshSelectionLanguage() async {
        guard !selectedFiles.isEmpty else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        let paths = selectedFiles.map(\.path)
        isResolving = true
        do {
            let refreshed = try await host.resolve(paths: paths)
            guard generation == selectionGeneration else { return }
            selection = refreshed
            isResolving = false
        } catch {
            guard generation == selectionGeneration else { return }
            isResolving = false
            report(error)
        }
    }

    func clearHistory() async {
        do { try await host.clearHistory(); historyEntries = [] }
        catch { report(error) }
    }

    func requestAccessibilityPermission() {
        permissionOnboarding.settingsRequested()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermission()
        guard !hasAccessibilityPermission else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        permissionOnboarding.settingsOpenFailed = !NSWorkspace.shared.open(url)
    }

    func refreshPermission() {
        let previouslyGranted = hasAccessibilityPermission
        hasAccessibilityPermission = AXIsProcessTrusted()
        permissionOnboarding.updatePermission(hasAccessibilityPermission)
        if !previouslyGranted, hasAccessibilityPermission { onAccessibilityPermissionGranted?() }
    }

    func beginPermissionOnboarding() {
        permissionOnboarding.begin(hasCompleted: defaults.bool(forKey: "hasCompletedPermissionOnboarding"))
        presentInitialPermissionOnboardingIfNeeded()
    }

    func presentInitialPermissionOnboardingIfNeeded() {
        permissionOnboarding.presentIfNeeded(hasPermission: hasAccessibilityPermission,
                                            isBusy: isResolving || isConverting || radialVisible)
    }

    func showPermissionOnboarding() {
        refreshPermission()
        permissionOnboarding.present(hasPermission: hasAccessibilityPermission)
    }

    func completePermissionOnboarding() {
        permissionOnboarding.complete()
        defaults.set(true, forKey: "hasCompletedPermissionOnboarding")
    }
    private func report(_ error: Error) { statusMessage = L(error.localizedDescription) }

    static func stateTitle(_ state: String) -> String {
        switch state.lowercased() {
        case "completed", "done": L("완료")
        case "completedwitherrors": L("일부 실패")
        case "failed": L("실패")
        case "cancelled": L("취소됨")
        case "queued", "pending": L("대기 중")
        case "running": L("변환 중")
        case "skipped": L("Skipped")
        case "interrupted": L("Interrupted")
        default: state
        }
    }
}
