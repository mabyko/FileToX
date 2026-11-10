// PDF image XObjects as PNG (what PdfPig's TryGetPng did for PdfDocumentReader): the decoded samples of gray, RGB,
// CMYK and indexed images at 1, 2, 4, 8 or 16 bits per component. Anything else (JPEG 2000, CCITT, DeviceN, ...)
// returns nil and is cut out of the rendered page instead.

import CoreGraphics
import Foundation
import ImageIO

enum PdfImageSamples {
    private enum Space {
        case gray, rgb, cmyk
        case indexed(base: [UInt8] /* RGB per entry */)

        var components: Int {
            switch self {
            case .gray, .indexed: 1
            case .rgb: 3
            case .cmyk: 4
            }
        }
    }

    /// Number of colour components of the image's colour space (PdfPig's NumberOfColorComponents).
    static func componentCount(_ dictionary: CGPDFDictionaryRef) -> Int? {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceGray", "CalGray", "G": return 1
            case "DeviceRGB", "CalRGB", "RGB", "Lab": return 3
            case "DeviceCMYK", "CMYK": return 4
            default: return nil
            }
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array else { return nil }
        return space(array).map(\.components) ?? arrayComponents(array)
    }

    private static func arrayComponents(_ array: CGPDFArrayRef) -> Int? {
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        switch String(cString: family) {
        case "CalRGB", "Lab": return 3
        case "CalGray", "Separation", "Indexed", "I": return 1
        default: return nil
        }
    }

    /// The image as a PNG file, or nil when its samples can't be turned into one here.
    static func png(_ stream: CGPDFStreamRef) -> Data? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0, width * height <= 1 << 28 else { return nil }
        CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits)
        guard [1, 2, 4, 8, 16].contains(bits), let space = imageSpace(dictionary) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { return nil }
        let samples = [UInt8](data)
        let components = space.components
        let rowBytes = (width * components * bits + 7) / 8
        guard samples.count >= rowBytes * height else { return nil }

        // 8-bit values per component.
        var values = [UInt8](repeating: 0, count: width * height * components)
        let maximum = (1 << bits) - 1
        var inverted = false
        var decode: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Decode", &decode), let decode, CGPDFArrayGetCount(decode) >= 2 {
            var low: CGPDFReal = 0, high: CGPDFReal = 1
            CGPDFArrayGetNumber(decode, 0, &low)
            CGPDFArrayGetNumber(decode, 1, &high)
            inverted = low > high
        }
        for y in 0..<height {
            let row = y * rowBytes
            for i in 0..<width * components {
                var value: Int
                switch bits {
                case 8: value = Int(samples[row + i])
                case 16: value = Int(samples[row + i * 2])
                default:
                    let bit = i * bits
                    value = Int(samples[row + bit / 8]) >> (8 - bits - bit % 8) & maximum
                }
                if case .indexed = space {
                    // Indexes stay indexes; Decode [hival 0] inverts them.
                    if inverted { value = maximum - value }
                    values[y * width * components + i] = UInt8(min(value, 255))
                } else {
                    if bits != 8 && bits != 16 { value = value * 255 / maximum }
                    if inverted && components == 1 { value = 255 - value }
                    values[y * width * components + i] = UInt8(value)
                }
            }
        }

        let image: CGImage
        switch space {
        case .gray:
            image = ImagePixels.make(values, width, height, components: 1, space: CGColorSpaceCreateDeviceGray(), alpha: false)
        case .rgb:
            image = ImagePixels.make(values, width, height, components: 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
        case .cmyk:
            let provider = CGDataProvider(data: Data(values) as CFData)!
            guard let cmyk = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            image = cmyk
        case .indexed(let palette):
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            for i in 0..<width * height {
                let entry = Int(values[i]) * 3
                if entry + 2 < palette.count { (rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]) = (palette[entry], palette[entry + 1], palette[entry + 2]) }
            }
            image = ImagePixels.make(rgb, width, height, components: 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }

    private static func imageSpace(_ dictionary: CGPDFDictionaryRef) -> Space? {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name { return deviceSpace(String(cString: name)) }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array else { return nil }
        return space(array)
    }

    private static func deviceSpace(_ name: String) -> Space? {
        switch name {
        case "DeviceGray", "CalGray", "G": .gray
        case "DeviceRGB", "CalRGB", "RGB": .rgb
        case "DeviceCMYK", "CMYK": .cmyk
        default: nil
        }
    }

    /// [/ICCBased stream], [/CalRGB dict], [/Indexed base hival lookup] …
    private static func space(_ array: CGPDFArrayRef) -> Space? {
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        switch String(cString: family) {
        case "ICCBased":
            var profile: CGPDFStreamRef?
            var n: CGPDFInteger = 0
            guard CGPDFArrayGetStream(array, 1, &profile), let profile, let info = CGPDFStreamGetDictionary(profile),
                  CGPDFDictionaryGetInteger(info, "N", &n) else { return nil }
            return n == 1 ? .gray : n == 3 ? .rgb : n == 4 ? .cmyk : nil
        case "Indexed", "I":
            var hival: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, 2, &hival), hival >= 0, hival < 256 else { return nil }
            var baseSpace: Space?
            var baseName: UnsafePointer<CChar>?
            var baseArray: CGPDFArrayRef?
            if CGPDFArrayGetName(array, 1, &baseName), let baseName {
                baseSpace = deviceSpace(String(cString: baseName))
            } else if CGPDFArrayGetArray(array, 1, &baseArray), let baseArray {
                baseSpace = space(baseArray)
            }
            guard let baseSpace else { return nil }
            var lookup: [UInt8] = []
            var string: CGPDFStringRef?
            var lookupStream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                lookup = Array(UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(string)))
            } else if CGPDFArrayGetStream(array, 3, &lookupStream), let lookupStream {
                var format = CGPDFDataFormat.raw
                lookup = (CGPDFStreamCopyData(lookupStream, &format) as Data?).map { [UInt8]($0) } ?? []
            }
            let entries = hival + 1
            var palette = [UInt8](repeating: 0, count: entries * 3)
            for e in 0..<entries {
                switch baseSpace {
                case .gray:
                    let v = e < lookup.count ? lookup[e] : 0
                    (palette[e * 3], palette[e * 3 + 1], palette[e * 3 + 2]) = (v, v, v)
                case .rgb:
                    for c in 0..<3 where e * 3 + c < lookup.count { palette[e * 3 + c] = lookup[e * 3 + c] }
                case .cmyk:
                    guard e * 4 + 3 < lookup.count else { continue }
                    let (c, m, y, k) = (Double(lookup[e * 4]) / 255, Double(lookup[e * 4 + 1]) / 255, Double(lookup[e * 4 + 2]) / 255, Double(lookup[e * 4 + 3]) / 255)
                    palette[e * 3] = UInt8(((1 - c) * (1 - k) * 255).rounded())
                    palette[e * 3 + 1] = UInt8(((1 - m) * (1 - k) * 255).rounded())
                    palette[e * 3 + 2] = UInt8(((1 - y) * (1 - k) * 255).rounded())
                case .indexed:
                    return nil
                }
            }
            return .indexed(base: palette)
        default:
            return deviceSpace(String(cString: family))
        }
    }
}
