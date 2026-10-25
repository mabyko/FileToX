import Foundation
import Darwin

/// State and disk work are confined to the host's serial watch queue, never its RPC gate.
final class WatchFolderMonitor {
    static let batchLimit = 128
    struct RootIdentity: Equatable { let device: Int32; let inode: UInt64 }
    struct Stamp: Equatable {
        let device: Int32, inode: UInt64, size: Int64
        let modified: timespec, changed: timespec
        static func == (a: Self, b: Self) -> Bool {
            a.sameContent(as: b) &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
        func sameContent(as other: Self) -> Bool {
            device == other.device && inode == other.inode && size == other.size &&
            modified.tv_sec == other.modified.tv_sec && modified.tv_nsec == other.modified.tv_nsec
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
        let physicalOutputRoot: String, protectedOriginals: [String]
        func validateOutput(_ path: String, currentOriginals: [String] = []) throws {
            let root = WatchFolderMonitor.canonical(rule.resolvedOutputFolder)
            guard FileSystemPaths.equal(root, physicalOutputRoot), WatchFolderMonitor.contains(physicalOutputRoot, WatchFolderMonitor.canonical(path)) else {
                throw OutputCommitException("error.output_commit_failed", "The watch output folder changed after validation.")
            }
            let originals = (protectedOriginals + currentOriginals).map(WatchFolderMonitor.canonical)
            do {
                try Validation.watchOutput(physicalOutputRoot, originals: originals, resolve: { $0 })
                try Validation.watchOutput(WatchFolderMonitor.canonical(path), originals: originals, resolve: { $0 })
            }
            catch { throw OutputCommitException("error.output_commit_failed", "The watch output now overlaps saved originals.") }
        }
    }
    struct Contents { let identity: RootIdentity; let files: [String: Stamp] }
    private struct Observation { let stamp: Stamp; let since: TimeInterval; var handled: Bool }
    private struct Snapshot { let rule: WatchRule; let root: RootIdentity; var files: [String: Observation] }
    private var snapshots: [String: Snapshot] = [:]
    private var active = Set<String>()
    private var errors: [String: String] = [:]
    private(set) var statuses: [[String: Any]] = []
    private let excluded: [String]
    private let reader: ((WatchRule, String, [String]) throws -> Contents)?
    private let clock: () -> TimeInterval
    init(excluding paths: [String] = [], clock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }, reader: ((WatchRule, String, [String]) throws -> Contents)? = nil) {
        excluded = paths; self.clock = clock; self.reader = reader
    }

    func scan(_ rules: [WatchRule], presets: [Preset], now: TimeInterval? = nil) -> [Batch] {
        let now = now ?? clock()
        snapshots = snapshots.filter { id, _ in rules.contains { $0.id == id && $0.enabled } }
        let outputRoots = rules.filter { !$0.folder.isEmpty }.flatMap { [Self.canonical($0.resolvedOutputFolder), Self.canonical($0.originalsFolder)] } + excluded.map(Self.canonical)
        var batches: [Batch] = []
        statuses = rules.map { rule in
            var status: [String: Any] = ["id": rule.id, "state": "disabled", "detail": NSNull()]
            guard rule.enabled else { return status }
            do {
                try Validation.watchRule(rule, originals: rules.filter { !$0.folder.isEmpty }.map(\.originalsFolder), resolve: Self.canonical)
                guard let preset = presets.first(where: { $0.id == rule.presetId }) else { throw ConversionError("Choose an existing preset for this watch folder.") }
                let originalFolders = rules.filter { !$0.folder.isEmpty }.map(\.originalsFolder)
                let protectedOriginals = originalFolders + originalFolders.map(Self.canonical)
                let physicalOutput = Self.canonical(rule.resolvedOutputFolder)
                try Validation.watchOutput(physicalOutput, originals: protectedOriginals, resolve: Self.canonical)
                let root = Self.canonical(rule.folder)
                guard !outputRoots.contains(where: { Self.contains($0, root) }) else { throw ConversionError("A watch folder cannot be inside an output, originals, or engine data folder.") }
                let contents = try reader?(rule, root, outputRoots) ?? collect(rule, root: root, excluding: outputRoots)
                let files = contents.files
                let old = snapshots[rule.id].flatMap { $0.rule == rule && $0.root == contents.identity ? $0.files : nil }
                var next: [String: Observation] = [:], ready: [String: Stamp] = [:]
                for path in files.keys.sorted() {
                    let stamp = files[path]!
                    var observation: Observation
                    if let previous = old?[path], previous.stamp.sameContent(as: stamp) {
                        observation = Observation(stamp: stamp, since: previous.stamp == stamp ? previous.since : now, handled: previous.handled)
                    }
                    else { observation = Observation(stamp: stamp, since: now, handled: old == nil) }
                    // shortcut: stable size and timestamps for 3 seconds, producers with longer pauses should publish by atomic rename.
                    if ready.count < Self.batchLimit && !observation.handled && !active.contains(path) && now - observation.since >= 3 {
                        observation.handled = true; ready[path] = stamp; active.insert(path)
                    }
                    next[path] = observation
                }
                snapshots[rule.id] = Snapshot(rule: rule, root: contents.identity, files: next)
                if !ready.isEmpty {
                    var effective = rule.apply(preset); effective.output.customFolder = physicalOutput
                    batches.append(Batch(rule: rule, preset: effective, files: ready, physicalOutputRoot: physicalOutput, protectedOriginals: protectedOriginals))
                    errors.removeValue(forKey: rule.id)
                }
                status["state"] = files.keys.contains(where: active.contains) ? "running" : "watching"
                if let error = errors[rule.id] { status["state"] = "error"; status["detail"] = error }
            } catch { status["state"] = "error"; status["detail"] = error.localizedDescription }
            return status
        }
        return batches
    }

