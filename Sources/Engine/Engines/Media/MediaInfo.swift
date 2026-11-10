// Port of Filee.Engines/Media/MediaInfo.cs: what the FFmpeg engine needs to know about a media file before encoding it
// (duration, first video and audio stream, cover picture), read from ffprobe's JSON output.

import CoreFoundation
import Foundation

/// The first real video stream of a file (cover pictures are not counted).
struct VideoStreamInfo: Equatable {
    /// Coded width in pixels.
    let width: Int
    /// Coded height in pixels.
    let height: Int
    /// Pixel aspect ratio (1 for square pixels, 8/9 for NTSC DV 4:3, ...).
    let sampleAspect: Double
    /// Display rotation in degrees from the display matrix (phones record portrait video this way).
    let rotation: Int
    /// Average frames per second, 0 when unknown.
    let frameRate: Double
    /// The stream's nominal timing rate. Variable-rate video can have much shorter intervals than its average.
    let nominalFrameRate: Double
    /// Declared frame count, 0 when the container does not provide it.
    let frameCount: Int

    init(_ width: Int, _ height: Int, _ sampleAspect: Double, _ rotation: Int, _ frameRate: Double, frameCount: Int = 0,
         nominalFrameRate: Double = 0) {
        self.width = width
        self.height = height
        self.sampleAspect = sampleAspect
        self.rotation = rotation
        self.frameRate = frameRate
        self.nominalFrameRate = nominalFrameRate
        self.frameCount = frameCount
    }

    /// True when the picture is shown turned by 90° (FFmpeg rotates it upright while decoding).
    var isRotated: Bool { abs(rotation % 180) == 90 }

    /// Width ÷ height as the picture is displayed: pixel aspect and rotation applied.
    var displayAspect: Double {
        if width <= 0 || height <= 0 { return 16 / 9.0 }
        let aspect = Double(width) * sampleAspect / Double(height)
        return isRotated ? 1 / aspect : aspect
    }
}

/// The first audio stream of a file.
struct AudioStreamInfo: Equatable {
    let channels: Int
    let sampleRate: Int

    init(_ channels: Int, _ sampleRate: Int) {
        self.channels = channels
        self.sampleRate = sampleRate
    }
}

/// Summary of a media file.
struct MediaInfo: Equatable {
    /// Playing time in seconds, nil when the container does not say (raw streams).
    let duration: Double?
    /// First video stream that is not a cover picture, if any.
    let video: VideoStreamInfo?
    /// First audio stream, if any.
    let audio: AudioStreamInfo?
    /// Index of an embedded cover picture (JPEG or PNG) such as album art, if any.
    let coverStreamIndex: Int?

    init(_ duration: Double?, _ video: VideoStreamInfo?, _ audio: AudioStreamInfo?, _ coverStreamIndex: Int?) {
        self.duration = duration
        self.video = video
        self.audio = audio
        self.coverStreamIndex = coverStreamIndex
    }

    private static let probeTimeout: TimeInterval = 60

    /// Runs ffprobe on `input`; throws with FFmpeg's message when the file cannot be read.
    static func probe(_ ffprobe: String, _ input: String) async throws -> MediaInfo {
        let result = try await ProcessRunner.run(ffprobe,
            ["-hide_banner", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", input],
            timeout: probeTimeout)
        if result.exitCode != 0 {
            let reason = FfmpegRunner.summarize(result.standardError)
            throw ConversionError("FFmpeg cannot read this file\(reason.isEmpty ? "." : ": " + reason)")
        }
        return try parse(result.standardOutput)
    }

    /// Parses the output of `ffprobe -print_format json -show_format -show_streams`.
    static func parse(_ json: String) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ConversionError("ffprobe returned no information.")
        }

        var video: VideoStreamInfo?
        var audio: AudioStreamInfo?
        var cover: Int?
        var longestStream = 0.0
        for stream in root["streams"] as? [[String: Any]] ?? [] {
            longestStream = max(longestStream, number(stream, "duration"))
            switch text(stream, "codec_type") {
            case "video" where isAttachedPicture(stream):
                // Album art and thumbnails: kept for audio targets that can hold a cover, never encoded as video.
                if cover == nil, let codec = text(stream, "codec_name"), codec == "mjpeg" || codec == "png" {
                    cover = int(number(stream, "index"))
                }
            case "video" where video == nil:
                let sar = ratio(text(stream, "sample_aspect_ratio"), ":")
                video = VideoStreamInfo(int(number(stream, "width")), int(number(stream, "height")), sar > 0 ? sar : 1,
                                        rotationOf(stream), frameRateOf(stream), frameCount: int(number(stream, "nb_frames")),
                                        nominalFrameRate: nominalFrameRateOf(stream))
            case "audio" where audio == nil:
                audio = AudioStreamInfo(int(number(stream, "channels")), int(number(stream, "sample_rate")))
            default:
                break
            }
        }

        var seconds = (root["format"] as? [String: Any]).map { number($0, "duration") } ?? 0
        if seconds <= 0 { seconds = longestStream }
        return MediaInfo(seconds > 0 ? seconds : nil, video, audio, cover)
    }

    private static func isAttachedPicture(_ stream: [String: Any]) -> Bool {
        guard let disposition = stream["disposition"] as? [String: Any], let attached = jsonNumber(disposition["attached_pic"]) else {
            return false
        }
        return attached == 1
    }

    /// Average frame rate; the nominal rate when the average is missing or nonsense (e.g. "0/0").
    private static func frameRateOf(_ stream: [String: Any]) -> Double {
        let average = ratio(text(stream, "avg_frame_rate"), "/")
        if average > 0 && average < 1000 { return average }
        return nominalFrameRateOf(stream)
    }

    private static func nominalFrameRateOf(_ stream: [String: Any]) -> Double {
        let rate = ratio(text(stream, "r_frame_rate"), "/")
        return rate > 0 && rate < 1000 ? rate : 0
    }

    /// Rotation from the display matrix side data, or the older "rotate" tag.
    private static func rotationOf(_ stream: [String: Any]) -> Int {
        for item in stream["side_data_list"] as? [[String: Any]] ?? [] {
            if let rotation = jsonNumber(item["rotation"]) { return int(rotation.rounded(.toNearestOrEven)) }
        }
        let tags = stream["tags"] as? [String: Any]
        return tags.flatMap { text($0, "rotate") }.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    }

    private static func text(_ element: [String: Any], _ name: String) -> String? { element[name] as? String }

    /// C#'s `(int)` cast, kept in range so odd values can't trap.
    private static func int(_ value: Double) -> Int { Int(min(max(value, -2_147_483_648), 2_147_483_647)) }

    /// ffprobe writes most numbers as strings ("2.000000"), some as JSON numbers.
    private static func number(_ element: [String: Any], _ name: String) -> Double {
        if let value = jsonNumber(element[name]) { return value }
        guard let text = element[name] as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else {
            return 0
        }
        return number
    }

    /// A JSON number (not a string or a boolean).
    private static func jsonNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// "30000/1001" → 29.97, "16:9" → 1.78; 0 for missing or invalid values.
    private static func ratio(_ text: String?, _ separator: Character) -> Double {
        guard let parts = text?.split(separator: separator, omittingEmptySubsequences: false), parts.count == 2,
              let num = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let den = Double(parts[1].trimmingCharacters(in: .whitespaces)), den > 0 else { return 0 }
        return num / den
    }
}
