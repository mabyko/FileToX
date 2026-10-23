// Port of Filee.Engines/Archives/ArchivePacker.cs: writes archives. ZIP, TAR and TAR.GZ are written in-process (Filee
// used System.IO.Compression and System.Formats.Tar; here `ZipWriter`, a PAX TAR writer with the same headers as .NET's
// TarWriter, and zlib for gzip), so file names are exactly what Filee chooses: UTF-8 in ZIP (with the language
// encoding flag), PAX headers in TAR. 7Z, the bzip2 / xz TAR variants and single-file GZ / BZ2 / XZ are written by the
// bundled 7-Zip.

import Darwin
import Foundation

/// A file or folder to store in an archive under `entryName`; folders go in with their content.
struct PackItem: Equatable {
    let sourcePath: String
    let entryName: String
}

/// Creates archives from files and folders.
final class ArchivePacker {
    /// Formats written without 7-Zip.
    static let builtInFormats: Set<String> = ["zip", "tar", "tgz"]

    /// Formats that hold exactly one file, without name or folders.
    static let singleFileFormats = ["gz", "bz2", "xz"]

    static func isBuiltIn(_ format: String) -> Bool { builtInFormats.contains(format.lowercased()) }

    static func isSingleFile(_ format: String) -> Bool { singleFileFormats.contains(format.lowercased()) }

    private let sevenZip: SevenZip?

    init(_ sevenZip: SevenZip?) { self.sevenZip = sevenZip }

    /// Writes `items` into a new archive of `format` at `outputPath`. The archive is built under a temporary name next
    /// to it and renamed when complete, so a failed or cancelled run never leaves a broken archive (or replaces an
    /// existing one).
    func pack(_ items: [PackItem], _ outputPath: String, _ format: String, _ level: ArchiveLevel, _ workDirectory: String,
              _ progress: ProgressHandler?) async throws {
        let dir = FilePath.directoryName(FilePath.fullPath(outputPath)) ?? "/"
        try FileManager.default.createDirectoryIfNeeded(dir)
        let temp = FilePath.combine(dir, ".\(FilePath.fileName(outputPath)).filee-\(ArchiveFiles.guid().prefix(8)).tmp")
        defer { ArchiveFiles.tryDeleteFile(temp) }

        switch format {
        case "zip":
            try Self.writeZip(items, temp, level, progress)
        case "tar", "tgz":
            try Self.writeTar(items, temp, format == "tgz" ? level : nil, progress)
        case "tbz2", "txz":
            // 7-Zip compresses a single stream; the TAR is written first, in the work folder.
            let tar = FilePath.combine(workDirectory, "pack-\(ArchiveFiles.guid()).tar")
            defer { ArchiveFiles.tryDeleteFile(tar) }
            try Self.writeTar(items, tar, nil, Self.scaled(progress, 0, 0.3))
            try await runSevenZip(format == "tbz2" ? "bzip2" : "xz", [tar], temp, level, workDirectory, progress, 0.3)
        case "7z":
            try await runSevenZip("7z", try Self.namedAs(items, workDirectory), temp, level, workDirectory, progress, 0)
        case "gz", "bz2", "xz":
            if items.count != 1 || !FileManager.default.fileExists(items[0].sourcePath) {
                throw ConversionError("A .\(format) file holds a single file. Choose TAR.\(format.uppercased()) to compress several files or folders.")
            }
            let type = format == "gz" ? "gzip" : format == "bz2" ? "bzip2" : "xz"
            try await runSevenZip(type, try Self.namedAs(items, workDirectory), temp, level, workDirectory, progress, 0)
        default:
            throw ConversionError("Filee cannot write \(format) archives.")
        }
        // File.Move(temp, outputPath, overwrite: true)
        if rename(temp, outputPath) != 0 { throw ConversionError("\(String(cString: strerror(errno))) : '\(outputPath)'") }
    }

    private func runSevenZip(_ type: String, _ paths: [String], _ archive: String, _ level: ArchiveLevel, _ workDirectory: String,
                             _ progress: ProgressHandler?, _ from: Double) async throws {
        guard let sevenZip else { throw ConversionError("7-Zip was not found (engines/7zip).") }
        // 7-Zip reports nothing while it works: estimate from the amount of data (~40 MB/s at normal level).
        let bytes = paths.reduce(Int64(0)) { $0 + Self.totalSize($1) }
        let estimate = ProgressEstimate.start(progress, typical: max(0.5, Double(bytes) / 40e6), from: max(from, 0.05), to: 0.95)
        defer { estimate.stop() }
        try await sevenZip.add(archive, type, level, paths, workDirectory)
    }

