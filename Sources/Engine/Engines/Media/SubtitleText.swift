// The text of a video or audio file with its times: a subtitle track's cues or the stretches of transcribed speech,
// written as plain text or as SubRip (SRT) subtitles.

import Foundation

enum SubtitleText {
    /// A stretch of text shown or spoken from `start` to `end` (seconds).
    struct Cue: Equatable {
        var start: Double, end: Double, text: String
    }

    /// The cues of a SubRip file as FFmpeg writes it. Styling (`<i>`, `{\an8}`) is left out and a cue's lines are joined.
    static func parse(_ srt: String) -> [Cue] {
        srt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { block -> Cue? in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timing].components(separatedBy: "-->").map { seconds($0.trimmingCharacters(in: .whitespaces)) }
            let text = lines[(timing + 1)...].joined(separator: " ")
                .replacingOccurrences(of: #"<[^>]+>|\{\\[^}]*\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard times.count == 2, let start = times[0], let end = times[1], !text.isEmpty else { return nil }
            return Cue(start: start, end: end, text: text)
        }
    }

    /// "00:01:02,500" (also with a point) in seconds.
    private static func seconds(_ time: String) -> Double? {
        let parts = time.prefix { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".").split(separator: ":").map { Double($0) }
        guard parts.count == 3, let hours = parts[0], let minutes = parts[1], let seconds = parts[2] else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// One line per cue; a cue that repeats the one before it (karaoke and roll-up captions) is left out.
    static func plain(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for cue in cues where cue.text != lines.last { lines.append(cue.text) }
        return lines.joined(separator: "\r\n")
    }

    static func srt(_ cues: [Cue]) -> String {
        func time(_ seconds: Double) -> String {
            let ms = Int((max(0, seconds) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { "\($0 + 1)\n\(time($1.start)) --> \(time(max($1.end, $1.start)))\n\($1.text)\n" }.joined(separator: "\n")
    }
}
