// Port of Filee.Engines/Archives/SevenZip.cs: runs FileToX's own copy of the 7-Zip console program (engines/7zip/7zz,
// GNU LGPL with the unRAR restriction, used as a separate process) to list, unpack and create archives, and turns its
// messages into clear errors. 7-Zip installed on the system is never used.

import Foundation

/// One entry of a 7-Zip listing (`7zz l -slt`).
struct SevenZipEntry: Equatable {
    /// Path inside the archive as 7-Zip reports it.
    let path: String
    let isFolder: Bool
    let size: Int64
    let isEncrypted: Bool
    /// Target of a symbolic link entry (tar, cpio, zip from Unix), otherwise nil.
    let symbolicLink: String?
    /// Target of a hard link entry (tar), otherwise nil.
    let hardLink: String?
    /// Unix mode or attribute string of the entry, used to spot links that carry no target field.
    var mode: String?

    /// True for symbolic links, which Filee never unpacks (they could point anywhere).
    var isSymbolicLink: Bool {
        !(symbolicLink ?? "").isEmpty
            || (mode?.split(separator: " ", omittingEmptySubsequences: false).contains { $0.utf16.count == 10 && $0.first == "l" } ?? false)
    }
}

/// The bundled 7-Zip console program.
final class SevenZip {
    /// Archives can be many gigabytes; the timeout only ends a process that hangs.
    private static let timeout: TimeInterval = 6 * 3600

    /// Password passed when reading, so 7-Zip never waits for one on the console. Unencrypted archives ignore it; for
    /// encrypted ones 7-Zip reports "Wrong password", which becomes the "password-protected" message.
    private static let noPassword = "-pfilee-no-password"

    let executable: String

    init(_ executable: String) { self.executable = executable }

    /// FileToX's own copy (engines/7zip), never one installed on the system.
    static func locate() -> SevenZip? {
        guard let folder = EngineEnvironment.findBundled("7zip"),
              let exe = EngineEnvironment.firstExisting(FilePath.combine(folder, "7zz")) else { return nil }
        return SevenZip(exe)
    }

    /// Lists the entries of an archive.
    func list(_ archive: String) async throws -> [SevenZipEntry] {
        let result = try await run(["l", "-slt", "-sccUTF-8", "-bsp0", Self.noPassword, "--", FilePath.fullPath(archive)])
        guard result.exitCode == 0 || result.exitCode == 1 else { throw Self.failure(archive, result) }
        return Self.parseListing(result.standardOutput)
    }

    /// Unpacks every entry of `archive` except `exclude` into `outputDirectory`. Clashing names ("A.txt" and "a.txt" on
    /// a case-insensitive volume) are renamed, not overwritten.
    func extract(_ archive: String, _ outputDirectory: String, _ exclude: [String], _ workDirectory: String) async throws {
        var args = ["x", "-y", "-aou", "-sccUTF-8", "-scsUTF-8", "-bsp0", "-bb0", Self.noPassword, "-o" + FilePath.fullPath(outputDirectory)]
        if !exclude.isEmpty {
            // A list file keeps unusual names intact; -spd turns off wildcard matching so "*" in a name is literal.
            let list = FilePath.combine(workDirectory, "exclude-\(ArchiveFiles.guid()).txt")
            try ArchiveFiles.writeAllLines(list, exclude)
            args += ["-spd", "-x@" + list]
        }
        args += ["--", FilePath.fullPath(archive)]

        let result = try await run(args)
        if result.exitCode == 0 || result.exitCode == 1 || (result.exitCode == 2 && Self.onlyLinkErrors(result)) { return }
        throw Self.failure(archive, result)
    }

