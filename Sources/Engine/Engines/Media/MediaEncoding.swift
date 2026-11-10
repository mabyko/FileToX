// Port of Filee.Engines/Media/MediaEncoding.cs: which container and codecs Filee writes for every video and audio
// format, and the FFmpeg command lines for them. Pure (no processes), so the choices are unit tested without FFmpeg.
// Every encoder and muxer used here was checked against the pinned FFmpeg build (`ffmpeg -encoders` / `-muxers`).
// Filee's ordered dictionaries are arrays here: their order is the order of the engine's edges.

import Foundation

/// How one target format is written. `muxer` is FFmpeg's container name (`-f`), always given explicitly: some
/// extensions are ambiguous. `videoCodec` is nil for audio-only formats.
struct MediaTarget: Equatable {
    let muxer: String
    let videoCodec: String?
    let audioCodec: String

    init(_ muxer: String, _ videoCodec: String?, _ audioCodec: String) {
        self.muxer = muxer
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }
}

/// One run of ffmpeg: the command line after the executable, and its share of the whole conversion's progress (the
/// passes of one conversion add up to 1).
struct FfmpegPass {
    let arguments: [String]
    let weight: Double
}

/// Encoding choices and command lines.
enum MediaEncoding {
    /// Video formats Filee writes. H.264 + AAC wherever the container allows it: it plays on every browser, phone, TV
    /// and editor. The other containers get the codecs their players expect.
    static let videoTargets: [(key: String, value: MediaTarget)] = [
        ("mp4", MediaTarget("mp4", "libx264", "aac")),
        // Apple's M4V is MP4 (FFmpeg's "m4v" muxer would write a raw MPEG-4 part 2 stream instead).
        ("m4v", MediaTarget("mp4", "libx264", "aac")),
        ("mov", MediaTarget("mov", "libx264", "aac")),
        ("mkv", MediaTarget("matroska", "libx264", "aac")),
        ("flv", MediaTarget("flv", "libx264", "aac")),
        ("ts", MediaTarget("mpegts", "libx264", "aac")),
        ("m2ts", MediaTarget("mpegts", "libx264", "aac")), // + 192-byte Blu-ray packets, see containerArguments
        ("3gp", MediaTarget("3gp", "libx264", "aac")),
        ("3g2", MediaTarget("3g2", "libx264", "aac")),
        // The WebM specification allows only VP8/VP9/AV1 with Vorbis/Opus.
        ("webm", MediaTarget("webm", "libvpx-vp9", "libopus")),
        // MPEG-4 part 2 tagged XVID + CBR MP3: what DVD players, old TVs and Windows' built-in codecs read in AVI.
        ("avi", MediaTarget("avi", "mpeg4", "libmp3lame")),
        ("wmv", MediaTarget("asf", "wmv2", "wmav2")),
        // MPEG-2 program stream ("vob" is FFmpeg's plain MPEG-2 PS muxer; "mpeg" would write an MPEG-1 system stream).
        ("mpg", MediaTarget("vob", "mpeg2video", "mp2")),
        // DVD-Video compliant: 720×480 NTSC / 720×576 PAL, AC-3, DVD mux rate and navigation packets.
        ("vob", MediaTarget("dvd", "mpeg2video", "ac3")),
        ("ogv", MediaTarget("ogg", "libtheora", "libvorbis")),
        // DV has fixed frame sizes and rates (see dvdOrDvFilter) and 48 kHz PCM.
        ("dv", MediaTarget("dv", "dvvideo", "pcm_s16le")),
        // MXF OP1a with long-GOP MPEG-2 (XDCAM style) and 48 kHz PCM: what broadcast and editing tools import.
        ("mxf", MediaTarget("mxf", "mpeg2video", "pcm_s16le")),
    ]