    /// Paths 7-Zip can take as they are: it stores each under its own file name, so items whose entry name differs (a
    /// renamed duplicate) are copied under that name into the work folder first.
    private static func namedAs(_ items: [PackItem], _ workDirectory: String) throws -> [String] {
        var paths: [String] = []
        for item in items {
            if FilePath.fileName(item.sourcePath).utf16.elementsEqual(item.entryName.utf16) {
                paths.append(item.sourcePath)
                continue
            }
            let folder = FilePath.combine(workDirectory, "rename-\(ArchiveFiles.guid().prefix(8))")
            try FileManager.default.createDirectoryIfNeeded(folder)
            let copy = FilePath.combine(folder, item.entryName)
            if FileManager.default.directoryExists(item.sourcePath) {
                try copyFolder(item.sourcePath, copy)
            } else {
                try copyFile(item.sourcePath, copy)
            }
            paths.append(copy)
        }
        return paths
    }

    /// A byte copy with the source's modification time (the copy gets new-file permissions, as .NET's stream copy).
    private static func copyFile(_ source: String, _ target: String) throws {
        let output = try ArchiveFiles.createNew(target)
        do {
            defer { try? output.close() }
            try ArchiveFiles.copyLimited(ArchiveFiles.chunks(ofFile: source), to: { try output.write(contentsOf: $0) }, maxBytes: .max)
        }
        if let time = ArchiveFiles.modificationDate(source) { try ArchiveFiles.setModificationDate(target, time) }
    }

    /// Copies a folder tree without following links.
    private static func copyFolder(_ source: String, _ target: String) throws {
        let fm = FileManager.default
        try fm.createDirectoryIfNeeded(target)
        for name in try fm.contentsOfDirectory(atPath: source) {
            let path = FilePath.combine(source, name)
            let type = try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { continue }
            let destination = FilePath.combine(target, name)
            if type == .typeDirectory {
                try copyFolder(path, destination)
            } else {
                try copyFile(path, destination)
            }
        }
        if let time = ArchiveFiles.modificationDate(source) { try ArchiveFiles.setModificationDate(target, time) }
    }

    private static func writeZip(_ items: [PackItem], _ path: String, _ level: ArchiveLevel, _ progress: ProgressHandler?) throws {
        let files = try expand(items)
        let counter = ByteCounter(files.reduce(0) { $0 + $1.length }, progress)
        let compression: ZipCompressionLevel = switch level {
        case .store: .noCompression
        case .fast: .fastest
        case .maximum: .smallestSize
        case .normal: .optimal
        }

        // UTF-8 names get the "language encoding" flag, so every unzip tool shows Korean or Chinese names correctly.
        let zip = try ZipWriter(path: path)
        for file in files {
            try Task.checkCancellation()
            if file.isFolder {
                try zip.addDirectory(file.entryName + "/", date: zipTime(file.modified))
                continue
            }
            // .NET's ZipArchive gives every created entry rw-r--r--.
            try zip.add(file.entryName, contentsOf: file.path, level: compression, date: zipTime(file.modified), unixMode: 0o644,
                        progress: counter.add)
        }
        try zip.close()
    }

    /// Writes a PAX TAR (UTF-8 names, times), gzip-compressed when `gzipLevel` is set.
    private static func writeTar(_ items: [PackItem], _ path: String, _ gzipLevel: ArchiveLevel?, _ progress: ProgressHandler?) throws {
        let files = try expand(items)
        let counter = ByteCounter(files.reduce(0) { $0 + $1.length }, progress)
        let writer = try TarWriter(path, gzipLevel: gzipLevel.map {
            switch $0 {
            case .store: 0
            case .fast: 1
            case .maximum: 9
            case .normal: 6
            }
        })
        for item in files {
            try Task.checkCancellation()
            if item.isFolder {
                try writer.writeEntry(item.entryName + "/", directory: true, mode: 0o755, modified: item.modified, dataPath: nil)
                continue
            }
            try writer.writeEntry(item.entryName, directory: false, mode: 0o644, modified: item.modified, dataPath: item.path,
                                  onRead: counter.add)
        }
        try writer.finish()
    }

    /// A file or folder in the order it is written, with its name inside the archive.
    private struct PackFile {
        let path: String
        let entryName: String
        let isFolder: Bool
        let length: Int64
        let modified: FileTime
    }

    /// A modification time with .NET's precision (100 ns ticks since 1970, truncated from the file system's ns).
    struct FileTime {
        let ticks: Int64

