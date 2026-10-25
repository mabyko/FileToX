// JPEG encoding with libjpeg-turbo 3.2.0, the library and version under the C# helper's ImageMagick, set up the way
// ImageMagick's jpeg coder set it up for Filee (Vendor/libjpeg-turbo/FileToX/encode.c): the same files byte for byte.
// ImageMagick decides here what goes in: a gray picture (every pixel R = G = B) becomes a one-component JPEG, a JPEG
// source keeps its sampling factors, the resolution goes into JFIF, then EXIF, ICC and XMP.

import CJpegTurbo
import CoreGraphics
import Foundation
import ImageIO

enum JpegEncoder {
    /// "3.2.0".
    static let version = String(cString: ftx_jpeg_version())
    /// Largest ICC profile a JPEG holds: 255 APP2 markers of 65519 profile bytes.
    static let maxProfileLength = 65519 * 255

    static func write(_ frame: ImageFrame, to path: String) throws {
        try FileManager.default.writeFile(path, try encode(frame))
    }

    static func encode(_ frame: ImageFrame) throws -> Data {
        let native = frame.image.colorSpace?.model == .cmyk ? ImagePixels.straight(frame.image) : nil
        let cmyk = native?.space.model == .cmyk
        let (straight, channels) = native.map { ($0.samples, $0.channels) } ?? CodecPixels.straight(frame.image)
        let count = frame.image.width * frame.image.height
        // IdentifyImageCoderGray: exactly gray pictures are written with one component (the alpha channel, already
        // removed for JPEG targets, is never written).
        var gray = !cmyk
        for i in 0..<count where straight[i * channels] != straight[i * channels + 1] || straight[i * channels + 1] != straight[i * channels + 2] {
            gray = false
            break
        }
        let components = cmyk ? 4 : gray ? 1 : 3
        var samples = [UInt8](repeating: 0, count: count * components)
        for i in 0..<count {
            for c in 0..<components { samples[i * components + c] = cmyk ? 255 - straight[i * channels + c] : straight[i * channels + c] }
        }

        var image = FTXJpegImage()
        image.width = Int32(frame.image.width)
        image.height = Int32(frame.image.height)
        image.components = Int32(components)
        image.quality = Int32((frame.properties[ImageFrame.qualityKey] as? Int) ?? 0)
        if let resolution = frame.properties[ImageFrame.resolutionKey] as? [Double], resolution.count == 3 {
            (image.x_density, image.y_density, image.density_unit) = (resolution[0], resolution[1], Int32(resolution[2]))
        } else if let dpi = frame.dpi {
            (image.x_density, image.y_density, image.density_unit) = (dpi.x, dpi.y, 1)
        }
        // ImageMagick keeps the source's sampling when the source decodes to the colour type it writes.
        if let sampling = frame.properties[ImageFrame.jpegSamplingKey] as? [Int], sampling.count == 2 * components {
            image.sampling_count = Int32(components)
            let h = (0..<4).map { $0 < components ? Int32(sampling[2 * $0]) : 1 }, v = (0..<4).map { $0 < components ? Int32(sampling[2 * $0 + 1]) : 1 }
            image.h_sampling = (h[0], h[1], h[2], h[3])
            image.v_sampling = (v[0], v[1], v[2], v[3])
        }
        var tagged = frame
        if let native, !cmyk {
            tagged.image = ImagePixels.make(native.samples, frame.image.width, frame.image.height, components: native.channels,
                                            space: native.space, alpha: false)
        }
        if let orientation = (frame.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            // ImageMagick keeps the orientation in the EXIF profile it writes.
            let existing = frame.properties[ImageFrame.metadataKey].flatMap { CFGetTypeID($0 as CFTypeRef) == CGImageMetadataGetTypeID() ? ($0 as! CGImageMetadata) : nil }
            let metadata = existing.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            tagged.properties[ImageFrame.metadataKey] = metadata
        }
        let blobs = CodecPixels.metadataBlobs(tagged, colorModel: cmyk ? .cmyk : gray ? .monochrome : .rgb)
        // 255 APP2 markers of 65519 bytes (the native encoder's limit too); never drop a valid profile to make it fit.
        if let icc = blobs.icc, icc.count > maxProfileLength {
            throw ConversionError("The colour profile (\(icc.count) bytes) is too large for JPEG, which holds at most \(maxProfileLength) bytes.")
        }
        // ImageMagick's EXIF profile keeps the APP1 identifier.
        let exif = blobs.exif.map { Data("Exif\0\0".utf8) + $0 }

        var data: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        var message = [CChar](repeating: 0, count: 256)
        let status = samples.withUnsafeBufferPointer { pixels in
            withBlob(exif) { exifBytes, exifLength in
                withBlob(blobs.icc) { iccBytes, iccLength in
                    withBlob(blobs.xmp) { xmpBytes, xmpLength in
                        image.pixels = pixels.baseAddress
                        (image.exif, image.exif_length) = (exifBytes, exifLength)
                        (image.icc, image.icc_length) = (iccBytes, iccLength)
                        (image.xmp, image.xmp_length) = (xmpBytes, xmpLength)
                        return ftx_jpeg_encode(&image, &data, &length, &message)
                    }
                }
            }
        }
        defer { free(data) }
        guard status == 0, let data else {
            throw ConversionError("JPEG encoding failed: " + String(cString: message))
        }
        let encoded = Data(bytes: data, count: Int(length))
        guard let markers = frame.properties[ImageFrame.jpegMarkersKey] as? Data else { return encoded }
        // COM and Photoshop APP13 are opaque; keep their complete payloads instead of converting IPTC to XMP.
        // JFIF requires APP0 immediately after SOI; Adobe's APP14 also stays in the encoder header.
        var offset = 2
        while offset + 4 <= encoded.count, encoded[offset] == 0xFF, [0xE0, 0xEE].contains(encoded[offset + 1]) {
            let size = Int(encoded[offset + 2]) << 8 | Int(encoded[offset + 3])
            guard size >= 2, size <= encoded.count - offset - 2 else { break }
            offset += size + 2
        }
        return encoded.prefix(offset) + markers + encoded.dropFirst(offset)
    }