    /// Creates `archive` (which must not exist) from files and folders; each is stored under its own name, folders with
    /// their content. `type` is 7-Zip's archive type: 7z, zip, tar, gzip, bzip2 or xz.
    func add(_ archive: String, _ type: String, _ level: ArchiveLevel, _ items: [String], _ workDirectory: String) async throws {
        let list = FilePath.combine(workDirectory, "items-\(ArchiveFiles.guid()).txt")
        try ArchiveFiles.writeAllLines(list, items.map(FilePath.fullPath))
        // -ssw packs files other programs have open; -sse stops instead of silently leaving out unreadable files.
        // No "--" here: it would also turn off the @list file.
        let result = try await run(["a", "-t" + type, Self.levelSwitch(level), "-ssw", "-sse", "-y", "-sccUTF-8", "-scsUTF-8",
                                    "-bsp0", "-bb0", FilePath.fullPath(archive), "@" + list])
        if !(result.exitCode == 0 || result.exitCode == 1) || !FileManager.default.fileExists(archive) {
            throw ConversionError("7-Zip could not create the archive (exit \(result.exitCode)). \(Self.errorText(result))"
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 7-Zip's -mx switch for a preset level.
    static func levelSwitch(_ level: ArchiveLevel) -> String {
        switch level {
        case .store: "-mx0"
        case .fast: "-mx1"
        case .maximum: "-mx9"
        case .normal: "-mx5"
        }
    }

    /// Parses the technical listing: blocks of "Key = Value" lines, one per entry, after a "----------" line.
    static func parseListing(_ output: String) -> [SevenZipEntry] {
        var entries: [SevenZipEntry] = []
        var fields: [String: String]?
        var inEntries = false

        func flush() {
            defer { fields = nil }
            guard let current = fields, let path = current["Path"] else { return }
            func field(_ key: String) -> String? { current[key].flatMap { $0.isEmpty ? nil : $0 } }
            let attributes = field("Attributes") ?? ""
            var entry = SevenZipEntry(
                path: path,
                isFolder: field("Folder") == "+" || attributes.hasPrefix("D"),
                size: field("Size").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0,
                isEncrypted: field("Encrypted") == "+",
                symbolicLink: field("Symbolic Link"),
                hardLink: field("Hard Link"))
            entry.mode = field("Mode") ?? field("Attributes")
            entries.append(entry)
        }

        for raw in output.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if !inEntries {
                inEntries = line.hasPrefix("----------")
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let separator = line.range(of: " = "), separator.lowerBound > line.startIndex {
                fields = fields ?? [:]
                fields?[String(line[..<separator.lowerBound])] = String(line[separator.upperBound...])
            } else if line.hasSuffix(" =") {
                fields = fields ?? [:]
                fields?[String(line.dropLast(2))] = ""
            }
        }
        flush()
        return entries
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, arguments, timeout: Self.timeout)
    }

    /// True when every error 7-Zip reported is about a link it did not create (we never want links).
    private static func onlyLinkErrors(_ result: ProcessResult) -> Bool {
        let errors = errorLines(result)
        return !errors.isEmpty && errors.allSatisfy {
            $0.range(of: "symbolic link", options: .caseInsensitive) != nil || $0.range(of: "Dangerous link", options: .caseInsensitive) != nil
        }
    }

    /// Turns a failed 7-Zip run on an archive into an error with a message users understand.
    private static func failure(_ archive: String, _ result: ProcessResult) -> ConversionError {
        let name = FilePath.fileName(archive)
        let text = result.standardError + "\n" + result.standardOutput
        func has(_ s: String) -> Bool { text.range(of: s, options: .caseInsensitive) != nil }

        if has("Wrong password") || has("encrypted archive") { return ArchiveSafety.encrypted(name) }
        if has("Cannot open the file as") || has("Is not archive") || has("Can not open the file as") {
            return ConversionError("\(name) is not a valid archive, or not the kind its extension says.")
        }
        if has("Unexpected end") || has("Data Error") || has("CRC Failed") || has("Headers Error") || has("Missing volume") {
            return ArchiveSafety.damaged(name, errorText(result))
        }
        return ConversionError("7-Zip could not read \(name) (exit \(result.exitCode)). \(errorText(result))"
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The lines of 7-Zip's output that describe errors ("ERROR: ...", and the lines under an "ERRORS:" heading),
    /// without its banner and statistics.
    private static func errorLines(_ result: ProcessResult) -> [String] {
        var lines: [String] = []
        var underHeading = false
        for raw in (result.standardError + "\n" + result.standardOutput).components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "ERRORS:" || line == "WARNINGS:" {
                underHeading = true
                continue
            }
            if line.isEmpty {
                underHeading = false
                continue
            }
            if underHeading || hasPrefix(line, "ERROR") || hasPrefix(line, "Open ERROR") || hasPrefix(line, "WARNING") {
                lines.append(line)
            }
        }
        return lines
    }

    private static func errorText(_ result: ProcessResult) -> String {
        var seen = Set<String>()
        let lines = errorLines(result).filter { seen.insert($0).inserted }.prefix(3)
        let fallback = result.standardError.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(3)
        return (lines.isEmpty ? Array(fallback) : Array(lines)).joined(separator: " ")
    }

    private static func hasPrefix(_ line: String, _ prefix: String) -> Bool {
        line.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }
}