    /// Audio formats Filee writes (also the targets of audio extraction from video).
    static let audioTargets: [(key: String, value: MediaTarget)] = [
        ("mp3", MediaTarget("mp3", nil, "libmp3lame")),
        // The iPod muxer writes the M4A/M4B brands iTunes and phones expect.
        ("m4a", MediaTarget("ipod", nil, "aac")),
        ("m4b", MediaTarget("ipod", nil, "aac")),
        ("aac", MediaTarget("adts", nil, "aac")),
        ("wav", MediaTarget("wav", nil, "pcm_s16le")),
        ("flac", MediaTarget("flac", nil, "flac")),
        ("ogg", MediaTarget("ogg", nil, "libvorbis")),
        ("opus", MediaTarget("opus", nil, "libopus")),
        ("wma", MediaTarget("asf", nil, "wmav2")),
        ("aiff", MediaTarget("aiff", nil, "pcm_s16be")),
        ("ac3", MediaTarget("ac3", nil, "ac3")),
        // AMR-NB (OpenCORE): 8 kHz mono speech, what phones record voice memos in.
        ("amr", MediaTarget("amr", nil, "libopencore_amrnb")),
        ("au", MediaTarget("au", nil, "pcm_s16be")),
        // CAF with big-endian linear PCM, the variant Apple's own tools write by default.
        ("caf", MediaTarget("caf", nil, "pcm_s16be")),
        ("weba", MediaTarget("webm", nil, "libopus")),
        ("mka", MediaTarget("matroska", nil, "libopus")),
        ("mp2", MediaTarget("mp2", nil, "mp2")),
        // 16-bit PCM in an extended block: exact sample rate (8-bit blocks can only approximate it).
        ("voc", MediaTarget("voc", nil, "pcm_s16le")),
    ]

    static func videoTarget(_ format: String) -> MediaTarget? { videoTargets.first { $0.key == format }?.value }

    static func audioTarget(_ format: String) -> MediaTarget? { audioTargets.first { $0.key == format }?.value }

    /// Formats an animated GIF can be turned into.
    static let gifToVideoTargets = ["mp4", "webm", "mov"]

    /// Audio targets that can carry a cover picture (album art) copied from the source.
    private static let coverTargets: Set<String> = ["mp3", "m4a", "m4b", "flac"]

    /// Frame rates MPEG-2 (and MXF, which only knows broadcast rates) can signal exactly.
    private static let broadcastRates: [(num: Int, den: Int)] =
        [(24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1), (60000, 1001), (60, 1)]

    /// Container metadata that describes the source file, not the content: not copied.
    private static let sourceOnlyTags = ["major_brand", "minor_version", "compatible_brands"]

    /// Global arguments of every run: no banner, no keyboard input, only errors on stderr, overwrite.
    static let common = ["-hide_banner", "-nostdin", "-nostats", "-v", "error", "-y"]

    /// The ffmpeg runs that convert `input` into `output` in format `target`. `workDirectory` is the scratch folder (the
    /// GIF palette goes there); `cover` carries the source's cover for targets FFmpeg can't put a picture stream into
    /// (`CoverArt`). Throws when the file lacks the stream the target needs (e.g. no audio track).
    static func plan(_ input: String, _ output: String, _ target: String, _ options: MediaOptions, _ info: MediaInfo,
                     _ workDirectory: String, _ cover: CoverExtras? = nil) throws -> [FfmpegPass] {
        if target == "gif" { return try animatedGif(input, output, options, info, workDirectory) }
        if target == "png" { return [FfmpegPass(arguments: try posterFrame(input, output, info), weight: 1)] }
        if let video = videoTarget(target) {
            return [FfmpegPass(arguments: try self.video(input, output, target, video, options, info), weight: 1)]
        }
        if let audio = audioTarget(target) {
            return [FfmpegPass(arguments: try self.audio(input, output, target, audio, options, info, cover), weight: 1)]
        }
        throw ConversionError("FFmpeg cannot write '\(target)'.")
    }

    // ───────────────────────── Video ─────────────────────────

