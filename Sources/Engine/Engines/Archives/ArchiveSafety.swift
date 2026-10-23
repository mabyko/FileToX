// Port of Filee.Engines/Archives/ArchiveSafety.cs: guards for unpacking archives from anywhere: entries that would land
// outside the target folder ("zip slip"), symbolic links, encrypted content and archives that would not fit on the
// disk. Also the error messages for them.

import Darwin
import Foundation

/// Checks and path helpers shared by the 7-Zip and the built-in archive readers.
enum ArchiveSafety {
    /// More entries than this are refused: real archives stay far below, "entry bombs" do not.
    static let maxEntries = 1_000_000

    /// `maxEntries` as Filee writes it ("{MaxEntries:N0}").
    static let maxEntriesText = "1,000,000"

    /// Space that must stay free on the drive after unpacking.
    private static let reserve: Int64 = 64 * 1024 * 1024

    private static let invalidNameCharacters: Set<Unicode.Scalar> = ["\0", "/", "<", ">", ":", "\"", "\\", "|", "?", "*"]

    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// True if an entry path is absolute, starts with a drive, or climbs out of the target with "..". Checked per
    /// code point like .NET's chars: a separator followed by a combining mark is still a separator.
    static func isUnsafePath(_ entryPath: String) -> Bool {
        let scalars = Array(entryPath.unicodeScalars)
        guard let first = scalars.first else { return false }
        if first == "/" || first == "\\" { return true }
        if scalars.count >= 2, scalars[1] == ":", first.isASCII, first.properties.isAlphabetic { return true }
        return segments(entryPath, omittingEmpty: false).contains("..")
    }

    /// The parts of an entry name between "/" and "\\" (String.Split on chars, not on grapheme clusters).
    private static func segments(_ entryName: String, omittingEmpty: Bool) -> [String] {
        entryName.unicodeScalars.split(omittingEmptySubsequences: omittingEmpty, whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
    }

    /// Refuses a 7-Zip listing with encrypted entries, entries or hard links pointing outside the target folder, too
    /// many entries, or more data than the drive of `targetDirectory` can hold.
    static func checkListing(_ entries: [SevenZipEntry], _ archiveName: String, _ targetDirectory: String) throws {
        if entries.count > maxEntries {
            throw ConversionError("\(archiveName) has more than \(maxEntriesText) entries; Filee does not unpack it.")
        }
        for entry in entries {
            if entry.isEncrypted { throw encrypted(archiveName) }
            if isUnsafePath(entry.path) || (entry.hardLink.map { !$0.isEmpty && isUnsafePath($0) } ?? false) {
                throw unsafe(archiveName, entry.path)
            }
        }
        try ensureRoom(try ArchiveFiles.sum(entries.filter { !$0.isFolder }.map(\.size)), targetDirectory, archiveName)
    }

    /// Throws when `bytes` would not fit on the drive of `directory`.
    static func ensureRoom(_ bytes: Int64, _ directory: String, _ archiveName: String) throws {
        guard bytes > 0 else { return }
        // DriveInfo(root): the volume of the folder or of its nearest existing parent.
        var info = statfs()
        var probe = FilePath.fullPath(directory)
        while statfs(probe, &info) != 0 {
            guard let parent = FilePath.directoryName(probe), parent != probe else { return }
            probe = parent
        }
        let free = Int64(info.f_bavail) * Int64(info.f_bsize)
        let mount = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // The boot volume's data lives on /System/Volumes/Data; users know it as "/".
        let root = mount == "/System/Volumes/Data" || mount.isEmpty ? "/" : mount
        if bytes > free - reserve {
            throw ConversionError("\(archiveName) unpacks to \(formatSize(bytes)), but only \(formatSize(free)) is free on \(root).")
        }
    }

    /// Turns an entry name read by Filee's own readers into a path inside `root`: separators are normalized, characters
    /// Windows does not allow are replaced, and anything escaping the root is refused.
    static func resolveEntryPath(_ root: String, _ entryName: String, _ archiveName: String) throws -> String {
        if isUnsafePath(entryName) { throw unsafe(archiveName, entryName) }
        let parts = segments(entryName, omittingEmpty: true)
            .filter { $0 != "." }
            .map(sanitizeSegment)
        if parts.isEmpty { throw damaged(archiveName, "an entry has no name") }

        let fullRoot = FilePath.fullPath(root)
        let full = FilePath.fullPath(FilePath.combine([fullRoot] + parts))
        guard Array(full.lowercased().utf16).starts(with: Array((FilePath.trimEndingSeparator(fullRoot) + "/").lowercased().utf16)) else {
            throw unsafe(archiveName, entryName)
        }
        return full
    }

    /// Deletes symbolic links below `root` without following them, so nothing packed or moved later can reach outside
    /// the unpacked folder.
    static func removeLinks(_ root: String) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: root) {
            let path = FilePath.combine(root, name)
            let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                try fm.removeItem(atPath: path) // removes the link, not its target
            } else if type == .typeDirectory {
                try removeLinks(path)
            }
        }
    }

    static func encrypted(_ archiveName: String) -> ConversionError {
        ConversionError("\(archiveName) is password-protected. Filee cannot unpack encrypted archives.")
    }

    static func unsafe(_ archiveName: String, _ entry: String) -> ConversionError {
        ConversionError("\(archiveName) was not unpacked: the entry \"\(entry)\" points outside the target folder.")
    }

    static func damaged(_ archiveName: String, _ detail: String) -> ConversionError {
        ConversionError("\(archiveName) is damaged or incomplete (\(detail)).")
    }

    /// "1.4 GB" style size for messages (.NET "0.0" / "0": half away from zero, invariant).
    static func formatSize(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) bytes" }
        if value < 10 {
            let tenths = Int((value * 10).rounded(.toNearestOrAwayFromZero))
            return "\(tenths / 10).\(tenths % 10) \(units[unit])"
        }
        return "\(Int(value.rounded(.toNearestOrAwayFromZero))) \(units[unit])"
    }

    /// One path segment made valid on Windows: invalid characters become "_", device names get a prefix.
    private static func sanitizeSegment(_ segment: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in segment.unicodeScalars {
            scalars.append(invalidNameCharacters.contains(scalar) || scalar.properties.generalCategory == .control ? "_" : scalar)
        }
        var name = String(scalars)
        while let last = name.unicodeScalars.last, last == "." || last == " " { name.unicodeScalars.removeLast() }
        if name.isEmpty { return "_" }
        let stem = String(name.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)[0])
        return reservedNames.contains(stem.uppercased()) ? "_" + name : name
    }
}
