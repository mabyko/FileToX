// Photoshop documents for the image engine. ImageIO reads PSD and PSB composites but writes only PSD, so both are
// written here the way ImageMagick wrote them: one layer holding the picture (with its transparency) and the RLE
// composite. Files saved without "maximize compatibility" have no real composite; like ImageMagick, the visible layers
// are then composited (normal blending, layer opacity and offsets; 8-bit RGB and grayscale).

import CoreGraphics
import Foundation
import zlib

enum PsdCodec {
    // ───────────────────────── Writing ─────────────────────────

    /// Writes a PSD (version 1) or, when `large`, a PSB (version 2) with one layer "L1" and the composite.
    static func write(_ frame: ImageFrame, to path: String, large: Bool) throws {
        let bitmap = ImagePixels.bitmap(frame.image)
        let (width, height) = (bitmap.width, bitmap.height)
        let limit = large ? 300_000 : 30_000
        guard width <= limit, height <= limit else {
            throw ConversionError("The picture is \(width) × \(height) pixels; \(large ? "PSB" : "PSD") files hold at most \(limit) × \(limit).")
        }
        let gray = bitmap.gray != nil
        let colorChannels = gray ? 1 : 3
        let alpha = bitmap.hasAlpha
        // Straight (not premultiplied) channel planes.
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height), count: colorChannels + (alpha ? 1 : 0))
        for i in 0..<width * height {
            let a = Int(bitmap.pixels[i * 4 + 3])
            for c in 0..<colorChannels {
                let value = Int(bitmap.pixels[i * 4 + c])
                planes[c][i] = UInt8(a == 0 ? 0 : a == 255 ? value : min(255, (value * 255 + a / 2) / a))
            }
            if alpha { planes[colorChannels][i] = UInt8(a) }
        }

        var out = BigEndianData()
        out.bytes(Array("8BPS".utf8))
        out.u16(large ? 2 : 1)
        out.bytes([UInt8](repeating: 0, count: 6))
        out.u16(planes.count)
        out.u32(height)
        out.u32(width)
        out.u16(8)
        out.u16(gray ? 1 : 3)
        out.u32(0) // colour mode data

        var resources = BigEndianData()
        if let dpi = frame.dpi, dpi.x > 0 {
            resources.resource(0x03ED, resolutionInfo(dpi))
        }
        if ImagePixels.hasColorProfile(frame.image), let icc = frame.image.colorSpace?.copyICCData() as Data? {
            resources.resource(0x040F, [UInt8](icc))
        }
        out.u32(resources.data.count)
        out.bytes(resources.data)

        // Layer and mask information: one layer covering the canvas.
        var layerInfo = BigEndianData()
        layerInfo.i16(alpha ? -1 : 1) // negative: the first alpha channel is the composite's transparency
        let channelIds: [Int] = (0..<colorChannels).map { $0 } + (alpha ? [-1] : [])
        let channelData = planes.map { rle([$0], width: width, height: height, large: large, withCompression: true) }
        layerInfo.u32(0); layerInfo.u32(0); layerInfo.u32(height); layerInfo.u32(width)
        layerInfo.u16(channelIds.count)
        for (id, data) in zip(channelIds, channelData) {
            layerInfo.i16(id)
            large ? layerInfo.u64(data.count) : layerInfo.u32(data.count)
        }
        layerInfo.bytes(Array("8BIMnorm".utf8))
        layerInfo.bytes([255, 0, 1, 0]) // opacity, clipping, flags, filler
        layerInfo.u32(12)
        layerInfo.u32(0) // layer mask data
        layerInfo.u32(0) // blending ranges
        layerInfo.bytes([2, UInt8(ascii: "L"), UInt8(ascii: "1"), 0]) // Pascal name padded to 4 bytes
        for data in channelData { layerInfo.bytes(data) }
        let unit = large ? 4 : 2
        while layerInfo.data.count % unit != 0 { layerInfo.bytes([0]) }

        let sectionLength = (large ? 8 : 4) + layerInfo.data.count + 4
        large ? out.u64(sectionLength) : out.u32(sectionLength)
        large ? out.u64(layerInfo.data.count) : out.u32(layerInfo.data.count)
        out.bytes(layerInfo.data)
        out.u32(0) // global layer mask info

        // Composite image data: RLE, all channels.
        out.bytes(rle(planes, width: width, height: height, large: large, withCompression: true))
        try Data(out.data).write(to: URL(fileURLWithPath: path))
    }

    private static func resolutionInfo(_ dpi: (x: Double, y: Double)) -> [UInt8] {
        var info = BigEndianData()
        info.u32(Int((dpi.x * 65536).rounded())); info.u16(1); info.u16(1)
        info.u32(Int((dpi.y * 65536).rounded())); info.u16(1); info.u16(1)
        return info.data
    }

    /// Channel planes as PSD RLE: compression 1, the byte count of every row, then the PackBits rows.
    private static func rle(_ planes: [[UInt8]], width: Int, height: Int, large: Bool, withCompression: Bool) -> [UInt8] {
        var counts = BigEndianData()
        var rows: [UInt8] = []
        for plane in planes {
            for y in 0..<height {
                let packed = packBits(plane[y * width..<(y + 1) * width])
                large ? counts.u32(packed.count) : counts.u16(packed.count)
                rows += packed
            }
        }
        var result = BigEndianData()
        if withCompression { result.u16(1) }
        result.bytes(counts.data)
        result.bytes(rows)
        return result.data
    }

    /// PackBits: literal runs of 1…128 bytes, repeats of 2…128.
    static func packBits(_ row: ArraySlice<UInt8>) -> [UInt8] {
        let source = Array(row)
        var output: [UInt8] = []
        var i = 0
        while i < source.count {
            var run = 1
            while i + run < source.count && run < 128 && source[i + run] == source[i] { run += 1 }
            if run >= 2 {
                output.append(UInt8(257 - run))
                output.append(source[i])
                i += run
                continue
            }
            let start = i
            while i < source.count && i - start < 128 && !(i + 1 < source.count && source[i] == source[i + 1]) { i += 1 }
            output.append(UInt8(i - start - 1))
            output += source[start..<i]
        }
        return output
    }

    // ───────────────────────── Reading layers ─────────────────────────

    /// The composite of the visible layers when the file says it has no real merged image (Photoshop's "maximize
    /// compatibility" off); nil when the stored composite is valid or the layers can't be read here (ImageIO reads it).
    static func layerComposite(_ path: String) throws -> ImageFrame? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var reader = Reader(data: [UInt8](data))
        guard reader.bytes(4) == Array("8BPS".utf8) else { return nil }
        let version = reader.u16()
        reader.skip(6)
        let channels = reader.u16(), height = reader.u32(), width = reader.u32(), depth = reader.u16(), mode = reader.u16()
        let large = version == 2
        reader.skip(reader.u32()) // colour mode data
        let resourcesLength = reader.u32()
        let resourcesEnd = reader.position + resourcesLength
        var hasMergedData = true
        var dpi: (x: Double, y: Double)?
        while reader.position + 12 <= resourcesEnd {
            guard reader.bytes(4) == Array("8BIM".utf8) else { break }
            let id = reader.u16()
            let nameLength = reader.u8()
            reader.skip(nameLength + (nameLength + 1) % 2)
            let size = reader.u32()
            let start = reader.position
            if id == 0x0421, size >= 5 { // VersionInfo: version, hasRealMergedData
                reader.skip(4)
                hasMergedData = reader.u8() != 0
            } else if id == 0x03ED, size >= 16 {
                let x = Double(reader.u32()) / 65536
                reader.skip(4)
                let y = Double(reader.u32()) / 65536
                dpi = (x, y)
            }
            reader.position = start + size + size % 2
        }
        guard !hasMergedData, depth == 8, mode == 1 || mode == 3, width > 0, height > 0, channels >= 1 else { return nil }
        reader.position = resourcesEnd
        let sectionLength = large ? reader.u64() : reader.u32()
        guard sectionLength > 0 else { return nil }
        let layerInfoLength = large ? reader.u64() : reader.u32()
        guard layerInfoLength > 0 else { return nil }
        let layerCount = abs(reader.i16())
        struct Layer { var top = 0, left = 0, bottom = 0, right = 0; var channels: [(id: Int, length: Int)] = []; var opacity = 255; var visible = true }
        var layers: [Layer] = []
        for _ in 0..<layerCount {
            var layer = Layer()
            (layer.top, layer.left, layer.bottom, layer.right) = (reader.i32(), reader.i32(), reader.i32(), reader.i32())
            for _ in 0..<reader.u16() { layer.channels.append((reader.i16(), large ? reader.u64() : reader.u32())) }
            reader.skip(8) // "8BIM", blend mode key
            layer.opacity = reader.u8()
            reader.skip(1)
            layer.visible = reader.u8() & 0x02 == 0
            reader.skip(1)
            reader.skip(reader.u32()) // mask, blending ranges, name, additional information
            layers.append(layer)
        }
        let gray = mode == 1
        var canvas = [Double](repeating: 0, count: width * height * 4) // straight RGB + alpha, 0…1
        for layer in layers {
            try Task.checkCancellation()
            let (w, h) = (layer.right - layer.left, layer.bottom - layer.top)
            var planes: [Int: [UInt8]] = [:]
            for channel in layer.channels {
                let end = reader.position + channel.length
                if w > 0, h > 0, channel.length >= 2 { planes[channel.id] = readChannel(&reader, width: w, height: h, end: end, large: large) }
                reader.position = end
            }
            guard layer.visible, w > 0, h > 0 else { continue }
            let opacity = Double(layer.opacity) / 255
            for y in 0..<h {
                let cy = y + layer.top
                guard cy >= 0, cy < height else { continue }
                for x in 0..<w {
                    let cx = x + layer.left
                    guard cx >= 0, cx < width else { continue }
                    let i = y * w + x
                    let a = Double(planes[-1]?[i] ?? 255) / 255 * opacity
                    guard a > 0 else { continue }
                    let o = (cy * width + cx) * 4
                    let color: [Double] = gray
                        ? Array(repeating: Double(planes[0]?[i] ?? 0) / 255, count: 3)
                        : (0..<3).map { Double(planes[$0]?[i] ?? 0) / 255 }
                    let below = canvas[o + 3]
                    let outAlpha = a + below * (1 - a)
                    for c in 0..<3 { canvas[o + c] = (color[c] * a + canvas[o + c] * below * (1 - a)) / outAlpha }
                    canvas[o + 3] = outAlpha
                }
            }
        }
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<canvas.count { samples[i] = UInt8((canvas[i] * 255).rounded()) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var frame = ImageFrame(image: ImagePixels.make(samples, width, height, components: 4, space: space, alpha: true, premultiplied: false))
        if gray { frame.image = ImagePixels.grayscale(frame.image) }
        frame.dpi = dpi
        return frame
    }

    /// One layer channel: raw (0), RLE (1) or ZIP without (2) / with (3) prediction.
    private static func readChannel(_ reader: inout Reader, width: Int, height: Int, end: Int, large: Bool) -> [UInt8] {
        let compression = reader.u16()
        var plane = [UInt8](repeating: 0, count: width * height)
        switch compression {
        case 0:
            for i in 0..<min(plane.count, max(0, end - reader.position)) { plane[i] = reader.data[reader.position + i] }
        case 1:
            let counts = (0..<height).map { _ in large ? reader.u32() : reader.u16() }
            for y in 0..<height {
                let rowEnd = min(end, reader.position + counts[y])
                var x = 0
                while reader.position < rowEnd && x < width {
                    let control = Int(reader.u8())
                    if control < 128 {
                        for _ in 0...control where reader.position < rowEnd { let value = UInt8(reader.u8()); if x < width { plane[y * width + x] = value }; x += 1 }
                    } else if control > 128 {
                        let value = UInt8(reader.position < rowEnd ? reader.u8() : 0)
                        for _ in 0..<(257 - control) { if x < width { plane[y * width + x] = value }; x += 1 }
                    }
                }
                reader.position = rowEnd
            }
        case 2, 3:
            let compressed = Array(reader.data[reader.position..<min(end, reader.data.count)])
            var inflated = [UInt8](repeating: 0, count: plane.count)
            var size = uLongf(inflated.count)
            if uncompress(&inflated, &size, compressed, uLong(compressed.count)) == Z_OK {
                plane = inflated
                if compression == 3 {
                    for y in 0..<height { for x in 1..<max(1, width) { plane[y * width + x] &+= plane[y * width + x - 1] } }
                }
            }
        default:
            break
        }
        return plane
    }

    private struct Reader {
        let data: [UInt8]
        var position = 0

        mutating func u8() -> Int { defer { position += 1 }; return position < data.count ? Int(data[position]) : 0 }
        mutating func u16() -> Int { u8() << 8 | u8() }
        mutating func i16() -> Int { Int(Int16(bitPattern: UInt16(u16()))) }
        mutating func u32() -> Int { u16() << 16 | u16() }
        mutating func i32() -> Int { Int(Int32(bitPattern: UInt32(u32()))) }
        mutating func u64() -> Int { u32() << 32 | u32() }
        mutating func skip(_ count: Int) { position += count }
        mutating func bytes(_ count: Int) -> [UInt8] {
            defer { position += count }
            return position + count <= data.count ? Array(data[position..<position + count]) : []
        }
    }
}

/// Big-endian byte writer for the PSD codec.
private struct BigEndianData {
    var data: [UInt8] = []

    mutating func bytes(_ values: [UInt8]) { data += values }
    mutating func u16(_ value: Int) { data += [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    mutating func i16(_ value: Int) { u16(Int(UInt16(bitPattern: Int16(value)))) }
    mutating func u32(_ value: Int) { u16(value >> 16 & 0xFFFF); u16(value & 0xFFFF) }
    mutating func u64(_ value: Int) { u32(value >> 32 & 0xFFFF_FFFF); u32(value & 0xFFFF_FFFF) }

    /// An image resource block: "8BIM", id, empty name, size, data padded to even length.
    mutating func resource(_ id: Int, _ body: [UInt8]) {
        bytes(Array("8BIM".utf8))
        u16(id)
        bytes([0, 0])
        u32(body.count)
        bytes(body)
        if body.count % 2 == 1 { bytes([0]) }
    }
}
