// .NET System.IO.Path semantics on macOS, so ported engine code keeps the exact name handling of Filee.

import Foundation

public enum FilePath {
    /// `Path.GetFileName`: the part after the last "/".
    public static func fileName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `Path.GetExtension`: ".ext" of the file name including the dot, "" when there is none or the name ends with ".".
    public static func `extension`(_ path: String) -> String {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) != name.endIndex else { return "" }
        return String(name[dot...])
    }

    /// `Path.GetFileNameWithoutExtension`.
    public static func fileNameWithoutExtension(_ path: String) -> String {
        let name = fileName(path)
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }

    /// `Path.GetDirectoryName`: nil for "" and "/", "" for a bare name, else the folder without a trailing "/".
    public static func directoryName(_ path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return path.isEmpty ? nil : "" }
        if slash == path.startIndex { return path == "/" ? nil : "/" }
        var folder = String(path[..<slash])
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return folder
    }

    /// `Path.Combine`: a later absolute part replaces everything before it; empty parts are skipped.
    public static func combine(_ parts: String...) -> String { combine(parts) }

    public static func combine(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if part.hasPrefix("/") || result.isEmpty { result = part }
            else { result += (result.hasSuffix("/") ? "" : "/") + part }
        }
        return result
    }

    /// `Path.ChangeExtension(path, ext)`: `ext` with or without the dot; nil removes the extension.
    public static func changeExtension(_ path: String, _ ext: String?) -> String {
        let current = `extension`(path)
        let stem = current.isEmpty ? (path.hasSuffix(".") ? String(path.dropLast()) : path) : String(path.dropLast(current.count))
        guard let ext else { return stem }
        return ext.isEmpty ? stem + "." : stem + (ext.hasPrefix(".") ? ext : "." + ext)
    }

    /// `Path.GetFullPath`: absolute, with "." and ".." resolved lexically (no symlink resolution).
    public static func fullPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : combine(FileManager.default.currentDirectoryPath, path)
        var stack: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { if !stack.isEmpty { stack.removeLast() }; continue }
            stack.append(component)
        }
        let joined = "/" + stack.joined(separator: "/")
        return absolute.hasSuffix("/") && joined != "/" ? joined + "/" : joined
    }

    /// `Path.TrimEndingDirectorySeparator`.
    public static func trimEndingSeparator(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `Path.IsPathFullyQualified` on Unix.
    public static func isFullyQualified(_ path: String) -> Bool { path.hasPrefix("/") }

    /// `Path.GetInvalidFileNameChars()` on Unix.
    public static let invalidFileNameCharacters: Set<Character> = ["\0", "/"]
}

public extension FileManager {
    /// `File.Exists`: a regular file (symlinks followed), not a folder.
    func fileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// `Directory.Exists` (symlinks followed).
    func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `Directory.CreateDirectory`: creates every missing parent, succeeds when the folder already exists.
    func createDirectoryIfNeeded(_ path: String) throws {
        try createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Deletes a file or folder tree and ignores failures (a viewer may still hold a temp file).
    func removeIfPresent(_ path: String) {
        try? removeItem(atPath: path)
    }
}