    /// A JPEG the way Skia's encoder wrote it for the C# helper (comic pages, PDF scans): 4:2:0, optimized Huffman
    /// tables, no density or profiles. `quality` 1…100.
    static func writeSkia(_ image: CGImage, quality: Int, to path: String) throws {
        let (straight, channels) = CodecPixels.straight(image)
        let count = image.width * image.height
        var samples = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count { for c in 0..<3 { samples[i * 3 + c] = straight[i * channels + c] } }
        var jpeg = FTXJpegImage()
        (jpeg.width, jpeg.height, jpeg.components, jpeg.quality, jpeg.skia) = (Int32(image.width), Int32(image.height), 3, Int32(min(100, max(1, quality))), 1)
        var data: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        var message = [CChar](repeating: 0, count: 256)
        let status = samples.withUnsafeBufferPointer { pixels -> Int32 in
            jpeg.pixels = pixels.baseAddress
            return ftx_jpeg_encode(&jpeg, &data, &length, &message)
        }
        defer { free(data) }
        guard status == 0, let data else { throw ConversionError("JPEG encoding failed: " + String(cString: message)) }
        try FileManager.default.writeFile(path, Data(bytes: data, count: Int(length)))
    }

    private static func withBlob<T>(_ blob: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        guard let blob, !blob.isEmpty else { return body(nil, 0) }
        return blob.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress, blob.count) }
    }

    /// Complete, uniquely numbered APP2 ICC chunks; reject truncated or unusable source profiles.
    static func embeddedProfile(_ file: Data) -> Data? {
        let header = Data("ICC_PROFILE\0".utf8)
        var chunks: [Int: Data] = [:]
        var total = 0
        for (marker, payload) in segments(file) where marker == 0xE2 && payload.starts(with: header) {
            guard payload.count > 14 else { return nil }
            let sequence = Int(payload[12]), count = Int(payload[13])
            guard count > 0, sequence > 0, sequence <= count, total == 0 || total == count,
                  chunks[sequence] == nil else { return nil }
            total = count
            chunks[sequence] = Data(payload.dropFirst(14))
        }
        guard total > 0, chunks.count == total else { return nil }
        var profile = Data()
        for sequence in 1...total { profile.append(chunks[sequence]!) }
        return CodecPixels.validProfile(profile)
    }

    /// COM and Photoshop APP13, including multipart resources and markers between progressive scans.
    static func preservedMarkers(_ file: Data) -> Data {
        var result = Data()
        for (marker, payload) in segments(file) where marker == 0xFE ||
            (marker == 0xED && payload.starts(with: Data("Photoshop 3.0\0".utf8))) {
            let length = payload.count + 2
            result.append(contentsOf: [0xFF, marker, UInt8(length >> 8), UInt8(length & 255)])
            result.append(payload)
        }
        return result
    }

    /// JPEG marker payloads, with entropy stuffing/restarts skipped. Truncated segments are never sliced.
    static func segments(_ file: Data) -> [(UInt8, Data)] {
        let bytes = [UInt8](file)
        guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return [] }
        var result: [(UInt8, Data)] = []
        var i = 2
        while i < bytes.count {
            guard bytes[i] == 0xFF else { i += 1; continue }
            i += 1
            while i < bytes.count && bytes[i] == 0xFF { i += 1 }
            guard i < bytes.count else { break }
            let marker = bytes[i]
            i += 1
            if marker == 0xD9 { break }
            if marker == 0 || marker == 1 || (0xD0...0xD8).contains(marker) { continue }
            guard i + 2 <= bytes.count else { break }
            let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            guard length >= 2, length <= bytes.count - i else { break }
            result.append((marker, Data(bytes[i + 2..<i + length])))
            i += length
        }
        return result
    }

    /// Sampling factors in the first SOF marker: [h, v] per component.
    static func samplingFactors(_ file: Data) -> [Int]? {
        for (marker, data) in segments(file) where (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker) {
            let bytes = [UInt8](data)
            guard bytes.count >= 6 else { return nil }
            let components = Int(bytes[5])
            guard bytes.count >= 6 + 3 * components else { return nil }
            return (0..<components).flatMap { [Int(bytes[7 + 3 * $0] >> 4), Int(bytes[7 + 3 * $0] & 15)] }
        }
        return nil
    }
}
