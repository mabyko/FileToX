// The byte-level helpers of ACadSharp 3.8.0's DWG writer: a growable `MemoryStream`, the CRC-8 / CRC-32 stream
// handlers, `DwgCheckSumCalculator` (magic sequence and page checksum) and `DwgLZ77AC18Compressor`.

import Foundation

extension ACad {
    /// `MemoryStream`: bytes, a position that may lie anywhere up to the end, writes that overwrite or grow.
    final class DwgMemoryStream {
        private(set) var bytes: [UInt8] = []
        var position = 0

        init() {}

        var length: Int { bytes.count }

        func writeByte(_ value: UInt8) {
            if position < bytes.count {
                bytes[position] = value
            } else {
                if position > bytes.count { bytes.append(contentsOf: repeatElement(0, count: position - bytes.count)) }
                bytes.append(value)
            }
            position += 1
        }

        func write<C: Collection>(_ data: C) where C.Element == UInt8 {
            if position == bytes.count {
                bytes.append(contentsOf: data)
                position += data.count
            } else {
                for b in data { writeByte(b) }
            }
        }

        /// `ReadByte`: -1 at the end.
        func readByte() -> Int {
            guard position < bytes.count else { return -1 }
            defer { position += 1 }
            return Int(bytes[position])
        }

        func setLength(_ value: Int) {
            if value < bytes.count { bytes.removeLast(bytes.count - value) } else {
                bytes.append(contentsOf: repeatElement(0, count: value - bytes.count))
            }
            if position > value { position = value }
        }

        /// Direct access to the buffer (`GetBuffer`) for in-place changes.
        func withBytes<R>(_ body: (inout [UInt8]) -> R) -> R { body(&bytes) }
    }

    /// Little-endian byte images of numbers (`LittleEndianConverter.GetBytes`).
    enum DwgLE {
        static func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        static func bytes(_ value: Double) -> [UInt8] { bytes(value.bitPattern) }
    }

    /// `CRC`, `CRC8StreamHandler` and `CRC32StreamHandler`.
    enum DwgCrc {
        static let crc8Table: [UInt16] = [
            0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241, 0xC601, 0x06C0, 0x0780, 0xC741, 0x0500, 0xC5C1, 0xC481, 0x0440,
            0xCC01, 0x0CC0, 0x0D80, 0xCD41, 0x0F00, 0xCFC1, 0xCE81, 0x0E40, 0x0A00, 0xCAC1, 0xCB81, 0x0B40, 0xC901, 0x09C0, 0x0880, 0xC841,
            0xD801, 0x18C0, 0x1980, 0xD941, 0x1B00, 0xDBC1, 0xDA81, 0x1A40, 0x1E00, 0xDEC1, 0xDF81, 0x1F40, 0xDD01, 0x1DC0, 0x1C80, 0xDC41,
            0x1400, 0xD4C1, 0xD581, 0x1540, 0xD701, 0x17C0, 0x1680, 0xD641, 0xD201, 0x12C0, 0x1380, 0xD341, 0x1100, 0xD1C1, 0xD081, 0x1040,
            0xF001, 0x30C0, 0x3180, 0xF141, 0x3300, 0xF3C1, 0xF281, 0x3240, 0x3600, 0xF6C1, 0xF781, 0x3740, 0xF501, 0x35C0, 0x3480, 0xF441,
            0x3C00, 0xFCC1, 0xFD81, 0x3D40, 0xFF01, 0x3FC0, 0x3E80, 0xFE41, 0xFA01, 0x3AC0, 0x3B80, 0xFB41, 0x3900, 0xF9C1, 0xF881, 0x3840,
            0x2800, 0xE8C1, 0xE981, 0x2940, 0xEB01, 0x2BC0, 0x2A80, 0xEA41, 0xEE01, 0x2EC0, 0x2F80, 0xEF41, 0x2D00, 0xEDC1, 0xEC81, 0x2C40,
            0xE401, 0x24C0, 0x2580, 0xE541, 0x2700, 0xE7C1, 0xE681, 0x2640, 0x2200, 0xE2C1, 0xE381, 0x2340, 0xE101, 0x21C0, 0x2080, 0xE041,
            0xA001, 0x60C0, 0x6180, 0xA141, 0x6300, 0xA3C1, 0xA281, 0x6240, 0x6600, 0xA6C1, 0xA781, 0x6740, 0xA501, 0x65C0, 0x6480, 0xA441,
            0x6C00, 0xACC1, 0xAD81, 0x6D40, 0xAF01, 0x6FC0, 0x6E80, 0xAE41, 0xAA01, 0x6AC0, 0x6B80, 0xAB41, 0x6900, 0xA9C1, 0xA881, 0x6840,
            0x7800, 0xB8C1, 0xB981, 0x7940, 0xBB01, 0x7BC0, 0x7A80, 0xBA41, 0xBE01, 0x7EC0, 0x7F80, 0xBF41, 0x7D00, 0xBDC1, 0xBC81, 0x7C40,
            0xB401, 0x74C0, 0x7580, 0xB541, 0x7700, 0xB7C1, 0xB681, 0x7640, 0x7200, 0xB2C1, 0xB381, 0x7340, 0xB101, 0x71C0, 0x7080, 0xB041,
            0x5000, 0x90C1, 0x9181, 0x5140, 0x9301, 0x53C0, 0x5280, 0x9241, 0x9601, 0x56C0, 0x5780, 0x9741, 0x5500, 0x95C1, 0x9481, 0x5440,
            0x9C01, 0x5CC0, 0x5D80, 0x9D41, 0x5F00, 0x9FC1, 0x9E81, 0x5E40, 0x5A00, 0x9AC1, 0x9B81, 0x5B40, 0x9901, 0x59C0, 0x5880, 0x9841,
            0x8801, 0x48C0, 0x4980, 0x8941, 0x4B00, 0x8BC1, 0x8A81, 0x4A40, 0x4E00, 0x8EC1, 0x8F81, 0x4F40, 0x8D01, 0x4DC0, 0x4C80, 0x8C41,
            0x4400, 0x84C1, 0x8581, 0x4540, 0x8701, 0x47C0, 0x4680, 0x8641, 0x8201, 0x42C0, 0x4380, 0x8341, 0x4100, 0x81C1, 0x8081, 0x4040,
        ]

