// Port of Filee.Engines/Infrastructure/EngineEnvironment.cs (macOS part): where engines are found.
// Optional engines (FFmpeg, calibre, Pandoc, Ghostscript, LibreOffice) are looked up in this order: the copy the user
// chose (`ownCopies`, Settings → Engines), the bundled/downloaded copy, then one already on the Mac (PATH, Homebrew,
// /Applications). Process-wide state, like Filee's statics: one host process serves one data folder.

import Foundation

public final class EngineEnvironment: @unchecked Sendable {
    /// Writable directory for engine state (e.g. LibreOffice profiles).
    public let dataDirectory: String

    public init(dataDirectory: String) { self.dataDirectory = dataDirectory }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _downloadRoot = FilePath.combine(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path, "FileToX", "engines")
    nonisolated(unsafe) private static var _ownCopies: [String: String] = [:]
    nonisolated(unsafe) private static var _searchSystem = true
    nonisolated(unsafe) private static var systemCopies: [String: String?] = [:]
    nonisolated(unsafe) private static var _baseDirectory: String = {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().path
    }()

    /// Folder for engines installed later (the app passes `<Application Support>/FileToX/engines`).
    public static var downloadRoot: String {
        get { lock.withLock { _downloadRoot } }
        set { lock.withLock { _downloadRoot = newValue } }
    }

    /// The folder of the running executable: bundled engines are in its `engines/<name>` (AppContext.BaseDirectory).
    public static var baseDirectory: String {
        get { lock.withLock { _baseDirectory } }
        set { lock.withLock { _baseDirectory = newValue } }
    }

    /// Programs the user chose for an optional engine package: package id → program or its folder.
    public static var ownCopies: [String: String] {
        get { lock.withLock { _ownCopies } }
        set { lock.withLock { _ownCopies = newValue } }
    }

    /// Searching the Mac for engines; tests turn it off so the machine's tools don't change results.
    public static var searchSystem: Bool {
        get { lock.withLock { _searchSystem } }
        set { lock.withLock { _searchSystem = newValue } }
    }

    /// Programs required by each engine package.
    public static let ownCopyPrograms: [String: [String]] = [
        "libreoffice": ["soffice"],
        "pandoc": ["pandoc"],
        "ghostscript": ["gs"],
        "ffmpeg": ["ffmpeg", "ffprobe"],
        "calibre": ["ebook-convert"],
        "rhwp": ["rhwp"],
        "7zip": ["7zz"],
    ]

