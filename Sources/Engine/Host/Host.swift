import Foundation

final class Host: @unchecked Sendable {
    private struct Tracked { let job: ConversionJob; var dirty = true }
    private let gate = NSRecursiveLock()
    private var jobs: [String: Tracked] = [:], jobOrder: [String] = []
    private let wire: WireWriter, store: UserDataStore, catalog: ConverterCatalog, queue: JobQueue, loc: Localizer
    private let languageFixed: Bool
    private var revision = 1
    private let flush: DispatchSourceTimer
    init(_ wire: WireWriter, _ store: UserDataStore, _ converters: [Converter], _ loc: Localizer, languageFixed: Bool, onStaging: @escaping (String) throws -> Void) {
        self.wire = wire; self.store = store; self.loc = loc; self.languageFixed = languageFixed
        catalog = ConverterCatalog(converters); catalog.priority = store.settings.enginePriority
        EngineEnvironment.ownCopies = store.settings.engineOwnCopies
        queue = JobQueue(catalog, pdfMerger: EngineRegistry.findPdfMerger(converters), combiner: EngineRegistry.findFileCombiner(converters), tiffMerger: EngineRegistry.findTiffMerger(converters), onStaging: onStaging)
        flush = DispatchSource.makeTimerSource(queue: .global())
        queue.jobUpdated = { [weak self] job in self?.gate.withLock { if self?.jobs[job.id] != nil { self?.jobs[job.id]?.dirty = true } } }
        queue.jobFinished = { [weak self] job in self?.onJobFinished(job) }
        flush.schedule(deadline: .now() + 0.1, repeating: 0.1)
        flush.setEventHandler { [weak self] in self?.flushUpdates() }; flush.resume()
    }
    /// nil means job.start already queued its response under the event gate.
    func handle(_ id: String?, _ method: String, _ p: [String: Any]) throws -> Any? {
        switch method {
        case "catalog.get": return try catalogData()
        case "selection.resolve":
            let paths = try Validation.paths(Self.strings(p, "paths"))
            let snapshot = gate.withLock { (store.profiles, store.presets) }
            return Selection(catalog, snapshot.0, snapshot.1, loc).resolve(paths)
        case "job.start": try startJob(id, p); return nil
        case "job.cancel": let jobId = try Self.text(p, "jobId"); gate.withLock { jobs[jobId]?.job.cancel() }; return [String: Any]()
        case "history.get": return try gate.withLock { ["entries": try WireJson.toNode(store.history)] }
        case "history.clear": return try gate.withLock { try store.clearHistory(); return [String: Any]() }
        case "library.get": return try gate.withLock { try libraryData() }
        case "library.save": return try gate.withLock { try saveLibrary(p) }
        case "settings.save": return try saveSettings(p)
        default: throw WireException("unknown_method", "Unknown method \(method).")
        }
    }
    private func catalogData() throws -> [String: Any] {
        catalog.refresh()
        let formats = try FormatRegistry.known.map { f -> [String: Any] in
            ["id": f.id, "displayName": f.id == FormatRegistry.folder ? loc["format.folder"] : f.displayName, "category": try WireJson.toNode(f.category), "extensions": f.id == FormatRegistry.folder ? [] : f.extensions, "writable": f.writable, "isVirtual": f.id == FormatRegistry.folder]
        }
        let engines = catalog.ordered.map { c -> [String: Any] in
            let s = catalog.statusOf(c)
            return ["id": c.id, "displayName": c.displayName, "available": s.isAvailable, "reasonKey": s.reasonKey as Any? ?? NSNull(), "detail": s.detail as Any? ?? NSNull(), "version": s.version as Any? ?? NSNull()]
        }
        return ["formats": formats, "engines": engines]
    }
    private func startJob(_ id: String?, _ p: [String: Any]) throws {
        let paths = try Validation.paths(Self.strings(p, "paths"))
        let given = ["presetId", "targetFormat", "preset"].filter { p[$0] != nil && !(p[$0] is NSNull) }
        if given.count != 1 { throw WireException("bad_request", "Give exactly one of presetId, targetFormat and preset.") }
        var preset: Preset
        switch given[0] {
        case "presetId":
            let presetId = try Self.text(p, "presetId")
            guard let found = gate.withLock({ store.findPreset(presetId) }) else { throw WireException("not_found", "No preset \(presetId).") }; preset = found
        case "targetFormat":
            let target = try Self.text(p, "targetFormat")
            if !Validation.isTarget(target) { throw WireException("invalid_input", "\(target) is not a target format.") }
            preset = Preset(); preset.targetFormat = target; preset.output.conflict = .rename
        default: preset = try WireJson.readStrict(Preset.self, p["preset"], "preset"); try Validation.preset(preset)
        }
        gate.withLock {
            let job = queue.enqueue(paths, store.settings.withDefaultOutput(preset), loc.displayName(preset))
            jobs[job.id] = Tracked(job: job); jobOrder.append(job.id)
            wire.response(id, ["jobId": job.id])
        }
    }
    func cancelAll(_ timeout: TimeInterval) async {
        gate.withLock { for t in jobs.values { t.job.cancel() } }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if gate.withLock({ jobs.isEmpty }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        flush.cancel()
    }
    private func flushUpdates() {
        gate.withLock {
            for id in jobOrder {
                guard let t = jobs[id], t.dirty else { continue }
                jobs[id]?.dirty = false
                var data = jobData(t.job, finished: false)
                if !wire.send(event("job.updated", data)) { data["files"] = [[String: Any]](); _ = wire.send(event("job.updated", data)) }
            }
        }
    }
    private func onJobFinished(_ job: ConversionJob) {
        gate.withLock {
            defer { jobs.removeValue(forKey: job.id); jobOrder.removeAll { $0 == job.id } }
            do {
                let state = stateOf(job)
                var entry = HistoryEntry.from(job); entry.state = state
                var retry: [String]?
                if !entry.failures.isEmpty { retry = entry.failures.map(\.source) }
                else if state == .failed || state == .cancelled { retry = job.sources; entry.preset = job.preset }
                do { try store.addHistory(entry) } catch { FileHandle.standardError.write(Data("[host] could not save the history: \(error)\n".utf8)) }
                var data = jobData(job, finished: true)
                data["historyEntry"] = try WireJson.toNode(entry)
                data["retrySources"] = retry as Any? ?? NSNull()
                data["preset"] = try retry.map { _ in try WireJson.toNode(entry.preset ?? job.preset) } ?? NSNull()
                if !wire.send(event("job.finished", data)) { wire.fatal("message_too_large", "job.finished of \(job.id) is larger than \(WireJson.maxLine) bytes.") }
            } catch {
                if !wire.send(event("job.finished", jobData(job, finished: false))) { wire.fatal("internal", "Could not report job \(job.id).") }
            }
        }
    }
    private func event(_ name: String, _ data: [String: Any]) -> [String: Any] { ["v": 1, "event": name, "data": data] }
    private func stateOf(_ job: ConversionJob) -> JobState { job.lock.withLock { job.state == .failed && job.isCancellationRequested ? .cancelled : job.state } }
    private func jobData(_ job: ConversionJob, finished: Bool) -> [String: Any] {
        job.lock.withLock {
            let files = job.files.map { f -> [String: Any] in
                var data: [String: Any] = ["source": f.sourcePath, "state": String(f.state.rawValue.prefix(1)).lowercased() + f.state.rawValue.dropFirst(), "progress": f.progress, "errorKey": f.errorKey as Any? ?? NSNull()]
                if finished { data["outputs"] = f.outputs.map { ["path": $0, "isDirectory": FileManager.default.directoryExists($0)] as [String: Any] }; data["errorDetail"] = f.errorDetail as Any? ?? NSNull() }
                return data
            }
            let state = stateOf(job).rawValue
            return ["jobId": job.id, "state": String(state.prefix(1)).lowercased() + state.dropFirst(), "progress": job.progress, "presetName": job.presetDisplayName, "files": files]
        }
    }
    private func libraryData() throws -> [String: Any] { ["revision": revision, "settings": try WireJson.toNode(store.settings), "presets": try WireJson.toNode(store.presets), "profiles": try WireJson.toNode(store.profiles)] }
    private func saveLibrary(_ p: [String: Any]) throws -> [String: Any] {
        try checkRevision(p)
        let presets = try WireJson.readStrict([Preset].self, p["presets"], "presets"), profiles = try WireJson.readStrict([ToolbarProfile].self, p["profiles"], "profiles")
        try Validation.library(presets, profiles)
        store.presets = presets; store.profiles = profiles; try store.saveLibrary(); revision += 1; return try libraryData()
    }
    private func saveSettings(_ p: [String: Any]) throws -> [String: Any] {
        let result = try gate.withLock { () -> [String: Any] in
            try checkRevision(p)
            var settings = try WireJson.readStrict(AppSettings.self, p["settings"], "settings"); try Validation.settings(settings)
            settings.engineOwnCopies = settings.engineOwnCopies.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            store.settings = settings; try store.saveSettings(); revision += 1
            catalog.priority = settings.enginePriority; EngineEnvironment.ownCopies = settings.engineOwnCopies; EngineEnvironment.forgetSystemCopies()
            if !languageFixed { loc.setLanguage(settings.language) }
            return try libraryData()
        }
        catalog.refresh(); return result
    }
    private func checkRevision(_ p: [String: Any]) throws {
        guard let base = WireJson.integer(p["baseRevision"]) else { throw WireException("bad_request", "baseRevision must be an integer.") }
        if base != revision { throw WireException("conflict", "The library changed (revision \(revision), not \(base)).") }
    }
    static func text(_ p: [String: Any], _ name: String) throws -> String { guard let s = p[name] as? String, !s.isEmpty else { throw WireException("bad_request", "\(name) must be a non-empty string.") }; return s }
    static func strings(_ p: [String: Any], _ name: String) throws -> [String] { guard let list = p[name] as? [String] else { throw WireException("bad_request", "\(name) must be an array of strings.") }; return list }
}
