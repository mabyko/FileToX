// Port of Filee.Engines/Ebooks/Mobi/HuffCdic.cs.
import Foundation

final class HuffCdic {
    private var table1 = [(length: Int, terminal: Bool, maxCode: UInt64)](repeating: (0, false, 0), count: 256)
    private var minCode = [UInt64](repeating: 0, count: 33)
    private var maxCode = [UInt64](repeating: 0, count: 33)
    private var phrases: [Phrase] = []

    private final class Phrase {
        var data: Data
        var unpacked: Bool
        var busy = false
        init(_ data: Data, _ unpacked: Bool) { self.data = data; self.unpacked = unpacked }
    }

    init(_ huff: Data, _ cdics: [Data]) throws {
        let damaged = ConversionError("The book's HUFF compression table is damaged.")
        guard huff.count >= 24, huff.prefix(4) == Data("HUFF".utf8) else { throw damaged }
        let table1 = Int(BinaryPrimitives.readUInt32BigEndian(huff, 8))
        let table2 = Int(BinaryPrimitives.readUInt32BigEndian(huff, 12))
        guard table1 + 256 * 4 <= huff.count, table2 + 64 * 4 <= huff.count else { throw damaged }
        for i in 0..<256 {
            let value = BinaryPrimitives.readUInt32BigEndian(huff, table1 + i * 4)
            let length = Int(value & 0x1F)
            guard length != 0 else { throw damaged }
            self.table1[i] = (length, value & 0x80 != 0, ((UInt64(value >> 8) + 1) << (32 - length)) - 1)
        }
        for length in 1...32 {
            let min = BinaryPrimitives.readUInt32BigEndian(huff, table2 + (length - 1) * 8)
            let max = BinaryPrimitives.readUInt32BigEndian(huff, table2 + (length - 1) * 8 + 4)
            minCode[length] = UInt64(min) << (32 - length)
            maxCode[length] = ((UInt64(max) + 1) << (32 - length)) - 1
        }
        for cdic in cdics {
            guard cdic.count >= 16, cdic.prefix(4) == Data("CDIC".utf8) else {
                throw ConversionError("The book's CDIC dictionary is damaged.")
            }
            let total = Int(BinaryPrimitives.readUInt32BigEndian(cdic, 8))
            let bits = Int(BinaryPrimitives.readUInt32BigEndian(cdic, 12))
            let count = min(1 << min(20, max(0, bits)), total - phrases.count)
            for i in 0..<max(0, count) {
                let offset = 16 + PalmDatabase.u16(cdic, 16 + i * 2)
                let header = PalmDatabase.u16(cdic, offset)
                let length = min(header & 0x7FFF, max(0, cdic.count - offset - 2))
                guard offset + 2 <= cdic.count else { throw ConversionError("The book's CDIC dictionary is damaged.") }
                phrases.append(Phrase(cdic.subdata(in: offset + 2..<offset + 2 + length), header & 0x8000 != 0))
            }
        }
    }

    func decompress(_ data: Data) throws -> Data {
        var output = Data()
        try unpack(data, &output, 0)
        return output
    }

    private func unpack(_ data: Data, _ output: inout Data, _ depth: Int) throws {
        guard depth <= 32 else { throw ConversionError("The book's CDIC dictionary refers to itself.") }
        let padded = data + Data(repeating: 0, count: 8)
        var bitsLeft = data.count * 8
        var position = 0
        var window = BinaryPrimitives.readUInt64BigEndian(padded)
        var n = 32
        while true {
            if n <= 0 {
                position += 4
                window = position + 8 <= padded.count ? BinaryPrimitives.readUInt64BigEndian(padded, position) : 0
                n += 32
            }
            let code = (window >> n) & 0xFFFFFFFF
            var (length, terminal, maxCode) = table1[Int(code >> 24)]
            if !terminal {
                while length < 32 && code < minCode[length] { length += 1 }
                maxCode = self.maxCode[length]
            }
            n -= length; bitsLeft -= length
            if bitsLeft < 0 { break }
            let index = (maxCode &- code) >> (32 - length)
            guard index < phrases.count else { throw ConversionError("The book's compressed text is damaged.") }
            let phrase = phrases[Int(index)]
            if !phrase.unpacked {
                guard !phrase.busy else { throw ConversionError("The book's CDIC dictionary refers to itself.") }
                phrase.busy = true
                var unpacked = Data()
                try unpack(phrase.data, &unpacked, depth + 1)
                phrase.data = unpacked; phrase.unpacked = true; phrase.busy = false
            }
            output.append(phrase.data)
        }
    }
}
