// Port of Filee.Engines/Office/Sheets/XlsLayout.cs; OLE2 stream and BIFF records are also used by XlsReader.
import Foundation

enum XlsLayout {
    struct Sheet {
        var columns: [Int: (width: Double, hidden: Bool)] = [:]
        var rows: [Int: (points: Double, custom: Bool, hidden: Bool)] = [:]
    }
    struct Record {
        let id: Int
        let data: [UInt8]
    }
    static func u16(_ b: [UInt8], _ p: Int = 0) -> Int {
        p >= 0 && p + 2 <= b.count ? Int(b[p]) | Int(b[p + 1]) << 8 : 0
    }
    static func u32(_ b: [UInt8], _ p: Int = 0) -> UInt32 {
        p >= 0 && p + 4 <= b.count
            ? UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24 : 0
    }
    static func double(_ b: [UInt8], _ p: Int) -> Double {
        Double(bitPattern: UInt64(u32(b, p)) | UInt64(u32(b, p + 4)) << 32)
    }
    static func records(_ stream: [UInt8], _ offset: Int) throws -> [Record] {
        guard offset >= 0, offset + 4 <= stream.count, [0x0009, 0x0209, 0x0409, 0x0809].contains(u16(stream, offset))
        else { throw ConversionError("The Excel 97–2003 workbook could not be read: Invalid BIFF substream.") }
        var result: [Record] = []
        var p = offset
        while p + 4 <= stream.count {
            let id = u16(stream, p)
            let count = u16(stream, p + 2)
            if id == 0x000a || [0x0009, 0x0209, 0x0409, 0x0809].contains(id) && p != offset { return result }
            guard count <= stream.count - p - 4 else {
                throw ConversionError("The Excel 97–2003 workbook could not be read: Truncated BIFF record.")
            }
            result.append(Record(id: id, data: Array(stream[(p + 4)..<(p + 4 + count)])))
            p += 4 + count
            if result.count % 1024 == 0 { try Task.checkCancellation() }
        }
        return result
    }
    static func read(_ path: String) -> [Sheet]? {
        guard let bytes = try? workbookStream(Array(Data(contentsOf: URL(fileURLWithPath: path)))),
            let records = try? records(bytes, 0), !records.contains(where: { $0.id == 0x002f })
        else { return nil }
        return try? records.filter { $0.id == 0x0085 && $0.data.count >= 6 && $0.data[5] == 0 }.map { record in
            parse(try Self.records(bytes, Int(u32(record.data))))
        }
    }
    static func parse(_ records: [Record]) -> Sheet {
        var sheet = Sheet()
        for record in records {
            let d = record.data
            if record.id == 0x007d && d.count >= 10 {
                let first = u16(d)
                let last = min(u16(d, 2), 16383)
                let width = Double(u16(d, 4)) / 256
                let hidden = d[8] & 1 != 0 || width == 0
                if last >= first { for c in first...last { sheet.columns[c] = (width, hidden) } }
            } else if record.id == 0x0208 && d.count >= 14 {
                let flags = u16(d, 12)
                sheet.rows[u16(d)] = (Double(u16(d, 6) & 0x7fff) / 20, flags & 0x40 != 0, flags & 0x20 != 0)
            }
        }
        return sheet
    }
    static func workbookStream(_ file: [UInt8]) throws -> [UInt8]? {
        guard file.count >= 512, Array(file.prefix(8)) == [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1] else {
            return nil
        }
        let shift = u16(file, 30)
        let miniShift = u16(file, 32)
        guard [9, 12].contains(shift), miniShift >= 3, miniShift <= shift else { return nil }
        let size = 1 << shift
        let miniSize = 1 << miniShift
        let count = file.count / size
        let last: UInt32 = 0xffff_fffa
        func sector(_ index: UInt32) -> [UInt8] {
            let start = (Int(index) + 1) * size
            return start >= file.count ? [] : Array(file[start..<min(file.count, start + size)])
        }
        var fatSectors = (0..<109).map { u32(file, 76 + $0 * 4) }
        var difat = u32(file, 68)
        var visited = Set<UInt32>()
        while difat < last && fatSectors.count < count * 2 {
            guard visited.insert(difat).inserted else { return nil }
            let s = sector(difat)
            if s.count < size { return nil }
            for p in stride(from: 0, to: size - 4, by: 4) { fatSectors.append(u32(s, p)) }
            difat = u32(s, size - 4)
        }
        var fat: [UInt32] = []
        for i in fatSectors where i < last {
            let s = sector(i)
            fat += stride(from: 0, to: s.count - s.count % 4, by: 4).map { u32(s, $0) }
        }
        func chain(_ start: UInt32, _ table: [UInt32], _ read: (UInt32) -> [UInt8]) throws -> [UInt8] {
            var bytes: [UInt8] = []
            var s = start
            var visited = Set<UInt32>()
            while s < last {
                try Task.checkCancellation()
                guard Int(s) < table.count, visited.insert(s).inserted else {
                    throw ConversionError("The Excel 97–2003 workbook could not be read: Invalid compound file chain.")
                }
                let block = read(s)
                guard !block.isEmpty else {
                    throw ConversionError("The Excel 97–2003 workbook could not be read: Truncated compound file.")
                }
                bytes += block
                s = table[Int(s)]
            }
            return bytes
        }
        let directory = try chain(u32(file, 48), fat, sector)
        var workbook: (UInt32, Int)?
        for p in stride(from: 0, to: directory.count - directory.count % 128, by: 128) {
            let length = min(max(u16(directory, p + 64) - 2, 0), 62)
            let name = String(
                decoding: stride(from: p, to: p + length - length % 2, by: 2).map { UInt16(u16(directory, $0)) },
                as: UTF16.self)
            if directory[p + 66] == 2 && ["workbook", "book"].contains(name.lowercased()) {
                workbook = (u32(directory, p + 116), Int(u32(directory, p + 120)))
                break
            }
        }
        guard let (start, length) = workbook, directory.count >= 128 else { return nil }
        let bytes: [UInt8]
        if length < Int(u32(file, 56)) {
            let miniStream = try chain(u32(directory, 116), fat, sector)
            let miniFatData = try chain(u32(file, 60), fat, sector)
            let miniFat = stride(from: 0, to: miniFatData.count - miniFatData.count % 4, by: 4).map {
                u32(miniFatData, $0)
            }
            bytes = try chain(start, miniFat) { s in
                let p = Int(s) * miniSize
                return p + miniSize <= miniStream.count ? Array(miniStream[p..<p + miniSize]) : []
            }
        } else {
            bytes = try chain(start, fat, sector)
        }
        guard bytes.count >= length else {
            throw ConversionError("The Excel 97–2003 workbook could not be read: Truncated workbook stream.")
        }
        return Array(bytes.prefix(length))
    }
}
