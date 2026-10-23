import Foundation

public enum FileSystemPaths {
    // Patch 0002 uses ordinal paths on Unix. Encode keys to preserve distinct Unicode spellings in Swift sets.
    public static func key(_ path: String) -> String { Data(path.utf8).base64EncodedString() }
    public static func equal(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
}
