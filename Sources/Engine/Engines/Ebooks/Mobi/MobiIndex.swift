// Port of Filee.Engines/Ebooks/Mobi/MobiIndex.cs.
import Foundation

struct MobiIndexEntry {
    let key: String
    let tags: [Int: [Int]]
    func tag(_ tag: Int, _ position: Int = 0) -> Int {
        guard let values = tags[tag], position >= 0, position < values.count else { return -1 }
        return values[position]
    }
}

enum MobiIndex {
    private struct TagDefinition {
        let tag: Int, valuesPerEntry: Int, mask: Int
        let endFlag: Bool
    }

    static func read(_ database: PalmDatabase, _ first: Int, _ strings: inout [Int: String]) throws -> [MobiIndexEntry] {
        var entries: [MobiIndexEntry] = []
        let primary = database.record(first)
        guard primary.count >= 56, primary.prefix(4) == Data("INDX".utf8) else { throw ConversionError("The book's index is damaged.") }
        let headerLength = PalmDatabase.u32(primary, 4)
        let recordCount = PalmDatabase.u32(primary, 24)
        let cncxCount = max(0, PalmDatabase.u32(primary, 52))
        let (controlBytes, tags) = try tagTable(primary, headerLength)
        for c in 0..<cncxCount {
            let cncx = database.record(first + recordCount + 1 + c)
            var offset = 0
            while offset < cncx.count && cncx[offset] != 0 {
                let start = offset
                var (length, consumed) = forwardVarint(cncx, offset)
                offset += consumed
                length = min(length, cncx.count - offset)
                guard length >= 0 else { throw ConversionError("The book's index is damaged.") }
                strings[c * 0x10000 + start] = String(decoding: cncx.subdata(in: offset..<offset + length), as: UTF8.self)
                offset += length
            }
        }
        for r in 0..<max(0, recordCount) {
            let record = database.record(first + r + 1)
            guard record.count >= 28, record.prefix(4) == Data("INDX".utf8) else { continue }
            let idxt = PalmDatabase.u32(record, 20), count = PalmDatabase.u32(record, 24)
            guard idxt >= 0, count >= 0, idxt + 4 + count * 2 <= record.count else { continue }
            var offsets = (0..<count).map { PalmDatabase.u16(record, idxt + 4 + $0 * 2) }
            offsets.append(idxt)
            for i in 0..<count {
                let start = offsets[i]
                if start >= record.count { continue }
                let keyLength = Int(record[start])
                let key = TextEncodings.decode(record.subdata(in: start + 1..<start + 1 + min(keyLength, record.count - start - 1)), encoding: .isoLatin1)
                let values = tagValues(record, start + 1 + keyLength, offsets[i + 1], controlBytes, tags)
                entries.append(MobiIndexEntry(key: key, tags: values))
            }
        }
        return entries
    }

    private static func tagTable(_ record: Data, _ start: Int) throws -> (Int, [TagDefinition]) {
        guard start >= 0, start + 12 <= record.count, record.subdata(in: start..<start + 4) == Data("TAGX".utf8) else {
            throw ConversionError("The book's index has no tag table.")
        }
        let length = PalmDatabase.u32(record, start + 4), controlBytes = PalmDatabase.u32(record, start + 8)
        var tags: [TagDefinition] = []
        var i = 12
        while i + 4 <= length && start + i + 4 <= record.count {
            let p = start + i
            tags.append(TagDefinition(tag: Int(record[p]), valuesPerEntry: Int(record[p + 1]), mask: Int(record[p + 2]), endFlag: record[p + 3] == 1))
            i += 4
        }
        return (controlBytes, tags)
    }

    private static func tagValues(_ record: Data, _ start: Int, _ end: Int, _ controlBytes: Int, _ tags: [TagDefinition]) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        var controlIndex = 0, position = start + controlBytes
        var headers: [(tag: Int, count: Int?, bytes: Int?, perEntry: Int)] = []
        for tag in tags {
            if tag.endFlag { controlIndex += 1; continue }
            if start + controlIndex < 0 || start + controlIndex >= record.count { break }
            var value = Int(record[start + controlIndex]) & tag.mask
            if value == 0 { continue }
            if value == tag.mask {
                if tag.mask.nonzeroBitCount > 1 {
                    let (bytes, consumed) = forwardVarint(record, position)
                    position += consumed
                    headers.append((tag.tag, nil, bytes, tag.valuesPerEntry))
                } else { headers.append((tag.tag, 1, nil, tag.valuesPerEntry)) }
            } else {
                var mask = tag.mask
                while mask & 1 == 0 { mask >>= 1; value >>= 1 }
                headers.append((tag.tag, value, nil, tag.valuesPerEntry))
            }
        }
        for (tag, count, bytes, perEntry) in headers {
            var values: [Int] = []
            if let groups = count {
                for _ in 0..<max(0, groups * perEntry) where position < end {
                    let (value, consumed) = forwardVarint(record, position)
                    position += consumed; values.append(value)
                }
            } else {
                var read = 0
                while read < (bytes ?? 0) && position < end {
                    let (value, consumed) = forwardVarint(record, position)
                    position += consumed; read += consumed; values.append(value)
                }
            }
            result[tag] = values
        }
        return result
    }

    static func forwardVarint(_ data: Data, _ offset: Int) -> (value: Int, consumed: Int) {
        var value = 0, consumed = 0
        while offset >= 0 && offset + consumed < data.count && consumed < 9 {
            let b = data[offset + consumed]; consumed += 1
            value = (value &<< 7) | Int(b & 0x7F)
            if b & 0x80 != 0 { break }
        }
        return (value, max(1, consumed))
    }
}
