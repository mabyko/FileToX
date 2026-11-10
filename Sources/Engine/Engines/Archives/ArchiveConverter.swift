// Port of Filee.Engines/Archives/ArchiveConverter.cs. Archives: unpack (to a folder, the "Extract" preset), convert
// between archive formats (ZIP, 7Z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ and single-file GZ / BZ2 / XZ), and "Compress into one
// archive" for any files (FileCombiner). Reading uses the bundled 7-Zip (engines/7zip, LGPL, separate process) plus
// Filee's own ALZ, EGG and lzip readers; ZIP, TAR and TAR.GZ are written in-process, the other formats by 7-Zip.

import Darwin
import Foundation

/// The archive engine.
final class ArchiveConverter: Converter, FileCombiner {
    /// Archive formats Filee writes (plus `FormatRegistry.folder`).
    private static let archiveTargets = ["zip", "7z", "tar", "tgz", "tbz2", "txz"]

    /// Compressed single files (no names or folders inside); they convert among each other.
    private static let singleFileSources = ["gz", "bz2", "xz", "lzma", "z", "lz"]

    private let lock = NSLock()
    private var cachedSevenZip: SevenZip?

    let id = "archive"
    let displayName = "Archives (7-Zip)"

    /// 7-Zip already uses several threads; two jobs at once keep the disk busy without thrashing it.
    let maxParallelism = 2

    let edges: [ConversionEdge] =
        ArchiveExtractor.readableFormats.flatMap { source in
            (ArchiveConverter.archiveTargets + [FormatRegistry.folder]).map { ConversionEdge(source, $0) }
        }
        + ArchiveConverter.singleFileSources.flatMap { source in ArchivePacker.singleFileFormats.map { ConversionEdge(source, $0) } }

    func status() -> EngineStatus {
        let sevenZip = SevenZip.locate()
        lock.withLock { cachedSevenZip = sevenZip }
        guard let sevenZip else { return .unavailable("engine.reason.not_installed") }
        return .available(detail: sevenZip.executable, version: "7-Zip \(EngineVersions.component("7zip") ?? "")")
    }

    /// The 7-Zip found by the last status check, or a new search (Filee's `_sevenZip ??= SevenZip.Locate()`).
    private var sevenZip: SevenZip? {
        lock.withLock {
            if cachedSevenZip == nil { cachedSevenZip = SevenZip.locate() }
            return cachedSevenZip
        }
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        let sevenZip = self.sevenZip
        let extractor = ArchiveExtractor(sevenZip)
        if step.to == FormatRegistry.folder { return try await Self.extractToFolder(step, extractor, progress) }

        // Archive → archive: unpack into the job's work folder, then pack everything that came out.
        let scratch = FilePath.combine(step.workDirectory, "archive-\(ArchiveFiles.guid().prefix(8))")
        try FileManager.default.createDirectoryIfNeeded(scratch)
        defer { ArchiveFiles.tryDeleteFolder(scratch) }

        let estimate = ProgressEstimate.start(progress, typical: Self.typicalDuration(step.inputPath), from: 0.02, to: 0.45)
        let unpacked: String
        do {
            defer { estimate.stop() }
            unpacked = try await extractor.extract(step.inputPath, step.from, scratch)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: unpacked)
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            .map { PackItem(sourcePath: FilePath.combine(unpacked, $0), entryName: $0) }

        guard let output = try step.output.allocate(FormatRegistry.get(step.to).primaryExtension) else { return [] }
        try await ArchivePacker(sevenZip).pack(items, output, step.to, step.preset.archive.level, scratch,
                                               ArchivePacker.scaled(progress, 0.5, 1))
        progress?(1)
        return [output]
    }

    /// Unpacks into the folder the output rule names. The archive is unpacked into a hidden folder next to it (same
    /// drive, so the final move is instant) and only moved into place when complete; one top folder is not nested twice.
    private static func extractToFolder(_ step: ConversionStep, _ extractor: ArchiveExtractor, _ progress: ProgressHandler?) async throws -> [String] {
        guard let output = try step.output.allocate("") else { return [] }

        let staging = FilePath.combine(FilePath.directoryName(output) ?? "/",
                                       ".\(FilePath.fileName(output)).filee-\(ArchiveFiles.guid().prefix(8))")
        try FileManager.default.createDirectoryIfNeeded(staging)
        _ = chflags(staging, UInt32(UF_HIDDEN))
        defer { ArchiveFiles.tryDeleteFolder(staging) }

        let estimate = ProgressEstimate.start(progress, typical: typicalDuration(step.inputPath), from: 0.02, to: 0.95)
        let unpacked: String
        do {
            defer { estimate.stop() }
            unpacked = try await extractor.extract(step.inputPath, step.from, staging)
        }
        try ArchiveFiles.moveFolder(try ArchiveFiles.contentRoot(unpacked), output)
        progress?(1)
        return [output]
    }

    func canCombine(into format: String) -> Bool {
        ArchivePacker.isBuiltIn(format)
            || (Self.archiveTargets.contains(format.lowercased()) || ArchivePacker.isSingleFile(format)) && sevenZip != nil
    }

    func combine(_ inputPaths: [String], into outputPath: String, format: String, preset: Preset, workDirectory: String,
                 progress: ProgressHandler?) async throws {
        let sevenZip = ArchivePacker.isBuiltIn(format) ? nil : self.sevenZip
        try await ArchivePacker(sevenZip).pack(Self.uniqueEntries(inputPaths), outputPath, format, preset.archive.level,
                                               workDirectory, progress)
        progress?(1)
    }

    /// Each file (or folder) under its own name; later ones with a name already used become "name (2).ext".
    static func uniqueEntries(_ paths: [String]) -> [PackItem] {
        // OrdinalIgnoreCase: code units, so NFC and NFD spellings of a name stay different (a Swift String set would merge them).
        var used = Set<[UInt16]>()
        var items: [PackItem] = []
        for path in paths {
            var name = FilePath.fileName(FilePath.trimEndingSeparator(path))
            let stem = FilePath.fileNameWithoutExtension(name)
            let ext = FilePath.extension(name)
            var n = 2
            while !used.insert(Array(name.lowercased().utf16)).inserted {
                name = "\(stem) (\(n))\(ext)"
                n += 1
            }
            items.append(PackItem(sourcePath: path, entryName: name))
        }
        return items
    }

    /// Expected duration of unpacking for the progress estimate (~60 MB/s).
    private static func typicalDuration(_ path: String) -> TimeInterval {
        max(0.5, Double(ArchiveFiles.fileLength(path)) / 60e6)
    }
}
