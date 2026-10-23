// Netpbm (PBM, PGM, PPM, PNM, PAM) for the "ppm" format: ImageIO writes only ASCII PPM, ImageMagick writes the binary
// kinds (P4 bitmap, P5 gray, P6 colour) with maxval 255, and reads every kind including ASCII and 16-bit files.

import CoreGraphics
import Foundation

enum NetpbmCodec {
    // ───────────────────────── Reading ─────────────────────────

    /// Every image in the file (Netpbm files may hold several, one after the other).
    static func read(_ path: String) throws -> [ImageFrame] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var parser = Parser(bytes: [UInt8](data))
        var frames: [ImageFrame] = []
        while true {
            parser.skipWhitespace()
            guard parser.position + 1 < parser.bytes.count, parser.bytes[parser.position] == UInt8(ascii: "P") else { break }
            frames.append(ImageFrame(image: try parser.image()))
            try Task.checkCancellation()
        }
        guard !frames.isEmpty else { throw ConversionError("\(FilePath.fileName(path)) is not a Netpbm (PBM/PGM/PPM) image.") }
        return frames
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        mutating func skipWhitespace() {
            while position < bytes.count {
                if bytes[position] == UInt8(ascii: "#") {
                    while position < bytes.count && bytes[position] != 0x0A && bytes[position] != 0x0D { position += 1 }
                } else if [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C].contains(bytes[position]) {
                    position += 1
                } else {
                    return
                }
            }
        }

        mutating func token() throws -> String {
            skipWhitespace()
            let start = position
            while position < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, UInt8(ascii: "#")].contains(bytes[position]) { position += 1 }
            guard position > start else { throw ConversionError("The Netpbm header is incomplete.") }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        mutating func number() throws -> Int {
            guard let value = Int(try token()), value >= 0 else { throw ConversionError("The Netpbm header has an invalid number.") }
            return value
        }

        mutating func image() throws -> CGImage {
            position += 1
            let kind = bytes[position] - UInt8(ascii: "0")
            position += 1
            var width = 0, height = 0, maxValue = 1, depth = 0
            switch kind {
            case 7:
                while true {
                    let key = try token()
                    if key == "ENDHDR" { break }
                    switch key {
                    case "WIDTH": width = try number()
                    case "HEIGHT": height = try number()
                    case "DEPTH": depth = try number()
                    case "MAXVAL": maxValue = try number()
                    default: // TUPLTYPE and unknown keys: rest of the line
                        while position < bytes.count && bytes[position] != 0x0A { position += 1 }
                    }
                }
            case 1, 4:
                (width, height, depth) = (try number(), try number(), 1)
            case 2, 5:
                (width, height, maxValue, depth) = (try number(), try number(), try number(), 1)
            case 3, 6:
                (width, height, maxValue, depth) = (try number(), try number(), try number(), 3)
            default:
                throw ConversionError("Unknown Netpbm kind P\(kind).")
            }
            guard width > 0, height > 0, width * height <= 1 << 30, (1...4).contains(depth), (1...65535).contains(maxValue) else {
                throw ConversionError("The Netpbm image has an invalid size.")
            }
            if kind >= 4 { position += 1 } // the single whitespace before binary data
            var samples = [UInt8](repeating: 0, count: width * height * depth)
            let wide = maxValue > 255
            func scale(_ value: Int) -> UInt8 { UInt8(min(255, (value * 255 + maxValue / 2) / maxValue)) }
            switch kind {
            case 1:
                for i in 0..<width * height {
                    skipWhitespace()
                    guard position < bytes.count else { break }
                    samples[i] = bytes[position] == UInt8(ascii: "1") ? 0 : 255
                    position += 1
                }
            case 2, 3:
                for i in 0..<samples.count { samples[i] = scale((try? number()) ?? 0) }
            case 4:
                let rowBytes = (width + 7) / 8
                for y in 0..<height {
                    for x in 0..<width {
                        let at = position + y * rowBytes + x / 8
                        let bit = at < bytes.count ? (bytes[at] >> (7 - UInt8(x % 8))) & 1 : 0
                        samples[y * width + x] = bit == 1 ? 0 : 255
                    }
                }
                position += rowBytes * height
            default: // 5, 6, 7: binary samples, 1 or 2 bytes (big-endian) each
                let size = wide ? 2 : 1
                for i in 0..<samples.count {
                    let at = position + i * size
                    guard at + size <= bytes.count else { break }
                    samples[i] = scale(wide ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : Int(bytes[at]))
                }
                position += samples.count * size
            }
            let gray = depth <= 2
            let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
            return ImagePixels.make(samples, width, height, components: depth, space: space, alpha: depth == 2 || depth == 4, premultiplied: false)
        }
    }

    // ───────────────────────── Writing ─────────────────────────

    /// Writes P6 ("ppm"), P5 ("pgm", Rec. 709 luma) or P4 ("pbm", luma below half is black) with maxval 255.
    static func write(_ frame: ImageFrame, to path: String, kind: String) throws {
        let bitmap = ImagePixels.bitmap(frame.image)
        let (width, height) = (bitmap.width, bitmap.height)
        var output = Data()
        func value(_ i: Int, _ c: Int) -> Int {
            let alpha = Int(bitmap.pixels[i * 4 + 3])
            let premultiplied = Int(bitmap.pixels[i * 4 + c])
            return alpha == 0 ? 0 : alpha == 255 ? premultiplied : min(255, (premultiplied * 255 + alpha / 2) / alpha)
        }
        func luma(_ i: Int) -> Double { 0.212656 * Double(value(i, 0)) + 0.715158 * Double(value(i, 1)) + 0.072186 * Double(value(i, 2)) }
        switch kind {
        case "pbm":
            output.append(contentsOf: Array("P4\n\(width) \(height)\n".utf8))
            let rowBytes = (width + 7) / 8
            var row = [UInt8](repeating: 0, count: rowBytes)
            for y in 0..<height {
                for i in 0..<rowBytes { row[i] = 0 }
                for x in 0..<width where luma(y * width + x) < 127.5 { row[x / 8] |= 0x80 >> UInt8(x % 8) }
                output.append(contentsOf: row)
            }
        case "pgm":
            output.append(contentsOf: Array("P5\n\(width) \(height)\n255\n".utf8))
            var gray = [UInt8](repeating: 0, count: width * height)
            for i in 0..<width * height { gray[i] = UInt8(min(255, luma(i).rounded())) }
            output.append(contentsOf: gray)
        default:
            output.append(contentsOf: Array("P6\n\(width) \(height)\n255\n".utf8))
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            for i in 0..<width * height {
                for c in 0..<3 { rgb[i * 3 + c] = UInt8(value(i, c)) }
            }
            output.append(contentsOf: rgb)
        }
        try FileManager.default.writeFile(path, output)
    }
}
