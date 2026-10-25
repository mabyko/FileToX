import Foundation
import Darwin

public struct OutputCommitException: LocalizedError {
    public let errorKey: String
    public let message: String
    public init(_ errorKey: String, _ message: String) { self.errorKey = errorKey; self.message = message }
    public var errorDescription: String? { message }
}
public extension OutputCommit {
    static let stagingPrefix = ".filee-out-"
    static func isStagingFolderName(_ name: String) -> Bool { name.utf16.count == stagingPrefix.utf16.count + 8 && name.hasPrefix(stagingPrefix) && name.dropFirst(stagingPrefix.count).allSatisfy { $0.isASCII && $0.isHexDigit } }
    static func createStagingFolder(_ directory: String) throws -> String {
        while true {
            let path = FilePath.combine(directory, stagingPrefix + Preset.newId().prefix(8))
            if mkdir(path, 0o755) == 0 { return path }
            if errno == EEXIST { continue }
            throw failed(path)
        }
    }
    static func move(_ staged: String, _ final: String, overwrite: Bool, sources: [String], validate: (String) throws -> Void = { _ in }, didMove: () -> Void = {}) throws {
        try validate(final)
        let directory = FileManager.default.directoryExists(staged)
        if !exists(final) {
            try validate(final)
            if try !renameExclusive(staged, final, directory) { throw OutputCommitException("error.output_exists", "\(final) appeared while converting.") }
            didMove()
            return
        }
        try checkExisting(staged, final, overwrite, sources)
        if !directory {
            try validate(final)
            if Darwin.rename(staged, final) != 0 { throw failed(final) }
            didMove()
            return
        }
        for entry in try entries(staged) { try move(entry, FilePath.combine(final, FilePath.fileName(entry)), overwrite: overwrite, sources: sources, validate: validate, didMove: didMove) }
        tryDelete(staged)
    }
    static func check(_ staged: String, _ final: String, overwrite: Bool, sources: [String], validate: (String) throws -> Void = { _ in }) throws {
        try validate(final)
        if !exists(final) { return }
        try checkExisting(staged, final, overwrite, sources)
        if FileManager.default.directoryExists(staged) {
            for entry in try entries(staged) { try check(entry, FilePath.combine(final, FilePath.fileName(entry)), overwrite: overwrite, sources: sources, validate: validate) }
        }
    }
    static func isSource(_ path: String, _ sources: [String]) -> Bool {
        if let target = identity(path, follow: false) {
            return sources.contains { identity($0, follow: false).map { $0 == target } == true || identity($0, follow: true).map { $0 == target } == true }
        }
        return sources.contains { FilePath.fullPath($0).caseInsensitiveCompare(FilePath.fullPath(path)) == .orderedSame }
    }
    static func tryDelete(_ path: String) { FileManager.default.removeIfPresent(path) }
    internal static func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }
    internal static func entries(_ path: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: path).map { FilePath.combine(path, $0) } }
    internal static func isSymbolicLink(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK }
    private static func identity(_ path: String, follow: Bool) -> (dev_t, ino_t)? {
        var info = stat(); let result = follow ? stat(path, &info) : lstat(path, &info)
        return result == 0 ? (info.st_dev, info.st_ino) : nil
    }
    private static func checkExisting(_ staged: String, _ final: String, _ overwrite: Bool, _ sources: [String]) throws {
        if !overwrite { throw OutputCommitException("error.output_exists", "\(final) already exists.") }
        if isSource(final, sources) { throw OutputCommitException("error.output_is_source", "\(final) is a source file of this job.") }
        if FileManager.default.directoryExists(staged) && (!FileManager.default.directoryExists(final) || isSymbolicLink(final)) { throw OutputCommitException("error.output_exists", "\(final) is in the way of the extracted folder.") }
    }
    private static func renameExclusive(_ from: String, _ to: String, _ directory: Bool) throws -> Bool {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return true }
        let error = errno
        if error == EEXIST { return false }
        if !directory && [ENOTSUP, EINVAL, ENOSYS].contains(error) {
            if link(from, to) == 0 { _ = unlink(from); return true }
            if errno == EEXIST { return false }
        }
        throw failed(to)
    }
    private static func failed(_ path: String) -> OutputCommitException {
        let error = errno
        return OutputCommitException("error.output_commit_failed", "Could not move the result to \(path): \(String(cString: strerror(error))) (errno \(error)).")
    }
}

final class StagedOutputs {
    private struct StagedEntry { let final: String; var stageDir: String; let staged: String }
    private let lock = NSLock()
    private var entries: [StagedEntry] = []
    private let onStaging: ((String) throws -> Void)?
    init(_ onStaging: ((String) throws -> Void)? = nil) { self.onStaging = onStaging }
    func stage(_ final: String) throws -> String {
        let dir = try OutputCommit.createStagingFolder(FilePath.directoryName(final)!)
        do { try onStaging?(dir) } catch { OutputCommit.tryDelete(dir); throw error }
        let staged = FilePath.combine(dir, FilePath.fileName(final))
        OutputCommit.track(staged: staged, final: final)
        lock.withLock { entries.append(StagedEntry(final: final, stageDir: dir, staged: staged)) }
        return staged
    }
    func commit(_ produced: [String], _ outputs: inout [String], _ rule: OutputRule, _ sources: [String], _ release: (String) -> Void) throws {
        try commit(produced, rule, sources, release, validate: { _ in }, published: { outputs.append($0) })
    }
    func commit(_ produced: [String], _ rule: OutputRule, _ sources: [String], _ release: (String) -> Void, validate: (String) throws -> Void, published: (String) -> Void) throws {
        var entries = take()
        for entry in entries { OutputCommit.untrack(staged: entry.staged) }
        let wanted = Set(produced), overwrite = rule.conflict == .overwrite
        defer { for e in entries where !e.stageDir.isEmpty { release(e.final); OutputCommit.tryDelete(e.stageDir) } }
        for i in entries.indices {
            let e = entries[i]
            try validate(e.final)
            if !wanted.contains(e.staged) || !(FileManager.default.fileExists(e.staged) || FileManager.default.directoryExists(e.staged)) {
                release(e.final); OutputCommit.tryDelete(e.stageDir); entries[i].stageDir = ""; continue
            }
            let folder = FilePath.directoryName(e.final)!
            let sides = try OutputCommit.entries(e.stageDir).filter { $0 != e.staged }
            for side in sides { try OutputCommit.check(side, FilePath.combine(folder, FilePath.fileName(side)), overwrite: overwrite, sources: sources, validate: validate) }
            var recorded = false
            func record() { if !recorded { recorded = true; published(e.final) } }
            try OutputCommit.move(e.staged, e.final, overwrite: overwrite, sources: sources, validate: validate, didMove: record)
            record()
            for side in sides { try OutputCommit.move(side, FilePath.combine(folder, FilePath.fileName(side)), overwrite: overwrite, sources: sources, validate: validate) }
            OutputCommit.tryDelete(e.stageDir); entries[i].stageDir = ""
        }
    }
    func abort(_ release: (String) -> Void) { for e in take() { OutputCommit.untrack(staged: e.staged); release(e.final); OutputCommit.tryDelete(e.stageDir) } }
    private func take() -> [StagedEntry] { lock.withLock { let result = entries; entries.removeAll(); return result } }
}
