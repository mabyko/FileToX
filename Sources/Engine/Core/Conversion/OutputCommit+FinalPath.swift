// Part of the port of OutputCommit.cs (Vendor/Filee.patches/0001): which final path a staged output will get.
// Engines that write links relative to their output (built-in Markdown → HTML) ask where the file ends up.

import Foundation

public enum OutputCommit {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var finals: [String: String] = [:]

    /// The final path of a staged output, or `path` itself when it is not staged.
    public static func finalPath(of path: String) -> String {
        lock.withLock { finals[path] } ?? path
    }

    static func track(staged: String, final: String) { lock.withLock { finals[staged] = final } }

    static func untrack(staged: String) { _ = lock.withLock { finals.removeValue(forKey: staged) } }
}
