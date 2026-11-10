// On-device speech transcription with Apple's Speech framework (SpeechAnalyzer, macOS 26 or later), for video and
// audio → TXT. FfmpegConverter extracts the sound as a WAV file first.

import AVFoundation
import Foundation
import Speech

enum SpeechText {
    /// Speech reads one language per file: the first of the user's languages it supports, else American English.
    @available(macOS 26.0, *)
    static func locale(_ preferred: [String] = Locale.preferredLanguages) async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        for identifier in preferred + ["en-US"] {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)), supported.contains(match) { return match }
        }
        return Locale(identifier: "en-US")
    }

    /// The speech of the audio file at `path`: one line for each stretch of speech between pauses. The system downloads
    /// the language's model on first use. `progress` gets the share of `duration` (seconds) read so far.
    @available(macOS 26.0, *)
    static func transcribe(_ path: String, duration: Double?, progress: ProgressHandler?) async throws -> String {
        let locale = await locale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        } catch {
            throw ConversionError("The speech model for \(locale.identifier) could not be installed: \(error.localizedDescription)")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        return try await withTaskCancellationHandler {
            async let lines = transcriber.results.reduce(into: [String]()) { lines, result in
                let line = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { lines.append(line) }
                if let duration, duration > 0 { progress?(min(1, result.range.end.seconds / duration)) }
            }
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let text = try await lines.joined(separator: "\r\n")
            try Task.checkCancellation()
            return text
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
