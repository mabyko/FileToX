// Pixel work of the image engine, what Filee left to ImageMagick (Q8): EXIF orientation, resizing (ImageMagick's own
// filters, MagickResize), grayscale, flattening onto a background and padding. Pictures are processed as 8-bit RGBA
// (premultiplied; straight for resizing, like ImageMagick) in their own RGB colour space (values are not converted, like
// ImageMagick keeps the ICC profile beside the pixels); grayscale sources come back as grayscale images.

import Accelerate
import CoreGraphics
import Foundation

enum ImagePixels {
    /// 8-bit premultiplied RGBA, rows top to bottom.
    struct Bitmap {
        var width: Int
        var height: Int
        var pixels: [UInt8]
        /// RGB colour space the values are in.
        var space: CGColorSpace
        /// Grayscale colour space of the source, to turn the result back into a grayscale image.
        var gray: CGColorSpace?
        var hasAlpha: Bool
    }

    /// ImageMagick's `HasAlpha`: the picture has an alpha channel (even when every pixel is opaque).
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// The picture as an RGBA bitmap. Drawn in its own colour space, so the values are not converted.
    static func bitmap(_ image: CGImage) -> Bitmap {
        let (w, h) = (image.width, image.height)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let model = image.colorSpace?.model
        if model == .monochrome, let gray = image.colorSpace {
            // Gray drawn onto black is the premultiplied value; the alpha comes from an alpha-only drawing.
            var values = [UInt8](repeating: 0, count: w * h)
            values.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: gray,
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.interpolationQuality = .none
                context.draw(image, in: rect)
            }
            var alpha = [UInt8](repeating: 255, count: w * h)
            let hasAlpha = hasAlpha(image)
            if hasAlpha {
                // Alpha is not colour managed: take it from an RGBA drawing.
                var rgba = [UInt8](repeating: 0, count: w * h * 4)
                rgba.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: rect)
                }
                for i in 0..<w * h { alpha[i] = rgba[i * 4 + 3] }
            }
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<w * h { (pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]) = (values[i], values[i], values[i], alpha[i]) }
            return Bitmap(width: w, height: h, pixels: pixels, space: CGColorSpace(name: CGColorSpace.sRGB)!, gray: gray, hasAlpha: hasAlpha)
        }
        let space = model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        var bitmap = Bitmap(width: w, height: h, pixels: [UInt8](repeating: 0, count: w * h * 4), space: space, gray: nil, hasAlpha: hasAlpha(image))
        bitmap.pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: rect)
        }
        return bitmap
    }

    /// The bitmap as an image: RGB(A), or gray(+alpha) when the source was grayscale.
    static func image(_ bitmap: Bitmap) -> CGImage {
        if let gray = bitmap.gray {
            var values = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * (bitmap.hasAlpha ? 2 : 1))
            let step = bitmap.hasAlpha ? 2 : 1
            for i in 0..<bitmap.width * bitmap.height {
                values[i * step] = bitmap.pixels[i * 4]
                if bitmap.hasAlpha { values[i * 2 + 1] = bitmap.pixels[i * 4 + 3] }
            }
            return make(values, bitmap.width, bitmap.height, components: step, space: gray, alpha: bitmap.hasAlpha)
        }
        if bitmap.hasAlpha { return make(bitmap.pixels, bitmap.width, bitmap.height, components: 4, space: bitmap.space, alpha: true) }
        var rgb = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 3)
        for i in 0..<bitmap.width * bitmap.height {
            rgb[i * 3] = bitmap.pixels[i * 4]
            rgb[i * 3 + 1] = bitmap.pixels[i * 4 + 1]
            rgb[i * 3 + 2] = bitmap.pixels[i * 4 + 2]
        }
        return make(rgb, bitmap.width, bitmap.height, components: 3, space: bitmap.space, alpha: false)
    }

    /// An image over interleaved 8-bit samples; `alpha` means the last component is premultiplied alpha.
    static func make(_ samples: [UInt8], _ width: Int, _ height: Int, components: Int, space: CGColorSpace, alpha: Bool,
                     premultiplied: Bool = true) -> CGImage {
        let info: CGImageAlphaInfo = !alpha ? (components == 4 ? .noneSkipLast : .none) : premultiplied ? .premultipliedLast : .last
        let provider = CGDataProvider(data: Data(samples) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: width * components,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    // ───────────────────────── Operations ─────────────────────────

    /// GIF has binary transparency. ImageMagick thresholds at 50%; ImageIO otherwise
    /// makes every nonzero alpha opaque, turning semi-transparent shadows into black.
    static func gifImage(_ image: CGImage) -> CGImage {
        guard hasAlpha(image) else { return image }
        var source = bitmap(image)
        for i in 0..<source.width * source.height {
            let p = i * 4, alpha = Int(source.pixels[p + 3])
            if alpha < 128 {
                for c in 0..<4 { source.pixels[p + c] = 0 }
            } else {
                for c in 0..<3 { source.pixels[p + c] = UInt8(min(255, (Int(source.pixels[p + c]) * 255 + alpha / 2) / alpha)) }
                source.pixels[p + 3] = 255
            }
        }
        return self.image(source)
    }

    /// Turns the picture upright for an EXIF orientation (1…8), ImageMagick's AutoOrient.
    static func oriented(_ image: CGImage, _ orientation: Int) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let source = bitmap(image)
        let (w, h) = (source.width, source.height)
        let swapped = orientation >= 5
        var result = source
        (result.width, result.height) = swapped ? (h, w) : (w, h)
        source.pixels.withUnsafeBytes { from in
            result.pixels.withUnsafeMutableBytes { to in
                let input = from.bindMemory(to: UInt32.self), output = to.bindMemory(to: UInt32.self)
                let outWidth = result.width
                for y in 0..<result.height {
                    for x in 0..<outWidth {
                        // Displayed (x, y) comes from stored (sx, sy).
                        let (sx, sy): (Int, Int) = switch orientation {
                        case 2: (w - 1 - x, y)
                        case 3: (w - 1 - x, h - 1 - y)
                        case 4: (x, h - 1 - y)
                        case 5: (y, x)
                        case 6: (y, h - 1 - x)
                        case 7: (w - 1 - y, h - 1 - x)
                        default: (w - 1 - y, x)
                        }
                        output[y * outWidth + x] = input[sy * w + sx]
                    }
                }
            }
        }
        return self.image(result)
    }

    /// ImageMagick's Resize to `width` × `height` (`MagickResize`). `filter` nil is ImageMagick's own choice: Lanczos,
    /// Mitchell for pictures with alpha or a palette (indexed or gray: ImageMagick reads those PseudoClass) and for
    /// enlargements; then the same size leaves the picture as it is. The result has straight (not premultiplied) alpha.
    static func resized(_ image: CGImage, width: Int, height: Int, filter: MagickResize.Filter? = nil) -> CGImage {
        let size = (width: max(1, width), height: max(1, height))
        guard filter != nil || size != (image.width, image.height) else { return image }
        let model = image.colorSpace?.model
        let alpha = hasAlpha(image)
        let chosen = filter ?? MagickResize.defaultFilter(from: (image.width, image.height), to: size, alpha: alpha,
                                                          palette: model == .indexed || model == .monochrome)
        let (samples, channels, space) = straight(image)
        let result = MagickResize.resize(samples, width: image.width, height: image.height, channels: channels, alpha: alpha, to: size,
                                         filter: chosen)
        return make(result, size.width, size.height, components: channels, space: space, alpha: alpha, premultiplied: false)
    }

    /// The picture's samples as ImageMagick holds them: gray or RGB in the picture's own colour space (other colour
    /// models converted to sRGB), then straight alpha when it has alpha.
    static func straight(_ image: CGImage) -> (samples: [UInt8], channels: Int, space: CGColorSpace) {
        let model = image.colorSpace?.model
        let space = model == .rgb || model == .monochrome ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let channels = (model == .monochrome ? 1 : 3) + (hasAlpha(image) ? 1 : 0)
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: UInt32(8 * channels), colorSpace: Unmanaged.passUnretained(space),
                                          bitmapInfo: CGBitmapInfo(rawValue: (hasAlpha(image) ? CGImageAlphaInfo.last : .none).rawValue),
                                          version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        var samples = [UInt8](repeating: 0, count: image.width * image.height * channels)
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            // Not a format vImage converts: go through the premultiplied bitmap.
            let bitmap = bitmap(image)
            for i in 0..<image.width * image.height {
                let a = Int(bitmap.pixels[i * 4 + 3])
                for c in 0..<channels - (hasAlpha(image) ? 1 : 0) {
                    let value = Int(bitmap.pixels[i * 4 + c])
                    samples[i * channels + c] = UInt8(hasAlpha(image) && a > 0 && a < 255 ? min(255, (value * 255 + a / 2) / a) : value)
                }
                if hasAlpha(image) { samples[i * channels + channels - 1] = UInt8(a) }
            }
            return (samples, channels, space)
        }
        defer { free(buffer.data) }
        samples.withUnsafeMutableBytes { output in
            for y in 0..<image.height {
                memcpy(output.baseAddress! + y * image.width * channels, buffer.data + y * buffer.rowBytes, image.width * channels)
            }
        }
        return (samples, channels, space)
    }

    /// ImageMagick's Grayscale: Rec. 709 luma of the (gamma-encoded) values; alpha is kept.
    static func grayscale(_ image: CGImage) -> CGImage {
        var source = bitmap(image)
        for i in 0..<source.width * source.height {
            let p = i * 4
            // Luma is linear in R, G and B, so it can be taken from premultiplied values.
            let luma = 0.212656 * Double(source.pixels[p]) + 0.715158 * Double(source.pixels[p + 1]) + 0.072186 * Double(source.pixels[p + 2])
            let value = UInt8(min(255, luma.rounded()))
            (source.pixels[p], source.pixels[p + 1], source.pixels[p + 2]) = (value, value, value)
        }
        source.gray = CGColorSpaceCreateDeviceGray()
        return self.image(source)
    }

    /// Composites the picture over an opaque colour and drops alpha (ImageMagick's `Alpha(AlphaOption.Remove)`): its
    /// FlattenPixelInfo on straight samples, `Sa·p + q·(1 − Sa)` normalised, with clang's fused multiply-adds.
    static func flattened(_ image: CGImage, background: (red: UInt8, green: UInt8, blue: UInt8)) -> CGImage {
        guard hasAlpha(image) else { return image }
        let (samples, channels, space) = straight(image)
        let fill = [Double(background.red), Double(background.green), Double(background.blue)]
        let gray = channels == 2, keepGray = gray && fill[0] == fill[1] && fill[1] == fill[2]
        let colors = keepGray ? 1 : 3
        var result = [UInt8](repeating: 0, count: image.width * image.height * colors)
        let quantumScale = 1.0 / 255.0, opaque = quantumScale * 255.0
        for i in 0..<image.width * image.height {
            let a = Double(samples[i * channels + channels - 1])
            let sa = quantumScale * a
            let gamma = MagickResize.reciprocal(opaque.addingProduct(opaque, -sa) + sa)
            for c in 0..<colors {
                let value = Double(samples[i * channels + (gray ? 0 : c)])
                let over = ((opaque * fill[c]) * (1.0 - sa)).addingProduct(sa, value)
                result[i * colors + c] = MagickResize.clamp(gamma * over)
            }
        }
        return make(result, image.width, image.height, components: colors,
                    space: keepGray || !gray ? space : CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
    }

    /// Centres the picture on a transparent `side` × `side` square (ImageMagick's Extent with Gravity.Center).
    static func padded(_ image: CGImage, side: Int) -> CGImage {
        // Straight samples, so semi-transparent pixels keep their exact values for the resizes that follow.
        let (samples, channels, space) = straight(image)
        let alpha = hasAlpha(image), outChannels = alpha ? channels : channels + 1
        var result = [UInt8](repeating: 0, count: side * side * outChannels)
        let (left, top) = ((side - image.width) / 2, (side - image.height) / 2)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let from = (y * image.width + x) * channels, to = ((y + top) * side + left + x) * outChannels
                for c in 0..<channels { result[to + c] = samples[from + c] }
                if !alpha { result[to + channels] = 255 }
            }
        }
        return make(result, side, side, components: outChannels, space: space, alpha: true, premultiplied: false)
    }

    /// The same values without their ICC profile (ImageMagick's Strip): read as plain sRGB / gray / CMYK afterwards.
    static func untagged(_ image: CGImage) -> CGImage {
        let space: CGColorSpace? = switch image.colorSpace?.model {
        case .rgb: CGColorSpace(name: CGColorSpace.sRGB)
        case .monochrome: CGColorSpaceCreateDeviceGray()
        case .cmyk: CGColorSpaceCreateDeviceCMYK()
        default: nil
        }
        guard let space, image.colorSpace?.name != space.name else { return image }
        return image.copy(colorSpace: space) ?? image
    }

    /// True when the image carries an ICC profile other than the untagged default (plain sRGB / gray).
    static func hasColorProfile(_ image: CGImage) -> Bool {
        guard let space = image.colorSpace, let name = space.name as String? else { return image.colorSpace?.copyICCData() != nil }
        return ![CGColorSpace.sRGB as String, "kCGColorSpaceDeviceRGB", "kCGColorSpaceDeviceGray", "kCGColorSpaceDeviceCMYK"].contains(name)
            && space.copyICCData() != nil
    }

    /// "#RRGGBB", "#RGB" or "#RRGGBBAA" as RGB; white for anything else (Filee's ParseColor fallback).
    static func parseColor(_ hex: String) -> (red: UInt8, green: UInt8, blue: UInt8) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return named[text.lowercased()] ?? (255, 255, 255) }
        text.removeFirst()
        if text.count == 3 || text.count == 4 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text.prefix(6), radix: 16) else { return (255, 255, 255) }
        return (UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }

    private static let named: [String: (red: UInt8, green: UInt8, blue: UInt8)] = [
        "white": (255, 255, 255), "black": (0, 0, 0), "red": (255, 0, 0), "green": (0, 128, 0), "lime": (0, 255, 0),
        "blue": (0, 0, 255), "yellow": (255, 255, 0), "gray": (128, 128, 128), "grey": (128, 128, 128), "silver": (192, 192, 192),
    ]
}
