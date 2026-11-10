// .NET BinaryPrimitives / BinaryReader / BinaryWriter equivalents, so ported binary-format code (fonts, ICNS, MOBI,
// XLS, CAD, archive readers) keeps its shape. Offsets are relative to the Data's start; reads past the end throw.

import Foundation

public struct EndOfStreamError: LocalizedError, Sendable {
    public var errorDescription: String? { "Unable to read beyond the end of the stream." }
    public init() {}
}

public enum BinaryPrimitives {
    @inline(__always) static func byte(_ data: Data, _ offset: Int) -> UInt8 { data[data.startIndex + offset] }

    public static func readUInt16BigEndian(_ data: Data, _ offset: Int = 0) -> UInt16 { UInt16(byte(data, offset)) << 8 | UInt16(byte(data, offset + 1)) }
    public static func readUInt16LittleEndian(_ data: Data, _ offset: Int = 0) -> UInt16 { UInt16(byte(data, offset + 1)) << 8 | UInt16(byte(data, offset)) }
    public static func readInt16BigEndian(_ data: Data, _ offset: Int = 0) -> Int16 { Int16(bitPattern: readUInt16BigEndian(data, offset)) }
    public static func readInt16LittleEndian(_ data: Data, _ offset: Int = 0) -> Int16 { Int16(bitPattern: readUInt16LittleEndian(data, offset)) }
    public static func readUInt32BigEndian(_ data: Data, _ offset: Int = 0) -> UInt32 {
        UInt32(readUInt16BigEndian(data, offset)) << 16 | UInt32(readUInt16BigEndian(data, offset + 2))
    }
    public static func readUInt32LittleEndian(_ data: Data, _ offset: Int = 0) -> UInt32 {
        UInt32(readUInt16LittleEndian(data, offset + 2)) << 16 | UInt32(readUInt16LittleEndian(data, offset))
    }
    public static func readInt32BigEndian(_ data: Data, _ offset: Int = 0) -> Int32 { Int32(bitPattern: readUInt32BigEndian(data, offset)) }
    public static func readInt32LittleEndian(_ data: Data, _ offset: Int = 0) -> Int32 { Int32(bitPattern: readUInt32LittleEndian(data, offset)) }
    public static func readUInt64BigEndian(_ data: Data, _ offset: Int = 0) -> UInt64 {
        UInt64(readUInt32BigEndian(data, offset)) << 32 | UInt64(readUInt32BigEndian(data, offset + 4))
    }
    public static func readUInt64LittleEndian(_ data: Data, _ offset: Int = 0) -> UInt64 {
        UInt64(readUInt32LittleEndian(data, offset + 4)) << 32 | UInt64(readUInt32LittleEndian(data, offset))
    }
    public static func readInt64LittleEndian(_ data: Data, _ offset: Int = 0) -> Int64 { Int64(bitPattern: readUInt64LittleEndian(data, offset)) }
    public static func readInt64BigEndian(_ data: Data, _ offset: Int = 0) -> Int64 { Int64(bitPattern: readUInt64BigEndian(data, offset)) }
    public static func readSingleLittleEndian(_ data: Data, _ offset: Int = 0) -> Float { Float(bitPattern: readUInt32LittleEndian(data, offset)) }
    public static func readDoubleLittleEndian(_ data: Data, _ offset: Int = 0) -> Double { Double(bitPattern: readUInt64LittleEndian(data, offset)) }

    public static func writeUInt16BigEndian(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        data[data.startIndex + offset] = UInt8(value >> 8); data[data.startIndex + offset + 1] = UInt8(value & 0xFF)
    }
    public static func writeUInt32BigEndian(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        writeUInt16BigEndian(&data, offset, UInt16(value >> 16)); writeUInt16BigEndian(&data, offset + 2, UInt16(value & 0xFFFF))
    }
    public static func writeUInt16LittleEndian(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        data[data.startIndex + offset] = UInt8(value & 0xFF); data[data.startIndex + offset + 1] = UInt8(value >> 8)
    }
    public static func writeUInt32LittleEndian(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        writeUInt16LittleEndian(&data, offset, UInt16(value & 0xFFFF)); writeUInt16LittleEndian(&data, offset + 2, UInt16(value >> 16))
    }
}

/// Little-endian reader over bytes (System.IO.BinaryReader on a MemoryStream).
public final class BinaryReader {
    public let data: Data
    public var position: Int
    public var length: Int { data.count }
    public var remaining: Int { data.count - position }

    public init(_ data: Data, position: Int = 0) {
        self.data = data.startIndex == 0 ? data : Data(data)
        self.position = position
    }

    private func take(_ count: Int) throws -> Int {
        guard count >= 0, position + count <= data.count else { throw EndOfStreamError() }
        defer { position += count }
        return position
    }

    public func readByte() throws -> UInt8 { data[try take(1)] }
    public func readSByte() throws -> Int8 { Int8(bitPattern: try readByte()) }
    public func readBoolean() throws -> Bool { try readByte() != 0 }
    public func readBytes(_ count: Int) throws -> Data { let start = try take(count); return data.subdata(in: start..<start + count) }
    public func readUInt16() throws -> UInt16 { BinaryPrimitives.readUInt16LittleEndian(data, try take(2)) }
    public func readInt16() throws -> Int16 { BinaryPrimitives.readInt16LittleEndian(data, try take(2)) }
    public func readUInt32() throws -> UInt32 { BinaryPrimitives.readUInt32LittleEndian(data, try take(4)) }
    public func readInt32() throws -> Int32 { BinaryPrimitives.readInt32LittleEndian(data, try take(4)) }
    public func readUInt64() throws -> UInt64 { BinaryPrimitives.readUInt64LittleEndian(data, try take(8)) }
    public func readInt64() throws -> Int64 { BinaryPrimitives.readInt64LittleEndian(data, try take(8)) }
    public func readSingle() throws -> Float { BinaryPrimitives.readSingleLittleEndian(data, try take(4)) }
    public func readDouble() throws -> Double { BinaryPrimitives.readDoubleLittleEndian(data, try take(8)) }
    public func skip(_ count: Int) throws { _ = try take(count) }
    public func seek(_ offset: Int) throws {
        guard offset >= 0, offset <= data.count else { throw EndOfStreamError() }
        position = offset
    }
}

/// Little-endian writer into memory (System.IO.BinaryWriter on a MemoryStream).
public final class BinaryWriter {
    public private(set) var data = Data()
    public init() {}

    public var position: Int { data.count }
    public func write(_ value: UInt8) { data.append(value) }
    public func write(_ value: Int8) { data.append(UInt8(bitPattern: value)) }
    public func write(_ bytes: Data) { data.append(bytes) }
    public func write(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    public func write(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    public func write(_ value: Int16) { write(UInt16(bitPattern: value)) }
    public func write(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    public func write(_ value: Int32) { write(UInt32(bitPattern: value)) }
    public func write(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    public func write(_ value: Int64) { write(UInt64(bitPattern: value)) }
    public func write(_ value: Float) { write(value.bitPattern) }
    public func write(_ value: Double) { write(value.bitPattern) }
    public func writeBigEndian(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    public func writeBigEndian(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
}