        /// The reflected CRC-32 table (polynomial 0xEDB88320).
        static let crc32Table: [UInt32] = (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }

        static func crc8<S: Sequence>(_ seed: UInt16, _ bytes: S) -> UInt16 where S.Element == UInt8 {
            var key = seed
            for b in bytes { key = (key >> 8) ^ crc8Table[Int(b ^ UInt8(truncatingIfNeeded: key))] }
            return key
        }

        /// `CRC32StreamHandler.Seed` after the bytes, starting from `seed`.
        static func crc32<S: Sequence>(_ seed: UInt32, _ bytes: S) -> UInt32 where S.Element == UInt8 {
            var value = ~seed
            for b in bytes { value = (value >> 8) ^ crc32Table[Int((value ^ UInt32(b)) & 0xFF)] }
            return ~value
        }
    }

    /// `DwgCheckSumCalculator`.
    enum DwgCheckSum {
        static let magicSequence: [UInt8] = {
            var seed: Int32 = 1
            return (0..<256).map { _ in
                seed = seed &* 0x343FD &+ 0x269EC3
                return UInt8(truncatingIfNeeded: seed >> 0x10)
            }
        }()

        static func compressionCalculator(_ length: Int) -> Int { 0x1F - (length + 0x20 - 1) % 0x20 }

        static func calculate(_ seed: UInt32, _ buffer: [UInt8], _ offset: Int, _ size: Int) -> UInt32 {
            var sum1 = seed & 0xFFFF
            var sum2 = seed >> 16
            var index = offset
            var size = size
            while size != 0 {
                let chunkSize = min(0x15B0, size)
                size -= chunkSize
                for _ in 0..<chunkSize {
                    sum1 &+= UInt32(buffer[index])
                    sum2 &+= sum1
                    index += 1
                }
                sum1 %= 0xFFF1
                sum2 %= 0xFFF1
            }
            return (sum2 << 0x10) | (sum1 & 0xFFFF)
        }
    }

    /// `DwgLZ77AC18Compressor`.
    final class DwgLZ77AC18Compressor {
        private var source: [UInt8] = []
        private var dest: DwgMemoryStream!
        private var block = [Int](repeating: -1, count: 0x8000)
        private var initialOffset = 0
        private var currPosition = 0
        private var currOffset = 0
        private var totalOffset = 0