    private static func video(_ input: String, _ output: String, _ target: String, _ spec: MediaTarget, _ options: MediaOptions,
                              _ info: MediaInfo) throws -> [String] {
        guard let video = info.video else { throw ConversionError("The file has no video stream.") }
        // An input without sound is fine: the output simply has no audio track.
        let audio = options.removeAudio ? nil : info.audio

        var args = common + ["-i", input, "-map", "0:V:0"]
        if audio != nil { args += ["-map", "0:a:0"] }

        let pal = isPal(video.frameRate)
        // A low average can hide a short burst (e.g. three frames in one second, with a 20 ms interval).
        // Respect its nominal timing grid instead of rounding those changes to the average's broadcast multiple.
        let sourceRate = max(video.frameRate, video.nominalFrameRate)
        let timingRate = ["ts", "m2ts"].contains(target) && sourceRate > 60 ? String(sourceRate) : broadcastRate(sourceRate)
        let slowRate = video.frameRate > 0 && video.frameRate < 24000 / 1001.0 && ["ts", "m2ts", "mpg", "mxf"].contains(target)
            ? timingRate : nil
        var filter = target == "vob" || target == "dv" ? dvdOrDvFilter(video, pal: pal) : scaleFilter(options.maxHeight)
        if let slowRate {
            // Preserve a slow frame's full display time, including the last one. `-r` alone can round that end down;
            // one-frame transport streams also have ambiguous duration estimates. Fill a broadcast-rate timeline.
            filter += ",fps=\(slowRate):eof_action=pass"
        }
        args += ["-vf", filter]
        args += try videoCodecArguments(target, spec.videoCodec ?? "", options.quality, video, pal, timingRate: slowRate)
        if slowRate != nil, spec.videoCodec == "libx264" {
            // The fps filter already supplies the encoder's rate. A second CFR pass would pad a late-starting
            // video back to zero, changing its display span and its timing relative to audio.
            args += ["-fps_mode", "passthrough"]
            // A few tiny frames can otherwise be mistaken for an MPEG program stream during format probing.
            if target == "ts" { args += ["-mpegts_flags", "+pat_pmt_at_frames"] }
        }
        if target == "webm", FilePath.extension(input).lowercased() == ".gif", video.frameCount == 1, video.frameRate > 0 {
            // VP9 otherwise signals the GIF's 100 Hz time base instead of its single frame's delay.
            args += ["-r", String(video.frameRate)]
        }

        if let audio {
            args += audioCodecArguments(target, spec.audioCodec, options, audio, inVideo: true)
        } else {
            args.append("-an")
        }

        args += metadataArguments()
        args += containerArguments(target)
        // Sparse or late-starting streams (subtitles-like audio) otherwise fail with "too many packets buffered".
        args += ["-max_muxing_queue_size", "4096", "-f", spec.muxer, "-progress", "pipe:1", output]
        return args
    }

    /// Scales down to `maxHeight` (never up) keeping the aspect ratio, and makes both sides even, which 4:2:0 encoders
    /// require (an odd-sized GIF or phone video would otherwise fail).
    static func scaleFilter(_ maxHeight: Int) -> String {
        maxHeight > 0
            ? "scale=w=-2:h='trunc(min(ih,\(max(16, maxHeight)))/2)*2'"
            : "scale=w='trunc(iw/2)*2':h='trunc(ih/2)*2'"
    }

    /// DVD and DV frames are always 720×480 (NTSC) or 720×576 (PAL), shown at 4:3 or 16:9 through the pixel aspect.
    /// The picture is fitted into whichever of the two is closer to its own shape, with black bars for the rest.
    static func dvdOrDvFilter(_ video: VideoStreamInfo, pal: Bool) -> String {
        let height = pal ? 576 : 480
        let aspect = video.displayAspect
        let wide = aspect >= 1.55 // between 4:3 (1.33) and 16:9 (1.78)
        let frameAspect = wide ? 16 / 9.0 : 4 / 3.0
        let (w, h) = aspect > frameAspect
            ? (720, even(Double(height) * frameAspect / aspect))
            : (even(720 * aspect / frameAspect), height)
        return "scale=\(w):\(h),pad=720:\(height):(ow-iw)/2:(oh-ih)/2:black,setdar=\(wide ? "16/9" : "4/3")"
    }

    /// PAL (25 fps) for 25/50 fps sources, NTSC (29.97 fps) for everything else.
    static func isPal(_ fps: Double) -> Bool { abs(fps - 25) < 0.5 || abs(fps - 50) < 1 || abs(fps - 12.5) < 0.3 }

