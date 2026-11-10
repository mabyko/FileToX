// OpenJPEG supplies ImageMagick's PSNR-controlled codestream; ImageIO keeps the JP2 metadata container.
import Accelerate
import COpenJPEG
import CoreGraphics
import Foundation

enum Jpeg2000Encoder {
    static func replacingCodestream(in container: Data, image source: CGImage, quality: Int) throws -> Data {
        try Task.checkCancellation()
        let image = source
        // ImageIO may convert unsupported ICC profiles to sRGB. Encode samples in the container's actual space.
        let imageHeader = try box("jp2h", in: container).payload
        let color = try box("colr", in: imageHeader).payload
        let layout = try box("ihdr", in: imageHeader).payload
        guard layout.count == 14 else { throw ConversionError("The JPEG 2000 image header is invalid.") }
        let space: CGColorSpace
        if color.first == 2, let profile = CGColorSpace(iccData: color.dropFirst(3) as CFData) {
            space = profile
        } else if image.colorSpace?.model == .monochrome {
            space = CGColorSpaceCreateDeviceGray()
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let channels = (space.model == .monochrome ? 1 : 3) + (ImagePixels.hasAlpha(image) ? 1 : 0)
        // Match the container precision, including ImageIO's existing normalization of 16-bit gray/alpha.
        let bits = layout[10] == 15 ? 16 : 8
        let alpha: CGImageAlphaInfo = ImagePixels.hasAlpha(image) ? .last : .none
        var info = CGBitmapInfo(rawValue: alpha.rawValue)
        if bits == 16 { info.insert(.byteOrder16Little) }
        var format = vImage_CGImageFormat(bitsPerComponent: UInt32(bits), bitsPerPixel: UInt32(bits * channels),
                                        colorSpace: Unmanaged.passUnretained(space), bitmapInfo: info, version: 0,
                                        decode: nil, renderingIntent: image.renderingIntent)
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw ConversionError("Could not prepare the JPEG 2000 pixels.")
        }
        defer { free(buffer.data) }
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        var message = [CChar](repeating: 0, count: 256)
        let status = ftx_j2k_encode(buffer.data, Int32(image.width), Int32(image.height), buffer.rowBytes, Int32(channels),
                                   Int32(bits), Int32(quality), &bytes, &length, &message, { Task.isCancelled ? 1 : 0 })
        defer { free(bytes) }
        if status == 2 { throw CancellationError() }
        guard status == 0, let bytes else { throw ConversionError(String(cString: message)) }
        try Task.checkCancellation()
        let typed = try replacingBox("jp2h", in: container) { header in
            try replacingBox("ihdr", in: header) { payload in
                guard payload.count == 14 else { throw ConversionError("The JPEG 2000 image header is invalid.") }
                var payload = payload
                payload[8] = 0
                payload[9] = UInt8(channels)
                payload[10] = UInt8(bits - 1)
                return payload
            }
        }
        return try replaceCodestream(in: typed, with: Data(bytes: bytes, count: length))
    }

    /// Keep the header, ICC, resolution and UUID metadata boxes byte for byte. Validate lengths before slicing.
    static func replaceCodestream(in container: Data, with codestream: Data) throws -> Data {
        try replacingBox("jp2c", in: container) { _ in codestream }
    }

    private static func replacingBox(_ type: String, in container: Data, payload: (Data) throws -> Data) throws -> Data {
        let found = try box(type, in: container)
        let replacement = try payload(found.payload)
        var header = Data()
        if UInt64(replacement.count) + 8 <= UInt32.max {
            let total = UInt32(replacement.count) + 8
            for shift in stride(from: 24, through: 0, by: -8) { header.append(UInt8(truncatingIfNeeded: total >> shift)) }
            header.append(contentsOf: type.utf8)
        } else {
            header.append(contentsOf: [0, 0, 0, 1])
            header.append(contentsOf: type.utf8)
            let total = UInt64(replacement.count) + 16
            for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8(truncatingIfNeeded: total >> shift)) }
        }
        var result = Data(container.prefix(found.range.lowerBound))
        result.append(header)
        result.append(replacement)
        result.append(container.dropFirst(found.range.upperBound))
        return result
    }

    private static func box(_ type: String, in container: Data) throws -> (range: Range<Int>, payload: Data) {
        let data = [UInt8](container)
        func number(_ offset: Int, _ count: Int) -> UInt64 {
            data[offset..<offset + count].reduce(0) { $0 << 8 | UInt64($1) }
        }
        var position = 0
        while position + 8 <= data.count {
            var length = number(position, 4)
            let header = length == 1 ? 16 : 8
            guard position + header <= data.count else { break }
            if length == 1 { length = number(position + 8, 8) }
            if length == 0 { length = UInt64(data.count - position) }
            guard length >= header, length <= data.count - position else { break }
            if Array(data[position + 4..<position + 8]) == Array(type.utf8) {
                return (position..<position + Int(length), Data(data[position + header..<position + Int(length)]))
            }
            position += Int(length)
        }
        throw ConversionError("The JPEG 2000 container has no valid \(type) box.")
    }
}
