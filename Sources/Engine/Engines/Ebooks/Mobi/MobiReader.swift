// Port of Filee.Engines/Ebooks/Mobi/MobiReader.cs. Latin-1 strings retain byte offsets for Kindle links.
import Foundation

enum MobiReader {
    static func read(_ path: String, _ workFolder: String) throws -> HDocument { try readBook(path, workFolder).document }
    static func readBook(_ path: String, _ workFolder: String) throws -> Book {
        let database = try open(path)
        let folder = try EbookFiles.newFolder(workFolder, "mobi")
        if database.typeCreator == "TEXtREAd" {
            let metadata = BookMetadata(); metadata.title = database.name
            return Book(PlainText.toDocument(decodeText(palmDocText(database))), metadata)
        }
        let header = try MobiHeader.parse(database, 0)
        if header.encryption != 0 { throw ConversionError(EbookFiles.drmMessage) }
        let metadata = header.metadata(database.name)
        let document: HDocument, resources: Resources
        let kf8Start = header.version >= 8 ? 0 : header.kf8Boundary
        if let start = kf8Start, start >= 0, start < database.count {
            let kf8 = start == 0 ? header : try MobiHeader.parse(database, start)
            if kf8.encryption != 0 { throw ConversionError(EbookFiles.drmMessage) }
            resources = Resources(database, start == 0 ? kf8.firstImage : header.firstImage, folder)
            document = try self.kf8(database, kf8, start, resources, folder)
        } else {
            resources = Resources(database, header.firstImage, folder)
            document = try mobi6(database, header, resources, folder)
        }
        if let cover = header.coverOffset, let file = try resources.save(cover) { metadata.coverImage = file }
        document.title = metadata.title
        return Book(document, metadata)
    }

    static func printReplicaPdf(_ path: String) throws -> Data {
        let database = try open(path), header = try MobiHeader.parse(database, 0)
        if header.encryption != 0 { throw ConversionError(EbookFiles.drmMessage) }
        let text = try self.text(database, header, 0)
        if text.starts(with: Data("%MOP".utf8)), text.count >= 12 {
            let tables = Int(BinaryPrimitives.readUInt32BigEndian(text, 4)), index = 8 + 4 * min(tables, 1000)
            let offset = PalmDatabase.u32(text, index), length = PalmDatabase.u32(text, index + 4)
            if offset > 0 && length > 0 && offset + length <= text.count { return text.subdata(in: offset..<offset + length) }
        }
        guard let range = text.range(of: Data("%PDF-".utf8)) else { throw ConversionError("This book is not a Print Replica (AZW4) book: it contains no PDF.") }
        return text.subdata(in: range.lowerBound..<text.count)
    }

    private static func open(_ path: String) throws -> PalmDatabase {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.starts(with: Data("CONT".utf8)) || data.starts(with: Data([0xEA]) + Data("DRMION".utf8)) {
            throw ConversionError("This is a KFX book (Kindle's newest format), which cannot be converted. Download it from Amazon as an AZW3 or MOBI file (\"Download & transfer via USB\").")
        }
        if data.starts(with: Data("TPZ".utf8)) { throw ConversionError("This is a Topaz book, which cannot be converted.") }
        let database = try PalmDatabase.open(data)
        guard ["BOOKMOBI", "TEXtREAd"].contains(database.typeCreator) else { throw ConversionError("This is not a Mobipocket or Kindle book (type \"\(database.typeCreator)\").") }
        return database
    }

    private static func text(_ database: PalmDatabase, _ header: MobiHeader, _ start: Int) throws -> Data {
        let decompress: (Data) throws -> Data
        switch header.compression {
        case 1: decompress = { $0 }
        case 2: decompress = PalmDocCompression.decompress
        case 17480:
            let huff = start + header.huffRecord
            let reader = try HuffCdic(database.record(huff), (0..<max(0, header.huffCount - 1)).map { database.recordArray(huff + 1 + $0) })
            decompress = reader.decompress
        default: throw ConversionError("The book uses an unknown compression (\(header.compression)).")
        }
        var text = Data()
        for i in 0..<header.textRecords {
            let record = database.record(start + i + 1)
            let size = record.count - trailingSize(record, header.extraFlags)
            text.append(try decompress(Data(record.prefix(max(0, size)))))
        }
        return header.textLength > 0 && header.textLength < text.count ? Data(text.prefix(header.textLength)) : text
    }

