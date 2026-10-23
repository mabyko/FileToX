// Port of Filee.Engines/Archives/ArchiveFiles.cs: file system helpers for the archive engine: copying with a size cap,
// unique names, and moving an unpacked folder into place (with the "one top folder is not nested twice" rule of the
// Extract preset).
//
// .NET streams become chunk callbacks: a source calls `emit` with each piece of data, a sink receives it. Filee's
// BoundedStream (one entry's packed bytes) is a slice of the memory-mapped archive; CrcStream and NonClosingStream are
// sinks that update an `ArchiveCrc32` before writing to a FileHandle.

import Darwin
import Foundation

/// Produces data in pieces, handing each to `emit`.
typealias ArchiveSource = ((Data) throws -> Void) throws -> Void

/// Copy, naming and folder-moving helpers.
enum ArchiveFiles {
    /// Copies a source, failing when it holds more than `maxBytes` (a lying or damaged header).
    @discardableResult
    static func copyLimited(_ source: ArchiveSource, to sink: (Data) throws -> Void, maxBytes: Int64,
                            progress: ((Int) -> Void)? = nil) throws -> Int64 {
        try withoutActuallyEscaping(sink) { sink in
            var total: Int64 = 0
            try source { chunk in
                try Task.checkCancellation()
                total += Int64(chunk.count)
                if total > maxBytes { throw ConversionError("the data unpacks to more than the archive declares") }
                try sink(chunk)
                progress?(chunk.count)
            }
            return total
        }
    }

    /// The bytes of `data` (usually a slice of a memory-mapped archive) in 64 KiB pieces.
    static func chunks(_ data: Data) -> ArchiveSource {
        { emit in
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = min(offset + (1 << 16), data.endIndex)
                try emit(data[offset..<end])
                offset = end
            }
        }
    }

    /// The content of a file in 1 MiB pieces.
    static func chunks(ofFile path: String) -> ArchiveSource {
        { emit in
            let input = try openForReading(path)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try emit(chunk) }
        }
    }

    /// Maps a file into memory (Filee opened a FileStream on it).
    static func map(_ path: String) throws -> Data {
        guard FileManager.default.fileExists(path) else { throw notFound(path) }
        return try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    }

    static func openForReading(_ path: String) throws -> FileHandle {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw FileManager.default.fileExists(path) ? accessDenied(path) : notFound(path)
        }
        return handle
    }

    /// Creates a file that must not exist yet (FileMode.CreateNew), with the usual 0666 & ~umask permissions.
    static func createNew(_ path: String) throws -> FileHandle {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case EEXIST: throw ConversionError("The file '\(path)' already exists.")
            case EACCES, EPERM: throw accessDenied(path)
            case ENOENT: throw ConversionError("Could not find a part of the path '\(path)'.")
            default: throw ConversionError("\(String(cString: strerror(code))) : '\(path)'")
            }
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Writes `lines` as UTF-8 without BOM, each followed by "\n" (File.WriteAllLines on Unix).
    static func writeAllLines(_ path: String, _ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path))
    }

    /// `path` if it is free, else "name_1.ext", "name_2.ext" … (as 7-Zip names clashing entries), so entries that differ
    /// only in case both survive on case-insensitive volumes.
    static func uniquePath(_ path: String) -> String {
        if !exists(path) { return path }
        let dir = FilePath.directoryName(path) ?? ""
        let stem = FilePath.fileNameWithoutExtension(path)
        let ext = FilePath.extension(path)
        var n = 1
        while true {
            let candidate = FilePath.combine(dir, "\(stem)_\(n)\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// The folder whose content forms the result of "Extract": the unpacked folder itself, or its only entry when that
    /// is a folder ("photos.zip" holding "photos/…" becomes "photos/…", not "photos/photos/…").
    static func contentRoot(_ unpacked: String) throws -> String {
        let entries = try FileManager.default.contentsOfDirectory(atPath: unpacked)
        guard entries.count == 1 else { return unpacked }
        let only = FilePath.combine(unpacked, entries[0])
        return FileManager.default.directoryExists(only) ? only : unpacked
    }

    /// Moves the folder `source` to `target`. An existing target (the preset overwrites) receives the files, replacing
    /// those with the same names.
    static func moveFolder(_ source: String, _ target: String) throws {
        let fm = FileManager.default
        if fm.fileExists(target) {
            throw ConversionError("A file named \(FilePath.fileName(target)) is in the way of the extracted folder.")
        }
        if !fm.directoryExists(target) {
            try move(source, target)
            return
        }
        try mergeInto(source, target)
    }

    /// Directory.Move: rename(2), which keeps the name as given (FileManager.moveItem would store it decomposed, NFD).
    /// Across volumes, where rename fails, FileManager copies (Filee's "different drives" fallback).
    static func move(_ source: String, _ target: String) throws {
        if rename(source, target) == 0 { return }
        let code = errno
        guard code == EXDEV else { throw FilePath.writeError(code, target) }
        try FileManager.default.moveItem(atPath: source, toPath: target)
    }

    private static func mergeInto(_ source: String, _ target: String) throws {
        let fm = FileManager.default
        if isLink(target) { throw ConversionError("\(target) is a link; Filee does not extract into links.") }
        try fm.createDirectoryIfNeeded(target)
        let names = try fm.contentsOfDirectory(atPath: source)
        for name in names where !fm.directoryExists(FilePath.combine(source, name)) {
            // File.Move(overwrite: true): rename(2) replaces a file of the same name.
            let from = FilePath.combine(source, name), to = FilePath.combine(target, name)
            if rename(from, to) != 0 { throw ConversionError("\(String(cString: strerror(errno))) : '\(to)'") }
        }
        for name in names where fm.directoryExists(FilePath.combine(source, name)) {
            let dir = FilePath.combine(source, name)
            let destination = FilePath.combine(target, name)
            if exists(destination) && !fm.directoryExists(destination) { try fm.removeItem(atPath: destination) }
            if !fm.directoryExists(destination) {
                try move(dir, destination)
            } else {
                try mergeInto(dir, destination)
            }
        }
        if let time = modificationDate(source) { try? fm.setAttributes([.modificationDate: time], ofItemAtPath: target) }
    }

    /// Deletes a folder tree, ignoring failures (a scanner may still hold a file; temp is cleaned later).
    static func tryDeleteFolder(_ path: String) {
        if FileManager.default.directoryExists(path) { FileManager.default.removeIfPresent(path) }
    }

    /// Deletes a file, ignoring failures.
    static func tryDeleteFile(_ path: String) {
        _ = unlink(path)
    }

    /// 32 lower-case hex digits, like .NET's `Guid.NewGuid().ToString("N")`.
    static func guid() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// True when something (file, folder or link) is at `path`.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func setModificationDate(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    static func fileLength(_ path: String) -> Int64 {
        var info = stat()
        return stat(path, &info) == 0 ? Int64(info.st_size) : 0
    }

    static func notFound(_ path: String) -> ConversionError { ConversionError("Could not find file '\(path)'.") }

    static func accessDenied(_ path: String) -> ConversionError { ConversionError("Access to the path '\(path)' is denied.") }
}
