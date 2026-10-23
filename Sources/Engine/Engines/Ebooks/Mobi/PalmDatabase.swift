// Port of Filee.Engines/Ebooks/Mobi/PalmDatabase.cs.
import Foundation

final class PalmDatabase {
    private let data: Data
    private let offsets: [Int]
    let name: String
    let typeCreator: String
    var count: Int { offsets.count }

    private init(_ data: Data, _ name: String, _ typeCreator: String, _ offsets: [Int]) {
        self.data = data; self.name = name; self.typeCreator = typeCreator; self.offsets = offsets
    }

    static func open(_ data: Data) throws -> PalmDatabase {
        guard data.count >= 78 else { throw ConversionError("The file is too short to be an e-book.") }
        let count = u16(data, 76)
        guard count > 0, 78 + count * 8 <= data.count else { throw ConversionError("The e-book's record table is damaged.") }
        var offsets: [Int] = []
        for i in 0..<count {
            let offset = Int(BinaryPrimitives.readUInt32BigEndian(data, 78 + i * 8))
            guard offset <= data.count, i == 0 || offset >= offsets[i - 1] else {
                throw ConversionError("The e-book's record table is damaged.")
            }
            offsets.append(offset)
        }
        let name = TextEncodings.decode(Data(data.prefix(32)), encoding: .isoLatin1).reversed().drop(while: { $0 == "\0" }).reversed().map(String.init).joined()
        return PalmDatabase(data, name, TextEncodings.decode(data.subdata(in: 60..<68), encoding: .ascii), offsets)
    }

    func record(_ index: Int) -> Data {
        guard index >= 0, index < offsets.count else { return Data() }
        let end = index + 1 < offsets.count ? offsets[index + 1] : data.count
        return data.subdata(in: offsets[index]..<max(offsets[index], end))
    }

    func recordArray(_ index: Int) -> Data { record(index) }
    static func u16(_ data: Data, _ offset: Int) -> Int {
        offset >= 0 && offset + 2 <= data.count ? Int(BinaryPrimitives.readUInt16BigEndian(data, offset)) : 0
    }
    static func u32(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return -1 }
        let value = BinaryPrimitives.readUInt32BigEndian(data, offset)
        return value == UInt32.max ? -1 : Int(value)
    }
}

enum PalmDocCompression {
    static func decompress(_ input: Data) -> Data {
        let input = [UInt8](input)
        var output: [UInt8] = []
        var i = 0
        while i < input.count {
            let c = input[i]; i += 1
            if c >= 1 && c <= 8 {
                for _ in 0..<Int(c) where i < input.count { output.append(input[i]); i += 1 }
            } else if c < 0x80 {
                output.append(c)
            } else if c >= 0xC0 {
                output.append(32); output.append(c ^ 0x80)
            } else if i < input.count {
                let pair = (Int(c) << 8) | Int(input[i]); i += 1
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 7) + 3
                if distance == 0 || distance > output.count { continue }
                let start = output.count - distance
                for n in 0..<length { output.append(output[start + n]) }
            }
        }
        return Data(output)
    }
}