        init(_ time: timespec) { ticks = Int64(time.tv_sec) * 10_000_000 + Int64(time.tv_nsec) / 100 }

        var date: Date { Date(timeIntervalSince1970: Double(ticks) / 10_000_000) }

        /// Whole seconds since 1970 (floor), the TAR header's mtime.
        var seconds: Int64 { ticks >= 0 ? ticks / 10_000_000 : (ticks - 9_999_999) / 10_000_000 }

        /// PAX "mtime": seconds with up to 7 decimals, trailing zeros dropped (.NET's decimal "G").
        var paxText: String {
            let magnitude = ticks.magnitude
            let whole = magnitude / 10_000_000, fraction = magnitude % 10_000_000
            let sign = ticks < 0 ? "-" : ""
            if fraction == 0 { return sign + String(whole) }
            var digits = String(fraction)
            digits = String(repeating: "0", count: 7 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            return "\(sign)\(whole).\(digits)"
        }
    }

    /// Every file and folder of the items, folders before their content. Links are skipped, never followed, so nothing
    /// outside the given folders ends up in the archive.
    private static func expand(_ items: [PackItem]) throws -> [PackFile] {
        var files: [PackFile] = []
        for item in items {
            let name = item.entryName.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var info = stat()
            guard stat(item.sourcePath, &info) == 0 else { throw ConversionError("\(item.sourcePath) was not found.") }
            if info.st_mode & S_IFMT == S_IFDIR {
                try expandFolder(FilePath.fullPath(item.sourcePath), name, FileTime(info.st_mtimespec), &files)
            } else if info.st_mode & S_IFMT == S_IFREG {
                files.append(PackFile(path: FilePath.fullPath(item.sourcePath), entryName: name, isFolder: false,
                                      length: Int64(info.st_size), modified: FileTime(info.st_mtimespec)))
            } else {
                throw ConversionError("\(item.sourcePath) was not found.")
            }
        }
        return files
    }

    private static func expandFolder(_ folder: String, _ name: String, _ modified: FileTime, _ files: inout [PackFile]) throws {
        files.append(PackFile(path: folder, entryName: name, isFolder: true, length: 0, modified: modified))
        // OrderBy(Name, StringComparer.Ordinal): UTF-16 code unit order.
        let children = try FileManager.default.contentsOfDirectory(atPath: folder)
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for child in children {
            let path = FilePath.combine(folder, child)
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let entry = name + "/" + child
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try expandFolder(path, entry, FileTime(info.st_mtimespec), &files)
            case S_IFREG:
                files.append(PackFile(path: path, entryName: entry, isFolder: false, length: Int64(info.st_size),
                                      modified: FileTime(info.st_mtimespec)))
            default:
                continue // links (and sockets, pipes, devices) are never packed
            }
        }
    }

