// Port of MobiHeader in Filee.Engines/Ebooks/Mobi/MobiReader.cs.
import Foundation

final class MobiHeader {
    private(set) var compression = 0, textLength = 0, textRecords = 0, encryption = 0, codepage = 1252, version = 0
    private(set) var firstImage = -1, huffRecord = 0, huffCount = 0, extraFlags = 0, fdst = -1, fragment = -1, skeleton = -1
    private(set) var kf8Boundary: Int?
    private(set) var coverOffset: Int?
    private var fullName: String?
    private var locale = 0
    private var exth: [Int: [Data]] = [:]

    static func parse(_ database: PalmDatabase, _ record: Int) throws -> MobiHeader {
        let data = database.record(record)
        guard data.count >= 16 else { throw ConversionError("The book's header is damaged.") }
        let hasMobi = data.count >= 24 && data.subdata(in: 16..<20) == Data("MOBI".utf8)
        let length = hasMobi ? PalmDatabase.u32(data, 20) : 0
        let header = MobiHeader()
        header.compression = PalmDatabase.u16(data, 0); header.textLength = PalmDatabase.u32(data, 4)
        header.textRecords = PalmDatabase.u16(data, 8); header.encryption = PalmDatabase.u16(data, 12)
        header.codepage = hasMobi ? PalmDatabase.u32(data, 28) : 1252
        header.version = hasMobi ? PalmDatabase.u32(data, 36) : 0
        header.firstImage = hasMobi ? PalmDatabase.u32(data, 108) : -1
        header.huffRecord = hasMobi ? max(0, PalmDatabase.u32(data, 112)) : 0
        header.huffCount = hasMobi ? max(0, PalmDatabase.u32(data, 116)) : 0
        header.extraFlags = hasMobi && length >= 0xE4 ? PalmDatabase.u16(data, 0xF2) : 0
        header.fdst = hasMobi && length >= 0xE4 ? PalmDatabase.u32(data, 0xC0) : -1
        header.fragment = hasMobi && length >= 0xE8 ? PalmDatabase.u32(data, 0xF8) : -1
        header.skeleton = hasMobi && length >= 0xEC ? PalmDatabase.u32(data, 0xFC) : -1
        if !hasMobi { return header }
        if header.version < 8 { header.fdst = -1; header.fragment = -1; header.skeleton = -1 }
        let nameOffset = PalmDatabase.u32(data, 84), nameLength = PalmDatabase.u32(data, 88)
        header.locale = max(0, PalmDatabase.u32(data, 92))
        if nameOffset > 0 && nameLength > 0 && nameOffset + nameLength <= data.count { header.fullName = header.decode(data.subdata(in: nameOffset..<nameOffset + nameLength)) }
        if PalmDatabase.u32(data, 128) & 0x40 != 0 && length >= 0 && 16 + length + 12 <= data.count && data.subdata(in: 16 + length..<20 + length) == Data("EXTH".utf8) {
            let count = PalmDatabase.u32(data, 16 + length + 8)
            var position = 16 + length + 12
            for _ in 0..<max(0, count) {
                if position + 8 > data.count { break }
                let type = PalmDatabase.u32(data, position), size = PalmDatabase.u32(data, position + 4)
                if size < 8 || position + size > data.count { break }
                header.exth[type, default: []].append(data.subdata(in: position + 8..<position + size))
                position += size
            }
            if let boundary = header.number(121), boundary > 0 { header.kf8Boundary = boundary }
            header.coverOffset = header.number(201)
        }
        return header
    }

    func metadata(_ databaseName: String) -> BookMetadata {
        let metadata = BookMetadata()
        metadata.title = strings(503).first ?? fullName ?? databaseName.replacingOccurrences(of: "_", with: " ")
        metadata.publisher = strings(101).first; metadata.description = strings(103).first
        metadata.language = strings(524).first ?? Self.language(locale)
        for author in strings(100) {
            for name in author.components(separatedBy: "&").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty && !metadata.authors.contains(name) { metadata.authors.append(name) }
        }
        return metadata
    }

    private func strings(_ type: Int) -> [String] {
        (exth[type] ?? []).map { decode($0).trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) }.filter { !$0.isEmpty }
    }
    private func number(_ type: Int) -> Int? {
        guard let data = exth[type]?.first, data.count == 4 else { return nil }
        let value = BinaryPrimitives.readUInt32BigEndian(data)
        return value == UInt32.max ? nil : min(Int(value), Int(Int32.max))
    }
    private func decode(_ bytes: Data) -> String {
        TextEncodings.decode(bytes, encoding: codepage == 65001 ? .utf8 : TextEncodings.encoding(codePage: 1252)!)
    }
    private static func language(_ locale: Int) -> String? {
        [0x04: "zh", 0x07: "de", 0x09: "en", 0x0A: "es", 0x0C: "fr", 0x10: "it", 0x11: "ja", 0x12: "ko", 0x13: "nl", 0x16: "pt", 0x19: "ru"][locale & 0xFF]
    }
}
