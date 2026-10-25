import Foundation
import Darwin

/// Called under the host's event gate; the timer performs disk work on a utility queue.
final class WatchFolderMonitor {
    struct Stamp: Equatable {
        let device: Int32, inode: UInt64, size: Int64
        let modified: timespec, changed: timespec
        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size &&
            a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
        static func read(_ path: String) -> Self? {
            var value = stat()
            guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
            return Self(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                        modified: value.st_mtimespec, changed: value.st_ctimespec)
        }
    }
    struct Batch {
        let rule: WatchRule, preset: Preset, files: [String: Stamp]
    }
    private struct Observation { let stamp: Stamp; let since: Date; var handled: Bool }
    private struct Snapshot { let rule: WatchRule; var files: [String: Observation] }
    private var snapshots: [String: Snapshot] = [:]
    private var active = Set<String>()
    private var errors: [String: String] = [:]
    private(set) var statuses: [[String: Any]] = []
    private let excluded: [String]
    init(excluding paths: [String] = []) { excluded = paths.map(Self.canonical) }

    func scan(_ rules: [WatchRule], presets: [Preset], now: Date = Date()) -> [Batch] {
        snapshots = snapshots.filter { id, _ in rules.contains { $0.id == id && $0.enabled } }
        let outputRoots = rules.filter { !$0.folder.isEmpty }.flatMap { [Self.canonical($0.resolvedOutputFolder), Self.canonical($0.originalsFolder)] } + excluded
        var batches: [Batch] = []
        statuses = rules.map { rule in
            var status: [String: Any] = ["id": rule.id, "state": "disabled", "detail": NSNull()]
            guard rule.enabled else { return status }
            do {
                try Validation.watchRule(rule)
                guard let preset = presets.first(where: { $0.id == rule.presetId }) else { throw ConversionError("Choose an existing preset for this watch folder.") }
                let root = Self.canonical(rule.folder)
                guard !outputRoots.contains(where: { Self.contains($0, root) }) else { throw ConversionError("A watch folder cannot be inside an output, originals, or engine data folder.") }
                let files = try collect(rule, root: root, excluding: outputRoots)
                let old = snapshots[rule.id].flatMap { $0.rule == rule ? $0.files : nil }
                var next: [String: Observation] = [:], ready: [String: Stamp] = [:]
                for (path, stamp) in files {
                    var observation: Observation
                    if let previous = old?[path], previous.stamp == stamp { observation = previous }
                    else { observation = Observation(stamp: stamp, since: now, handled: old == nil) }
                    // shortcut: stable size and timestamps for 3 seconds, producers with longer pauses should publish by atomic rename.
                    if !observation.handled && !active.contains(path) && now.timeIntervalSince(observation.since) >= 3 &&
                        now.timeIntervalSince1970 - Double(stamp.modified.tv_sec) >= 3 {
                        observation.handled = true; ready[path] = stamp; active.insert(path)
                    }
                    next[path] = observation
                }
                snapshots[rule.id] = Snapshot(rule: rule, files: next)
                if !ready.isEmpty { batches.append(Batch(rule: rule, preset: rule.apply(preset), files: ready)); errors.removeValue(forKey: rule.id) }
                status["state"] = files.keys.contains(where: active.contains) ? "running" : "watching"
                if let error = errors[rule.id] { status["state"] = "error"; status["detail"] = error }
            } catch { status["state"] = "error"; status["detail"] = error.localizedDescription }
            return status
        }
        return batches
    }

    func complete(_ batch: Batch, job: ConversionJob, currentRules: [WatchRule]) {
        active.subtract(batch.files.keys)
        let failures = job.lock.withLock { job.files.compactMap { $0.errorDetail } }
        if let failure = failures.first { errors[batch.rule.id] = failure }
        guard !job.isCancellationRequested, currentRules.contains(batch.rule), batch.rule.originals == .moveToOriginals else { return }
        for file in job.files where file.state == .done && !file.outputs.isEmpty {
            guard let stamp = batch.files[file.sourcePath], Stamp.read(file.sourcePath) == stamp else { continue }
            do {
                let folder = batch.rule.originalsFolder
                guard Self.canonical(folder) == Self.canonical(batch.rule.folder) + "/" + WatchRule.originalsName else {
                    throw ConversionError("The originals folder must not be a symbolic link.")
                }
                try FileManager.default.createDirectoryIfNeeded(folder)
                let name = FilePath.fileName(file.sourcePath)
                var destination = FilePath.combine(folder, name), index = 2
                while FileManager.default.fileExists(atPath: destination) {
                    destination = FilePath.combine(folder, "\(index)-\(name)"); index += 1
                }
                // moveItem never replaces another original, even if a new collision appears after the check.
                try FileManager.default.moveItem(atPath: file.sourcePath, toPath: destination)
            } catch { errors[batch.rule.id] = error.localizedDescription }
        }
    }

    private func collect(_ rule: WatchRule, root: String, excluding roots: [String]) throws -> [String: Stamp] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { throw ConversionError("The watch folder is missing or inaccessible.") }
        var failure: Error?
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
            throw ConversionError("The watch folder cannot be read.")
        }
        let filter = FileNameFilter.of(rule.include)
        var files: [String: Stamp] = [:], count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= Validation.maxPaths else { throw ConversionError("A watch folder may contain at most \(Validation.maxPaths) entries. Choose a smaller folder.") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true || roots.contains(where: { Self.contains($0, url.path) }) { enumerator.skipDescendants(); continue }
            if values.isDirectory == true { if !rule.includeSubfolders { enumerator.skipDescendants() }; continue }
            if ["tmp", "temp", "part", "partial", "download", "crdownload", "filepart"].contains(url.pathExtension.lowercased()) { continue }
            guard filter.matches(url.lastPathComponent), FormatRegistry.detect(url.path) != nil, let stamp = Stamp.read(url.path) else { continue }
            files[url.path] = stamp
        }
        if let failure { throw failure }
        return files
    }
    static func canonical(_ path: String) -> String {
        var prefix = path, suffix: [String] = []
        while true {
            if let resolved = realpath(prefix, nil) {
                defer { free(resolved) }
                return FilePath.fullPath(FilePath.combine([String(cString: resolved)] + suffix.reversed()))
            }
            guard let parent = FilePath.directoryName(prefix), parent != prefix else { return FilePath.fullPath(path) }
            suffix.append(FilePath.fileName(prefix)); prefix = parent
        }
    }
    static func contains(_ folder: String, _ path: String) -> Bool { path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/") }
}
