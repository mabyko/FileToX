// AVIF writing with libavif 1.4.2 + libaom 3.14.1 (Vendor/LibAVIF) for 8-bit colour pictures. ImageIO still writes every
// AVIF first. libavif's 4:4:4 encode at ImageIO's AV1 quantizers then replaces that file only when both hold:
// - with both files decoded by ImageIO and compared with the encoder's input as premultiplied 8-bit samples in their own
//   colour space, its summed squared error is no larger for colour and for alpha, and smaller for one of them;
// - read back by ImageIO, it keeps every top-level tag of the frame's metadata that ImageIO's file kept, with equal
//   string values (arrays and structures by presence only), except the pixel dimensions, which it records from the
//   picture while ImageIO copies the source's.
// That bounds these measures, not visual, SSIM or full metadata equivalence. Colour pictures usually gain (ImageIO's
// 4:2:0 drops chroma detail); ImageIO's file usually stays for gray-like ones. The helper does not run for gray pictures,
// colour pictures whose samples are all gray, 16-bit and float pictures, several frames, frames not prepared for an AVIF
// target and pictures beyond libavif's default decoder limits.
//
// libaom's encode is one call that cannot be interrupted, so it runs in a helper process (FileToXAvifEncoder) that
// cancellation kills through ProcessRunner. Samples and metadata reach the helper in a private hand-off file; its result
// replaces the output only after it exited successfully and was checked.

import CoreGraphics
import Darwin
import Foundation
import ImageIO

enum AvifEncoder {
    /// libavif's default decoder limits (AVIF_DEFAULT_IMAGE_DIMENSION_LIMIT, AVIF_DEFAULT_IMAGE_SIZE_LIMIT): readers with
    /// default settings refuse larger single pictures, which ImageIO writes as tiles.
    static let maxDimension = 32768, maxPixels = 16384 * 16384
    /// Largest ICC, Exif or XMP block the helper accepts.
    static let maxMetadata = 64 << 20

    /// The helper next to the running executable (the engine helper app, `swift build`'s products) or next to the bundle
    /// with this code (test bundles in the build products); nil when this build has none, and ImageIO writes every AVIF.
    static let helper: String? = [EngineEnvironment.baseDirectory, Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().path]
        .map { FilePath.combine($0, "FileToXAvifEncoder") }.first { FileManager.default.isExecutableFile(atPath: $0) }

    private final class Marker {}

