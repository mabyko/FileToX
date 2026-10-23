// Port of Filee.Engines/Media/CoverArt.cs: album art for audio formats FFmpeg cannot write a picture stream into. Ogg
// (Vorbis, Opus) keeps the picture as a METADATA_BLOCK_PICTURE comment: a FLAC picture block in base64, which FFmpeg
// writes like any other tag when it comes from an ffmetadata file. Matroska audio keeps it as a cover.jpg / cover.png
// attachment. The picture's size comes from ImageIO (Filee: MagickImageInfo).

import Foundation

/// Extra inputs that carry the source's cover into the output (see `CoverArt.prepare`): an ffmpeg metadata file with
/// the source's tags and the picture comment (Ogg), or the picture to attach with its MIME type (Matroska).
struct CoverExtras: Equatable {
    let metadataFile: String?
    let attachmentFile: String?
    let attachmentMime: String?
}

enum CoverArt {
    /// Targets whose cover is a METADATA_BLOCK_PICTURE comment.
    static func asComment(_ target: String) -> Bool { target == "ogg" || target == "opus" }

    /// Targets whose cover is an attached file.
    static func asAttachment(_ target: String) -> Bool { target == "mka" }

    /// Extracts the cover (stream `stream`) of `input` and prepares what `target` needs to carry it. Nil when the target
    /// doesn't need it or anything fails: the file is then converted without its cover rather than not at all.
    static func prepare(_ ffmpeg: String, _ input: String, _ stream: Int, _ target: String, _ workDirectory: String) async throws -> CoverExtras? {
        guard asComment(target) || asAttachment(target) else { return nil }
        do {
            let folder = FilePath.combine(workDirectory, "cover-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
            try FileManager.default.createDirectoryIfNeeded(folder)
            let raw = FilePath.combine(folder, "cover.bin")
            guard try await run(ffmpeg, ["-i", input, "-map", "0:\(stream)", "-c", "copy", "-frames:v", "1", "-f", "image2", raw]) else {
                return nil
            }
            let image = try Data(contentsOf: URL(fileURLWithPath: raw))
            guard let mime = mimeOf(image) else { return nil }
            let picture = FilePath.combine(folder, mime == "image/png" ? "cover.png" : "cover.jpg")
            try FileManager.default.moveItem(atPath: raw, toPath: picture)

            if asAttachment(target) { return CoverExtras(metadataFile: nil, attachmentFile: picture, attachmentMime: mime) }

            // The source's own tags (title, artist, …) go into the same file: the output takes its tags from it.
            let metadata = FilePath.combine(folder, "metadata.txt")
            guard try await run(ffmpeg, ["-i", input, "-f", "ffmetadata", metadata]) else { return nil }
            guard let info = ImageSupport.info(picture) else { return nil }
            let line = "METADATA_BLOCK_PICTURE=" + escape(pictureBlock(image, mime, info.width, info.height))
            var lines = readAllLines(try Data(contentsOf: URL(fileURLWithPath: metadata)))
            lines.insert(line, at: min(1, lines.count)) // global tags come right after ";FFMETADATA1"
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: metadata))
            return CoverExtras(metadataFile: metadata, attachmentFile: nil, attachmentMime: nil)
        } catch let error as CancellationError {
            throw error
        } catch let error as FfmpegRunner.StallError {
            throw error
        } catch {
            return nil
        }
    }

    /// A FLAC METADATA_BLOCK_PICTURE (front cover) in base64, as Ogg comments carry it: big-endian picture type, MIME
    /// type, description, width, height, colour depth, palette size and the image itself.
    static func pictureBlock(_ image: Data, _ mime: String, _ width: Int, _ height: Int) -> String {
        let mimeBytes = Data(mime.utf8)
        var block = Data()
        func int(_ value: Int) { withUnsafeBytes(of: Int32(truncatingIfNeeded: value).bigEndian) { block.append(contentsOf: $0) } }
        int(3) // front cover
        int(mimeBytes.count)
        block.append(mimeBytes)
        int(0) // no description
        int(width)
        int(height)
        int(24) // colour depth
        int(0) // not indexed
        int(image.count)
        block.append(image)
        return block.base64EncodedString()
    }

    /// ffmetadata escaping: '=', ';', '#', '\' and line breaks get a backslash.
    static func escape(_ value: String) -> String {
        var text = ""
        for scalar in value.unicodeScalars {
            if "=;#\\\n".unicodeScalars.contains(scalar) { text.append("\\") }
            text.unicodeScalars.append(scalar)
        }
        return text
    }

    /// JPEG or PNG by their first bytes; nil for anything else.
    static func mimeOf(_ image: Data) -> String? {
        let bytes = [UInt8](image.prefix(4))
        if image.count > 4 && bytes[0] == 0xFF && bytes[1] == 0xD8 { return "image/jpeg" }
        if image.count > 8 && bytes == [0x89, UInt8(ascii: "P"), UInt8(ascii: "N"), UInt8(ascii: "G")] { return "image/png" }
        return nil
    }

    /// File.ReadAllLines: UTF-8 with invalid bytes as U+FFFD (tags in a legacy code page keep the cover), a BOM dropped;
    /// "\r\n", "\n" and "\r" end lines and a final line break adds no empty line.
    static func readAllLines(_ data: Data) -> [String] {
        var text = TextEncodings.decode(data, encoding: .utf8)
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func run(_ ffmpeg: String, _ arguments: [String]) async throws -> Bool {
        try await FfmpegRunner.run(ffmpeg, MediaEncoding.common + arguments, onPosition: nil).exitCode == 0
    }
}
