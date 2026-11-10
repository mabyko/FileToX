import Foundation

public final class JobQueue: @unchecked Sendable {
    private let catalog: ConverterCatalog
    private let pdfMerger: PdfMerger?
    private let combiner: FileCombiner?
    private let tiffMerger: TiffMerger?
    private let onStaging: ((String) throws -> Void)?
    private let outputExists: (String) -> Bool
    private let beforeOutputCommit: ((String) throws -> Void)?
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var gates: [String: EngineConcurrencyGate] = [:]
    private var reserved: [String: String] = [:]
    public var jobUpdated: ((ConversionJob) -> Void)?
    public var jobFinished: ((ConversionJob) -> Void)?
    public init(_ catalog: ConverterCatalog, pdfMerger: PdfMerger? = nil, combiner: FileCombiner? = nil, tiffMerger: TiffMerger? = nil, outputExists: @escaping (String) -> Bool = { FileManager.default.fileExists($0) || FileManager.default.directoryExists($0) }, beforeOutputCommit: ((String) throws -> Void)? = nil, onStaging: ((String) throws -> Void)? = nil) { self.catalog = catalog; self.pdfMerger = pdfMerger; self.combiner = combiner; self.tiffMerger = tiffMerger; self.outputExists = outputExists; self.beforeOutputCommit = beforeOutputCommit; self.onStaging = onStaging }
    @discardableResult public func enqueue(_ sources: [String], _ preset: Preset, _ presetDisplayName: String, validateOutput: ((String) throws -> Void)? = nil) -> ConversionJob {
        let job = ConversionJob(sources, preset, presetDisplayName, validateOutput: validateOutput)
        lock.withLock {
            let previous = tail
            tail = Task { [self] in
                await previous?.value
                if job.isCancellationRequested { job.lock.withLock { job.state = .cancelled }; notify(job); jobFinished?(job) }
                else { await run(job) }
            }
        }
        notify(job); return job
    }
    public func dispose() async { let task = lock.withLock { tail }; await task?.value }
    public func run(_ job: ConversionJob) async {
        let task = Task { await self.execute(job) }
        job.attach(task)
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { job.cancel() })
        job.attach(nil)
    }
    private func execute(_ job: ConversionJob) async {
        job.lock.withLock { job.state = .running }; notify(job)
        let temp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let work = FilePath.combine(temp, "Filee", job.id)
        do {
            try FileManager.default.createDirectoryIfNeeded(work)
            let planner = catalog.createPlanner()
            if job.preset.pdf.mergeIntoSingle && job.preset.targetFormat == "pdf" && job.files.count > 1 && pdfMerger != nil {
                try await merged(job, planner, work, tiff: false)
            } else if job.preset.image.multiPageTiff && job.preset.targetFormat == "tiff" && tiffMerger != nil {
                try await merged(job, planner, work, tiff: true)
            } else if job.preset.archive.combineIntoOne && combiner != nil && FormatRegistry.find(id: job.preset.targetFormat)?.category == .archive && job.preset.targetFormat != FormatRegistry.folder {
                try await combined(job, work)
            } else {
                _ = await parallelFiles(job) { file, i in await self.runFile(job, file, i, planner, work, finalOutput: true) }
            }
            job.lock.withLock {
                job.state = job.isCancellationRequested ? .cancelled : job.files.allSatisfy { $0.state == .done || $0.state == .skipped } ? .completed : job.files.contains { $0.state == .done } ? .completedWithErrors : .failed
            }
        } catch is CancellationError { job.lock.withLock { job.state = .cancelled } }
        catch { job.lock.withLock { job.state = .failed } }
        lock.withLock { for path in job.outputs where reserved[path.lowercased()] == job.id { reserved.removeValue(forKey: path.lowercased()) } }
        OutputCommit.tryDelete(work)
        notify(job); jobFinished?(job)
    }
    private func parallelFiles(_ job: ConversionJob, _ body: @escaping (FileResult, Int) async -> [String]) async -> [[String]] {
        await withTaskGroup(of: (Int, [String]).self) { group in
            var next = 0, results = Array(repeating: [String](), count: job.files.count)
            func add(_ i: Int) { group.addTask { (i, await body(job.files[i], i + 1)) } }
            while next < min(ProcessInfo.processInfo.activeProcessorCount, job.files.count) { add(next); next += 1 }
            while let (i, paths) = await group.next() { results[i] = paths; if next < job.files.count { add(next); next += 1 } }
            return results
        }
    }
    private func merged(_ job: ConversionJob, _ planner: RoutePlanner, _ work: String, tiff: Bool) async throws {
        let format = tiff ? "tiff" : "pdf"
        let parts = await parallelFiles(job) { file, index in
            if FormatRegistry.detect(file.sourcePath)?.id == format { return [file.sourcePath] }
            let paths = await self.runFile(job, file, index, planner, work, finalOutput: false, intermediate: format)
            return tiff ? paths : Array(paths.prefix(1))
        }
        let inputs = parts.flatMap { $0 }
        if inputs.isEmpty || job.isCancellationRequested { return }
        let first = job.files[0], allocator = FinalAllocator(self, job, job.files[0].sourcePath, 1)
        defer { allocator.abort() }
        guard let output = try allocator.allocate(format) else { job.lock.withLock { for f in job.files { f.state = .skipped } }; return }
        if tiff { try await tiffMerger!.merge(inputs, into: output, options: job.preset.image) }
        else { try await pdfMerger!.merge(inputs, into: output) }
        if try !commit(job, first, allocator, [output]) {
            job.lock.withLock { for f in job.files where f !== first && f.state != .failed { f.state = .failed; f.errorKey = first.errorKey; f.errorDetail = first.errorDetail } }; return
        }
        job.lock.withLock { for f in job.files where f.state != .failed { f.state = .done; f.progress = 1 } }; notify(job)
    }
    private func combined(_ job: ConversionJob, _ work: String) async throws {
        let format = FormatRegistry.get(job.preset.targetFormat)
        let inputs = job.files.filter { f in
            if FileManager.default.fileExists(f.sourcePath) || FileManager.default.directoryExists(f.sourcePath) { return true }
            fail(job, f, "error.conversion_failed", "The file no longer exists."); return false
        }
        if inputs.isEmpty { notify(job); return }
        let allocator = FinalAllocator(self, job, inputs[0].sourcePath, 1)
        defer { allocator.abort() }
        guard let output = try allocator.allocate(format.primaryExtension) else {
            job.lock.withLock { for f in inputs { f.state = .skipped; f.progress = 1 } }; notify(job); return
        }
        job.lock.withLock { for f in inputs { f.state = .running } }; notify(job)
        do {
            try job.checkCancellation()
            try await combiner!.combine(inputs.map(\.sourcePath), into: output, format: format.id, preset: job.preset, workDirectory: work, progress: { p in
                job.lock.withLock { let value = min(1, max(0, p)); if value > inputs[0].progress { for f in inputs { f.progress = value } } }; self.notify(job)
            })
            if try commit(job, inputs[0], allocator, [output]) { job.lock.withLock { for f in inputs { f.state = .done; f.progress = 1 } } }
            else { for f in inputs.dropFirst() { fail(job, f, inputs[0].errorKey ?? "", inputs[0].errorDetail ?? "") } }
        } catch is CancellationError { job.lock.withLock { for f in inputs { f.state = .cancelled } } }
        catch { for f in inputs { fail(job, f, "error.conversion_failed", error.localizedDescription) } }
        notify(job)
    }
    /// Formats that hold a PDF's page pictures through PDF → DOCX, so its pages without text are kept. Other targets, TXT
    /// included, keep the no-text failure and get only the text.
    private static let pagePictureFormats: Set = ["odt", "epub", "fb2", "htmlz", "txtz"]
    private func runFile(_ job: ConversionJob, _ file: FileResult, _ index: Int, _ planner: RoutePlanner, _ work: String, finalOutput: Bool, intermediate: String = "pdf", textExtraction: Bool = true) async -> [String] {
        guard let source = FormatRegistry.detect(file.sourcePath) else { fail(job, file, "error.unsupported_source", "." + FormatRegistry.extensionOf(file.sourcePath)); return [] }
        let target = !finalOutput ? intermediate : job.preset.targetFormat == BuiltInData.sameAsSource ? source.id : job.preset.targetFormat
        guard let route = planner.plan(source.id, target, textExtraction: textExtraction) else { fail(job, file, "error.no_route", "\(source.id) → \(target)"); return [] }
        let keepsPages = source.id == "pdf" && Self.pagePictureFormats.contains(target)
            && planner.plan(source.id, target, textExtraction: false)?.steps.first?.to == "docx"
        job.lock.withLock { file.state = .running }; notify(job)
        var final: FinalAllocator?
        defer { final?.abort() }
        do {
            var inputs = [file.sourcePath]
            for (s, step) in route.steps.enumerated() {
                let allocator: OutputAllocator
                if s == route.steps.count - 1 && finalOutput { let a = FinalAllocator(self, job, file.sourcePath, index); final = a; allocator = a }
                else { allocator = TempAllocator(work, FormatRegistry.nameWithoutExtension(file.sourcePath)) }
                var outputs: [String] = []
                for input in inputs {
                    try job.checkCancellation()
                    let gate = gateFor(step.converter)
                    try await gate.acquire()
                    do {
                        try job.checkCancellation()
                        let produced = try await step.converter.convert(ConversionStep(inputPath: input, from: step.from, to: step.to, preset: job.preset, output: allocator, workDirectory: work, keepsPages: keepsPages), progress: { p in
                            let value = (Double(s) + min(1, max(0, p))) / Double(route.steps.count)
                            let changed = job.lock.withLock { () -> Bool in if value <= file.progress { return false }; file.progress = value; return true }
                            if changed { self.notify(job) }
                        })
                        outputs += produced
                        await gate.release()
                    } catch { await gate.release(); throw error }
                }
                inputs = outputs
            }
            if finalOutput {
                let produced = inputs.count, committed = job.lock.withLock { file.outputs.count }
                if try !commit(job, file, final!, inputs) { return [] }
                inputs = job.lock.withLock { Array(file.outputs.dropFirst(committed)) }
                if job.preset.output.keepDates { copyDates(file.sourcePath, inputs) }
                if produced > 0 && inputs.isEmpty { fail(job, file, "error.output_commit_failed", "No output was written."); return [] }
            }
            job.lock.withLock { file.state = inputs.isEmpty && finalOutput ? .skipped : .done; file.progress = 1 }; notify(job)
            return inputs
        } catch is CancellationError { job.lock.withLock { file.state = .cancelled }; notify(job); return [] }
        // Only the text bridge failed (no text, or pages it would leave out), before the last step allocated an output:
        // plan once more through the page pictures.
        catch is NoTextError where keepsPages && textExtraction && final == nil {
            return await runFile(job, file, index, planner, work, finalOutput: finalOutput, intermediate: intermediate, textExtraction: false)
        }
        catch { fail(job, file, "error.conversion_failed", error.localizedDescription); return [] }
    }
    private func commit(_ job: ConversionJob, _ file: FileResult, _ allocator: FinalAllocator, _ produced: [String]) throws -> Bool {
        try job.checkCancellation()
        do { try allocator.commit(produced) { path in job.lock.withLock { file.outputs.append(path) } }; return true }
        catch let error as OutputCommitException { fail(job, file, error.errorKey, error.message); return false }
    }
    private func copyDates(_ source: String, _ outputs: [String]) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = attributes[.creationDate]; dates[.modificationDate] = attributes[.modificationDate]
        for output in outputs { try? FileManager.default.setAttributes(dates, ofItemAtPath: output) }
    }
    private func gateFor(_ converter: Converter) -> EngineConcurrencyGate {
        lock.withLock {
            if let gate = gates[converter.id] { return gate }
            let gate = EngineConcurrencyGate(converter.maxParallelism <= 0 ? ProcessInfo.processInfo.activeProcessorCount : converter.maxParallelism)
            gates[converter.id] = gate; return gate
        }
    }
    private func fail(_ job: ConversionJob, _ file: FileResult, _ key: String, _ detail: String) { job.lock.withLock { file.state = .failed; file.errorKey = key; file.errorDetail = detail; file.progress = 1 }; notify(job) }
    private func notify(_ job: ConversionJob) { jobUpdated?(job) }

    private final class FinalAllocator: OutputAllocator {
        let queue: JobQueue, job: ConversionJob, tokens: OutputPathResolver.Tokens
        let staged: StagedOutputs
        init(_ queue: JobQueue, _ job: ConversionJob, _ source: String, _ index: Int) { self.queue = queue; self.job = job; tokens = .init(source, job.presetDisplayName, index, job.createdAt); staged = StagedOutputs(queue.onStaging) }
        func allocate(_ ext: String, suffix: String?) throws -> String? {
            while true {
                try job.checkCancellation()
                guard let path = OutputPathResolver.resolve(job.preset.output, tokens, ext, reserved: { path in
                    self.queue.lock.withLock { self.queue.reserved[path.lowercased()] != nil }
                }, exists: { path in self.job.isCancellationRequested ? false : self.queue.outputExists(path) }, suffix: suffix) else { return nil }
                try job.validateOutput?(path)
                // Disk checks and rename-pattern matching must never hold the enqueue/reservation lock.
                guard queue.lock.withLock({ () -> Bool in
                    guard queue.reserved[path.lowercased()] == nil else { return false }
                    queue.reserved[path.lowercased()] = job.id; return true
                }) else { continue }
                do { try job.checkCancellation(); try job.validateOutput?(path); try FileManager.default.createDirectoryIfNeeded(FilePath.directoryName(path)!); return try staged.stage(path) }
                catch { release(path); throw error }
            }
        }
        func commit(_ produced: [String], published: (String) -> Void) throws {
            try staged.commit(produced, job.preset.output, job.sources, release, validate: { path in
                try self.queue.beforeOutputCommit?(path)
                try self.job.checkCancellation()
                try self.job.validateOutput?(path)
                try self.job.checkCancellation()
            }, published: published)
        }
        func abort() { staged.abort(release) }
        private func release(_ path: String) { queue.lock.withLock { if queue.reserved[path.lowercased()] == job.id { queue.reserved.removeValue(forKey: path.lowercased()) } } }
    }
    private final class TempAllocator: OutputAllocator {
        let work: String, base: String
        init(_ work: String, _ base: String) { self.work = work; self.base = base }
        func allocate(_ ext: String, suffix: String?) throws -> String? {
            let dir = FilePath.combine(work, String(Preset.newId().prefix(8))); try FileManager.default.createDirectoryIfNeeded(dir)
            let ext = String(ext.drop(while: { $0 == "." }))
            return FilePath.combine(dir, base + (suffix ?? "") + (ext.isEmpty ? "" : "." + ext))
        }
    }
}
private actor EngineConcurrencyGate {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var available: Int
    private var waiting: [Waiter] = []
    init(_ count: Int) { available = count }
    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append(Waiter(id: id, continuation: continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    func release() { if waiting.isEmpty { available += 1 } else { waiting.removeFirst().continuation.resume() } }
    private func cancel(_ id: UUID) {
        if let i = waiting.firstIndex(where: { $0.id == id }) { waiting.remove(at: i).continuation.resume(throwing: CancellationError()) }
    }
}