    /// Replaces ImageIO's AVIF of the frames at `path` with the helper's when the helper's has no larger squared error for
    /// colour and alpha and a smaller one for either, and keeps the metadata tags ImageIO's kept (see above); returns
    /// whether it did.
    @discardableResult
    static func improve(_ frames: [ImageFrame], at path: String, helper: String? = helper) throws -> Bool {
        guard let helper, frames.count == 1, let frame = frames.first, let quality = frame.properties[ImageFrame.qualityKey] as? Int,
              (1...100).contains(quality) else { return false }
        let image = frame.image
        guard image.colorSpace?.model == .rgb, image.bitsPerComponent == 8,
              image.width <= maxDimension, image.height <= maxDimension, image.width * image.height <= maxPixels else { return false }
        let (samples, channels) = CodecPixels.straight(image)
        guard !isGray(samples, channels) else { return false }
        // ImageIO keeps the resolution as Exif, even without other metadata; so does this writer.
        var described = frame
        if let dpi = frame.dpi, dpi.x > 0, dpi.y > 0 {
            let metadata = frame.properties[ImageFrame.metadataKey].flatMap { CFGetTypeID($0 as CFTypeRef) == CGImageMetadataGetTypeID() ? ($0 as! CGImageMetadata) : nil }
            described.properties[ImageFrame.metadataKey] = ImageEncoder.encoderMetadata(metadata ?? CGImageMetadataCreateMutable(), dpi)
        }
        let blobs = CodecPixels.metadataBlobs(described, colorModel: .rgb)
        let icc = blobs.icc ?? Data(), exif = blobs.exif ?? Data(), xmp = blobs.xmp ?? Data()
        guard [icc, exif, xmp].allSatisfy({ $0.count <= maxMetadata }) else { return false }
        try Task.checkCancellation()

        let scratch = try privateFolder()
        defer { FileManager.default.removeIfPresent(scratch) }
        let input = FilePath.combine(scratch, "picture"), output = FilePath.combine(scratch, "picture.avif")
        var header = Data("FTXAVIF\0".utf8)
        for value in [1, image.width, image.height, channels, quality, 0] { withUnsafeBytes(of: UInt32(value).littleEndian) { header += $0 } }
        for value in [icc.count, exif.count, xmp.count, 0] { withUnsafeBytes(of: UInt64(value).littleEndian) { header += $0 } }
        try write([header, samples, icc, exif, xmp], to: input)

        let result = try ProcessRunner.runBlocking(helper, [input, output], timeout: 600, isCancelled: { Task.isCancelled })
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw ConversionError("The AVIF encoder failed (\(result.exitCode)): " + result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let encoded = try Data(contentsOf: URL(fileURLWithPath: output))
        // An ISOBMFF file whose ftyp box names AVIF as its major brand.
        guard encoded.count > 12, encoded[4..<12] == Data("ftypavif".utf8) else {
            throw ConversionError("The AVIF encoder wrote no AVIF file.")
        }
        let source = ImagePixels.bitmap(image), imageIO = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let mine = errors(encoded, source) else { return false }
        if let theirs = errors(imageIO, source),
           !(mine.colour <= theirs.colour && mine.alpha <= theirs.alpha && (mine.colour < theirs.colour || mine.alpha < theirs.alpha)) {
            return false
        }
        // The shared serializer drops tags ImageIO's own AVIF writer keeps (a JPEG APP1 segment holds at most 64 KB of Exif).
        if let metadata = described.properties[ImageFrame.metadataKey], CFGetTypeID(metadata as CFTypeRef) == CGImageMetadataGetTypeID(),
           !keepsTags(of: metadata as! CGImageMetadata, encoded, comparedTo: imageIO) {
            return false
        }
        try Task.checkCancellation()
        try FileManager.default.writeFile(path, encoded)
        return true
    }

    /// True when every pixel is gray (R = G = B).
    static func isGray(_ samples: [UInt8], _ channels: Int) -> Bool {
        samples.withUnsafeBufferPointer { s in stride(from: 0, to: s.count, by: channels).allSatisfy { s[$0] == s[$0 + 1] && s[$0] == s[$0 + 2] } }
    }

    /// Summed squared errors of the file as ImageIO decodes it against the samples it was encoded from (premultiplied, in
    /// their own colour space), for colour and for alpha; nil when it does not decode to that size.
    static func errors(_ file: Data, _ source: ImagePixels.Bitmap) -> (colour: Int, alpha: Int)? {
        guard let decoder = CGImageSourceCreateWithData(file as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, CGImageSourceGetPrimaryImageIndex(decoder), nil),
              image.width == source.width, image.height == source.height else { return nil }
        let decoded = ImagePixels.bitmap(image).pixels
        var colour = 0, alpha = 0
        decoded.withUnsafeBufferPointer { d in
            source.pixels.withUnsafeBufferPointer { s in
                for i in 0..<d.count {
                    let e = Int(d[i]) - Int(s[i])
                    if i & 3 == 3 { alpha += e * e } else { colour += e * e }
                }
            }
        }
        return (colour, alpha)
    }

    /// True when `file` holds every top-level tag of `metadata` that `reference` holds, both as ImageIO reads them, with the
    /// same value where it is a string. Arrays and structures are compared by presence only, not item by item. Neither
    /// writer gets the source's file structure (`encoderMetadata`), and the pixel dimensions are left out: `CodecPixels`
    /// records the picture's own size, while ImageIO's AVIF writer copies the source's.
    static func keepsTags(of metadata: CGImageMetadata, _ file: Data, comparedTo reference: Data) -> Bool {
        func read(_ data: Data) -> [String: String] {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) else { return [:] }
            return tags(metadata)
        }
        var wanted = tags(ImageEncoder.encoderMetadata(metadata, nil))
        for name in ["PixelXDimension", "PixelYDimension"] { wanted[(kCGImageMetadataNamespaceExif as String) + " " + name] = nil }
        let kept = read(file)
        return read(reference).allSatisfy { key, value in wanted[key] == nil || kept[key] == value }
    }

    /// Namespace and name of each top-level tag, with its value when that is a string ("" otherwise).
    private static func tags(_ metadata: CGImageMetadata) -> [String: String] {
        var result: [String: String] = [:]
        for tag in (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]) ?? [] {
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            result[namespace + " " + name] = CGImageMetadataTagCopyValue(tag) as? String ?? ""
        }
        return result
    }

    /// A new folder only this user can open, in the host's temporary folder.
    private static func privateFolder() throws -> String {
        let temp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        var template = Array(FilePath.combine(temp, "FileToX-avif-XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { throw FilePath.writeError(errno, temp) }
        return String(cString: created)
    }

    /// Writes the parts one after another into a new file.
    private static func write(_ parts: [any ContiguousBytes], to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FilePath.writeError(errno, path) }
        defer { close(descriptor) }
        for part in parts {
            try part.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw FilePath.writeError(errno, path)
                    }
                    offset += written
                }
            }
        }
    }
}