    func discard(_ batches: [Batch]) {
        for batch in batches {
            active.subtract(batch.files.keys)
            for path in batch.files.keys { snapshots[batch.rule.id]?.files[path]?.handled = false }
        }
    }

    func complete(_ batch: Batch, job: ConversionJob, currentRules: [WatchRule], canMove: () -> Bool = { true }) {
        active.subtract(batch.files.keys)
        let failures = job.lock.withLock { job.files.compactMap { $0.errorDetail } }
        if let failure = failures.first { errors[batch.rule.id] = failure }
        guard !job.isCancellationRequested, !job.outputs.isEmpty, currentRules.contains(batch.rule), batch.rule.originals == .moveToOriginals, canMove() else { return }
        for file in job.files where file.state == .done {
            guard let stamp = batch.files[file.sourcePath], Stamp.read(file.sourcePath) == stamp else { continue }
            do {
                let folder = batch.rule.originalsFolder
                try FileManager.default.createDirectoryIfNeeded(folder)
                var info = stat(), parent = stat(), input = stat()
                guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                      stat(FilePath.directoryName(Self.canonical(folder))!, &parent) == 0, stat(batch.rule.folder, &input) == 0,
                      parent.st_dev == input.st_dev, parent.st_ino == input.st_ino else {
                    throw ConversionError("The originals folder must be a real child directory, not a symbolic link.")
                }
                let name = FilePath.fileName(file.sourcePath)
                var destination = FilePath.combine(folder, name), index = 2
                while canMove() && !job.isCancellationRequested && Stamp.read(file.sourcePath) == stamp {
                    if renamex_np(file.sourcePath, destination, UInt32(RENAME_EXCL)) == 0 { break }
                    guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    destination = FilePath.combine(folder, "\(index)-\(name)"); index += 1
                }
            } catch { errors[batch.rule.id] = error.localizedDescription }
        }
    }

    private func collect(_ rule: WatchRule, root: String, excluding roots: [String]) throws -> Contents {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        var info = stat()
        guard stat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ConversionError("The watch folder is missing or inaccessible.") }
        guard !Self.isTemporary(rootURL), try rootURL.resourceValues(forKeys: [.isPackageKey]).isPackage != true else { throw ConversionError("Packages and temporary-download directories cannot be watched.") }
        var failure: Error?
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else {
            throw ConversionError("The watch folder cannot be read.")
        }
        let filter = FileNameFilter.of(rule.include.compactMap(FileNameFilter.normalize))
        var files: [String: Stamp] = [:], count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= Validation.maxPaths else { throw ConversionError("A watch folder may contain at most \(Validation.maxPaths) entries. Choose a smaller folder.") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey])
            if values.isSymbolicLink == true || values.isPackage == true { continue }
            if Self.isTemporary(url) || roots.contains(where: { Self.contains($0, url.path) }) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { if !rule.includeSubfolders { enumerator.skipDescendants() }; continue }
            guard filter.matches(url.lastPathComponent), FormatRegistry.detect(url.path) != nil, let stamp = Stamp.read(url.path) else { continue }
            files[url.path] = stamp
        }
        if let failure { throw failure }
        return Contents(identity: RootIdentity(device: info.st_dev, inode: info.st_ino), files: files)
    }
    private static func isTemporary(_ url: URL) -> Bool { ["tmp", "temp", "part", "partial", "download", "crdownload", "filepart", "rtfd"].contains(url.pathExtension.lowercased()) }
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
