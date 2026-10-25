import Foundation

public enum JobState: String, CaseIterable, Sendable { case queued = "Queued", running = "Running", completed = "Completed", completedWithErrors = "CompletedWithErrors", failed = "Failed", cancelled = "Cancelled" }
public enum FileState: String, CaseIterable, Sendable { case pending = "Pending", running = "Running", done = "Done", skipped = "Skipped", failed = "Failed", cancelled = "Cancelled" }
public final class FileResult {
    public let sourcePath: String
    public var state = FileState.pending
    public var progress = 0.0
    public var outputs: [String] = []
    public var errorKey: String?
    public var errorDetail: String?
    public init(_ sourcePath: String) { self.sourcePath = sourcePath }
}
public final class ConversionJob: @unchecked Sendable {
    public let id = String(Preset.newId().prefix(10))
    public let createdAt = Date()
    public let sources: [String]
    public let preset: Preset
    public let presetDisplayName: String
    public let files: [FileResult]
    let validateOutput: ((String) throws -> Void)?
    public internal(set) var state = JobState.queued
    let lock = NSRecursiveLock()
    private var cancelled = false
    private var task: Task<Void, Never>?
    public init(_ sources: [String], _ preset: Preset, _ presetDisplayName: String, validateOutput: ((String) throws -> Void)? = nil) { self.sources = sources; self.preset = preset; self.presetDisplayName = presetDisplayName; self.validateOutput = validateOutput; files = sources.map(FileResult.init) }
    public var progress: Double { lock.withLock { files.isEmpty ? 1 : files.reduce(0) { $0 + $1.progress } / Double(files.count) } }
    public var outputs: [String] { lock.withLock { files.flatMap(\.outputs) } }
    public var isCancellationRequested: Bool { lock.withLock { cancelled } }
    public func cancel() { let task = lock.withLock { cancelled = true; return self.task }; task?.cancel() }
    func attach(_ task: Task<Void, Never>?) { let cancel = lock.withLock { self.task = task; return cancelled }; if cancel { task?.cancel() } }
    func checkCancellation() throws { if isCancellationRequested { throw CancellationError() }; try Task.checkCancellation() }
}
