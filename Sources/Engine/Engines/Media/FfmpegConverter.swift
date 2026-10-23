// Port of Filee.Engines/Media/FfmpegConverter.cs: video and audio conversion with FFmpeg (an optional engine run as a
// separate program: the user's copy, a downloaded one, or Homebrew's): video ↔ video, video → animated GIF or a still
// frame, audio extraction, audio ↔ audio and GIF → video. Container and codec choices live in MediaEncoding, the
// process handling in FfmpegRunner.

import Foundation

/// Converts video and audio files with FFmpeg.
final class FfmpegConverter: Converter {
    private static let versionsLock = NSLock()
    nonisolated(unsafe) private static var versions: [String: String] = [:]

    private let lock = NSLock()
    private var tools: (ffmpeg: String, ffprobe: String)?

    let id = "ffmpeg"
    let displayName = "FFmpeg"

    /// FFmpeg's encoders use every core themselves; two runs keep the CPU busy between files.
    let maxParallelism = 2

    let edges: [ConversionEdge] = FfmpegConverter.buildEdges()

    /// Every video format (read by FFmpeg's demuxers) → every video target, animated GIF, a still PNG frame and every
    /// audio target; every audio format → every audio target (including itself: re-encode with another bitrate);
    /// GIF → MP4, WEBM, MOV. Only formats FFmpeg can write are targets (see MediaEncoding).
    ///
    /// The GIF edge costs more (slow, 256 colours), so video → JPG / PDF / TIFF … goes through the still frame (video →
    /// PNG → image engines) and never renders an animated GIF of a whole film just to take one frame of it.
    private static func buildEdges() -> [ConversionEdge] {
        let videos = FormatRegistry.known.filter { $0.category == .video }.map(\.id)
        let audios = FormatRegistry.known.filter { $0.category == .audio }.map(\.id)
        let videoTargets = MediaEncoding.videoTargets.map(\.key) + MediaEncoding.audioTargets.map(\.key) + ["png"]
        return videos.flatMap { source in videoTargets.map { ConversionEdge(source, $0) } }
            + videos.map { ConversionEdge($0, "gif", 15) }
            + audios.flatMap { source in MediaEncoding.audioTargets.map { ConversionEdge(source, $0.key) } }
            + MediaEncoding.gifToVideoTargets.map { ConversionEdge("gif", $0) }
    }

    func status() -> EngineStatus {
        let found = Self.locate()
        lock.withLock { tools = found }
        guard let found else { return .unavailable("engine.reason.not_installed") }
        do {
            return .available(detail: found.ffmpeg, version: "FFmpeg \(try Self.versionOf(found.ffmpeg))")
        } catch {
            // Present but broken, e.g. a library next to ffmpeg is missing.
            return .unavailable("engine.reason.error", detail: error.localizedDescription)
        }
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        guard let (ffmpeg, ffprobe) = lock.withLock({ tools }) ?? Self.locate() else { throw ConversionError("FFmpeg was not found.") }
        let input = FilePath.fullPath(step.inputPath)
        let info = try await MediaInfo.probe(ffprobe, input)
        progress?(0.02)

        guard let output = try step.output.allocate(FormatRegistry.get(step.to).primaryExtension) else { return [] }

        // Album art for targets FFmpeg can't put a picture stream into (Ogg, Matroska): prepared on the side.
        var cover: CoverExtras?
        if let coverStream = info.coverStreamIndex {
            cover = try await CoverArt.prepare(ffmpeg, input, coverStream, step.to, step.workDirectory)
        }

        // Throws for a missing stream before anything is written (an existing file of that name stays untouched).
        let passes = try MediaEncoding.plan(input, output, step.to, step.preset.media, info, step.workDirectory, cover)
        do {
            var done = 0.0
            for pass in passes {
                try await Self.runPass(ffmpeg, pass, info.duration, progress, done)
                done += pass.weight
            }
            let length = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? NSNumber)?.int64Value ?? 0
            if !FileManager.default.fileExists(output) || length == 0 { throw ConversionError("FFmpeg did not write any output.") }
        } catch {
            // Never leave a half-written file where the user expects a finished one.
            if FileManager.default.fileExists(output) { try? FileManager.default.removeItem(atPath: output) }
            throw error
        }

        progress?(1)
        return [output]
    }

    /// Runs one pass and maps FFmpeg's position (seconds) onto this pass' share of the progress.
    private static func runPass(_ ffmpeg: String, _ pass: FfmpegPass, _ duration: Double?, _ progress: ProgressHandler?,
                                _ done: Double) async throws {
        let total = duration ?? 0
        let weight = pass.weight
        var onPosition: (@Sendable (Double) -> Void)?
        if let progress, total > 0 {
            onPosition = { seconds in progress(0.02 + 0.97 * (done + weight * min(max(seconds / total, 0), 1))) }
        }

        // Without a duration (raw streams) there is nothing to measure against: show an estimate instead.
        let estimate = total <= 0
            ? ProgressEstimate.start(progress, typical: 20, from: 0.02 + 0.97 * done, to: 0.02 + 0.97 * (done + weight))
            : nil
        let result: ProcessResult
        do {
            defer { estimate?.stop() }
            result = try await FfmpegRunner.run(ffmpeg, pass.arguments, onPosition: onPosition)
        }

        if result.exitCode != 0 {
            let reason = FfmpegRunner.summarize(result.standardError)
            throw ConversionError("FFmpeg failed (exit code \(result.exitCode))\(reason.isEmpty ? "." : ": " + reason)")
        }
    }

    /// Both tools must come from the same installation.
    static func locate() -> (ffmpeg: String, ffprobe: String)? {
        let folder = EngineEnvironment.ownCopyFolder("ffmpeg")
            ?? EngineEnvironment.findBundled("ffmpeg").flatMap { EngineEnvironment.folderWithPrograms("ffmpeg", $0) }
            ?? EngineEnvironment.systemCopyFolder("ffmpeg")
        return folder.map {
            (FilePath.combine($0, EngineEnvironment.programName("ffmpeg.exe")), FilePath.combine($0, EngineEnvironment.programName("ffprobe.exe")))
        }
    }

    /// "9.0.2" from `ffmpeg -version`; cached per executable so re-checking the engines stays cheap.
    private static func versionOf(_ ffmpeg: String) throws -> String {
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: ffmpeg))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(ffmpeg)|\(stamp)"
        if let cached = versionsLock.withLock({ versions[key] }) { return cached }

        let result: ProcessResult
        do {
            result = try ProcessRunner.runBlocking(ffmpeg, ["-hide_banner", "-version"], timeout: 10)
        } catch is ProcessTimeoutError {
            throw ConversionError("FFmpeg did not start in time.")
        }
        if result.exitCode != 0 { throw ConversionError("FFmpeg does not start (exit code \(result.exitCode)).") }
        // "ffmpeg version 9.0.2-full_build-www.gyan.dev Copyright …" → "9.0.2"
        let firstLine = result.standardOutput.components(separatedBy: "\n").first ?? ""
        let regex = try NSRegularExpression(pattern: #"version\s+n?(\d+(?:\.\d+)+|\S+)"#)
        let version = regex.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine))
            .flatMap { Range($0.range(at: 1), in: firstLine) }
            .map { String(firstLine[$0]) } ?? firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        versionsLock.withLock { versions[key] = version }
        return version
    }
}
