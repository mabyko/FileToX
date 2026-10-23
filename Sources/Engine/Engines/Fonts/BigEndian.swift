// Port of Filee.Engines/Fonts/BigEndian.cs. Font-local names avoid collisions in the shared module.
import Foundation

final class FontBigEndianReader {
    let data: Data
    var position: Int
    private let end: Int
    var remaining: Int { end - position }
    init(_ data: Data, _ offset: Int = 0, _ end: Int? = nil) {
        self.data = Data(data); position = offset; self.end = end ?? data.count
    }
    private func need(_ count: Int) throws {
        guard count >= 0, position >= 0, end <= data.count, position <= end - count else {
            throw ConversionError("The font file is truncated or damaged.")
        }
    }
    func u8() throws -> Int { try need(1); defer { position += 1 }; return Int(data[position]) }
    func u16() throws -> Int { try need(2); defer { position += 2 }; return Int(BinaryPrimitives.readUInt16BigEndian(data, position)) }
    func i16() throws -> Int { Int(Int16(bitPattern: UInt16(try u16()))) }
    func u32() throws -> UInt32 { try need(4); defer { position += 4 }; return BinaryPrimitives.readUInt32BigEndian(data, position) }
    func i32() throws -> Int { Int(Int32(bitPattern: try u32())) }
    func bytes(_ count: Int) throws -> Data { try need(count); defer { position += count }; return data.subdata(in: position..<position + count) }
    func skip(_ count: Int) throws { try need(count); position += count }
    func uintBase128() throws -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<5 {
            let b = try u8()
            if i == 0 && b == 0x80 { throw ConversionError("Invalid WOFF2 number (leading zeros).") }
            if value & 0xFE000000 != 0 { throw ConversionError("Invalid WOFF2 number (overflow).") }
            value = value << 7 | UInt32(b & 0x7F)
            if b & 0x80 == 0 { return value }
        }
        throw ConversionError("Invalid WOFF2 number (longer than five bytes).")
    }
    func read255UInt16() throws -> Int {
        let code = try u8()
        switch code { case 253: return try u16(); case 254: return try u8() + 506; case 255: return try u8() + 253; default: return code }
    }
}

final class FontBigEndianWriter {
    var written = Data()
    var length: Int { written.count }
    init(_ capacity: Int = 256) { written.reserveCapacity(max(16, capacity)) }
    func u8(_ value: Int) { written.append(UInt8(truncatingIfNeeded: value)) }
    func u16(_ value: Int) { u8(value >> 8); u8(value) }
    func i16(_ value: Int) { u16(value) }
    func u32(_ value: UInt32) { u16(Int(value >> 16)); u16(Int(value & 0xFFFF)) }
    func bytes(_ data: Data) { written.append(data) }
    func zeros(_ count: Int) { written.append(Data(repeating: 0, count: count)) }
    func pad4() { zeros((4 - (length & 3)) & 3) }
    func setU32(_ position: Int, _ value: UInt32) { BinaryPrimitives.writeUInt32BigEndian(&written, position, value) }
    func uintBase128(_ value: UInt32) {
        var groups = 1, v = value >> 7
        while v != 0 { groups += 1; v >>= 7 }
        for i in stride(from: groups - 1, through: 0, by: -1) {
            let bits = Int(value >> (7 * i)) & 0x7F; u8(i > 0 ? bits | 0x80 : bits)
        }
    }
    func write255UInt16(_ value: Int) {
        if value < 253 { u8(value) }
        else if value < 506 { u8(255); u8(value - 253) }
        else if value < 762 { u8(254); u8(value - 506) }
        else { u8(253); u16(value) }
    }
}
