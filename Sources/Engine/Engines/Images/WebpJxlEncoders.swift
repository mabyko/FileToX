// WebP and JPEG XL encoding with Google's libwebp and libjxl (ImageIO only decodes both), set up the way ImageMagick's
// webp and jxl coders set them up for Filee: WebP quality, near-lossless = quality and lossless at 100 or on request,
// animations through WebPAnimEncoder with the frames' timing and loop count, ICC/EXIF/XMP as RIFF chunks; JPEG XL
// distance from quality (libjxl's JxlEncoderDistanceFromQuality, the formula ImageMagick uses) and lossless at 100,
// ICC/EXIF/XMP as boxes. Encoder effort is the libraries' default, as in ImageMagick.

import CoreGraphics
import Foundation
import ImageIO
import libjxl
import libwebp

enum WebpEncoder {
    static func write(_ frames: [ImageFrame], to path: String, animation: Bool) throws {
        guard let first = frames.first else { return }
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw ConversionError("Could not set up the WebP encoder.") }
        if let quality = first.properties[ImageFrame.qualityKey] as? Int {
            config.quality = Float(quality)
            config.near_lossless = Int32(quality)
            if quality >= 100 { config.lossless = 1 }
        }
        if first.properties[ImageFrame.losslessKey] as? Bool == true { config.lossless = 1 }
        guard WebPValidateConfig(&config) != 0 else { throw ConversionError("The WebP encoder settings are invalid.") }

        var encoded: [UInt8]
        if animation && frames.count > 1 {
            encoded = try encodeAnimation(frames, config: &config)
        } else {
            encoded = try encodePicture(first.image, config: &config)
        }
        encoded = try addMetadata(encoded, first)
        try FileManager.default.writeFile(path, Data(encoded))
    }

    private static func encodePicture(_ image: CGImage, config: inout WebPConfig) throws -> [UInt8] {
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw ConversionError("Could not set up the WebP encoder.") }
        defer { WebPPictureFree(&picture) }
        try importPixels(image, into: &picture)
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let ok = withUnsafeMutablePointer(to: &writer) { pointer -> Int32 in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(pointer)
            return WebPEncode(&config, &picture)
        }
        guard ok != 0, let memory = writer.mem else { throw ConversionError("WebP encoding failed (error \(picture.error_code.rawValue)).") }
        return Array(UnsafeBufferPointer(start: memory, count: writer.size))
    }

    private static func encodeAnimation(_ frames: [ImageFrame], config: inout WebPConfig) throws -> [UInt8] {
        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else { throw ConversionError("Could not set up the WebP encoder.") }
        options.anim_params.loop_count = Int32((frames[0].properties[ImageFrame.loopCountKey] as? Int) ?? 0)
        guard let encoder = WebPAnimEncoderNew(Int32(frames[0].image.width), Int32(frames[0].image.height), &options) else {
            throw ConversionError("Could not set up the WebP animation encoder.")
        }
        defer { WebPAnimEncoderDelete(encoder) }
        var timestamp: Int32 = 0
        for frame in frames {
            try Task.checkCancellation()
            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else { throw ConversionError("Could not set up the WebP encoder.") }
            defer { WebPPictureFree(&picture) }
            try importPixels(frame.image, into: &picture)
            guard WebPAnimEncoderAdd(encoder, &picture, timestamp, &config) != 0 else {
                throw ConversionError("WebP encoding failed: " + String(cString: WebPAnimEncoderGetError(encoder)))
            }
            timestamp += Int32(((frame.delay ?? 0) * 1000).rounded())
        }
        guard WebPAnimEncoderAdd(encoder, nil, timestamp, nil) != 0 else { throw ConversionError("WebP encoding failed.") }
        var data = WebPData()
        WebPDataInit(&data)
        defer { WebPDataClear(&data) }
        guard WebPAnimEncoderAssemble(encoder, &data) != 0, let bytes = data.bytes else {
            throw ConversionError("WebP encoding failed: " + String(cString: WebPAnimEncoderGetError(encoder)))
        }
        return Array(UnsafeBufferPointer(start: bytes, count: data.size))
    }

    /// Straight RGBA (or RGB) samples, in the image's own colour space.
    private static func importPixels(_ image: CGImage, into picture: inout WebPPicture) throws {
        let (samples, channels) = CodecPixels.straight(image)
        picture.use_argb = 1
        picture.width = Int32(image.width)
        picture.height = Int32(image.height)
        let ok = samples.withUnsafeBufferPointer { buffer in
            channels == 4 ? WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(image.width * 4))
                : WebPPictureImportRGB(&picture, buffer.baseAddress, Int32(image.width * 3))
        }
        guard ok != 0 else { throw ConversionError("The picture is too large for WebP.") }
    }

    /// ICC profile, EXIF and XMP as WebP chunks (ImageMagick's WebPWriteImageProfile).
    private static func addMetadata(_ encoded: [UInt8], _ frame: ImageFrame) throws -> [UInt8] {
        let blobs = CodecPixels.metadataBlobs(frame, colorModel: .rgb)
        guard blobs.icc != nil || blobs.exif != nil || blobs.xmp != nil else { return encoded }
        return try encoded.withUnsafeBufferPointer { buffer -> [UInt8] in
            var bitstream = WebPData(bytes: buffer.baseAddress, size: buffer.count)
            guard let mux = WebPMuxCreate(&bitstream, 1) else { return encoded }
            defer { WebPMuxDelete(mux) }
            for (fourcc, blob) in [("ICCP", blobs.icc), ("EXIF", blobs.exif), ("XMP ", blobs.xmp)] {
                guard let blob else { continue }
                blob.withUnsafeBytes { raw in
                    var chunk = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
                    _ = WebPMuxSetChunk(mux, fourcc, &chunk, 1)
                }
            }
            var assembled = WebPData()
            WebPDataInit(&assembled)
            defer { WebPDataClear(&assembled) }
            guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK, let bytes = assembled.bytes else {
                throw ConversionError("Could not add the metadata to the WebP file.")
            }
            return Array(UnsafeBufferPointer(start: bytes, count: assembled.size))
        }
    }
}

