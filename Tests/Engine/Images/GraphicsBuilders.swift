// Port of Filee.Engines.Tests/GraphicsBuilders.cs: test inputs no encoder here writes — GIMP XCF files, DNG camera RAW
// files (linear, Bayer, lossy), ICNS entries in Apple's legacy RLE format, layered PSD files — and the SVG / EPS
// documents. (Windows metafiles are Windows-only in Filee and not ported.)

import CoreGraphics
import Foundation
import ImageIO
@testable import FileToXEngineKit

enum GraphicsBuilders {
    // ───────────────────────── SVG and EPS ─────────────────────────

    /// A 400×200 drawing with a gradient, a Bézier path, a circle and text; transparent background.
    static let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="400" height="200" viewBox="0 0 400 200">
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="1" y2="0">
              <stop offset="0" stop-color="#7F77DD"/>
              <stop offset="1" stop-color="#1D9E75"/>
            </linearGradient>
          </defs>
          <rect x="20" y="20" width="160" height="80" rx="12" fill="url(#g)"/>
          <path d="M 220 150 C 260 40, 320 40, 360 150 Z" fill="#E4572E" stroke="#222" stroke-width="3"/>
          <circle cx="200" cy="100" r="30" fill="#FF0000"/>
          <text x="20" y="170" font-family="Arial, sans-serif" font-size="28" fill="#222">Filee SVG 한글</text>
        </svg>
        """

    /// A 200×100 EPS: a filled triangle and a line of text.
    static let eps = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 200 100
        %%EndComments
        newpath 10 10 moveto 190 90 lineto 190 10 lineto closepath 0.2 0.5 0.8 setrgbcolor fill
        /Helvetica findfont 18 scalefont setfont 0 0 0 setrgbcolor 20 70 moveto (Filee EPS) show
        showpage
        %%EOF
        """

    // ───────────────────────── GIMP XCF ─────────────────────────

    /// A solid-colour XCF layer.
    struct XcfLayer {
        var name: String, width: Int, height: Int, x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255, visible = true
    }

    /// An 8-bit RGB XCF (format version 0, RLE tiles) with the layers given top-most first, as GIMP stores them.
    static func xcf(_ width: Int, _ height: Int, _ layers: [XcfLayer]) -> [UInt8] {
        var w = BigEndianWriter()
        w.bytes(Array("gimp xcf file\0".utf8))
        w.u32(width); w.u32(height); w.u32(0) // RGB
        w.u32(17); w.u32(1); w.byte(1) // PROP_COMPRESSION = RLE
        w.u32(0); w.u32(0) // PROP_END
        let layerTable = w.position
        for _ in layers { w.u32(0) }
        w.u32(0) // end of layers
        w.u32(0) // no channels
        for (i, layer) in layers.enumerated() {
            w.patch(layerTable + 4 * i, w.position)
            w.u32(layer.width); w.u32(layer.height); w.u32(1) // RGBA
            let name = Array((layer.name + "\0").utf8)
            w.u32(name.count); w.bytes(name)
            w.u32(6); w.u32(4); w.u32(255) // PROP_OPACITY
            w.u32(8); w.u32(4); w.u32(layer.visible ? 1 : 0) // PROP_VISIBLE
            w.u32(15); w.u32(8); w.u32(layer.x); w.u32(layer.y) // PROP_OFFSETS
            w.u32(7); w.u32(4); w.u32(0) // PROP_MODE normal
            w.u32(0); w.u32(0) // PROP_END
            let hierarchyPointer = w.position
            w.u32(0)
            w.u32(0) // no layer mask
            w.patch(hierarchyPointer, w.position)
            w.u32(layer.width); w.u32(layer.height); w.u32(4)
            let levelPointer = w.position
            w.u32(0); w.u32(0)
            w.patch(levelPointer, w.position)
            w.u32(layer.width); w.u32(layer.height)
            let columns = (layer.width + 63) / 64, rows = (layer.height + 63) / 64
            let tileTable = w.position
            for _ in 0..<columns * rows { w.u32(0) }
            w.u32(0)
            for t in 0..<columns * rows {
                w.patch(tileTable + 4 * t, w.position)
                let tileWidth = min(64, layer.width - t % columns * 64), tileHeight = min(64, layer.height - t / columns * 64)
                for value in [layer.r, layer.g, layer.b, layer.a] {
                    // One long run per channel: 127, 16-bit count, value.
                    w.byte(127); w.byte(UInt8((tileWidth * tileHeight) >> 8)); w.byte(UInt8((tileWidth * tileHeight) & 0xFF)); w.byte(value)
                }
            }
        }
        return w.data
    }

