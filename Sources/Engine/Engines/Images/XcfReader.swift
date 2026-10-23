// GIMP XCF reader (ImageIO has none), after ImageMagick's coders/xcf.c as Filee used it: 8-bit RGB, grayscale and
// indexed images with uncompressed or RLE tiles; the visible layers are composited bottom-up onto a transparent canvas
// of the document's size at their offsets, with their opacity and blend mode (Filee's FlattenXcf). Files saved with
// "better but slower compression" (zlib tiles) and high bit-depth images are refused like ImageMagick refuses them.

import CoreGraphics
import Foundation

enum XcfReader {
    /// The flattened picture of an XCF file.
    static func read(_ path: String) throws -> ImageFrame {
        guard let data = FileManager.default.contents(atPath: path) else { throw ConversionError("The file can't be read.") }
        var reader = Reader(bytes: [UInt8](data))
        guard reader.bytes.count >= 26, Array(reader.bytes[0..<9]) == Array("gimp xcf ".utf8) else { throw ConversionError("Not a GIMP XCF file.") }
        let versionText = String(decoding: reader.bytes[9..<13], as: UTF8.self)
        let version = versionText == "file" ? 0 : Int(versionText.dropFirst()) ?? 0
        reader.position = 14
        let width = try reader.u32(), height = try reader.u32(), baseType = try reader.u32()
        guard (1...524_288).contains(width), (1...524_288).contains(height) else { throw ConversionError("The XCF image has an invalid size.") }
        guard width * height <= 100_000_000 else { throw ConversionError("The XCF image is too large (\(width) × \(height) pixels).") }
        if version >= 4 {
            let precision = try reader.u32()
            let eightBit = version < 7 ? precision == 0 : precision == 100 || precision == 150
            guard eightBit else { throw ConversionError("Only 8-bit XCF images are supported.") }
        }
        reader.wide = version >= 11

        var colormap: [UInt8] = []
        var compression = 0
        try reader.properties { type, length, body in
            switch type {
            case 1 where length >= 4: // PROP_COLORMAP
                var sub = Reader(bytes: body)
                let count = try sub.u32()
                colormap = Array(body.dropFirst(4).prefix(count * 3))
            case 17 where length >= 1: // PROP_COMPRESSION
                compression = Int(body[0])
            default:
                break
            }
        }
        guard compression == 0 || compression == 1 else {
            throw ConversionError("The XCF file uses zlib compression (\"better but slower compression\").")
        }

        var layerOffsets: [Int] = []
        while true {
            let offset = try reader.pointer()
            if offset == 0 { break }
            layerOffsets.append(offset)
        }

        // Straight RGBA canvas, 0…1; layers are stored top-most first and composited bottom-up.
        var canvas = [Float](repeating: 0, count: width * height * 4)
        for offset in layerOffsets.reversed() {
            try Task.checkCancellation()
            reader.position = offset
            guard let layer = try readLayer(&reader, compression: compression, colormap: colormap) else { continue }
            composite(layer, onto: &canvas, width: width, height: height)
        }

        var samples = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<canvas.count { samples[i] = UInt8((min(max(canvas[i], 0), 1) * 255).rounded()) }
        let image = ImagePixels.make(samples, width, height, components: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true,
                                     premultiplied: false)
        // A grayscale document stays grayscale (with alpha).
        return ImageFrame(image: baseType == 1 ? ImagePixels.grayscale(image) : image)
    }

    private struct Layer {
        var width = 0, height = 0, x = 0, y = 0
        var opacity = 1.0
        var mode = 0
        /// Straight RGBA, 0…255.
        var pixels: [UInt8] = []
    }

