// Port of Filee.Engines/Media/FfmpegRunner.cs: runs ffmpeg and turns its machine-readable progress output into a
// position in seconds. Unlike other tools there is no overall timeout (a feature film legitimately encodes for an hour);
// a process that stops reporting for a long time is treated as hung and killed, and cancellation always kills the
// whole process tree (ProcessRunner does both when its task is cancelled).

import Foundation

/// Starts FFmpeg with live progress, a stall watchdog and cancellation.
enum FfmpegRunner {
    /// FFmpeg reports its progress every half second while it works, so this long without a single line means it is
    /// stuck (e.g. on a stalled network share).
    static let defaultStallTimeout: TimeInterval = 10 * 60

    private static let watchInterval: TimeInterval = 1
    private static let keptErrorLines = 40

    /// ProcessRunner's time limit, which only the stall watchdog may end early.
    private static let noTimeout: TimeInterval = 10 * 365 * 24 * 3600

    /// Key of the per-frame stats line the GIF palette pass writes (seconds, see MediaEncoding).
    static let frameTimeKey = "frame_time"

    /// FFmpeg went silent for longer than the stall timeout and was stopped.
    struct StallError: LocalizedError {
        let minutes: Int
        var errorDescription: String? { "FFmpeg stopped responding (no progress for \(minutes) minutes) and was stopped." }
    }

    /// Runs ffmpeg with `arguments` and waits for it to exit. `onPosition` gets the output position in seconds whenever
    /// FFmpeg reports one; `stallTimeout` is how long FFmpeg may stay silent before it is killed. Returns the exit code and
    /// the last lines FFmpeg wrote to stderr (its error messages).
    static func run(_ ffmpeg: String, _ arguments: [String], onPosition: (@Sendable (Double) -> Void)?,
                    stallTimeout: TimeInterval? = nil) async throws -> ProcessResult {
        let activity = Activity()
        let limit = stallTimeout ?? defaultStallTimeout
        let result = try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask {
                try await ProcessRunner.run(ffmpeg, arguments, timeout: noTimeout) { line in
                    activity.touch()
                    if let seconds = parsePosition(line) { onPosition?(seconds) }
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: UInt64(watchInterval * 1e9))
                    if activity.silence > limit {
                        throw StallError(minutes: Int((limit / 60).rounded(.toNearestOrAwayFromZero)))
                    }
                }
            }
            // The first child to end decides: ffmpeg's result, the watchdog's error or cancellation. Cancelling the
            // other one kills a still running ffmpeg (process tree) before the group returns.
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw CancellationError() }
            return result
        }

        var lines = result.standardError.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return ProcessResult(exitCode: result.exitCode, standardOutput: "",
                             standardError: lines.suffix(keptErrorLines).joined(separator: "\n"))
    }

    /// The position in seconds from one line of `-progress` output (`out_time_us=2000000`) or of the palette pass' frame
    /// stats (`frame_time=2.5`); nil for every other line.
    static func parsePosition(_ line: String) -> Double? {
        guard let separator = line.firstIndex(of: "="), separator > line.startIndex else { return nil }
        let key = line[..<separator]
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "out_time_us" {
            // "N/A" before the first frame
            guard let microseconds = Int64(value), microseconds >= 0 else { return nil }
            return Double(microseconds) / 1_000_000
        }
        if key == frameTimeKey {
            guard let seconds = Double(value), seconds >= 0, seconds.isFinite else { return nil }
            return seconds
        }
        return nil
    }

    /// A short, readable version of FFmpeg's error output: its last distinct lines, without log prefixes.
    static func summarize(_ stderr: String) -> String {
        var seen = Set<String>()
        let lines = stderr.components(separatedBy: "\n")
            .map { stripPrefix($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return lines.suffix(3).joined(separator: " ")
    }

    /// "[aost#0:1/wmav2 @ 0000012a] too many channels" → "too many channels".
    private static func stripPrefix(_ text: String) -> String {
        var line = text
        while line.hasPrefix("["), let end = line.range(of: "] "), end.lowerBound > line.startIndex {
            line = String(line[end.upperBound...]).trimmingLeadingWhitespace()
        }
        return line
    }

    /// When FFmpeg last wrote a line (stdout or stderr).
    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var last = DispatchTime.now().uptimeNanoseconds

        func touch() { lock.withLock { last = DispatchTime.now().uptimeNanoseconds } }

        /// Seconds since the last line.
        var silence: TimeInterval {
            let last = lock.withLock { self.last }
            let now = DispatchTime.now().uptimeNanoseconds
            return now > last ? Double(now - last) / 1e9 : 0
        }
    }
}

fileprivate extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop { $0.isWhitespace })
    }
}