        func compress(_ source: [UInt8], _ offset: Int, _ totalSize: Int, _ dest: DwgMemoryStream) throws {
            for i in block.indices { block[i] = -1 }
            self.source = source
            self.dest = dest
            initialOffset = offset
            totalOffset = initialOffset + totalSize
            currOffset = initialOffset
            currPosition = initialOffset + 4

            var compressionOffset = 0
            var matchPos = 0
            var chunkOffset = 0
            var lastMatchPos = 0
            while currPosition < totalOffset - 0x13 {
                if !compressChunk(&chunkOffset, &lastMatchPos) {
                    currPosition += 1
                    continue
                }
                let mask = currPosition - currOffset
                if compressionOffset != 0 {
                    try applyMask(matchPos, compressionOffset, mask)
                }
                try writeLiteralLength(mask)
                currPosition += chunkOffset
                currOffset = currPosition
                compressionOffset = chunkOffset
                matchPos = lastMatchPos
            }
            let literalLength = totalOffset - currOffset
            if compressionOffset != 0 {
                try applyMask(matchPos, compressionOffset, literalLength)
            }
            try writeLiteralLength(literalLength)
            // 0x11 : Terminates the input stream.
            dest.writeByte(0x11)
            dest.writeByte(0)
            dest.writeByte(0)
        }

        private static let argument = DwgError("Value does not fall within the expected range.")

        private func writeLen(_ len: Int) throws {
            guard len > 0 else { throw Self.argument }
            var len = len
            while len > 0xFF {
                len -= 0xFF
                dest.writeByte(0)
            }
            dest.writeByte(UInt8(truncatingIfNeeded: len))
        }

        private func writeOpCode(_ opCode: Int, _ compressionOffset: Int, _ value: Int) throws {
            guard compressionOffset > 0, value > 0 else { throw Self.argument }
            if compressionOffset <= value {
                dest.writeByte(UInt8(truncatingIfNeeded: opCode | (compressionOffset - 2)))
            } else {
                dest.writeByte(UInt8(truncatingIfNeeded: opCode))
                try writeLen(compressionOffset - value)
            }
        }

        private func writeLiteralLength(_ length: Int) throws {
            guard length > 0 else { return }
            if length > 3 {
                try writeOpCode(0, length - 1, 0x11)
            }
            dest.write(source[currOffset..<(currOffset + length)])
        }

        private func applyMask(_ matchPosition: Int, _ compressionOffset: Int, _ mask: Int) throws {
            var matchPosition = matchPosition
            var curr = 0
            var next = 0
            if compressionOffset >= 0x0F || matchPosition > 0x400 {
                if matchPosition <= 0x4000 {
                    matchPosition -= 1
                    try writeOpCode(0x20, compressionOffset, 0x21)
                } else {
                    matchPosition -= 0x4000
                    try writeOpCode(0x10 | ((matchPosition >> 11) & 8), compressionOffset, 0x09)
                }
                curr = (matchPosition & 0xFF) << 2
                next = matchPosition >> 6
            } else {
                matchPosition -= 1
                curr = ((compressionOffset + 1) << 4) | ((matchPosition & 0b11) << 2)
                next = matchPosition >> 2
            }
            if mask < 4 { curr |= mask }
            dest.writeByte(UInt8(truncatingIfNeeded: curr))
            dest.writeByte(UInt8(truncatingIfNeeded: next))
        }

        private func compressChunk(_ offset: inout Int, _ matchPos: inout Int) -> Bool {
            offset = 0
            let v1 = Int(source[currPosition + 3]) << 6
            let v2 = v1 ^ Int(source[currPosition + 2])
            let v3 = v2 << 5 ^ Int(source[currPosition + 1])
            let v4 = v3 << 5 ^ Int(source[currPosition])
            var valueIndex = (v4 + (v4 >> 5)) & 0x7FFF
            var value = block[valueIndex]
            matchPos = currPosition - value
            if value >= initialOffset && matchPos <= 0xBFFF {
                if matchPos > 0x400 && source[currPosition + 3] != source[value + 3] {
                    valueIndex = (valueIndex & 0x7FF) ^ 0b100_0000_0001_1111
                    value = block[valueIndex]
                    matchPos = currPosition - value
                    if value < initialOffset || matchPos > 0xBFFF
                        || (matchPos > 0x400 && source[currPosition + 3] != source[value + 3]) {
                        block[valueIndex] = currPosition
                        return false
                    }
                }
                if source[currPosition] == source[value] && source[currPosition + 1] == source[value + 1]
                    && source[currPosition + 2] == source[value + 2] {
                    offset = 3
                    var index = value + 3
                    var current = currPosition + 3
                    // `source[index++] == source[currOffset++]`: both indices advance even on the failing comparison.
                    while current < totalOffset {
                        let equal = source[index] == source[current]
                        index += 1
                        current += 1
                        if !equal { break }
                        offset += 1
                    }
                }
            }
            block[valueIndex] = currPosition
            return offset >= 3
        }
    }
}
