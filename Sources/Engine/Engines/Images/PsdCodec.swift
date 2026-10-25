// Photoshop documents for the image engine. ImageIO reads PSD and PSB composites but writes only PSD, so both are
// written here the way ImageMagick wrote them: one layer holding the picture (with its transparency) and the RLE
// composite with straight channel samples. Composites with transparency are
// read here too, with ImageMagick's white unblending (ImageIO darkens semi-transparent pixels). Files saved without
// "maximize compatibility" have no real composite; like ImageMagick, the visible layers are then composited (normal
// blending, layer opacity and offsets; 8-bit RGB and grayscale).

import CoreGraphics
import Foundation
import zlib

enum PsdCodec {
    // ───────────────────────── Writing ─────────────────────────

    /// Writes a PSD (version 1) or, when `large`, a PSB (version 2) with one layer "L1" and the composite.
    static func write(_ frame: ImageFrame, to path: String, large: Bool) throws {
        let (width, height) = (frame.image.width, frame.image.height)
        let limit = large ? 300_000 : 30_000
        guard width <= limit, height <= limit else {
            throw ConversionError("The picture is \(width) × \(height) pixels; \(large ? "PSB" : "PSD") files hold at most \(limit) × \(limit).")
        }
        let native = frame.image.colorSpace?.model == .cmyk ? ImagePixels.straight(frame.image) : nil
        let cmyk = native?.space.model == .cmyk
        var gray = false, colorChannels = 4, alpha = native?.channels == 5
        // Straight (not premultiplied) channel planes.
        var planes: [[UInt8]]
        if let native, cmyk {
            // CMYK keeps its inks, stored inverted (0 = full ink) as Photoshop and ImageMagick store them.
            planes = (0..<native.channels).map { c in
                (0..<width * height).map { i in c < 4 ? 255 - native.samples[i * native.channels + c] : native.samples[i * native.channels + c] }
            }
        } else {
            let bitmap = ImagePixels.bitmap(frame.image)
            gray = bitmap.gray != nil
            colorChannels = gray ? 1 : 3
            alpha = bitmap.hasAlpha
            planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: width * height), count: colorChannels + (alpha ? 1 : 0))
            for i in 0..<width * height {
                let a = Int(bitmap.pixels[i * 4 + 3])
                for c in 0..<colorChannels {
                    let value = Int(bitmap.pixels[i * 4 + c])
                    planes[c][i] = UInt8(a == 0 ? 0 : a == 255 ? value : min(255, (value * 255 + a / 2) / a))
                }
                if alpha { planes[colorChannels][i] = UInt8(a) }
            }
        }

        var out = BigEndianData()
        out.bytes(Array("8BPS".utf8))
        out.u16(large ? 2 : 1)
        out.bytes([UInt8](repeating: 0, count: 6))
        out.u16(planes.count)
        out.u32(height)
        out.u32(width)
        out.u16(8)
        out.u16(cmyk ? 4 : gray ? 1 : 3)
        out.u32(0) // colour mode data

        var resources = BigEndianData()
        if let dpi = frame.dpi, dpi.x > 0 {
            resources.resource(0x03ED, resolutionInfo(dpi))
        }
        // The source's metadata blocks, between resolution and profile as ImageMagick orders its resources.
        if let blocks = frame.properties[ImageFrame.photoshopKey] as? Data { resources.bytes([UInt8](blocks)) }
        let metadata = CodecPixels.metadataBlobs(frame, colorModel: cmyk ? .cmyk : gray ? .monochrome : .rgb)
        if let icc = metadata.icc { resources.resource(0x040F, [UInt8](icc)) }
        // EXIF and XMP as Photoshop stores them: TIFF-structured "EXIF data 1" and the XMP packet.
        if let exif = metadata.exif { resources.resource(0x0422, [UInt8](exif)) }
        if let xmp = metadata.xmp { resources.resource(0x0424, [UInt8](xmp)) }
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

        let sectionLength = try layerSectionLength(layerInfo.data.count, large: large)
        large ? out.u64(sectionLength) : out.u32(sectionLength)
        large ? out.u64(layerInfo.data.count) : out.u32(layerInfo.data.count)
        out.bytes(layerInfo.data)
        out.u32(0) // global layer mask info

        // Filee's ImageMagick writer stores straight samples in both the layer and composite.
        // Adding a white matte here changes the displayed pixels (also in ImageIO/Quick Look).
        out.bytes(rle(planes, width: width, height: height, large: large, withCompression: true))
        try FileManager.default.writeFile(path, Data(out.data))
    }

    /// Length of the layer and mask information section around `layerInfo` bytes. PSD stores it, and every length inside
    /// it, in 32 bits; a longer section would be cut short, so only PSB's 64-bit lengths may hold it.
    static func layerSectionLength(_ layerInfo: Int, large: Bool) throws -> Int {
        let length = (large ? 8 : 4) + layerInfo + 4
        guard large || length <= Int(UInt32.max) else {
            throw ConversionError("The picture's layer data is \(length) bytes; PSD files hold at most \(UInt32.max). Convert to PSB instead.")
        }
        return length
    }

    // ───────────────────────── Metadata resources ─────────────────────────

    /// Resources that only describe the document, true of any picture written from it: caption (0x03F0), IPTC-NAA
    /// record (0x0404), copyright flag (0x040A), URL (0x040B) and the IPTC digest (0x0425). The writer makes its own
    /// resolution, profile, EXIF and XMP; the rest describe the source's layers, channels, paths, slices, guides,
    /// thumbnails, colour mode or print setup, which the flattened, possibly resized or converted copy doesn't have.
    private static let metadataIds: Set<Int> = [0x03F0, 0x0404, 0x040A, 0x040B, 0x0425]

    /// The metadata resource blocks (`metadataIds`) of a JPEG, PNG, TIFF or PSD/PSB file, byte for byte in file order.
    /// JPEG: the Photoshop APP13 segments, joined (a block may continue in the next one). PNG: ImageMagick's hex "Raw
    /// profile type 8bim", or its bare IIM "Raw profile type iptc" when no 8bim profile holds an IPTC record. TIFF: the
    /// first picture's (`tiffMetadataResources` has every picture's). PSD/PSB: the image resources.
    static func metadataResources(_ file: Data, format: String) -> Data {
        var blocks: [(id: Int, bytes: [UInt8])] = []
        switch format {
        case "jpg":
            let header = Data("Photoshop 3.0\0".utf8)
            blocks = metadataBlocks(JpegEncoder.segments(file).filter { $0.0 == 0xED && $0.1.starts(with: header) }.flatMap { $0.1.dropFirst(header.count) })
        case "png":
            blocks = rawProfileBlocks(pngText(file, keywords: rawProfileKeywords))
        case "tiff":
            blocks = EmbeddedProfiles.tiffValues(file, tags: [34377, 33723], directories: 1)?.first.map(tiffBlocks) ?? []
        case "psd", "psb":
            blocks = resourceStream(file).map(metadataBlocks) ?? []
        default:
            break
        }
        return Data(blocks.flatMap(\.bytes))
    }

    /// The metadata resource blocks of every picture of a TIFF, when its main IFD chain has `pages` pictures (ImageIO's
    /// count); nil otherwise, so no picture is given another's.
    static func tiffMetadataResources(_ file: Data, pages: Int) -> [Data]? {
        guard let directories = EmbeddedProfiles.tiffValues(file, tags: [34377, 33723], directories: pages + 1),
              directories.count == pages else { return nil }
        return directories.map { Data(tiffBlocks($0).flatMap(\.bytes)) }
    }

    /// One TIFF picture's blocks: its Photoshop resources (34377), or its IPTC-NAA record (33723) when they hold none.
    private static func tiffBlocks(_ tags: [Int: Data]) -> [(id: Int, bytes: [UInt8])] {
        var blocks = tags[34377].map { metadataBlocks([UInt8]($0)) } ?? []
        // TIFF pads the record to whole LONGs; its datasets say where it ends.
        if !blocks.contains(where: { $0.id == 0x0404 }), let record = tags[33723].map({ [UInt8]($0) }), iimLength(record) > 0 {
            var wrapped = BigEndianData()
            wrapped.resource(0x0404, Array(record.prefix(iimLength(record))))
            blocks.append((0x0404, wrapped.data))
        }
        return blocks
    }

    /// The length of the complete IPTC-NAA datasets (tag 0x1C, record, number, length, value) that start `record`.
    private static func iimLength(_ record: [UInt8]) -> Int {
        var i = 0
        while record.count - i >= 5, record[i] == 0x1C {
            var size = Int(record[i + 3]) << 8 | Int(record[i + 4]), header = 5
            if size & 0x8000 != 0 { // an extended dataset: the length's own byte count, then the length
                let count = size & 0x7FFF
                guard count <= 4, record.count - i - 5 >= count else { break }
                size = record[i + 5..<i + 5 + count].reduce(0) { $0 << 8 | Int($1) }
                header += count
            }
            guard size <= record.count - i - header else { break }
            i += header + size
        }
        return i
    }

    /// The valid ICC profiles (0x040F) of a PSD/PSB file's image resources; nil without a readable resource section.
    static func profiles(_ file: Data) -> [Data]? {
        resourceStream(file).map { stream in blocks(stream, ids: [0x040F]).compactMap { CodecPixels.validProfile(Data($0.bytes[$0.data])) } }
    }

    /// The image resource section of a PSD/PSB file.
    private static func resourceStream(_ file: Data) -> [UInt8]? {
        func u32(_ at: Int) -> Int { file[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        guard file.count >= 34, file.starts(with: Array("8BPS".utf8)) else { return nil }
        let resources = file.startIndex + 30 + u32(file.startIndex + 26)
        guard file.endIndex - resources >= 4, u32(resources) <= file.endIndex - resources - 4 else { return nil }
        return Array(file[resources + 4..<resources + 4 + u32(resources)])
    }

    /// Signatures of Photoshop resource blocks; only 8BIM blocks are copied, the others are stepped over.
    private static let resourceSignatures: Set<[UInt8]> = Set(["8BIM", "MeSa", "PHUT", "AgHg", "DCSR"].map { Array($0.utf8) })

    /// The complete metadata blocks of a resource stream, each with its padding byte.
    private static func metadataBlocks(_ stream: [UInt8]) -> [(id: Int, bytes: [UInt8])] {
        blocks(stream, ids: metadataIds).map { ($0.id, $0.bytes) }
    }

    /// The complete 8BIM blocks with `ids` of a resource stream, each with its padding byte, and where in it the block's
    /// data lies. Reading stops at the first block that is malformed or runs past the stream.
    private static func blocks(_ stream: [UInt8], ids: Set<Int>) -> [(id: Int, bytes: [UInt8], data: Range<Int>)] {
        var blocks: [(id: Int, bytes: [UInt8], data: Range<Int>)] = [], i = 0
        while stream.count - i >= 12, resourceSignatures.contains(Array(stream[i..<i + 4])) {
            let id = Int(stream[i + 4]) << 8 | Int(stream[i + 5])
            let data = i + 6 + ((Int(stream[i + 6]) + 2) & ~1) // past the Pascal name, padded to an even length
            guard stream.count - data >= 4 else { break }
            let size = stream[data..<data + 4].reduce(0) { $0 << 8 | Int($1) }
            guard size <= stream.count - data - 4 else { break }
            if stream[i..<i + 4].elementsEqual("8BIM".utf8), ids.contains(id) {
                blocks.append((id, Array(stream[i..<data + 4 + size]) + (size % 2 == 1 ? [0] : []), data + 4 - i..<data + 4 + size - i))
            }
            i = data + 4 + size + size % 2
        }
        return blocks
    }

    /// The keywords of ImageMagick's PNG raw profiles holding Photoshop resources and bare IPTC.
    static let rawProfileKeywords: Set<String> = ["Raw profile type 8bim", "Raw profile type iptc"]

    /// The metadata blocks of a PNG's raw profiles (`pngText` with `rawProfileKeywords`), flattened.
    static func rawProfileResources(_ texts: [(keyword: String, text: Data)]) -> Data { Data(rawProfileBlocks(texts).flatMap(\.bytes)) }

    /// The text of a PNG's tEXt/zTXt/iTXt chunks with one of `keywords` and an intact CRC, in file order. Inflating
    /// shares one 16 MiB budget that counts all output, also of streams that then fail; once it is spent no later chunk
    /// is inflated.
    static func pngText(_ file: Data, keywords: Set<String>) -> [(keyword: String, text: Data)] {
        guard file.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return [] }
        var texts: [(keyword: String, text: Data)] = []
        var i = file.startIndex + 8, budget = 1 << 24
        while file.endIndex - i >= 12 {
            let length = file[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= file.endIndex - i - 12, length <= Int32.max else { break }
            let chunk = file[i + 4..<i + 8 + length], stored = file[i + 8 + length..<i + 12 + length].reduce(0) { $0 << 8 | UInt($1) }
            let type = String(decoding: chunk.prefix(4), as: UTF8.self), payload = chunk.dropFirst(4)
            i += 12 + length
            if type == "IEND" { break }
            guard ["tEXt", "zTXt", "iTXt"].contains(type), let nul = payload.prefix(80).firstIndex(of: 0),
                  case let keyword = String(decoding: payload[..<nul], as: UTF8.self), keywords.contains(keyword),
                  stored == chunk.withUnsafeBytes({ zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }) else { continue }
            var text = Data(payload[(nul + 1)...]), compressed = type == "zTXt"
            if type == "iTXt" {
                // As libpng reads it: a compression flag (1 needs method 0), then a NUL-terminated language tag and
                // translated keyword before the text.
                let flag = text.first, method = text.dropFirst().first
                guard flag == 0 || (flag == 1 && method == 0), let language = text.dropFirst(2).firstIndex(of: 0),
                      let translated = text[(language + 1)...].firstIndex(of: 0) else { continue }
                compressed = flag == 1
                text = Data(text[(translated + 1)...])
            } else if compressed {
                guard text.first == 0 else { continue } // zTXt's compression method
                text = Data(text.dropFirst())
            }
            if compressed {
                guard budget > 0 else { continue }
                var inflated = Data()
                let complete = (try? Deflate.inflate(text, windowBits: 15) { output in
                    budget -= output.count
                    if budget < 0 { throw ConversionError("The PNG metadata is too large.") }
                    inflated += output
                }) != nil
                guard complete else { continue }
                text = inflated
            }
            texts.append((keyword, text))
        }
        return texts
    }

    /// Metadata blocks of raw profiles among PNG texts.
    private static func rawProfileBlocks(_ texts: [(keyword: String, text: Data)]) -> [(id: Int, bytes: [UInt8])] {
        var photoshop: [(id: Int, bytes: [UInt8])] = [], bare: [(id: Int, bytes: [UInt8])] = []
        for (keyword, text) in texts where rawProfileKeywords.contains(keyword) {
            guard let profile = rawProfile(text) else { continue }
            if keyword == "Raw profile type 8bim" {
                photoshop += metadataBlocks(profile)
            } else if profile.starts(with: Array("8BIM".utf8)) {
                bare += metadataBlocks(profile)
            } else if profile.first == 0x1C {
                // ImageMagick's "iptc" profile is the bare IIM record.
                var wrapped = BigEndianData()
                wrapped.resource(0x0404, profile)
                bare.append((0x0404, wrapped.data))
            }
        }
        // ImageMagick writes the record of its 8bim profile again as "iptc".
        return photoshop.contains { $0.id == 0x0404 } ? photoshop : photoshop + bare
    }

    /// The bytes of ImageMagick's raw profile text: "\n<name>\n<length>\n" and hex digits, whitespace between them. Nil
    /// without a length or with too few or invalid digits; anything after them is ignored.
    private static func rawProfile(_ text: Data) -> [UInt8]? {
        let lines = text.split(separator: 10, maxSplits: 2)
        guard lines.count == 3, let length = Int(String(decoding: lines[1], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              length > 0, length <= lines[2].count / 2 else { return nil }
        var bytes: [UInt8] = [], high: UInt8?
        bytes.reserveCapacity(length)
        for c in lines[2] where bytes.count < length {
            let nibble: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = c - UInt8(ascii: "A") + 10
            case 9, 10, 13, 32: continue
            default: return nil
            }
            if let h = high { bytes.append(h << 4 | nibble); high = nil } else { high = nibble }
        }
        return bytes.count == length ? bytes : nil
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

    // ───────────────────────── Reading the composite ─────────────────────────

    /// The composite of an 8/16-bit RGB or grayscale document whose first extra channel is its transparency (negative
    /// layer count), unblended from white like ImageMagick's CorrectPSDAlphaBlend; nil for anything else.
    static func transparentComposite(_ path: String) throws -> ImageFrame? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var reader = Reader(data: [UInt8](data))
        guard reader.bytes(4) == Array("8BPS".utf8) else { return nil }
        let large = reader.u16() == 2
        reader.skip(6)
        let channels = reader.u16(), height = reader.u32(), width = reader.u32(), depth = reader.u16(), mode = reader.u16()
        let colorChannels = mode == 1 ? 1 : 3
        guard mode == 1 || mode == 3, depth == 8 || depth == 16, channels > colorChannels, width > 0, height > 0, width * height <= 1 << 30 else { return nil }
        reader.skip(reader.u32()) // colour mode data
        let resourcesLength = reader.u32()
        let resourcesEnd = reader.position + resourcesLength
        var icc: Data?
        var dpi: (x: Double, y: Double)?
        while reader.position + 12 <= resourcesEnd {
            guard reader.bytes(4) == Array("8BIM".utf8) else { break }
            let id = reader.u16()
            let nameLength = reader.u8()
            reader.skip(nameLength + (nameLength + 1) % 2)
            let size = reader.u32()
            let start = reader.position
            if id == 0x040F, size > 0, start + size <= reader.data.count {
                icc = Data(reader.data[start..<start + size])
            } else if id == 0x03ED, size >= 16 {
                let x = Double(reader.u32()) / 65536, xUnit = reader.u16()
                reader.skip(2)
                let y = Double(reader.u32()) / 65536
                let factor = xUnit == 2 ? 2.54 : 1
                if x > 0 { dpi = (x * factor, (y > 0 ? y : x) * factor) }
            }
            reader.position = start + size + size % 2
        }
        reader.position = resourcesEnd
        let sectionLength = large ? reader.u64() : reader.u32()
        let compositeStart = reader.position + sectionLength
        guard sectionLength > 0 else { return nil }
        _ = large ? reader.u64() : reader.u32() // layer info length
        guard reader.i16() < 0 else { return nil } // the first alpha channel is the composite's transparency
        reader.position = compositeStart
        let compression = reader.u16()
        let bytesPerSample = depth / 8
        let rowBytes = width * bytesPerSample
        var planes = [[UInt8]](repeating: [], count: colorChannels + 1)
        switch compression {
        case 0:
            for c in 0...colorChannels {
                let start = reader.position + c * rowBytes * height
                guard start + rowBytes * height <= reader.data.count else { return nil }
                planes[c] = Array(reader.data[start..<start + rowBytes * height])
            }
        case 1:
            let counts = (0..<channels * height).map { _ in large ? reader.u32() : reader.u16() }
            for c in 0...colorChannels {
                var plane = [UInt8](repeating: 0, count: rowBytes * height)
                for y in 0..<height {
                    let end = reader.position + counts[c * height + y]
                    var x = 0
                    while reader.position < end && x < rowBytes {
                        let control = reader.u8()
                        if control < 128 {
                            for _ in 0...control where reader.position < end { let v = UInt8(reader.u8()); if x < rowBytes { plane[y * rowBytes + x] = v }; x += 1 }
                        } else if control > 128 {
                            let v = UInt8(reader.position < end ? reader.u8() : 0)
                            for _ in 0..<(257 - control) { if x < rowBytes { plane[y * rowBytes + x] = v }; x += 1 }
                        }
                    }
                    reader.position = end
                }
                planes[c] = plane
            }
        default:
            return nil
        }
        // 8-bit straight RGBA (16-bit samples keep their high byte, as ImageMagick Q8 does), unblended from white.
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height {
            let a = Double(planes[colorChannels][i * bytesPerSample]) / 255
            for c in 0..<3 {
                let value = Double(planes[colorChannels == 1 ? 0 : c][i * bytesPerSample])
                samples[i * 4 + c] = a > 0 && a < 1 ? UInt8(min(255, max(0, ((value - (1 - a) * 255) / a).rounded()))) : UInt8(value)
            }
            samples[i * 4 + 3] = planes[colorChannels][i * bytesPerSample]
        }
        let gray = colorChannels == 1
        var space: CGColorSpace = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        if let icc, let profile = CGColorSpace(iccData: icc as CFData), profile.model == (gray ? .monochrome : .rgb) { space = profile }
        var frame: ImageFrame
        if gray {
            var pairs = [UInt8](repeating: 0, count: width * height * 2)
            for i in 0..<width * height { (pairs[i * 2], pairs[i * 2 + 1]) = (samples[i * 4], samples[i * 4 + 3]) }
            frame = ImageFrame(image: ImagePixels.make(pairs, width, height, components: 2, space: space, alpha: true, premultiplied: false))
        } else {
            frame = ImageFrame(image: ImagePixels.make(samples, width, height, components: 4, space: space, alpha: true, premultiplied: false))
        }
        frame.dpi = dpi
        return frame
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
        var icc: Data?
        while reader.position + 12 <= resourcesEnd {
            guard reader.bytes(4) == Array("8BIM".utf8) else { break }
            let id = reader.u16()
            let nameLength = reader.u8()
            reader.skip(nameLength + (nameLength + 1) % 2)
            let size = reader.u32()
            let start = reader.position
            if id == 0x040F, size > 0, start + size <= reader.data.count {
                icc = Data(reader.data[start..<start + size])
            } else if id == 0x0421, size >= 5 { // VersionInfo: version, hasRealMergedData
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
        guard !hasMergedData, depth == 8, mode == 1 || mode == 3, width > 0, height > 0, width * height <= 100_000_000, channels >= 1 else { return nil }
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
        var canvas = [Float](repeating: 0, count: width * height * 4) // straight RGB + alpha, 0…1
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
                    let below = Double(canvas[o + 3])
                    let outAlpha = a + below * (1 - a)
                    for c in 0..<3 { canvas[o + c] = Float((color[c] * a + Double(canvas[o + c]) * below * (1 - a)) / outAlpha) }
                    canvas[o + 3] = Float(outAlpha)
                }
            }
        }
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<canvas.count { samples[i] = UInt8((canvas[i] * 255).rounded()) }
        // The samples keep the document's colour space, like the merged composite ImageIO reads.
        let profile = icc.flatMap { CGColorSpace(iccData: $0 as CFData) }
        let space = !gray && profile?.model == .rgb ? profile! : CGColorSpace(name: CGColorSpace.sRGB)!
        var frame = ImageFrame(image: ImagePixels.make(samples, width, height, components: 4, space: space, alpha: true, premultiplied: false))
        if gray {
            frame.image = ImagePixels.grayscale(frame.image)
            if let profile, profile.model == .monochrome, let tagged = frame.image.copy(colorSpace: profile) { frame.image = tagged }
        }
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