    private static func videoCodecArguments(_ target: String, _ codec: String, _ quality: MediaQuality, _ video: VideoStreamInfo,
                                            _ pal: Bool, timingRate: String?) throws -> [String] {
        // Constant quantizer for the MPEG-style codecs: 2 is the best useful value, 4 good, 7 visibly compressed.
        let quantizer = String(choose(quality, 2, 4, 7))
        switch codec {
        case "libx264":
            // CRF 18 is visually lossless, 23 is x264's default, 28 is clearly smaller. Preset medium is x264's default
            // speed/size balance; yuv420p (8-bit 4:2:0) is the only format every H.264 decoder plays.
            return ["-c:v", "libx264", "-preset", "medium", "-crf", String(choose(quality, 18, 23, 28)), "-pix_fmt", "yuv420p"]
        case "libvpx-vp9":
            // Constant quality mode (-b:v 0 + CRF). Row multithreading and speed 4 keep VP9 usable on a desktop: the
            // slower speeds gain little size for several times the encoding time.
            return ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", String(choose(quality, 24, 32, 38)), "-row-mt", "1",
                    "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
        case "mpeg4":
            // GOP 250 because the encoder's default of 12 bloats files. The frame rate is fixed because MPEG-4 part 2
            // cannot store the fine time bases of phone videos.
            return ["-c:v", "mpeg4", "-tag:v", "XVID", "-q:v", quantizer, "-g", "250", "-bf", "2", "-pix_fmt", "yuv420p"]
                + frameRate(nearestRate(video.frameRate))
        case "wmv2":
            return ["-c:v", "wmv2", "-q:v", quantizer, "-g", "250", "-pix_fmt", "yuv420p"] + frameRate(nearestRate(video.frameRate))
        case "libtheora":
            // Theora quality 0-10.
            return ["-c:v", "libtheora", "-q:v", String(choose(quality, 8, 6, 4)), "-pix_fmt", "yuv420p"]
                + frameRate(nearestRate(video.frameRate))
        case "mpeg2video" where target == "vob":
            // DVD-Video limits: peak 9.8 Mbit/s for video + audio, 1.8 Mbit VBV buffer, GOP of 15 (PAL) / 18 (NTSC).
            return ["-c:v", "mpeg2video", "-b:v", "\(choose(quality, 8000, 6000, 4000))k", "-maxrate", "9000k",
                    "-minrate", "0", "-bufsize", "1835k", "-g", pal ? "15" : "18", "-bf", "2", "-pix_fmt", "yuv420p",
                    "-r", pal ? "25" : "30000/1001"]
        case "mpeg2video":
            // mpg and mxf: constant quantizer, broadcast GOP of 15 and a frame rate MPEG-2 can signal.
            return ["-c:v", "mpeg2video", "-q:v", quantizer, "-g", "15", "-bf", "2", "-pix_fmt", "yuv420p",
                    "-r", timingRate ?? broadcastRate(video.frameRate)]
        case "dvvideo":
            // DV is fixed at 25 Mbit/s: NTSC samples colour 4:1:1, PAL 4:2:0.
            return ["-c:v", "dvvideo", "-pix_fmt", pal ? "yuv420p" : "yuv411p", "-r", pal ? "25" : "30000/1001"]
        default:
            throw ConversionError(codec)
        }
    }

    /// `-r` for a rate, nothing when the source rate is unknown (FFmpeg then keeps its own guess).
    private static func frameRate(_ rate: String?) -> [String] { rate.map { ["-r", $0] } ?? [] }

    /// The source rate as a simple fraction: exact NTSC/film/PAL rates are kept, anything else (variable frame rate
    /// phone videos report averages like 29.87) is rounded to whole frames per second.
    static func nearestRate(_ fps: Double) -> String? {
        if fps <= 0 { return nil }
        for (num, den) in broadcastRates where abs(fps - Double(num) / Double(den)) < 0.01 {
            return den == 1 ? String(num) : "\(num)/\(den)"
        }
        return String(min(max(Int(fps.rounded(.toNearestOrEven)), 1), 120))
    }

    /// Prefer an exact multiple of a sub-broadcast rate (10 → 30, 12.5 → 25) so repeating frames preserves their
    /// display times. Otherwise choose the nearest broadcast rate; use PAL's 25 when the source rate is unknown.
    static func broadcastRate(_ fps: Double) -> String {
        if fps <= 0 { return "25" }
        let multiple = fps < 24000 / 1001.0 ? broadcastRates.first {
            let factor = Double($0.num) / Double($0.den) / fps
            return abs(factor - factor.rounded()) < 1e-6
        } : nil
        let rate = multiple ?? broadcastRates.min { abs(fps - Double($0.num) / Double($0.den)) < abs(fps - Double($1.num) / Double($1.den)) }!
        return rate.den == 1 ? String(rate.num) : "\(rate.num)/\(rate.den)"
    }