    // ───────────────────────── DNG ─────────────────────────

    /// How `dng` stores its raw image.
    enum DngKind {
        /// Demosaiced RGB, 16 bit, uncompressed: a "linear" DNG as written by raw converters.
        case linear
        /// One 16-bit sample per pixel behind an RGGB colour filter, uncompressed: what cameras write.
        case bayer
        /// Demosaiced RGB, 8 bit, JPEG-compressed: Adobe DNG Converter's lossy compression.
        case lossy
    }

    /// A minimal DNG: IFD0 is a small 8-bit preview with the DNG tags, the raw image is its SubIFD (Apple's RAW decoder
    /// wants this standard layout; Filee's LibRaw test file had the raw image in IFD0). The left half is red, the right
    /// half blue.
    static func dng(_ width: Int, _ height: Int, orientation: UInt16, kind: DngKind = .linear) -> [UInt8] {
        var pixels: [UInt8] = []
        var preview = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: [UInt16] = x < width / 2 ? [50000, 3000, 3000] : [3000, 3000, 50000]
                for c in 0..<3 { preview[(y * width + x) * 3 + c] = UInt8(rgb[c] >> 8) }
                // RGGB: red on even rows and columns, blue on odd ones, green elsewhere.
                let samples = kind == .bayer ? [rgb[x % 2 + y % 2]] : rgb
                if kind != .lossy { for value in samples { pixels += [UInt8(value & 0xFF), UInt8(value >> 8)] } }
            }
        }
        if kind == .lossy {
            let data = NSMutableData()
            let jpeg = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(jpeg, ImagePixels.make(preview, width, height, components: 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                              alpha: false), [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            CGImageDestinationFinalize(jpeg)
            pixels = [UInt8](data as Data)
        }
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        // XYZ → camera: the camera is linear sRGB, so this is the XYZ → linear sRGB matrix.
        let colorMatrix: [Int32] = [32406, -15372, -4986, -9689, 18758, 415, 557, -2040, 10570]
        typealias Entry = (tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])
        // Bits per sample, compression (1 none, 34892 lossy JPEG), photometric (34892 LinearRaw, 32803 CFA), samples.
        let (bits, compression, photometric, samples): ([UInt8], UInt16, UInt16, UInt16) = switch kind {
        case .linear: (u16(16) + u16(16) + u16(16), 1, 34892, 3)
        case .bayer: (u16(16), 1, 32803, 1)
        case .lossy: (u16(8) + u16(8) + u16(8), 34892, 34892, 3)
        }
        let cfa: [Entry] = kind == .bayer ? [(33421, 3, 2, u16(2) + u16(2)), (33422, 1, 4, [0, 1, 1, 2])] : []
        let rawEntries: [Entry] = [
            (254, 4, 1, u32(0)), (256, 4, 1, u32(UInt32(width))), (257, 4, 1, u32(UInt32(height))),
            (258, 3, UInt32(samples), bits), (259, 3, 1, u16(compression)), (262, 3, 1, u16(photometric)),
            (273, 4, 1, u32(0)), (277, 3, 1, u16(samples)), (278, 4, 1, u32(UInt32(height))), (279, 4, 1, u32(UInt32(pixels.count))),
            (284, 3, 1, u16(1)),
        ] + cfa + [(50717, 4, 1, u32(kind == .lossy ? 255 : 65535))]
        let mainEntries: [Entry] = [
            (254, 4, 1, u32(1)), (256, 4, 1, u32(UInt32(width))), (257, 4, 1, u32(UInt32(height))),
            (258, 3, 3, u16(8) + u16(8) + u16(8)), (259, 3, 1, u16(1)), (262, 3, 1, u16(2)),
            (271, 2, 6, Array("Filee\0".utf8)), (272, 2, 5, Array("Test\0".utf8)), (273, 4, 1, u32(0)),
            (274, 3, 1, u16(orientation)), (277, 3, 1, u16(3)), (278, 4, 1, u32(UInt32(height))),
            (279, 4, 1, u32(UInt32(preview.count))), (284, 3, 1, u16(1)), (330, 4, 1, u32(0)),
            (50706, 1, 4, [1, 4, 0, 0]), (50707, 1, 4, [1, 1, 0, 0]), (50708, 2, 11, Array("Filee Test\0".utf8)),
            (50721, 10, 9, colorMatrix.flatMap { u32(UInt32(bitPattern: $0)) + u32(10000) }),
            (50728, 5, 3, u32(1) + u32(1) + u32(1) + u32(1) + u32(1) + u32(1)), (50778, 3, 1, u16(21)), // D65
        ]
        // Layout: header, IFD0 + its values, raw SubIFD + its values, preview strip, raw strip.
        var file = Array("II*\0".utf8) + u32(8)
        func ifd(_ entries: [Entry], at start: Int) -> (block: [UInt8], fields: [UInt16: Int]) {
            let size = 2 + entries.count * 12 + 4
            var block = u16(UInt16(entries.count))
            var values: [UInt8] = []
            var fields: [UInt16: Int] = [:]
            for entry in entries {
                block += u16(entry.tag) + u16(entry.type) + u32(entry.count)
                fields[entry.tag] = start + block.count
                if entry.value.count <= 4 {
                    block += entry.value + [UInt8](repeating: 0, count: 4 - entry.value.count)
                } else {
                    block += u32(UInt32(start + size + values.count))
                    values += entry.value
                    if values.count % 2 == 1 { values.append(0) }
                }
            }
            return (block + u32(0) + values, fields)
        }
        let main = ifd(mainEntries, at: file.count)
        file += main.block
        let rawStart = file.count
        let raw = ifd(rawEntries, at: rawStart)
        file += raw.block
        let previewStart = file.count
        file += preview
        let pixelStart = file.count
        file += pixels
        func patch(_ at: Int, _ value: Int) { file.replaceSubrange(at..<at + 4, with: u32(UInt32(value))) }
        patch(main.fields[273]!, previewStart)
        patch(main.fields[330]!, rawStart)
        patch(raw.fields[273]!, pixelStart)
        return file
    }

    // ───────────────────────── ICNS ─────────────────────────

    /// An .icns file from raw entries (no table of contents, as old files have).
    static func icns(_ entries: [(type: String, data: [UInt8])]) -> [UInt8] {
        var w = BigEndianWriter()
        w.bytes(Array("icns".utf8))
        w.u32(8 + entries.reduce(0) { $0 + 8 + $1.data.count })
        for entry in entries {
            w.bytes(Array(entry.type.utf8))
            w.u32(8 + entry.data.count)
            w.bytes(entry.data)
        }
        return w.data
    }

    /// Legacy RGB entry data (is32, il32, ih32, it32): R, G and B planes of one colour, RLE encoded.
    static func legacyRgb(_ size: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, it32: Bool = false) -> [UInt8] {
        var planes = [UInt8](repeating: r, count: size * size) + [UInt8](repeating: g, count: size * size) + [UInt8](repeating: b, count: size * size)
        // Vary the first row so the encoder emits literal runs too.
        for x in stride(from: 0, to: size, by: 2) { planes[x] = r ^ 1 }
        let packed = packBits(planes)
        return it32 ? [0, 0, 0, 0] + packed : packed
    }

    /// Apple's icon RLE (see IcnsFile.unpackBits): literal runs of 1…128 bytes, repeats of 3…130.
    static func packBits(_ source: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var i = 0
        while i < source.count {
            var run = 1
            while i + run < source.count && run < 130 && source[i + run] == source[i] { run += 1 }
            if run >= 3 {
                output.append(UInt8(run + 125))
                output.append(source[i])
                i += run
                continue
            }
            let start = i
            while i < source.count && i - start < 128 && !(i + 2 < source.count && source[i] == source[i + 1] && source[i] == source[i + 2]) { i += 1 }
            output.append(UInt8(i - start - 1))
            output += source[start..<i]
        }
        return output
    }

    // ───────────────────────── PSD ─────────────────────────

    /// A solid-colour PSD layer.
    struct PsdLayer {
        var left: Int, top: Int, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8
    }

    /// An 8-bit RGB (or, with `gray`, grayscale: the red values) PSD with a composite (raw) and the given layers (raw
    /// channels, bottom-most first as Photoshop stores them). With `realComposite` false the composite is white and the
    /// VersionInfo resource says it is not real (Photoshop's "maximize compatibility" off).
    static func layeredPsd(_ width: Int, _ height: Int, composite: (Int, Int) -> (UInt8, UInt8, UInt8), layers: [PsdLayer],
                           realComposite: Bool = true, gray: Bool = false) -> [UInt8] {
        let channels = gray ? 1 : 3
        var w = BigEndianWriter()
        w.bytes(Array("8BPS".utf8)); w.u16(1); w.bytes([0, 0, 0, 0, 0, 0]); w.u16(channels); w.u32(height); w.u32(width); w.u16(8); w.u16(gray ? 1 : 3)
        w.u32(0)
        var resources = BigEndianWriter()
        resources.bytes(Array("8BIM".utf8)); resources.u16(0x0421); resources.bytes([0, 0]); resources.u32(6)
        resources.u32(1); resources.byte(realComposite ? 1 : 0); resources.byte(0)
        w.u32(resources.data.count); w.bytes(resources.data)
        var info = BigEndianWriter()
        info.u16(layers.count)
        for layer in layers {
            info.u32(layer.top); info.u32(layer.left); info.u32(layer.top + layer.height); info.u32(layer.left + layer.width)
            info.u16(channels)
            for c in 0..<channels { info.u16(c); info.u32(2 + layer.width * layer.height) }
            info.bytes(Array("8BIMnorm".utf8)); info.bytes([255, 0, 0, 0])
            info.u32(12); info.u32(0); info.u32(0); info.bytes([3, 0x4C, 0x31, 0x20])
        }
        for layer in layers {
            for value in [layer.r, layer.g, layer.b].prefix(channels) {
                info.u16(0)
                info.bytes([UInt8](repeating: value, count: layer.width * layer.height))
            }
        }
        if info.data.count % 2 == 1 { info.byte(0) }
        w.u32(4 + info.data.count + 4); w.u32(info.data.count); w.bytes(info.data); w.u32(0)
        w.u16(0) // raw composite
        for c in 0..<channels {
            for y in 0..<height {
                for x in 0..<width {
                    let rgb = realComposite ? composite(x, y) : (255, 255, 255)
                    w.byte(c == 0 ? rgb.0 : c == 1 ? rgb.1 : rgb.2)
                }
            }
        }
        return w.data
    }

    /// Big-endian writer with back-patching of 32-bit offsets.
    struct BigEndianWriter {
        var data: [UInt8] = []
        var position: Int { data.count }

        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func bytes(_ values: [UInt8]) { data += values }
        mutating func u16(_ value: Int) { data += [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        mutating func u32(_ value: Int) { data += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        mutating func patch(_ at: Int, _ value: Int) {
            data.replaceSubrange(at..<at + 4, with: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
    }
}