    static func trailingSize(_ record: Data, _ flags: Int) -> Int {
        var size = 0, bits = flags >> 1
        while bits != 0 {
            defer { bits >>= 1 }
            if bits & 1 == 0 { continue }
            var value = 0, shift = 0, p = record.count - size - 1
            while p >= 0 {
                let b = Int(record[p]); value |= (b & 0x7F) << shift; shift += 7
                if b & 0x80 != 0 || shift >= 28 || p == 0 { break }
                p -= 1
            }
            size += value
        }
        if flags & 1 != 0 && record.count - size - 1 >= 0 { size += Int(record[record.count - size - 1] & 3) + 1 }
        return min(record.count, max(0, size))
    }

    private static func palmDocText(_ database: PalmDatabase) -> Data {
        let header = database.record(0), compression = PalmDatabase.u16(header, 0), records = PalmDatabase.u16(header, 8)
        var text = Data()
        for i in 0..<min(records, max(0, database.count - 1)) { text.append(compression == 2 ? PalmDocCompression.decompress(database.record(i + 1)) : database.record(i + 1)) }
        return text
    }
    private static func decodeText(_ bytes: Data) -> String {
        String(data: bytes, encoding: .utf8) ?? TextEncodings.decode(bytes, encoding: TextEncodings.encoding(codePage: 1252)!)
    }

    private static let filePos = #"\bfilepos\s*=\s*['"]?0*(\d{1,12})['"]?"#
    private static let recIndex = #"\b(?:hi|lo)?recindex\s*=\s*['"]?(\d{1,9})['"]?"#
    private static func mobi6(_ database: PalmDatabase, _ header: MobiHeader, _ resources: Resources, _ folder: String) throws -> HDocument {
        let text = TextEncodings.decode(try self.text(database, header, 0), encoding: .isoLatin1)
        try Task.checkCancellation()
        let source = text as NSString, output = NSMutableString(string: text)
        let positions = Set(EbookRegex.matches(filePos, text, .caseInsensitive).compactMap { Int(EbookRegex.group($0, text, 1)) }.filter { $0 <= source.length }).sorted(by: >)
        for position in positions {
            var at = position
            let range = NSRange(location: 0, length: max(0, at))
            let open = source.range(of: "<", options: .backwards, range: range).location
            let close = source.range(of: ">", options: .backwards, range: range).location
            if open != NSNotFound && (close == NSNotFound || open > close) { at = open }
            output.insert("<a id=\"filepos\(position)\"></a>", at: at)
        }
        let inserted = output as String
        var html = EbookRegex.replace(filePos, inserted, .caseInsensitive) { "href=\"#filepos\(Int(EbookRegex.group($0, inserted, 1)) ?? 0)\"" }
        let beforeImages = html
        html = try EbookRegex.replace(recIndex, beforeImages, .caseInsensitive) {
            if let file = try resources.save((Int(EbookRegex.group($0, beforeImages, 1)) ?? 0) - 1) { return "src=\"\(FilePath.fileName(file))\"" }
            return ""
        }
        let encoding = header.codepage == 65001 ? String.Encoding.utf8 : TextEncodings.encoding(codePage: header.codepage == 0 ? 1252 : header.codepage) ?? TextEncodings.encoding(codePage: 1252)!
        let page = FilePath.combine(folder, "book.html")
        let decoded = TextEncodings.decode(html.data(using: .isoLatin1) ?? Data(), encoding: encoding)
        try (Data([0xEF, 0xBB, 0xBF]) + Data(decoded.utf8)).write(to: URL(fileURLWithPath: page))
        return try ChapterReader.read([page], FilePath.combine(folder, "~media"))
    }

    private static let kindlePos = #"kindle:pos:fid:([0-9A-Va-v]{4}):off:([0-9A-Va-v]{10})"#
    private static let kindleEmbed = #"kindle:embed:([0-9A-Va-v]{4})(?:\?mime=[^'"\)\s]*)?"#
    private static let kindleFlow = #"kindle:flow:([0-9A-Va-v]{4})(?:\?mime=([^'"\)\s]*))?"#
    private static let aid = #"\said\s*=\s*['"]([^'"]+)['"]"#
    private static let idAttribute = #"^<[^>]*\s(?:id|name)\s*=\s*['"]([^'"]*)['"]"#
    private static let aidAttribute = #"^<[^>]+\said\s*=\s*['"]([^'"]+)['"]"#
    private static let selectorAid = #"@aid='([^']+)'"#