enum JpegXlEncoder {
    static func write(_ frame: ImageFrame, to path: String) throws {
        let image = frame.image
        let quality = frame.properties[ImageFrame.qualityKey] as? Int ?? 90
        let lossless = quality >= 100
        let gray = image.colorSpace?.model == .monochrome
        let alpha = ImagePixels.hasAlpha(image)
        var (samples, channels) = CodecPixels.straight(image)
        if gray {
            // Keep one (or one + alpha) channel.
            let step = channels
            samples = stride(from: 0, to: samples.count, by: step).flatMap { alpha ? [samples[$0], samples[$0 + 3]] : [samples[$0]] }
            channels = alpha ? 2 : 1
        }

        guard let encoder = JxlEncoderCreate(nil) else { throw ConversionError("Could not set up the JPEG XL encoder.") }
        defer { JxlEncoderDestroy(encoder) }
        let runner = JxlThreadParallelRunnerCreate(nil, JxlThreadParallelRunnerDefaultNumWorkerThreads())
        defer { if let runner { JxlThreadParallelRunnerDestroy(runner) } }
        if let runner { _ = JxlEncoderSetParallelRunner(encoder, JxlThreadParallelRunner, runner) }

        var info = JxlBasicInfo()
        JxlEncoderInitBasicInfo(&info)
        info.xsize = UInt32(image.width)
        info.ysize = UInt32(image.height)
        info.bits_per_sample = 8
        info.num_color_channels = gray ? 1 : 3
        info.alpha_bits = alpha ? 8 : 0
        info.num_extra_channels = alpha ? 1 : 0
        info.uses_original_profile = lossless ? JXL_TRUE : JXL_FALSE
        try check(JxlEncoderSetBasicInfo(encoder, &info), encoder)
        if alpha {
            var extra = JxlExtraChannelInfo()
            JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &extra)
            extra.bits_per_sample = 8
            try check(JxlEncoderSetExtraChannelInfo(encoder, 0, &extra), encoder)
        }
        let blobs = CodecPixels.metadataBlobs(frame)
        if let icc = blobs.icc {
            try icc.withUnsafeBytes { try check(JxlEncoderSetICCProfile(encoder, $0.bindMemory(to: UInt8.self).baseAddress, $0.count), encoder) }
        } else {
            var color = JxlColorEncoding()
            JxlColorEncodingSetToSRGB(&color, gray ? JXL_TRUE : JXL_FALSE)
            try check(JxlEncoderSetColorEncoding(encoder, &color), encoder)
        }
        if blobs.exif != nil || blobs.xmp != nil {
            try check(JxlEncoderUseBoxes(encoder), encoder)
            if let exif = blobs.exif {
                // The Exif box starts with the offset of the TIFF header.
                let box = Data([0, 0, 0, 0]) + exif
                try box.withUnsafeBytes { try check(JxlEncoderAddBox(encoder, "Exif", $0.bindMemory(to: UInt8.self).baseAddress, $0.count, JXL_FALSE), encoder) }
            }
            if let xmp = blobs.xmp {
                try xmp.withUnsafeBytes { try check(JxlEncoderAddBox(encoder, "xml ", $0.bindMemory(to: UInt8.self).baseAddress, $0.count, JXL_FALSE), encoder) }
            }
            JxlEncoderCloseBoxes(encoder)
        }

