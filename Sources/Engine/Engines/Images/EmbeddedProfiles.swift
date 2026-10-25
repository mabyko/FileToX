// The ICC profiles source files other than JPEG and PNG (read in JpegEncoder and ImageEncoder) embed where ImageIO
// looks for them. `CodecPixels.sourceProfile` matches them with the colour space ImageIO decoded each picture in, so
// writers repeat the exact source bytes and never ImageIO's defaults for untagged pictures.

import Foundation
import libjxl

enum EmbeddedProfiles {
    /// Most profile bytes read from one file: far more than any real profile (a JPEG holds at most 255 × 65519).
    static let budget = 1 << 24

    /// The valid profiles of `file` for each of the `count` pictures ImageIO reads from it (one list for all of them when
    /// the format stores one per file), and whether it declares colour without ICC: HEIF/AVIF nclx, JPEG XL's enumerated
    /// colour or a JPEG 2000 enumerated colourspace. Nil for other formats, for files whose pictures can't be matched
    /// with ImageIO's and above the budget: the profile then stays inferred.
    static func read(_ file: Data, format: String, count: Int) -> (profiles: [[Data]], declared: Bool)? {
        switch format {
        case "tiff": tiff(file, count: count).map { ($0, false) }
        case "psd", "psb": PsdCodec.profiles(file).map { ([$0], false) }
        case "webp": webp(file).map { ([$0], false) }
        case "gif": gif(file).map { ([$0], false) }
        case "heic", "avif": heif(file)
        case "jxl": jxl(file)
        case "jp2": jp2(file)
        case "tga": ([[]], false) // the format has no profile
        default: nil
        }
    }