    /// Filee's Windows program names ("gswin64c.exe", "x.exe") mapped to the macOS name.
    public static func programName(_ name: String) -> String {
        name == "gswin64c.exe" ? "gs" : name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    /// Finds an engine directory `engines/<name>`: next to the executable (bundled), in `downloadRoot`, then — for
    /// development and tests — `$FILETOX_BUNDLED_ENGINES/<name>` or `build/engines/osx-<arch>/<name>` of the
    /// FileToX checkout the executable runs from.
    public static func findBundled(_ name: String) -> String? {
        let fm = FileManager.default
        let local = FilePath.combine(baseDirectory, "engines", name)
        if fm.directoryExists(local) { return local }
        let downloaded = FilePath.combine(downloadRoot, name)
        if fm.directoryExists(downloaded) { return downloaded }
        if let override = ProcessInfo.processInfo.environment["FILETOX_BUNDLED_ENGINES"], !override.isEmpty {
            let candidate = FilePath.combine(override, name)
            return fm.directoryExists(candidate) ? candidate : nil
        }
        var folder: String? = baseDirectory
        for _ in 0..<10 {
            guard let current = folder else { break }
            if fm.fileExists(FilePath.combine(current, "Package.swift")), fm.directoryExists(FilePath.combine(current, "Sources/Engine")) {
                let candidate = FilePath.combine(current, "build", "engines", runtimeIdentifier, name)
                return fm.directoryExists(candidate) ? candidate : nil
            }
            folder = current == "/" ? nil : FilePath.directoryName(current)
        }
        return nil
    }

    /// "osx-arm64" or "osx-x64", the name of the bundled engine folders.
    public static let runtimeIdentifier: String = {
        #if arch(arm64)
        "osx-arm64"
        #else
        "osx-x64"
        #endif
    }()

    /// The folder of the user's own copy of package `id`, when it has every program.
    public static func ownCopyFolder(_ id: String) -> String? {
        ownCopies[id].flatMap { folderWithPrograms(id, $0) }
    }

    /// A program of the user's own copy of package `id`, or nil.
    public static func ownProgram(_ id: String, _ program: String) -> String? {
        ownCopyFolder(id).map { FilePath.combine($0, programName(program)) }
    }

    public static func bundledProgram(_ id: String, _ program: String) -> String? {
        guard let root = findBundled(id), let folder = folderWithPrograms(id, root) else { return nil }
        return FilePath.combine(folder, programName(program))
    }

    /// The folder with all programs of package `id`, given a program the user picked or a folder: that folder or its
    /// bin/, program/, Contents/MacOS or <App>.app/Contents/MacOS sub folder. Nil when they are missing.
    public static func folderWithPrograms(_ id: String, _ path: String) -> String? {
        let fm = FileManager.default
        guard !path.allSatisfy(\.isWhitespace), let programs = ownCopyPrograms[id] else { return nil }
        let start: String? = fm.fileExists(path) ? FilePath.directoryName(path) : fm.directoryExists(path) ? path : nil
        guard let start else { return nil }
        var candidates = [start, FilePath.combine(start, "bin"), FilePath.combine(start, "program"), FilePath.combine(start, "Contents", "MacOS")]
        if let app = id == "libreoffice" ? "LibreOffice.app" : id == "calibre" ? "calibre.app" : nil {
            candidates.append(FilePath.combine(start, app, "Contents", "MacOS"))
        }
        return candidates.first { folder in programs.allSatisfy { fm.fileExists(FilePath.combine(folder, $0)) } }
    }

    /// True when package `id` runs from the bundled/downloaded copy (not the user's or the Mac's).
    public static func usesBundledCopy(_ id: String) -> Bool {
        ownCopyFolder(id) == nil && findBundled(id).flatMap { folderWithPrograms(id, $0) } != nil
    }

    /// The folder of a copy of package `id` already on the Mac (PATH, Homebrew, /Applications). Cached until
    /// `forgetSystemCopies()`.
    public static func systemCopyFolder(_ id: String) -> String? {
        guard searchSystem else { return nil }
        if let cached = lock.withLock({ systemCopies[id] }) { return cached }
        let found = systemFolders(id).lazy.compactMap { folderWithPrograms(id, $0) }.first
        lock.withLock { systemCopies[id] = .some(found) }
        return found
    }

    /// A program of the copy of package `id` on the Mac, or nil.
    public static func systemProgram(_ id: String, _ program: String) -> String? {
        systemCopyFolder(id).map { FilePath.combine($0, programName(program)) }
    }

    /// Searches the Mac again (settings changes, Check again).
    public static func forgetSystemCopies() { lock.withLock { systemCopies.removeAll() } }

    private static func systemFolders(_ id: String) -> [String] {
        var folders = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        folders += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if id == "libreoffice" {
            folders += ["/Applications/LibreOffice.app", FilePath.combine(home, "Applications", "LibreOffice.app"),
                        "/usr/lib/libreoffice/program", "/usr/lib64/libreoffice/program"]
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/opt") {
                folders += entries.filter { $0.hasPrefix("libreoffice") }.sorted(by: >).map { FilePath.combine("/opt", $0, "program") }
            }
        }
        if id == "calibre" {
            folders += ["/Applications/calibre.app", FilePath.combine(home, "Applications", "calibre.app"), "/opt/calibre"]
        }
        var seen = Set<String>()
        // Never the bundled folders: those are the bundled copy, found before.
        return folders.filter { seen.insert($0).inserted && !isWithin($0, downloadRoot) && !isWithin($0, baseDirectory) }
    }

    private static func isWithin(_ path: String, _ root: String) -> Bool {
        let trimmedRoot = FilePath.trimEndingSeparator(root)
        return FilePath.trimEndingSeparator(path) == trimmedRoot || path.hasPrefix(trimmedRoot + "/")
    }

    /// The first path that exists as a file.
    public static func firstExisting(_ candidates: String?...) -> String? {
        candidates.compactMap { $0 }.first { !$0.allSatisfy(\.isWhitespace) && FileManager.default.fileExists($0) }
    }
}
