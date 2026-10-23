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

    static func write(_ frame: ImageFrame, to path: String) throws {
        try FileManager.default.writeFile(path, try encode(frame))
    }

    static func encode(_ frame: ImageFrame) throws -> Data {
        let (straight, channels) = CodecPixels.straight(frame.image)
        let count = frame.image.width * frame.image.height
        // IdentifyImageCoderGray: exactly gray pictures are written with one component (the alpha channel, already
        // removed for JPEG targets, is never written).
        var gray = true
        for i in 0..<count where straight[i * channels] != straight[i * channels + 1] || straight[i * channels + 1] != straight[i * channels + 2] {
            gray = false
            break
        }
        let components = gray ? 1 : 3
        var samples = [UInt8](repeating: 0, count: count * components)
        for i in 0..<count {
            for c in 0..<components { samples[i * components + c] = straight[i * channels + c] }
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
        if let orientation = (frame.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            // ImageMagick keeps the orientation in the EXIF profile it writes.
            let existing = frame.properties[ImageFrame.metadataKey].flatMap { CFGetTypeID($0 as CFTypeRef) == CGImageMetadataGetTypeID() ? ($0 as! CGImageMetadata) : nil }
            let metadata = existing.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            tagged.properties[ImageFrame.metadataKey] = metadata
        }
        let blobs = CodecPixels.metadataBlobs(tagged)
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
        return Data(bytes: data, count: Int(length))
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

    /// Sampling factors in the first SOF marker of a JPEG file, [h, v] per component (nil when it isn't a JPEG).
    static func samplingFactors(_ file: Data) -> [Int]? {
        let bytes = [UInt8](file)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue } // fill byte
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            // SOF0…SOF15 except DHT (C4), JPG (C8) and DAC (CC).
            if (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard i + 10 <= bytes.count else { return nil }
                let components = Int(bytes[i + 9])
                guard i + 10 + 3 * components <= bytes.count else { return nil }
                return (0..<components).flatMap { c in [Int(bytes[i + 11 + 3 * c] >> 4), Int(bytes[i + 11 + 3 * c] & 15)] }
            }
            if marker == 0xDA || length < 2 { return nil }
            i += 2 + length
        }
        return nil
    }
}