    private static func totalSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        if fm.fileExists(path) { return ArchiveFiles.fileLength(path) }
        guard fm.directoryExists(path), let walker = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while walker.nextObject() != nil {
            if (walker.fileAttributes?[.type] as? FileAttributeType) == .typeRegular {
                total += (walker.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// ZIP stores DOS times (local, 1980–2107).
    private static func zipTime(_ time: FileTime) -> Date {
        let calendar = ZipReader.dosCalendar
        let year = calendar.component(.year, from: time.date)
        if year < 1980 { return calendar.date(from: DateComponents(year: 1980, month: 1, day: 1)) ?? time.date }
        if year > 2107 { return calendar.date(from: DateComponents(year: 2107, month: 12, day: 31)) ?? time.date }
        return time.date
    }

    static func scaled(_ progress: ProgressHandler?, _ from: Double, _ to: Double) -> ProgressHandler? {
        guard let progress else { return nil }
        return { p in progress(from + (to - from) * p) }
    }

    /// Turns bytes written into a 0..1 progress value.
    private final class ByteCounter {
        private let total: Int64
        private let progress: ProgressHandler?
        private var done: Int64 = 0
        private var reported = 0.0

        init(_ total: Int64, _ progress: ProgressHandler?) {
            self.total = total
            self.progress = progress
        }

        func add(_ bytes: Int) {
            done += Int64(bytes)
            let value = total <= 0 ? 1 : min(1, Double(done) / Double(total))
            if value - reported >= 0.01 {
                reported = value
                progress?(value)
            }
        }
    }

    /// The PAX TAR format of .NET's `TarWriter(stream, TarEntryFormat.Pax)`: before every entry an extended header
    /// ("./PaxHeaders.<pid>/.") with its path and mtime, then a ustar header (name cut to 100 bytes, uid/gid 0, no
    /// user names), the data padded to 512 bytes, and two empty records at the end.
    final class TarWriter {
        private let handle: FileHandle
        private let compressor: Deflate.Compressor?
        private var buffer = Data()
        private static let extendedName = "./PaxHeaders.\(getpid())/."

        init(_ path: String, gzipLevel: Int32?) throws {
            handle = try ArchiveFiles.createNew(path)
            compressor = try gzipLevel.map { try Deflate.Compressor(level: $0, windowBits: 31) }
        }

        deinit { try? handle.close() }

        func writeEntry(_ name: String, directory: Bool, mode: Int, modified: FileTime, dataPath: String?,
                        onRead: ((Int) -> Void)? = nil) throws {
            let input = try dataPath.map(ArchiveFiles.openForReading)
            defer { try? input?.close() }
            let size = try input.map { Int64(try $0.seekToEnd()) } ?? 0
            try input?.seek(toOffset: 0)

            var records = Self.record("path", name) + Self.record("mtime", modified.paxText)
            if size > 0o77777777777 { records += Self.record("size", String(size)) }
            var extended = Self.header(name: Self.extendedName, mode: 0o644, size: Int64(records.count), mtime: nil, type: "x")
            extended.append(records)
            pad(&extended)
            try write(extended)
            try write(Self.header(name: name, mode: mode, size: size > 0o77777777777 ? 0 : size,
                                  mtime: max(0, modified.seconds), type: directory ? "5" : "0"))

            guard let input else { return }
            var remaining = size
            while remaining > 0 {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
                    throw ConversionError("\(name) changed while it was being packed.")
                }
                try write(chunk)
                remaining -= Int64(chunk.count)
                onRead?(chunk.count)
            }
            let tail = Int(size % 512)
            if tail != 0 { try write(Data(count: 512 - tail)) }
        }

        /// The two empty records that end the archive; then the gzip trailer.
        func finish() throws {
            try write(Data(count: 1024))
            try flush(finish: true)
            try handle.synchronize()
            try handle.close()
        }

        private func write(_ data: Data) throws {
            buffer.append(data)
            if buffer.count >= 1 << 20 { try flush(finish: false) }
        }

        private func flush(finish: Bool) throws {
            let bytes = try compressor.map { try $0.compress(buffer, finish: finish) } ?? buffer
            buffer.removeAll(keepingCapacity: true)
            if !bytes.isEmpty { try handle.write(contentsOf: bytes) }
        }

        private func pad(_ data: inout Data) {
            let tail = data.count % 512
            if tail != 0 { data.append(Data(count: 512 - tail)) }
        }

        /// "<length> key=value\n", the length counting itself.
        static func record(_ key: String, _ value: String) -> Data {
            let body = " \(key)=\(value)\n".utf8.count
            var length = body + String(body).count
            if String(length).count != String(body).count { length = body + String(length).count }
            return Data("\(length) \(key)=\(value)\n".utf8)
        }

        /// One 512-byte ustar header. `mtime` nil leaves the field empty (extended headers).
        static func header(name: String, mode: Int, size: Int64, mtime: Int64?, type: Character) -> Data {
            var block = Data(count: 512)
            func put(_ bytes: Data, _ offset: Int) { block.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
            func octal(_ value: Int64, _ digits: Int) -> Data {
                let text = String(value, radix: 8)
                return Data((String(repeating: "0", count: max(0, digits - text.count)) + text).utf8) + Data([0])
            }
            put(truncatedUTF8(name, 100), 0)
            put(octal(Int64(mode), 7), 100)
            put(octal(0, 7), 108)
            put(octal(0, 7), 116)
            put(octal(size, 11), 124)
            if let mtime { put(octal(mtime, 11), 136) }
            put(Data(repeating: 0x20, count: 8), 148)
            put(Data(String(type).utf8), 156)
            put(Data("ustar\u{0}00".utf8), 257)
            let checksum = block.reduce(0) { $0 + Int($1) }
            let text = String(checksum, radix: 8)
            put(Data((String(repeating: "0", count: max(0, 6 - text.count)) + text).utf8) + Data([0, 0x20]), 148)
            return block
        }

        /// The UTF-8 bytes of whole characters that fit into `limit` bytes.
        private static func truncatedUTF8(_ text: String, _ limit: Int) -> Data {
            var result = Data()
            for scalar in text.unicodeScalars {
                let bytes = Data(String(scalar).utf8)
                if result.count + bytes.count > limit { break }
                result.append(bytes)
            }
            return result
        }
    }
}