    private static func kf8(_ database: PalmDatabase, _ header: MobiHeader, _ start: Int, _ resources: Resources, _ folder: String) throws -> HDocument {
        let text = try self.text(database, header, start)
        try Task.checkCancellation()
        var flows: [Data] = []
        if header.fdst >= 0 {
            let fdst = database.record(start + header.fdst)
            if fdst.count >= 12 && fdst.prefix(4) == Data("FDST".utf8) {
                let tableOffset = PalmDatabase.u32(fdst, 4), count = PalmDatabase.u32(fdst, 8)
                for i in 0..<max(0, count) {
                    let from = min(text.count, max(0, PalmDatabase.u32(fdst, tableOffset + i * 8)))
                    let to = min(text.count, max(from, PalmDatabase.u32(fdst, tableOffset + i * 8 + 4)))
                    flows.append(text.subdata(in: from..<to))
                }
            }
        }
        if flows.isEmpty { flows.append(text) }
        var strings: [Int: String] = [:]
        let skeletons = header.skeleton >= 0 ? try MobiIndex.read(database, start + header.skeleton, &strings) : []
        let fragments = header.fragment >= 0 ? try MobiIndex.read(database, start + header.fragment, &strings) : []
        let parts = assemble(flows[0], skeletons, fragments, strings)
        var texts = parts.map { TextEncodings.decode($0.text, encoding: .isoLatin1) }
        let insertPositions = fragments.map { Int($0.key.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        var linkedAids: Set<String> = []
        var files: [String] = []
        for i in texts.indices {
            let source = texts[i]
            var xhtml = EbookRegex.replace(kindlePos, source) { match in
                let fragment = base32(EbookRegex.group(match, source, 1))
                let position = (fragment < insertPositions.count ? insertPositions[fragment] : 0) + base32(EbookRegex.group(match, source, 2))
                guard let part = parts.firstIndex(where: { position >= $0.start && position < $0.start + $0.text.count }) else { return partName(0) }
                let id = idBefore(texts[part], position - parts[part].start, &linkedAids)
                return id.isEmpty ? partName(part) : "\(partName(part))#\(id)"
            }
            let beforeEmbed = xhtml
            xhtml = try EbookRegex.replace(kindleEmbed, beforeEmbed) { match in
                if let file = try resources.save(base32(EbookRegex.group(match, beforeEmbed, 1)) - 1) { return FilePath.fileName(file) }
                return "missing"
            }
            let beforeFlow = xhtml
            xhtml = try EbookRegex.replace(kindleFlow, beforeFlow) { try flow(flows, base32(EbookRegex.group($0, beforeFlow, 1)), EbookRegex.group($0, beforeFlow, 2), folder) }
            texts[i] = xhtml
        }
        for i in texts.indices {
            let source = texts[i]
            let xhtml = linkedAids.isEmpty ? source : EbookRegex.replace(aid, source) { match in
                let id = EbookRegex.group(match, source, 1), original = EbookRegex.group(match, source)
                return linkedAids.contains(id) ? "\(original) id=\"aid-\(id)\"" : original
            }
            let file = FilePath.combine(folder, partName(i))
            try (Data([0xEF, 0xBB, 0xBF]) + (xhtml.data(using: .isoLatin1) ?? Data())).write(to: URL(fileURLWithPath: file))
            files.append(file)
        }
        return try ChapterReader.read(files, FilePath.combine(folder, "~media"))
    }

    private static func partName(_ index: Int) -> String { String(format: "part%04d.xhtml", index) }
    private static func assemble(_ markup: Data, _ skeletons: [MobiIndexEntry], _ fragments: [MobiIndexEntry], _ strings: [Int: String]) -> [(text: Data, start: Int)] {
        if skeletons.isEmpty { return [(markup, 0)] }
        var parts: [(Data, Int)] = [], next = 0
        for skeleton in skeletons {
            let skeletonStart = min(markup.count, max(0, skeleton.tag(6, 0)))
            let skeletonLength = min(markup.count - skeletonStart, max(0, skeleton.tag(6, 1)))
            var part = [UInt8](markup.subdata(in: skeletonStart..<skeletonStart + skeletonLength))
            var position = skeletonStart + skeletonLength
            let count = max(0, skeleton.tag(1))
            for _ in 0..<count {
                if next >= fragments.count { break }
                let fragment = fragments[next]
                let length = min(markup.count - position, max(0, fragment.tag(6, 1)))
                let slice = markup.subdata(in: position..<position + length); position += length
                var insert = min(part.count, max(0, (Int(fragment.key.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) - skeletonStart))
                if insideTag(part, insert) { insert = afterAidTag(part, strings[fragment.tag(2)] ?? "") ?? nextTagEnd(part, insert) }
                part.insert(contentsOf: slice, at: insert)
                next += 1
            }
            parts.append((Data(part), skeletonStart))
        }
        return parts
    }
    private static func insideTag(_ text: [UInt8], _ position: Int) -> Bool {
        for i in (0..<position).reversed() {
            if text[i] == 62 { return false }
            if text[i] == 60 { return true }
        }
        return false
    }
    private static func nextTagEnd(_ text: [UInt8], _ position: Int) -> Int {
        guard let end = text[position...].firstIndex(of: 62) else { return text.count }
        return end + 1
    }
    private static func afterAidTag(_ text: [UInt8], _ selector: String) -> Int? {
        guard let match = EbookRegex.matches(selectorAid, selector).first else { return nil }
        let needle = Data("aid=\"\(EbookRegex.group(match, selector, 1))\"".utf8)
        guard let at = Data(text).range(of: needle)?.lowerBound else { return nil }
        return nextTagEnd(text, at)
    }
    private static func idBefore(_ text: String, _ position: Int, _ linkedAids: inout Set<String>) -> String {
        let text = text as NSString
        var position = min(text.length, max(0, position))
        let rest = NSRange(location: position, length: text.length - position)
        let open = text.range(of: "<", range: rest).location, close = text.range(of: ">", range: rest).location
        if close != NSNotFound && (open == position || open == NSNotFound || close < open) { position = close + 1 }
        var end = position
        while end > 0 {
            let tagEnd = text.range(of: ">", options: .backwards, range: NSRange(location: 0, length: end)).location
            if tagEnd == NSNotFound { break }
            let tagStart = text.range(of: "<", options: .backwards, range: NSRange(location: 0, length: tagEnd + 1)).location
            if tagStart == NSNotFound { break }
            let tag = text.substring(with: NSRange(location: tagStart, length: tagEnd - tagStart + 1))
            end = tagStart
            if tag.lowercased().hasPrefix("<body") { return "" }
            if tag.lowercased().hasPrefix("<meta") { continue }
            if let id = EbookRegex.matches(idAttribute, tag, .caseInsensitive).first { return EbookRegex.group(id, tag, 1) }
            if let aid = EbookRegex.matches(aidAttribute, tag, .caseInsensitive).first {
                let value = EbookRegex.group(aid, tag, 1); linkedAids.insert(value)
                return "aid-" + value
            }
        }
        return ""
    }
    private static func flow(_ flows: [Data], _ index: Int, _ mime: String, _ folder: String) throws -> String {
        if index <= 0 || index >= flows.count { return "missing" }
        let ext = mime.lowercased().contains("svg") ? "svg" : mime.lowercased().contains("css") ? "css" : "txt"
        let name = String(format: "flow%04d.%@", index, ext), file = FilePath.combine(folder, name)
        if !FileManager.default.fileExists(file) { try flows[index].write(to: URL(fileURLWithPath: file)) }
        return name
    }
    static func base32(_ text: String) -> Int {
        var value = 0
        for ch in text.uppercased().utf16 { value = value &* 32 &+ (ch <= 57 ? Int(ch) - 48 : Int(ch) - 65 + 10) }
        return value
    }

    private final class Resources {
        let database: PalmDatabase, firstImage: Int, folder: String
        private var saved: [Int: String] = [:], missing: Set<Int> = []
        init(_ database: PalmDatabase, _ firstImage: Int, _ folder: String) { self.database = database; self.firstImage = firstImage; self.folder = folder }
        func save(_ index: Int) throws -> String? {
            if firstImage < 0 || index < 0 { return nil }
            if let known = saved[index] { return known }
            if missing.contains(index) { return nil }
            let record = database.record(firstImage + index)
            let ext: String?
            if record.starts(with: [0xFF, 0xD8, 0xFF]) { ext = "jpg" }
            else if record.starts(with: [0x89, 80, 78, 71]) { ext = "png" }
            else if record.starts(with: Data("GIF8".utf8)) { ext = "gif" }
            else if record.starts(with: Data("BM".utf8)) { ext = "bmp" }
            else { ext = nil }
            guard let ext else { missing.insert(index); return nil }
            let file = FilePath.combine(folder, String(format: "image%05d.%@", index + 1, ext))
            try record.write(to: URL(fileURLWithPath: file)); saved[index] = file
            return file
        }
    }
}
