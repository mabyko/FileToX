// .NET System.IO.Path semantics on macOS, so ported engine code keeps the exact name handling of Filee. Like .NET's
// char-based code, "/" and "." are found per code point: a combining mark after them must not hide them (Swift's
// Characters would merge "/" + U+0301 into one grapheme).

import Foundation

public enum FilePath {
    /// `Path.GetFileName`: the part after the last "/".
    public static func fileName(_ path: String) -> String {
        let scalars = path.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else { return path }
        return String(scalars[scalars.index(after: slash)...])
    }

    /// `Path.GetExtension`: ".ext" of the file name including the dot, "" when there is none or the name ends with ".".
    public static func `extension`(_ path: String) -> String {
        let name = fileName(path).unicodeScalars
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) != name.endIndex else { return "" }
        return String(name[dot...])
    }

    /// `Path.GetFileNameWithoutExtension`.
    public static func fileNameWithoutExtension(_ path: String) -> String {
        let name = fileName(path).unicodeScalars
        guard let dot = name.lastIndex(of: ".") else { return String(name) }
        return String(name[..<dot])
    }

    /// `Path.GetDirectoryName`: nil for "" and "/", "" for a bare name, else the folder without a trailing "/".
    public static func directoryName(_ path: String) -> String? {
        let scalars = path.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else { return path.isEmpty ? nil : "" }
        if slash == scalars.startIndex { return path == "/" ? nil : "/" }
        var folder = String(scalars[..<slash])
        while folder.unicodeScalars.count > 1, folder.unicodeScalars.last == "/" { folder.unicodeScalars.removeLast() }
        return folder
    }

    /// `Path.Combine`: a later absolute part replaces everything before it; empty parts are skipped.
    public static func combine(_ parts: String...) -> String { combine(parts) }

    public static func combine(_ parts: [String]) -> String {
        var result = ""
        for part in parts where !part.isEmpty {
            if part.unicodeScalars.first == "/" || result.isEmpty { result = part }
            else { result += (result.unicodeScalars.last == "/" ? "" : "/") + part }
        }
        return result
    }

    /// `Path.ChangeExtension(path, ext)`: `ext` with or without the dot; nil removes the extension.
    public static func changeExtension(_ path: String, _ ext: String?) -> String {
        let current = `extension`(path)
        var stem = path
        if !current.isEmpty { stem.unicodeScalars.removeLast(current.unicodeScalars.count) }
        else if stem.unicodeScalars.last == "." { stem.unicodeScalars.removeLast() }
        guard let ext else { return stem }
        return ext.isEmpty ? stem + "." : stem + (ext.unicodeScalars.first == "." ? ext : "." + ext)
    }

    /// `Path.GetFullPath`: absolute, with "." and ".." resolved lexically (no symlink resolution).
    public static func fullPath(_ path: String) -> String {
        let absolute = isFullyQualified(path) ? path : combine(FileManager.default.currentDirectoryPath, path)
        var stack: [String] = []
        for component in absolute.unicodeScalars.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            if component == ".." { if !stack.isEmpty { stack.removeLast() }; continue }
            stack.append(component)
        }
        let joined = "/" + stack.joined(separator: "/")
        return absolute.unicodeScalars.last == "/" && joined != "/" ? joined + "/" : joined
    }

    /// `Path.TrimEndingDirectorySeparator`.
    public static func trimEndingSeparator(_ path: String) -> String {
        guard path.unicodeScalars.count > 1, path.unicodeScalars.last == "/" else { return path }
        return String(path.unicodeScalars.dropLast())
    }

    /// `Path.IsPathFullyQualified` on Unix.
    public static func isFullyQualified(_ path: String) -> Bool { path.unicodeScalars.first == "/" }

    /// `Path.GetInvalidFileNameChars()` on Unix.
    public static let invalidFileNameCharacters: Set<Character> = ["\0", "/"]

    /// The Cocoa error FileManager reports for a failed write of `path` (errno `code`).
    static func writeError(_ code: Int32, _ path: String) -> CocoaError {
        let kind: CocoaError.Code = switch code {
        case EACCES, EPERM: .fileWriteNoPermission
        case EEXIST: .fileWriteFileExists
        case ENOSPC, EDQUOT: .fileWriteOutOfSpace
        case EROFS: .fileWriteVolumeReadOnly
        case ENAMETOOLONG: .fileWriteInvalidFileName
        default: .fileWriteUnknown
        }
        return CocoaError(kind, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }
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

    /// `Directory.CreateDirectory`: creates every missing parent, succeeds when the folder already exists. mkdir(2) keeps
    /// names as given, like .NET; FileManager.createDirectory would store them decomposed (NFD), which shows Korean names
    /// as separated jamo once they leave the Mac.
    func createDirectoryIfNeeded(_ path: String) throws {
        if directoryExists(path) { return }
        if let parent = FilePath.directoryName(path), !parent.isEmpty, parent != path { try createDirectoryIfNeeded(parent) }
        guard mkdir(path, 0o777) != 0 else { return }
        let code = errno
        if code == EEXIST && directoryExists(path) { return }
        throw FilePath.writeError(code, path)
    }

    /// Deletes a file or folder tree and ignores failures (a viewer may still hold a temp file).
    func removeIfPresent(_ path: String) {
        try? removeItem(atPath: path)
    }
}
