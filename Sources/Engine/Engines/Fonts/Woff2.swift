// Port of Filee.Engines/Fonts/Woff2.cs. Encoding uses Google's Brotli (quality 11, window 22, as Filee); decoding uses
// Apple's Compression framework.
import Foundation
import brotli
import Compression

enum Woff2 {
    static let signature: UInt32 = 0x774F4632
    static let knownTags = ["cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT", "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH", "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar", "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill"]
    private struct Entry {
        let tag: String, version: Int, origLength: Int, storedLength: Int, transformed: Bool
        var offset = 0
    }
    static func encode(_ source: SfntFont, _ progress: ProgressHandler? = nil) throws -> Data {
        let font = source.clone(); font.tables.removeValue(forKey: "DSIG")
        var glyf: Woff2Transforms.TransformedGlyf?, hmtx: Data?
        if !font.hasCffOutlines && font["glyf"] != nil && font["loca"] != nil && font["head"] != nil { glyf = try Woff2Transforms.tryTransformGlyf(font) }
        if let glyf = glyf {
            var head = try FontTables.withIndexToLocFormat(font.require("head"), glyf.longLoca)
            let flags = try FontBigEndianReader(head, 16).u16()
            BinaryPrimitives.writeUInt16BigEndian(&head, 16, UInt16(flags | 1 << 11)); font.tables["head"] = head
            if let metrics = font["hmtx"], let hhea = font["hhea"], hhea.count >= 36 {
                hmtx = try Woff2Transforms.tryTransformHmtx(metrics, font.glyphCount, FontTables.numberOfMetrics(hhea), glyf.xMins)
            }
        }
        var entries: [Entry] = [], sfntSize = 12 + 16 * font.tables.count
        let stream = FontBigEndianWriter()
        for tag in font.tables.keys.sorted() {
            var data = font.tables[tag]!
            let entry: Entry
            if tag == "glyf", let glyf = glyf { entry = Entry(tag: tag, version: 0, origLength: glyf.glyfLength, storedLength: glyf.data.count, transformed: true); data = glyf.data }
            else if tag == "loca", let glyf = glyf { entry = Entry(tag: tag, version: 0, origLength: glyf.locaLength, storedLength: 0, transformed: true); data = Data() }
            else if tag == "glyf" || tag == "loca" { entry = Entry(tag: tag, version: 3, origLength: data.count, storedLength: data.count, transformed: false) }
            else if tag == "hmtx", let hmtx = hmtx { entry = Entry(tag: tag, version: 1, origLength: data.count, storedLength: hmtx.count, transformed: true); data = hmtx }
            else { entry = Entry(tag: tag, version: 0, origLength: data.count, storedLength: data.count, transformed: false) }
            entries.append(entry); stream.bytes(data); sfntSize += (entry.origLength + 3) & ~3
        }
        try Task.checkCancellation()
        let compressed = try compress(stream.written, progress), w = FontBigEndianWriter()
        w.u32(signature); w.u32(font.flavor); w.u32(0); w.u16(entries.count); w.u16(0); w.u32(UInt32(clamping: sfntSize)); w.u32(UInt32(compressed.count))
        let (major, minor) = Woff.fontVersion(font); w.u16(major); w.u16(minor); w.zeros(20)
        for entry in entries {
            let index = knownTags.firstIndex(of: entry.tag)
            w.u8((index ?? 63) | entry.version << 6)
            if index == nil { w.u32(SfntFont.tagValue(entry.tag)) }
            w.uintBase128(UInt32(entry.origLength))
            if entry.transformed { w.uintBase128(UInt32(entry.storedLength)) }
        }
        w.bytes(compressed); w.pad4(); w.setU32(8, UInt32(w.length)); return w.written
    }
    static func decode(_ data: Data) throws -> SfntFont {
        let r = FontBigEndianReader(data)
        if try r.u32() != signature { throw ConversionError("This is not a WOFF2 file.") }
        var flavor = try r.u32(); try r.skip(4)
        let tableCount = try r.u16(); try r.skip(6)
        let compressedLength = Int(try r.u32()); r.position = 48
        var entries: [Entry] = [], streamLength = 0
        for _ in 0..<tableCount {
            let flags = try r.u8(), tag = flags & 63 == 63 ? SfntFont.tagName(try r.u32()) : knownTags[flags & 63], version = flags >> 6
            let origLength = Int(try r.uintBase128()), transformed = tag == "glyf" || tag == "loca" ? version != 3 : version != 0
            if transformed && !((tag == "glyf" || tag == "loca") && version == 0) && !(tag == "hmtx" && version == 1) { throw ConversionError("The WOFF2 table '\(tag.trimmingCharacters(in: .whitespaces))' uses an unknown transform.") }
            let storedLength = transformed ? Int(try r.uintBase128()) : origLength
            if tag == "loca" && transformed && storedLength != 0 { throw ConversionError("The WOFF2 'loca' table is damaged.") }
            entries.append(Entry(tag: tag, version: version, origLength: origLength, storedLength: storedLength, transformed: transformed, offset: min(streamLength, Int(Int32.max))))
            streamLength += storedLength
        }
        if streamLength > Int32.max { throw ConversionError("The WOFF2 file is too large.") }
        var selected = entries
        if flavor == SfntFont.collectionTag {
            _ = try r.u32(); let fonts = try r.read255UInt16()
            if fonts == 0 { throw ConversionError("The WOFF2 font collection is empty.") }
            for member in 0..<fonts {
                let count = try r.read255UInt16(), fontFlavor = try r.u32(), indices = try (0..<count).map { _ in try r.read255UInt16() }
                if indices.contains(where: { $0 >= entries.count }) { throw ConversionError("The WOFF2 font collection is damaged.") }
                if member == 0 { flavor = fontFlavor; selected = indices.map { entries[$0] } }
            }
        }
        guard [SfntFont.trueTypeFlavor, SfntFont.cffFlavor, SfntFont.appleTrueTypeFlavor].contains(flavor) else { throw ConversionError("The WOFF2 file contains an unknown kind of font.") }
        if compressedLength > data.count - r.position { throw ConversionError("The WOFF2 file is truncated.") }
        let stream = try decompress(r.bytes(compressedLength), streamLength)
        try Task.checkCancellation()
        let font = SfntFont(flavor == SfntFont.appleTrueTypeFlavor ? SfntFont.trueTypeFlavor : flavor)
        for entry in selected where !entry.transformed { font.tables[entry.tag] = stream.subdata(in: entry.offset..<entry.offset + entry.storedLength) }
        let glyfEntry = selected.first { $0.tag == "glyf" }, locaEntry = selected.first { $0.tag == "loca" }
        if (glyfEntry == nil) != (locaEntry == nil) || glyfEntry?.transformed != locaEntry?.transformed { throw ConversionError("The WOFF2 'glyf' and 'loca' tables don't match.") }
        var xMins: [Int]?
        if let entry = glyfEntry, entry.transformed {
            let (glyf, loca, longLoca, mins) = try Woff2Transforms.reconstructGlyf(stream, entry.offset, entry.storedLength)
            font.tables["glyf"] = glyf; font.tables["loca"] = loca; font.tables["head"] = try FontTables.withIndexToLocFormat(font.require("head"), longLoca); xMins = mins
        }
        if let entry = selected.first(where: { $0.tag == "hmtx" && $0.transformed }) {
            guard let xMins = xMins else { throw ConversionError("The WOFF2 'hmtx' table is transformed without 'glyf'.") }
            font.tables["hmtx"] = try Woff2Transforms.reconstructHmtx(stream, entry.offset, entry.storedLength, font.glyphCount, FontTables.numberOfMetrics(font.require("hhea")), xMins)
        }
        return font
    }
    /// Brotli at the highest quality (11, window 22) with Google's encoder, like Filee's BrotliEncoder. That takes about
    /// 10 s per MB, so the data is fed in chunks to report progress and honour cancellation (same result as one call).
    static func compress(_ data: Data, _ progress: ProgressHandler? = nil) throws -> Data {
        let failure = "Brotli compression failed."
        guard let encoder = BrotliEncoderCreateInstance(nil, nil, nil) else { throw ConversionError(failure) }
        defer { BrotliEncoderDestroyInstance(encoder) }
        guard BrotliEncoderSetParameter(encoder, BROTLI_PARAM_QUALITY, 11) == BROTLI_TRUE,
              BrotliEncoderSetParameter(encoder, BROTLI_PARAM_LGWIN, 22) == BROTLI_TRUE else { throw ConversionError(failure) }
        let chunk = 256 * 1024
        var output = Data()
        output.reserveCapacity(data.count / 2 + 64)
        var buffer = [UInt8](repeating: 0, count: chunk)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while true {
                let take = min(chunk, data.count - offset), final = offset + take == data.count
                var availableIn = take
                var nextIn: UnsafePointer<UInt8>? = raw.bindMemory(to: UInt8.self).baseAddress.map { $0 + offset }
                repeat {
                    let written: Int = try buffer.withUnsafeMutableBufferPointer { out in
                        var availableOut = chunk
                        var nextOut: UnsafeMutablePointer<UInt8>? = out.baseAddress
                        guard BrotliEncoderCompressStream(encoder, final ? BROTLI_OPERATION_FINISH : BROTLI_OPERATION_PROCESS,
                                                          &availableIn, &nextIn, &availableOut, &nextOut, nil) == BROTLI_TRUE else {
                            throw ConversionError(failure)
                        }
                        return chunk - availableOut
                    }
                    output.append(contentsOf: buffer[0..<written])
                } while availableIn > 0 || BrotliEncoderHasMoreOutput(encoder) == BROTLI_TRUE || (final && BrotliEncoderIsFinished(encoder) != BROTLI_TRUE)
                offset += take
                if final { return }
                try Task.checkCancellation()
                progress?(Double(offset) / Double(data.count))
            }
        }
        return output
    }
    static func decompress(_ data: Data, _ length: Int) throws -> Data { try brotli(data, encode: false, expectedLength: length, progress: nil) }
    private static func brotli(_ data: Data, encode: Bool, expectedLength: Int?, progress: ProgressHandler?) throws -> Data {
        let failure = encode ? "Brotli compression failed." : "The WOFF2 font data can't be decompressed (the file is damaged)."
        let chunk = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk); defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: chunk, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, encode ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK else { throw ConversionError(failure) }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        try data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            var offset = 0
            while true {
                let take = min(chunk, data.count - offset), final = offset + take == data.count
                stream.src_ptr = base.advanced(by: offset); stream.src_size = take
                var status: compression_status
                repeat {
                    stream.dst_ptr = buffer; stream.dst_size = chunk
                    let before = stream.src_size
                    status = compression_stream_process(&stream, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = chunk - stream.dst_size
                    guard status != COMPRESSION_STATUS_ERROR, status == COMPRESSION_STATUS_END || produced > 0 || stream.src_size < before else { throw ConversionError(failure) }
                    output.append(buffer, count: produced)
                    if let length = expectedLength, output.count > length { throw ConversionError(failure) }
                } while status != COMPRESSION_STATUS_END && (stream.src_size > 0 || stream.dst_size == 0 || final)
                offset += take
                if status == COMPRESSION_STATUS_END {
                    if let length = expectedLength, output.count != length { throw ConversionError(failure) }
                    return
                }
                if final { throw ConversionError(failure) }
                if encode { try Task.checkCancellation(); progress?(Double(offset) / Double(data.count)) }
            }
        }
        return output
    }
}
