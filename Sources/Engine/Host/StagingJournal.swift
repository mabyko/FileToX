import Foundation
import Darwin

final class StagingJournal {
    private let path: String, lock = NSLock()
    init(_ path: String) { self.path = path }
    func append(_ folder: String) throws {
        try lock.withLock {
            let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o666)
            guard fd >= 0 else { throw ConversionError(String(cString: strerror(errno))) }
            defer { close(fd) }
            let data = Data((folder + "\n").utf8)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw ConversionError(String(cString: strerror(errno))) }; offset += n
                }
            }
            if fsync(fd) != 0 { throw ConversionError(String(cString: strerror(errno))) }
        }
    }
    func cleanUp() throws {
        guard FileManager.default.fileExists(path) else { return }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if FilePath.isFullyQualified(line) && OutputCommit.isStagingFolderName(FilePath.fileName(line)) && FileManager.default.directoryExists(line) && !OutputCommit.isSymbolicLink(line) { OutputCommit.tryDelete(line) }
        }
        try FileManager.default.removeItem(atPath: path)
    }
}