    private static func readLayer(_ reader: inout Reader, compression: Int, colormap: [UInt8]) throws -> Layer? {
        var layer = Layer()
        layer.width = try reader.u32()
        layer.height = try reader.u32()
        let type = try reader.u32()
        _ = try reader.string() // name
        var visible = true, group = false
        try reader.properties { kind, length, body in
            var sub = Reader(bytes: body)
            switch kind {
            case 6 where length >= 4: layer.opacity = Double(min(try sub.u32(), 255)) / 255 // PROP_OPACITY
            case 33 where length >= 4: layer.opacity = Double(Float(bitPattern: UInt32(try sub.u32()))) // PROP_FLOAT_OPACITY
            case 7 where length >= 4: layer.mode = try sub.u32() // PROP_MODE
            case 8 where length >= 4: visible = try sub.u32() != 0 // PROP_VISIBLE
            case 15 where length >= 8: (layer.x, layer.y) = (try sub.i32(), try sub.i32()) // PROP_OFFSETS
            case 29: group = true // PROP_GROUP_ITEM: a layer group (its children are layers of their own)
            default: break
            }
        }
        guard visible, !group, layer.width > 0, layer.height > 0, layer.width * layer.height <= 1 << 30 else { return nil }
        let hierarchy = try reader.pointer()
        _ = try reader.pointer() // layer mask
        guard hierarchy > 0 else { return nil }

        reader.position = hierarchy
        _ = try reader.u32(); _ = try reader.u32()
        let bpp = try reader.u32()
        let level = try reader.pointer()
        reader.position = level
        let levelWidth = try reader.u32(), levelHeight = try reader.u32()
        guard levelWidth == layer.width, levelHeight == layer.height, (1...4).contains(bpp) else {
            throw ConversionError("The XCF layer data is inconsistent.")
        }
        var tiles: [Int] = []
        while true {
            let tile = try reader.pointer()
            if tile == 0 { break }
            tiles.append(tile)
        }
        let columns = (layer.width + 63) / 64, rows = (layer.height + 63) / 64
        guard tiles.count >= columns * rows else { throw ConversionError("The XCF layer has missing tiles.") }

        var channels = [UInt8](repeating: 0, count: layer.width * layer.height * bpp)
        for t in 0..<columns * rows {
            let tileWidth = min(64, layer.width - t % columns * 64), tileHeight = min(64, layer.height - t / columns * 64)
            let count = tileWidth * tileHeight
            reader.position = tiles[t]
            var tile = [UInt8](repeating: 0, count: count * bpp)
            if compression == 0 {
                for i in 0..<count * bpp { tile[i] = try reader.u8() }
            } else {
                for channel in 0..<bpp { try reader.rle(into: &tile, channel: channel, stride: bpp, count: count) }
            }
            for ty in 0..<tileHeight {
                for tx in 0..<tileWidth {
                    let x = t % columns * 64 + tx, y = t / columns * 64 + ty
                    for c in 0..<bpp { channels[(y * layer.width + x) * bpp + c] = tile[(ty * tileWidth + tx) * bpp + c] }
                }
            }
        }

        // To straight RGBA: types 0 RGB, 1 RGBA, 2 GRAY, 3 GRAYA, 4 INDEXED, 5 INDEXEDA.
        layer.pixels = [UInt8](repeating: 255, count: layer.width * layer.height * 4)
        for i in 0..<layer.width * layer.height {
            let p = i * bpp, o = i * 4
            switch type {
            case 0, 1:
                (layer.pixels[o], layer.pixels[o + 1], layer.pixels[o + 2]) = (channels[p], channels[p + 1], channels[p + 2])
                if type == 1, bpp >= 4 { layer.pixels[o + 3] = channels[p + 3] }
            case 2, 3:
                (layer.pixels[o], layer.pixels[o + 1], layer.pixels[o + 2]) = (channels[p], channels[p], channels[p])
                if type == 3, bpp >= 2 { layer.pixels[o + 3] = channels[p + 1] }
            default:
                let index = Int(channels[p]) * 3
                if index + 2 < colormap.count {
                    (layer.pixels[o], layer.pixels[o + 1], layer.pixels[o + 2]) = (colormap[index], colormap[index + 1], colormap[index + 2])
                }
                if type == 5, bpp >= 2 { layer.pixels[o + 3] = channels[p + 1] }
            }
        }
        return layer
    }

    /// Composites a layer onto the canvas with its blend mode (ImageMagick's operator for the GIMP mode): the blended
    /// colour where both are opaque, the layer over the canvas elsewhere.
    private static func composite(_ layer: Layer, onto canvas: inout [Float], width: Int, height: Int) {
        let blend = blendFunction(layer.mode)
        for ly in 0..<layer.height {
            let y = ly + layer.y
            guard y >= 0, y < height else { continue }
            for lx in 0..<layer.width {
                let x = lx + layer.x
                guard x >= 0, x < width else { continue }
                let p = (ly * layer.width + lx) * 4, o = (y * width + x) * 4
                let sa = Double(layer.pixels[p + 3]) / 255 * layer.opacity
                guard sa > 0 else { continue }
                let da = Double(canvas[o + 3])
                let outAlpha = sa + da - sa * da
                for c in 0..<3 {
                    let sc = Double(layer.pixels[p + c]) / 255, dc = Double(canvas[o + c])
                    let mixed = blend(sc, dc) * sa * da + sc * sa * (1 - da) + dc * da * (1 - sa)
                    canvas[o + c] = Float(outAlpha > 0 ? mixed / outAlpha : 0)
                }
                canvas[o + 3] = Float(outAlpha)
            }
        }
    }