    private static func containerArguments(_ target: String) -> [String] {
        switch target {
        // Moves the index to the front so playback (and web streaming) can start before the file is loaded.
        case "mp4", "m4v", "mov", "3gp", "3g2", "m4a", "m4b": ["-movflags", "+faststart"]
        // Blu-ray / AVCHD transport stream: 192-byte packets with timestamps.
        case "m2ts": ["-mpegts_m2ts_mode", "1"]
        // DVD program stream: 10.08 Mbit/s mux rate and 2 KB sectors.
        case "vob": ["-muxrate", "10080000", "-packetsize", "2048"]
        // ID3v2.3 is what Windows Explorer and most car stereos read (FFmpeg writes 2.4 by default).
        case "mp3": ["-id3v2_version", "3"]
        // WAV is limited to 4 GB; long recordings switch to RF64 automatically.
        case "wav": ["-rf64", "auto"]
        default: []
        }
    }

    private static func metadataArguments(_ from: Int = 0) -> [String] {
        // Keep title, artist, dates, … (chapters are kept by default); an empty value removes a tag.
        ["-map_metadata", String(from)] + sourceOnlyTags.flatMap { ["-metadata", $0 + "="] }
    }

    // ───────────────────────── Audio ─────────────────────────

    private static func audio(_ input: String, _ output: String, _ target: String, _ spec: MediaTarget, _ options: MediaOptions,
                              _ info: MediaInfo, _ extras: CoverExtras?) throws -> [String] {
        guard let audio = info.audio else { throw ConversionError("The file has no audio track.") }
        var args = common + ["-i", input]
        // Ogg: the tags, and the picture as a comment, come from a metadata file (input 1) instead of the source.
        if let metadata = extras?.metadataFile { args += ["-i", metadata] }
        args += ["-map", "0:a:0"]
        if let cover = info.coverStreamIndex, coverTargets.contains(target) {
            args += ["-map", "0:\(cover)", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        }
        if let picture = extras?.attachmentFile, let mime = extras?.attachmentMime {
            args += ["-attach", picture, "-metadata:s:t", "mimetype=" + mime, "-metadata:s:t", "filename=" + FilePath.fileName(picture)]
        }
        let codec = target == "wav" ? wavCodec(options.wavFormat) : spec.audioCodec
        args += audioCodecArguments(target, codec, options, audio, inVideo: false)
        args += channelAndRateArguments(target, codec, options)
        args += metadataArguments(extras?.metadataFile == nil ? 0 : 1)
        args += containerArguments(target)
        args += ["-f", spec.muxer, "-progress", "pipe:1", output]
        return args
    }

    /// The PCM codec of a WAV sample format (little-endian, 8-bit is unsigned as WAV defines it).
    static func wavCodec(_ format: WavSampleFormat) -> String {
        switch format {
        case .pcm8: "pcm_u8"
        case .pcm24: "pcm_s24le"
        case .pcm32: "pcm_s32le"
        case .float32: "pcm_f32le"
        case .pcm16: "pcm_s16le"
        }
    }

    /// Mono or stereo for any audio target (after the codec's own limits, so the user's choice wins), and the sample rate
    /// for WAV, whose PCM takes any rate. Codecs with a fixed layout (AMR is mono, 8 kHz) are left alone.
    static func channelAndRateArguments(_ target: String, _ codec: String, _ options: MediaOptions) -> [String] {
        var args: [String] = []
        if options.audioChannels == 1 || options.audioChannels == 2, codec != "libopencore_amrnb" {
            args += ["-ac", String(options.audioChannels)]
        }
        if target == "wav", (8000...192_000).contains(options.audioSampleRate) {
            args += ["-ar", String(options.audioSampleRate)]
        }
        return args
    }

    /// Encoder options for one audio codec. `MediaOptions.audioBitrateKbps` wins when set (clamped to what the codec
    /// accepts); otherwise the quality picks a bitrate or VBR level. Lossless and PCM codecs ignore both. Channel counts
    /// the codec cannot store are mixed down.
    private static func audioCodecArguments(_ target: String, _ codec: String, _ options: MediaOptions, _ audio: AudioStreamInfo,
                                            inVideo: Bool) -> [String] {
        let quality = options.quality
        let requested = options.audioBitrateKbps
        let channels = audio.channels > 0 ? audio.channels : 2
        var args = ["-c:a", codec]

        switch codec {
        case "aac":
            // Per stereo pair: 256 kbit/s is transparent, 192 excellent, 128 fine for speech and small files.
            args += bitrate(requested > 0 ? requested : scaled(choose(quality, 256, 192, 128), channels), 16, 256 * channels)
        case "libopus":
            // Opus is transparent at about 128 kbit/s for stereo; 64 is still good for music.
            args += bitrate(requested > 0 ? requested : scaled(choose(quality, 160, 128, 64), channels), 6, 256 * channels)
        case "libmp3lame" where requested > 0 || inVideo:
            // Constant bitrate (variable-bitrate MP3 confuses AVI players' audio sync) from the MP3 bitrate table.
            args += bitrate(snap(requested > 0 ? requested : choose(quality, 256, 192, 128), mp3Bitrates), 32, 320)
        case "libmp3lame":
            // LAME's VBR presets: V0 ≈ 245, V2 ≈ 190, V5 ≈ 130 kbit/s.
            args += ["-q:a", String(choose(quality, 0, 2, 5))]
        case "libvorbis" where requested > 0:
            args += bitrate(requested, 32, 500)
        case "libvorbis":
            // Vorbis quality 6 ≈ 192, 4 ≈ 128, 2 ≈ 96 kbit/s.
            args += ["-q:a", String(choose(quality, 6, 4, 2))]
        case "wmav2":
            // WMA 2 stores at most two channels.
            args += bitrate(requested > 0 ? requested : choose(quality, 192, 128, 96), 32, 320)
            if channels > 2 { args += ["-ac", "2"] }
        case "mp2":
            // Layer II allows only the bitrates of its table, and those only at 32 kHz or more.
            args += bitrate(snap(requested > 0 ? requested : choose(quality, 320, 224, 160), mp2Bitrates), 32, 384)
            if audio.sampleRate > 0 && audio.sampleRate < 32000 { args += ["-ar", "32000"] }
        case "ac3" where target == "vob":
            // DVD audio is 48 kHz; 448 kbit/s is the DVD maximum for 5.1, 192 the usual stereo rate.
            args += bitrate(snap(requested > 0 ? requested : channels > 2 ? 448 : 192, ac3Bitrates), 64, 448)
            args += ["-ar", "48000"]
        case "ac3":
            // Without a bitrate the encoder picks the standard rate for the channel layout (192k stereo, 448k 5.1).
            if requested > 0 { args += bitrate(snap(requested, ac3Bitrates), 32, 640) }
        case "libopencore_amrnb":
            // AMR-NB is defined for 8 kHz mono only; 12.2 kbit/s is its best mode.
            args += ["-ar", "8000", "-ac", "1", "-b:a", "12.2k"]
        case "pcm_s16le" where target == "dv":
            args += ["-ar", "48000", "-ac", "2"]
        case "pcm_s16le" where target == "mxf":
            // MXF (SMPTE 377) carries 48 kHz audio only.
            args += ["-ar", "48000"]
        case "pcm_s16le" where target == "voc" && channels > 2:
            args += ["-ac", "2"]
        default:
            break
        }
        return args
    }

    /// Bitrate for a stereo pair scaled to the channel count (mono gets half, 5.1 three times as much).
    private static func scaled(_ stereoKbps: Int, _ channels: Int) -> Int { stereoKbps * min(max(channels, 1), 8) / 2 }

    private static func bitrate(_ kbps: Int, _ low: Int, _ high: Int) -> [String] {
        ["-b:a", "\(min(max(kbps, low), max(low, high)))k"]
    }

    /// The largest allowed bitrate not above `kbps` (the smallest one if all are above).
    static func snap(_ kbps: Int, _ allowed: [Int]) -> Int { allowed.filter { $0 <= kbps }.max() ?? allowed[0] }

    private static let mp3Bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let mp2Bitrates = [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
    private static let ac3Bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]

    // ───────────────────────── Animated GIF ─────────────────────────

    /// Animated GIF in two passes: the first finds the 256 colours that suit the whole clip best (palettegen), the second
    /// maps every frame to them (paletteuse). A single pass with a fixed palette looks banded; generating the palette in
    /// the same run would keep every frame in memory until the end. Frame rate and width are limited by the quality
    /// setting because GIF stores every frame uncompressed-ish and grows fast.
    private static func animatedGif(_ input: String, _ output: String, _ options: MediaOptions, _ info: MediaInfo,
                                    _ workDirectory: String) throws -> [FfmpegPass] {
        guard let video = info.video else { throw ConversionError("The file has no video stream.") }
        let quality = options.quality
        let chain = gifFrames(video, options.maxHeight, fps: choose(quality, 15, 12, 10), maxWidth: choose(quality, 640, 480, 320))
        let palette = FilePath.combine(workDirectory, "palette-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).png")
        let colors = choose(quality, 256, 256, 128)
        // Error diffusion looks best; ordered (Bayer) dithering compresses much better because it does not flicker.
        let dither = choose(quality, "sierra2_4a", "bayer:bayer_scale=4", "bayer:bayer_scale=5")

        // Pass 1 reports no output time until the palette is written at the very end, so a second, discarded copy of
        // the frames goes to a null output whose per-frame stats (frame_time=<seconds>) serve as progress.
        let first = common + [
            "-i", input,
            "-filter_complex", "[0:V:0]\(chain),split[a][b];[a]palettegen=max_colors=\(colors)[palette]",
            "-map", "[palette]", "-frames:v", "1", "-update", "1", "-c:v", "png", "-f", "image2", palette,
            "-map", "[b]", "-c:v", "wrapped_avframe", "-stats_enc_pre", "pipe:1", "-stats_enc_pre_fmt", FfmpegRunner.frameTimeKey + "={t}", "-f", "null", "-",
        ]
        let second = common + [
            "-i", input, "-i", palette,
            "-filter_complex", "[0:V:0]\(chain)[frames];[frames][1:v]paletteuse=dither=\(dither):diff_mode=rectangle[gif]",
            "-map", "[gif]", "-loop", "0", "-c:v", "gif", "-f", "gif", "-progress", "pipe:1", output,
        ]
        return [FfmpegPass(arguments: first, weight: 0.4), FfmpegPass(arguments: second, weight: 0.6)]
    }

    /// Frame rate, square pixels and size of the GIF frames (never upscaled).
    private static func gifFrames(_ video: VideoStreamInfo, _ maxHeight: Int, fps: Int, maxWidth: Int) -> String {
        let height = maxHeight > 0 ? "'min(ih,\(max(16, maxHeight)))'" : "ih"
        return "fps=\(fps),\(squarePixels(video))scale=w='min(iw,\(maxWidth))':h=\(height):force_original_aspect_ratio=decrease:flags=lanczos"
    }

    /// Images have no pixel aspect ratio: anamorphic video (DV, DVD) is stretched to square pixels first.
    private static func squarePixels(_ video: VideoStreamInfo) -> String {
        abs(video.sampleAspect - 1) > 0.01 ? "scale=w='trunc(iw*sar/2)*2':h=ih,setsar=1," : ""
    }

    // ───────────────────────── Still frame ─────────────────────────

    /// One full-size PNG frame from a tenth into the video (the first frames are often black), the start for video →
    /// image conversions (the image engines take it from there). Without this edge the route planner would reach images
    /// through an animated GIF of the whole video.
    static func posterFrame(_ input: String, _ output: String, _ info: MediaInfo, decodeFromStart: Bool = false) throws -> [String] {
        guard let video = info.video else { throw ConversionError("The file has no video stream.") }
        let seconds = (info.duration ?? 0) / 10
        let seek = ["-ss", formatSeconds(seconds)]
        let source = decodeFromStart ? ["-i", input] + seek : seek + ["-i", input]
        return common + source + [
            "-map", "0:V:0",
            "-vf", squarePixels(video) + "null", "-frames:v", "1", "-update", "1", "-c:v", "png", "-f", "image2",
            "-progress", "pipe:1", output,
        ]
    }

    /// .NET's "0.###" (invariant): the double taken to 15 significant digits, then at most three decimals rounded half
    /// away from zero, no trailing zeros (0.0105 → "0.011", where rounding the binary value would give "0.01").
    static func formatSeconds(_ seconds: Double) -> String {
        var value = Decimal(string: String(format: "%.15g", seconds)) ?? 0
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 3, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    // ───────────────────────── Helpers ─────────────────────────

    private static func choose<T>(_ quality: MediaQuality, _ high: T, _ balanced: T, _ small: T) -> T {
        switch quality {
        case .high: high
        case .small: small
        case .balanced: balanced
        }
    }

    /// `Math.Max(2, (int)Math.Round(value / 2) * 2)`: banker's rounding like .NET.
    private static func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded(.toNearestOrEven)) * 2) }
}
