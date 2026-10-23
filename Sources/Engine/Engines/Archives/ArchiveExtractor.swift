// Port of Filee.Engines/Archives/ArchiveExtractor.cs: unpacks every archive format Filee reads into a folder: the
// bundled 7-Zip for most of them, Filee's own readers for ALZ, EGG and lzip. Compressed TARs (.tar.gz, .tar.lz …) and
// RPM payloads are unpacked stage by stage until the files appear. Every stage is checked first (encryption, paths
// leaving the folder, disk space) and links are removed.

import Foundation

/// Unpacks archives into scratch folders.
final class ArchiveExtractor {
    /// Formats read by 7-Zip.
    static let sevenZipFormats = [
        "zip", "jar", "7z", "rar", "tar", "tgz", "tbz2", "txz", "tar7z", "tz", "gz", "bz2", "xz", "lzma", "z",
        "cab", "cpio", "deb", "rpm", "dmg", "iso", "img", "lha", "arj",
    ]

    /// Formats read by Filee's own code (lzip still needs 7-Zip's LZMA decoder).
    static let builtInFormats = ["alz", "egg", "lz", "tlz"]

    /// Everything that can be unpacked.
    static var readableFormats: [String] { sevenZipFormats + builtInFormats }

    /// A TAR inside a compressed stream (or a 7z): unpacking the outer layer yields one .tar file.
    private static let tarWrapped: Set<String> = ["tgz", "tbz2", "txz", "tar7z", "tz", "tlz"]

    /// Formats an RPM payload comes in (7-Zip shows it as one compressed CPIO file).
    private static let rpmPayload: Set<String> = ["cpio", "gz", "bz2", "xz", "lzma", "z", "zst"]

    private static let maxStages = 3

    private let sevenZip: SevenZip?

    init(_ sevenZip: SevenZip?) { self.sevenZip = sevenZip }

    /// Unpacks `archive` (of format `format`) into a new folder below `scratchRoot` and returns that folder.
    func extract(_ archive: String, _ format: String, _ scratchRoot: String) async throws -> String {
        var current = archive
        var currentFormat = format
        var previous: String?
        var stage = 0
        while true {
            let folder = FilePath.combine(scratchRoot, "x\(stage)")
            try FileManager.default.createDirectoryIfNeeded(folder)
            try await extractOnce(current, currentFormat, folder, scratchRoot)
            try ArchiveSafety.removeLinks(folder)
            if let previous { ArchiveFiles.tryDeleteFolder(previous) }

            if stage + 1 < Self.maxStages, let inner = try Self.innerArchive(format, folder) {
                previous = folder
                (current, currentFormat) = inner
                stage += 1
                continue
            }
            return folder
        }
    }

    private func extractOnce(_ archive: String, _ format: String, _ folder: String, _ scratchRoot: String) async throws {
        let name = FilePath.fileName(archive)
        switch format {
        case "alz":
            try AlzReader.extract(archive, folder)
        case "egg":
            try await EggReader.extract(archive, folder, sevenZip, scratchRoot)
        case "lz", "tlz":
            let output = FormatRegistry.nameWithoutExtension(archive) + (format == "tlz" ? ".tar" : "")
            try await LzipReader.decompress(archive, FilePath.combine(folder, output), try require(), scratchRoot)
        default:
            let tool = try require()
            let entries = try await tool.list(archive)
            try ArchiveSafety.checkListing(entries, name, folder)
            let links = entries.filter(\.isSymbolicLink).map(\.path)
            try await tool.extract(archive, folder, links, scratchRoot)
        }
    }

    /// The single archive file a stage produced that must be unpacked as well, or nil when done.
    private static func innerArchive(_ originalFormat: String, _ folder: String) throws -> (String, String)? {
        guard tarWrapped.contains(originalFormat) || originalFormat == "rpm" else { return nil }
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder)
        guard entries.count == 1 else { return nil }
        let file = FilePath.combine(folder, entries[0])
        guard FileManager.default.fileExists(file) else { return nil }

        if try isTar(file) { return (file, "tar") }
        if originalFormat == "rpm" {
            let detected = FormatRegistry.detect(file)?.id ?? String(FilePath.extension(file).drop { $0 == "." }).lowercased()
            if rpmPayload.contains(detected) { return (file, detected) }
        }
        return nil
    }

    /// True for a .tar file or a file with the "ustar" signature at offset 257.
    static func isTar(_ path: String) throws -> Bool {
        if path.lowercased().hasSuffix(".tar") { return true }
        let input = try ArchiveFiles.openForReading(path)
        defer { try? input.close() }
        let header = try input.read(upToCount: 262) ?? Data()
        return header.count == 262 && header.suffix(5) == Data("ustar".utf8)
    }

    private func require() throws -> SevenZip {
        guard let sevenZip else { throw ConversionError("7-Zip was not found (engines/7zip).") }
        return sevenZip
    }
}