    /// TIFF: the InterColorProfile tag (34675) of every picture in the main IFD chain, when the chain has as many
    /// pictures as ImageIO reads. BigTIFF is not read.
    private static func tiff(_ file: Data, count: Int) -> [[Data]]? {
        guard file.count >= 8, file[file.startIndex] == file[file.startIndex + 1], [0x49, 0x4D].contains(file[file.startIndex]) else { return nil }
        let little = file[file.startIndex] == 0x49
        func number(_ at: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 << 8 | Int(file[file.startIndex + at + (little ? size - 1 - $1 : $1)]) }
        }
        guard number(2, 2) == 42 else { return nil }
        var profiles: [[Data]] = [], seen = Set<Int>(), ifd = number(4, 4), left = budget
        while ifd != 0 {
            // Room for the entry count and the next directory's offset.
            guard profiles.count < count, ifd >= 8, ifd <= file.count - 6, seen.insert(ifd).inserted else { return nil }
            let entries = number(ifd, 2)
            guard entries <= (file.count - ifd - 6) / 12 else { return nil }
            var found: [Data] = []
            for entry in (0..<entries).map({ ifd + 2 + 12 * $0 }) where number(entry, 2) == 34675 && [1, 7].contains(number(entry + 2, 2)) {
                let size = number(entry + 4, 4), offset = size <= 4 ? entry + 8 : number(entry + 8, 4)
                guard size <= left, offset <= file.count - size else { return nil }
                left -= size
                if let valid = CodecPixels.validProfile(file.subdata(in: file.startIndex + offset..<file.startIndex + offset + size)) {
                    found.append(valid)
                }
            }
            profiles.append(found)
            ifd = number(ifd + 2 + 12 * entries, 4)
        }
        return profiles.count == count ? profiles : nil
    }

    /// WebP: the ICCP chunk, the profile of every frame.
    private static func webp(_ file: Data) -> [Data]? {
        guard file.count >= 12, file.starts(with: Array("RIFF".utf8)), file.dropFirst(8).starts(with: Array("WEBP".utf8)) else { return nil }
        var i = file.startIndex + 12
        while file.endIndex - i >= 8 {
            let size = file[i + 4..<i + 8].reversed().reduce(0) { $0 << 8 | Int($1) }
            guard size <= file.endIndex - i - 8 else { break }
            if file[i..<i + 4].elementsEqual("ICCP".utf8) {
                guard size <= budget else { return nil }
                return CodecPixels.validProfile(file.subdata(in: i + 8..<i + 8 + size)).map { [$0] } ?? []
            }
            i += 8 + size + size % 2
        }
        return []
    }

    /// GIF: the ICC application extension ("ICCRGBG1" "012") before the first picture, the profile of every frame.
    private static func gif(_ file: Data) -> [Data]? {
        let bytes = file.startIndex, end = file.endIndex
        guard file.count >= 13, file.starts(with: Array("GIF87a".utf8)) || file.starts(with: Array("GIF89a".utf8)) else { return nil }
        var i = bytes + 13 + (file[bytes + 10] & 0x80 != 0 ? 3 << (Int(file[bytes + 10] & 7) + 1) : 0)
        while i + 2 < end, file[i] == 0x21 {
            var block = i + 2, profile: Data?
            if file[i + 1] == 0xFF, block + 12 <= end, file[block] == 11, file[block + 1..<block + 12].elementsEqual("ICCRGBG1012".utf8) {
                profile = Data()
                block += 12
            }
            // The extension's sub-blocks: a size byte, then that many bytes, up to a zero size.
            while block < end, file[block] != 0 {
                let size = Int(file[block])
                guard block + 1 + size <= end else { return nil }
                if profile != nil {
                    guard profile!.count + size <= budget else { return nil }
                    profile! += file[block + 1..<block + 1 + size]
                }
                block += 1 + size
            }
            if let profile { return CodecPixels.validProfile(profile).map { [$0] } ?? [] }
            i = block + 1
        }
        return []
    }

    /// The boxes of an ISO base media file (HEIF, AVIF, JPEG 2000) between `start` and `end`: type and payload.
    private static func boxes(_ file: Data, _ start: Int, _ end: Int) -> [(type: String, payload: Range<Int>)] {
        var result: [(String, Range<Int>)] = [], i = start
        while end - i >= 8 {
            var size = file[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }, header = 8
            if size == 1 {
                guard end - i >= 16 else { break }
                let large = file[i + 8..<i + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard large <= UInt64(end - i) else { break }
                (size, header) = (Int(large), 16)
            } else if size == 0 {
                size = end - i
            }
            guard size >= header, size <= end - i else { break }
            result.append((String(decoding: file[i + 4..<i + 8], as: UTF8.self), i + header..<i + size))
            i += size
        }
        return result
    }

    /// HEIF/AVIF: the colr properties of the primary item and of the items it is derived from (grid tiles): "prof" and
    /// "rICC" hold a profile, "nclx" declares colour by code points.
    private static func heif(_ file: Data) -> (profiles: [[Data]], declared: Bool)? {
        guard let meta = boxes(file, file.startIndex, file.endIndex).first(where: { $0.type == "meta" })?.payload, meta.count >= 4 else { return nil }
        func number(_ at: Int, _ size: Int) -> Int? { at >= file.startIndex && size <= file.endIndex - at ? file[at..<at + size].reduce(0) { $0 << 8 | Int($1) } : nil }
        var primary: Int?, sources: [Int: [Int]] = [:], properties: [(type: String, payload: Range<Int>)] = [], associations: [Int: [Int]] = [:]
        for box in boxes(file, meta.lowerBound + 4, meta.upperBound) {
            let version = box.payload.isEmpty ? 0 : Int(file[box.payload.lowerBound])
            switch box.type {
            case "pitm":
                primary = number(box.payload.lowerBound + 4, version == 0 ? 2 : 4)
            case "iref":
                for reference in boxes(file, box.payload.lowerBound + 4, box.payload.upperBound) where reference.type == "dimg" {
                    let id = version == 0 ? 2 : 4
                    guard let from = number(reference.payload.lowerBound, id), let count = number(reference.payload.lowerBound + id, 2) else { continue }
                    sources[from, default: []] += (0..<count).compactMap { number(reference.payload.lowerBound + id + 2 + id * $0, id) }
                }
            case "iprp":
                for child in boxes(file, box.payload.lowerBound, box.payload.upperBound) {
                    if child.type == "ipco" { properties = boxes(file, child.payload.lowerBound, child.payload.upperBound) }
                    guard child.type == "ipma", child.payload.count >= 8, let entries = number(child.payload.lowerBound + 4, 4) else { continue }
                    let childVersion = Int(file[child.payload.lowerBound]), wide = file[child.payload.lowerBound + 3] & 1 == 1
                    var at = child.payload.lowerBound + 8
                    for _ in 0..<min(entries, child.payload.count) {
                        let id = childVersion < 1 ? 2 : 4
                        guard let item = number(at, id), let count = number(at + id, 1), at + id + 1 + count * (wide ? 2 : 1) <= child.payload.upperBound else { break }
                        at += id + 1
                        associations[item, default: []] += (0..<count).compactMap { number(at + $0 * (wide ? 2 : 1), wide ? 2 : 1).map { $0 & (wide ? 0x7FFF : 0x7F) } }
                        at += count * (wide ? 2 : 1)
                    }
                }
            default:
                break
            }
        }
        guard let primary else { return nil }
        var profiles: [Data] = [], declared = false, left = budget
        for index in Set(([primary] + (sources[primary] ?? [])).flatMap { associations[$0] ?? [] }).sorted() where index >= 1 && index <= properties.count {
            let colr = properties[index - 1]
            guard colr.type == "colr", colr.payload.count >= 4 else { continue }
            switch String(decoding: file[colr.payload.lowerBound..<colr.payload.lowerBound + 4], as: UTF8.self) {
            case "nclx":
                declared = true
            case "prof", "rICC":
                guard colr.payload.count - 4 <= left else { return nil }
                left -= colr.payload.count - 4
                if let valid = CodecPixels.validProfile(file.subdata(in: colr.payload.lowerBound + 4..<colr.payload.upperBound)) { profiles.append(valid) }
            default:
                break
            }
        }
        return ([profiles], declared)
    }

    /// JPEG XL: the profile libjxl reads from the codestream header; a colour encoded by enumerated values has none.
    private static func jxl(_ file: Data) -> (profiles: [[Data]], declared: Bool)? {
        guard let decoder = JxlDecoderCreate(nil) else { return nil }
        defer { JxlDecoderDestroy(decoder) }
        guard JxlDecoderSubscribeEvents(decoder, Int32(JXL_DEC_COLOR_ENCODING.rawValue)) == JXL_DEC_SUCCESS else { return nil }
        return file.withUnsafeBytes { raw -> (profiles: [[Data]], declared: Bool)? in
            guard JxlDecoderSetInput(decoder, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) == JXL_DEC_SUCCESS else { return nil }
            JxlDecoderCloseInput(decoder)
            guard JxlDecoderProcessInput(decoder) == JXL_DEC_COLOR_ENCODING else { return nil }
            if JxlDecoderGetColorAsEncodedProfile(decoder, JXL_COLOR_PROFILE_TARGET_ORIGINAL, nil) == JXL_DEC_SUCCESS { return ([[]], true) }
            var size = 0
            guard JxlDecoderGetICCProfileSize(decoder, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &size) == JXL_DEC_SUCCESS, size <= budget else { return nil }
            var profile = [UInt8](repeating: 0, count: size)
            guard JxlDecoderGetColorAsICCProfile(decoder, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &profile, size) == JXL_DEC_SUCCESS else { return nil }
            return ([CodecPixels.validProfile(Data(profile)).map { [$0] } ?? []], false)
        }
    }

    /// JPEG 2000: the colr boxes of the JP2 header. Method 2 and 3 hold a profile; method 1 enumerates a colourspace, of
    /// which sRGB (16) and greyscale (17) are the defaults a JP2 must name when it has no profile.
    private static func jp2(_ file: Data) -> (profiles: [[Data]], declared: Bool)? {
        guard let header = boxes(file, file.startIndex, file.endIndex).first(where: { $0.type == "jp2h" })?.payload else { return ([[]], false) }
        var profiles: [Data] = [], declared = false, left = budget
        for colr in boxes(file, header.lowerBound, header.upperBound) where colr.type == "colr" && colr.payload.count >= 3 {
            switch file[colr.payload.lowerBound] {
            case 1:
                let space = colr.payload.count >= 7 ? file[colr.payload.lowerBound + 3..<colr.payload.lowerBound + 7].reduce(0) { $0 << 8 | Int($1) } : 0
                declared = declared || ![16, 17].contains(space)
            case 2, 3:
                guard colr.payload.count - 3 <= left else { return nil }
                left -= colr.payload.count - 3
                if let valid = CodecPixels.validProfile(file.subdata(in: colr.payload.lowerBound + 3..<colr.payload.upperBound)) { profiles.append(valid) }
            default:
                break
            }
        }
        return ([profiles], declared)
    }
}