        guard let settings = JxlEncoderFrameSettingsCreate(encoder, nil) else { throw ConversionError("Could not set up the JPEG XL encoder.") }
        if lossless {
            try check(JxlEncoderSetFrameDistance(settings, 0), encoder)
            try check(JxlEncoderSetFrameLossless(settings, JXL_TRUE), encoder)
        } else {
            try check(JxlEncoderSetFrameDistance(settings, JxlEncoderDistanceFromQuality(Float(quality))), encoder)
        }
        var format = JxlPixelFormat(num_channels: UInt32(channels), data_type: JXL_TYPE_UINT8, endianness: JXL_NATIVE_ENDIAN, align: 0)
        try samples.withUnsafeBytes { try check(JxlEncoderAddImageFrame(settings, &format, $0.baseAddress, $0.count), encoder) }
        JxlEncoderCloseInput(encoder)

        var output = [UInt8](repeating: 0, count: 1 << 16)
        var written = 0
        while true {
            try Task.checkCancellation()
            var status = JXL_ENC_ERROR
            var available = output.count - written
            output.withUnsafeMutableBufferPointer { buffer in
                var next: UnsafeMutablePointer<UInt8>? = buffer.baseAddress! + written
                status = JxlEncoderProcessOutput(encoder, &next, &available)
                written = next! - buffer.baseAddress!
            }
            if status == JXL_ENC_NEED_MORE_OUTPUT {
                output += [UInt8](repeating: 0, count: output.count)
                continue
            }
            try check(status, encoder)
            break
        }
        try FileManager.default.writeFile(path, Data(output[0..<written]))
    }

    private static func check(_ status: JxlEncoderStatus, _ encoder: OpaquePointer) throws {
        guard status == JXL_ENC_SUCCESS else {
            throw ConversionError("JPEG XL encoding failed (error \(JxlEncoderGetError(encoder).rawValue)).")
        }
    }
}