    /// Per-channel blend of layer colour `s` over canvas colour `d` for a GIMP layer mode (legacy and 2.10 numbers).
    /// Hue, saturation, colour and value modes are composited as normal.
    private static func blendFunction(_ mode: Int) -> (Double, Double) -> Double {
        switch mode {
        case 3, 30: { s, d in s * d } // multiply
        case 4, 31: { s, d in s + d - s * d } // screen
        case 5, 23: { s, d in d < 0.5 ? 2 * s * d : 1 - 2 * (1 - s) * (1 - d) } // overlay
        case 6, 32: { s, d in abs(s - d) } // difference
        case 7, 33: { s, d in min(1, s + d) } // addition
        case 8, 34: { s, d in max(0, d - s) } // subtract
        case 9, 35: { s, d in min(s, d) } // darken only
        case 10, 36: { s, d in max(s, d) } // lighten only
        case 15, 41: { s, d in s <= 0 ? (d > 0 ? 1 : 0) : min(1, d / s) } // divide
        case 16, 42: { s, d in s >= 1 ? (d > 0 ? 1 : 0) : min(1, d / (1 - s)) } // dodge
        case 17, 43: { s, d in s <= 0 ? (d >= 1 ? 1 : 0) : max(0, 1 - (1 - d) / s) } // burn
        case 18, 44: { s, d in s < 0.5 ? 2 * s * d : 1 - 2 * (1 - s) * (1 - d) } // hard light
        case 19, 45: { s, d in (1 - 2 * s) * d * d + 2 * s * d } // soft light
        case 20, 46: { s, d in min(1, max(0, d - s + 0.5)) } // grain extract
        case 21, 47: { s, d in min(1, max(0, d + s - 0.5)) } // grain merge
        default: { s, _ in s } // normal, dissolve, behind and the rest
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0
        /// Version 11 and later store 64-bit offsets.
        var wide = false

        mutating func u8() throws -> UInt8 {
            guard position < bytes.count else { throw ConversionError("The XCF file is truncated.") }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func u32() throws -> Int {
            guard position + 4 <= bytes.count else { throw ConversionError("The XCF file is truncated.") }
            defer { position += 4 }
            return Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
        }

        mutating func i32() throws -> Int { Int(Int32(bitPattern: UInt32(try u32()))) }

        mutating func pointer() throws -> Int { wide ? (try u32()) << 32 | (try u32()) : try u32() }

        mutating func string() throws -> String {
            let length = try u32()
            guard length <= bytes.count - position else { throw ConversionError("The XCF file is truncated.") }
            defer { position += length }
            return String(decoding: bytes[position..<position + length].prefix { $0 != 0 }, as: UTF8.self)
        }

        /// Reads properties up to PROP_END, handing each (type, length, payload) to `handle`.
        mutating func properties(_ handle: (Int, Int, [UInt8]) throws -> Void) throws {
            while true {
                let type = try u32(), length = try u32()
                if type == 0 { return }
                guard length <= bytes.count - position else { throw ConversionError("The XCF file is truncated.") }
                try handle(type, length, Array(bytes[position..<position + length]))
                position += length
            }
        }

        /// One channel of an RLE tile (GIMP's xcf_load_tile_rle): n < 128 repeats the next byte n + 1 times, n ≥ 128
        /// copies 256 − n bytes; a count of 128 is followed by a 16-bit count.
        mutating func rle(into tile: inout [UInt8], channel: Int, stride: Int, count: Int) throws {
            var written = 0
            while written < count {
                var length = Int(try u8())
                if length >= 128 {
                    length = 256 - length
                    if length == 128 { length = Int(try u8()) << 8 | Int(try u8()) }
                    for _ in 0..<length {
                        let value = try u8()
                        if written < count { tile[written * stride + channel] = value }
                        written += 1
                    }
                } else {
                    length += 1
                    if length == 128 { length = Int(try u8()) << 8 | Int(try u8()) }
                    let value = try u8()
                    for _ in 0..<length {
                        if written < count { tile[written * stride + channel] = value }
                        written += 1
                    }
                }
            }
        }
    }
}
