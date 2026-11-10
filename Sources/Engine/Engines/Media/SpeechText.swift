// On-device speech transcription with Apple's Speech framework (SpeechAnalyzer, macOS 26 or later), for video and
// audio → TXT. FfmpegConverter extracts the sound as a WAV file first. The language models are the system's: the user
// downloads the ones they need in the app's settings, and nothing is downloaded during a conversion.

import AVFoundation
import Foundation
import Speech

enum SpeechText {
    /// The languages to try, of the installed models: one per language (the user's region of it when installed), the
    /// user's languages first in their order.
    static func candidates(_ installed: [Locale], preferred: [String] = Locale.preferredLanguages) -> [Locale] {
        func language(_ locale: Locale) -> String { locale.language.languageCode?.identifier ?? locale.identifier }
        let wanted = preferred.map { Locale(identifier: $0) }
        let sorted = installed.sorted { $0.identifier < $1.identifier }
        var chosen: [Locale] = []
        for code in wanted.map(language) + sorted.map(language) where !chosen.contains(where: { language($0) == code }) {
            let group = sorted.filter { language($0) == code }
            let regions = wanted.filter { language($0) == code }.compactMap { $0.region?.identifier }
            if let best = group.first(where: { locale in regions.contains { $0 == locale.region?.identifier } }) ?? group.first { chosen.append(best) }
        }
        return chosen
    }

    /// The language that understood a sample best, by each one's amount of text and confidence in it. A language that
    /// hears a few characters where another hears sentences is sure of very little: those are left out first.
    static func choose(_ heard: [(characters: Int, confidence: Double)]) -> Int? {
        guard let longest = heard.map(\.characters).max(), longest > 0 else { return nil }
        return heard.indices.filter { heard[$0].characters * 3 >= longest }.max { heard[$0].confidence < heard[$1].confidence }
    }

    /// The speech of the audio file at `path`: one cue for each stretch of speech between pauses. With several language
    /// models installed, the one that understands the first 45 seconds best reads the file (the user's first language
    /// when no speech is in them). `progress` gets the share of `duration` (seconds) read so far.
    @available(macOS 26.0, *)
    static func transcribe(_ path: String, duration: Double?, workDirectory: String, progress: ProgressHandler?) async throws -> [SubtitleText.Cue] {
        let languages = Array(candidates(await SpeechTranscriber.installedLocales).prefix(5))
        guard var locale = languages.first else {
            throw ConversionError("No speech recognition language is installed. Download one in Settings → Conversion engines → Speech recognition languages.")
        }
        if languages.count > 1 {
            let sample = try sample(path, seconds: 45, in: workDirectory)
            defer { if sample != path { try? FileManager.default.removeItem(atPath: sample) } }
            // The languages listen to the sample at the same time.
            let heard = try await withThrowingTaskGroup(of: (Int, (characters: Int, confidence: Double)).self) { group in
                for (index, language) in languages.enumerated() {
                    group.addTask {
                        let result = try await recognize(sample, language, duration: nil, progress: nil)
                        return (index, (result.cues.reduce(0) { $0 + $1.text.count }, result.confidence))
                    }
                }
                var heard = [(characters: Int, confidence: Double)](repeating: (0, 0), count: languages.count)
                for try await (index, result) in group { heard[index] = result }
                return heard
            }
            if let best = choose(heard) { locale = languages[best] }
        }
        return try await recognize(path, locale, duration: duration, progress: progress).cues
    }

    /// The first `seconds` of the audio file as a file of its own (`path` itself when it is no longer than that).
    private static func sample(_ path: String, seconds: Double, in folder: String) throws -> String {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let frames = AVAudioFrameCount(seconds * file.processingFormat.sampleRate)
        guard file.length > AVAudioFramePosition(frames), let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return path }
        try file.read(into: buffer, frameCount: frames)
        let output = FilePath.combine(folder, "speech-sample-\(UUID().uuidString).wav")
        try AVAudioFile(forWriting: URL(fileURLWithPath: output), settings: file.fileFormat.settings).write(from: buffer)
        return output
    }

    @available(macOS 26.0, *)
    private static func recognize(_ path: String, _ locale: Locale, duration: Double?, progress: ProgressHandler?) async throws
        -> (cues: [SubtitleText.Cue], confidence: Double) {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.transcriptionConfidence])
        // Also readies an installed model; a request means it is not installed (any more).
        if try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) != nil {
            throw ConversionError("The speech recognition language \(locale.identifier) is not installed. Download it in Settings → Conversion engines.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        return try await withTaskCancellationHandler {
            async let heard = transcriber.results.reduce(into: (cues: [SubtitleText.Cue](), sum: 0.0, count: 0)) { heard, result in
                let line = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { heard.cues.append(SubtitleText.Cue(start: result.range.start.seconds, end: result.range.end.seconds, text: line)) }
                for run in result.text.runs {
                    guard let confidence = run.transcriptionConfidence else { continue }
                    let characters = result.text[run.range].characters.count
                    heard.sum += confidence * Double(characters)
                    heard.count += characters
                }
                if let duration, duration > 0 { progress?(min(1, result.range.end.seconds / duration)) }
            }
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let result = try await heard
            try Task.checkCancellation()
            return (result.cues, result.sum / Double(max(1, result.count)))
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