/// Pixels and metadata in the form the WebP and JPEG XL encoders take.
enum CodecPixels {
    /// Straight (not premultiplied) 8-bit samples: RGBA when the image has alpha, else RGB.
    static func straight(_ image: CGImage) -> (samples: [UInt8], channels: Int) {
        let bitmap = ImagePixels.bitmap(image)
        let count = bitmap.width * bitmap.height
        if !bitmap.hasAlpha {
            var rgb = [UInt8](repeating: 0, count: count * 3)
            for i in 0..<count { for c in 0..<3 { rgb[i * 3 + c] = bitmap.pixels[i * 4 + c] } }
            return (rgb, 3)
        }
        var rgba = bitmap.pixels
        for i in 0..<count {
            let a = Int(rgba[i * 4 + 3])
            guard a > 0 && a < 255 else { continue }
            for c in 0..<3 { rgba[i * 4 + c] = UInt8(min(255, (Int(rgba[i * 4 + c]) * 255 + a / 2) / a)) }
        }
        return (rgba, 4)
    }

    /// Exact source ICC bytes when known, restricted to the current pixels and the encoder's color model.
    static func colorProfile(_ frame: ImageFrame, colorModel: CGColorSpaceModel? = nil) -> Data? {
        let profile: Data?
        if let source = frame.properties[ImageFrame.jpegICCKey] as? Data {
            profile = source
        } else {
            profile = ImagePixels.hasColorProfile(frame.image) ? frame.image.colorSpace?.copyICCData() as Data? : nil
        }
        guard let profile, let space = CGColorSpace(iccData: profile as CFData),
              space.model == frame.image.colorSpace?.model, space.model == (colorModel ?? space.model) else { return nil }
        return profile
    }

    /// The frame's ICC profile, EXIF (TIFF-structured, as ImageIO writes it) and XMP (the
    /// metadata outside the EXIF/TIFF namespaces).
    static func metadataBlobs(_ frame: ImageFrame, colorModel: CGColorSpaceModel? = nil) -> (icc: Data?, exif: Data?, xmp: Data?) {
        let icc = colorProfile(frame, colorModel: colorModel)
        guard let value = frame.properties[ImageFrame.metadataKey], CFGetTypeID(value as CFTypeRef) == CGImageMetadataGetTypeID() else {
            return (icc, nil, nil)
        }
        let metadata = value as! CGImageMetadata
        return (icc, exif(metadata), xmp(metadata))
    }

    private static let exifNamespaces: Set<String> = [kCGImageMetadataNamespaceExif as String, kCGImageMetadataNamespaceExifAux as String,
                                                      kCGImageMetadataNamespaceExifEX as String, kCGImageMetadataNamespaceTIFF as String]

    /// EXIF of the metadata as ImageIO serializes it: the APP1 payload of a one-pixel JPEG, without "Exif\0\0".
    private static func exif(_ metadata: CGImageMetadata) -> Data? {
        // Metadata without EXIF/TIFF tags (a PNG's, for one) has no EXIF profile in ImageMagick; ImageIO would still write one.
        let tags = (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]) ?? []
        guard tags.contains(where: { (CGImageMetadataTagCopyNamespace($0) as String?).map(exifNamespaces.contains) == true }) else { return nil }
        let pixel = ImagePixels.make([0, 0, 0], 1, 1, components: 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageAndMetadata(destination, pixel, metadata, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = [UInt8](data as Data)
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1], length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xDA { break }
            if marker == 0xE1, length > 8, i + 2 + length <= bytes.count, Array(bytes[i + 4..<i + 10]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                return Data(bytes[i + 10..<i + 2 + length])
            }
            i += 2 + length
        }
        return nil
    }

    private static func xmp(_ metadata: CGImageMetadata) -> Data? {
        let rest = CGImageMetadataCreateMutable()
        var any = false
        for tag in (CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]) ?? [] {
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?, !exifNamespaces.contains(namespace),
                  let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            CGImageMetadataRegisterNamespaceForPrefix(rest, namespace as CFString, prefix as CFString, nil)
            if CGImageMetadataSetTagWithPath(rest, nil, "\(prefix):\(name)" as CFString, tag) { any = true }
        }
        return any ? CGImageMetadataCreateXMPData(rest, nil) as Data? : nil
    }
}
