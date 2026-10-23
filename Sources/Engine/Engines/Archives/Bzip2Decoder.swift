// Port of Filee.Engines/Archives/Bzip2Decoder.cs: bzip2 decompression in Swift, written for ALZip archives: ALZ stores
// bzip2 blocks without the "BZh" stream header, marks each block with "DLZ\x01" (instead of the 48-bit block magic,
// the block CRC and the "randomised" bit) and ends with "DLZ\x02". Standard bzip2 streams (used by EGG) are read too.
// The block format itself (Huffman coded MTF/RLE2 symbols, Burrows-Wheeler transform, RLE1) is plain bzip2.

import Foundation

/// Decodes standard or ALZ-framed bzip2 data.
final class Bzip2Decoder {
    private static let blockMagic: UInt64 = 0x314159265359
    private static let streamEndMagic: UInt64 = 0x177245385090
    private static let alzBlockMarker: UInt32 = 0x444C5A01 // "DLZ\x01"
    private static let alzEndMarker: UInt32 = 0x444C5A02 // "DLZ\x02"
    private static let maxCodeLength = 20
    private static let groupSize = 50
    private static let maxSelectors = 18002

    private static let blockCrcTable: [UInt32] = createBlockCrcTable()

    private let input: UnsafeRawBufferPointer
    private let output: (Data) throws -> Void
    private let maxOutput: Int64
    private var inPos = 0
    private var bits: UInt64 = 0
    private var bitCount = 0
    private var written: Int64 = 0
    private var tt: [Int32] = []

    private init(_ input: UnsafeRawBufferPointer, _ output: @escaping (Data) throws -> Void, _ maxOutput: Int64) {
        self.input = input
        self.output = output
        self.maxOutput = maxOutput
    }

    /// Decompresses `input` into `output`. `alzFraming` selects ALZ's variant of the stream framing (see the file
    /// comment); decoding stops with an error when the data would unpack to more bytes than `maxOutput`.
    /// Returns the number of bytes written.
    @discardableResult
    static func decompress(_ input: Data, _ output: (Data) throws -> Void, alzFraming: Bool, maxOutput: Int64) throws -> Int64 {
        try withoutActuallyEscaping(output) { sink in
            try input.withUnsafeBytes { raw in
                let decoder = Bzip2Decoder(raw, sink, maxOutput)
                if alzFraming {
                    try decoder.decodeAlz()
                } else {
                    try decoder.decodeStandard()
                }
                return decoder.written
            }
        }
    }

    private func decodeAlz() throws {
        // ALZip always writes 900k blocks and leaves out the stream header.
        while let marker = tryReadBits(32) {
            try Task.checkCancellation()
            if marker == Self.alzEndMarker { return }
            guard marker == Self.alzBlockMarker else { throw Self.invalid("bzip2 block marker missing") }
            try decodeBlock(9, expectedCrc: nil)
        }
    }

    private func decodeStandard() throws {
        // Several streams may follow each other (pbzip2, "cat a.bz2 b.bz2").
        var first = true
        while true {
            guard var b = tryReadBits(8) else {
                if first { throw Self.invalid("empty bzip2 data") }
                return
            }
            // Some writers leave out the "BZ" signature and start with "h9".
            if b == UInt32(UInt8(ascii: "B")) {
                guard try readBits(8) == UInt32(UInt8(ascii: "Z")) else { throw Self.invalid("not bzip2 data") }
                b = try readBits(8)
            }
            guard b == UInt32(UInt8(ascii: "h")) else { throw Self.invalid("not bzip2 data") }
            let level = Int(try readBits(8)) - Int(UInt8(ascii: "0"))
            guard (1...9).contains(level) else { throw Self.invalid("invalid bzip2 block size") }
            first = false

            var combined: UInt32 = 0
            while true {
                try Task.checkCancellation()
                let magic = UInt64(try readBits(24)) << 24 | UInt64(try readBits(24))
                let crc = try readBits(32)
                if magic == Self.streamEndMagic {
                    guard crc == combined else { throw Self.invalid("bzip2 stream checksum mismatch") }
                    break
                }
                guard magic == Self.blockMagic else { throw Self.invalid("bzip2 block magic missing") }
                guard try readBits(1) == 0 else { throw Self.invalid("randomised bzip2 blocks (bzip2 0.9.0) are not supported") }
                try decodeBlock(level, expectedCrc: crc)
                combined = ((combined << 1) | (combined >> 31)) ^ crc
            }
            // The next stream starts on a byte boundary.
            bitCount -= bitCount % 8
        }
    }

    /// Decodes one block, starting at origPtr (after magic, CRC and randomised bit).
    private func decodeBlock(_ level: Int, expectedCrc: UInt32?) throws {
        let blockMax = level * 100_000
        if tt.count < blockMax { tt = [Int32](repeating: 0, count: blockMax) }

        let origPtr = Int(try readBits(24))

        // Symbols used in this block, as a 16x16 bitmap.
        var seqToUnseq = [UInt8](repeating: 0, count: 256)
        var inUseCount = 0
        let inUse16 = try readBits(16)
        for i in 0..<16 where inUse16 & (0x8000 >> UInt32(i)) != 0 {
            let bits = try readBits(16)
            for j in 0..<16 where bits & (0x8000 >> UInt32(j)) != 0 {
                seqToUnseq[inUseCount] = UInt8(i * 16 + j)
                inUseCount += 1
            }
        }
        guard inUseCount > 0 else { throw Self.invalid("bzip2 block uses no symbols") }
        let alphaSize = inUseCount + 2

        let groupCount = Int(try readBits(3))
        let selectorCount = Int(try readBits(15))
        guard (2...6).contains(groupCount), selectorCount >= 1 else { throw Self.invalid("invalid bzip2 block header") }

        // Selectors (which Huffman table each group of 50 symbols uses), MTF and unary coded.
        var selectors = [UInt8](repeating: 0, count: min(selectorCount, Self.maxSelectors))
        var mtfGroups: [UInt8] = [0, 1, 2, 3, 4, 5]
        for i in 0..<selectorCount {
            var j = 0
            while try readBits(1) == 1 {
                j += 1
                if j >= groupCount { throw Self.invalid("invalid bzip2 selector") }
            }
            let value = mtfGroups[j]
            while j > 0 {
                mtfGroups[j] = mtfGroups[j - 1]
                j -= 1
            }
            mtfGroups[0] = value
            if i < selectors.count { selectors[i] = value } // bzip2 1.0.8 reads but ignores selectors beyond the limit
        }

        // Code lengths, delta coded, and the canonical Huffman decode tables built from them.
        let stride = Self.maxCodeLength + 2
        var limit = [Int](repeating: 0, count: groupCount * stride)
        var baseTable = [Int](repeating: 0, count: groupCount * stride)
        var perm = [Int](repeating: 0, count: groupCount * 258)
        var minLengths = [Int](repeating: 0, count: groupCount)
        var lengths = [Int](repeating: 0, count: alphaSize)
        for t in 0..<groupCount {
            var current = Int(try readBits(5))
            for i in 0..<alphaSize {
                while true {
                    guard (1...Self.maxCodeLength).contains(current) else { throw Self.invalid("invalid bzip2 code length") }
                    if try readBits(1) == 0 { break }
                    current += try readBits(1) == 0 ? 1 : -1
                }
                lengths[i] = current
            }
            minLengths[t] = Self.buildDecodeTable(lengths, alphaSize, t, &limit, &baseTable, &perm)
        }

        // MTF / RLE2 symbols → block bytes.
        var mtf = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { mtf[i] = UInt8(i) }
        var counts = [Int](repeating: 0, count: 256)
        let endOfBlock = inUseCount + 1
        var length = 0
        var groupIndex = -1
        var groupLeft = 0
        var table = 0

        func nextSymbol() throws -> Int {
            if groupLeft == 0 {
                groupIndex += 1
                guard groupIndex < selectors.count else { throw Self.invalid("bzip2 selectors exhausted") }
                table = Int(selectors[groupIndex])
                groupLeft = Self.groupSize
            }
            groupLeft -= 1
            var bitsUsed = minLengths[table]
            var code = Int(try readBits(bitsUsed))
            while bitsUsed <= Self.maxCodeLength && code > limit[table * stride + bitsUsed] {
                bitsUsed += 1
                code = (code << 1) | Int(try readBits(1))
            }
            guard bitsUsed <= Self.maxCodeLength else { throw Self.invalid("invalid bzip2 Huffman code") }
            let slot = code - baseTable[table * stride + bitsUsed]
            guard (0..<258).contains(slot) else { throw Self.invalid("invalid bzip2 Huffman code") }
            return perm[table * 258 + slot]
        }

        var symbol = try nextSymbol()
        while symbol != endOfBlock {
            if symbol <= 1 {
                // RUNA / RUNB: a bijective base-2 run length of the symbol at the MTF front.
                var run = 0
                var weight = 1
                repeat {
                    guard weight <= blockMax else { throw Self.invalid("bzip2 run too long") }
                    run += (symbol + 1) * weight
                    weight <<= 1
                    symbol = try nextSymbol()
                } while symbol <= 1

                let value = seqToUnseq[Int(mtf[0])]
                guard length + run <= blockMax else { throw Self.invalid("bzip2 block too long") }
                counts[Int(value)] += run
                tt.withUnsafeMutableBufferPointer { buffer in
                    for k in length..<length + run { buffer[k] = Int32(value) }
                }
                length += run
                continue
            }

            guard length < blockMax else { throw Self.invalid("bzip2 block too long") }
            let index = symbol - 1
            guard index < inUseCount else { throw Self.invalid("invalid bzip2 symbol") }
            let front = mtf[index]
            var k = index
            while k > 0 {
                mtf[k] = mtf[k - 1]
                k -= 1
            }
            mtf[0] = front
            let b = seqToUnseq[Int(front)]
            counts[Int(b)] += 1
            tt[length] = Int32(b)
            length += 1
            symbol = try nextSymbol()
        }
        guard origPtr >= 0, origPtr < max(length, 1) else { throw Self.invalid("invalid bzip2 origin pointer") }

        // Inverse Burrows-Wheeler transform: link every position to its successor.
        var starts = [Int](repeating: 0, count: 256)
        var sum = 0
        for i in 0..<256 {
            starts[i] = sum
            sum += counts[i]
        }
        tt.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<length {
                let b = Int(buffer[i] & 0xFF)
                buffer[starts[b]] |= Int32(i << 8)
                starts[b] += 1
            }
        }

        // Walk the chain and undo the initial run-length coding (4 equal bytes + a count byte).
        var crc: UInt32 = 0xFFFF_FFFF
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var used = 0

        func flush() throws {
            guard used > 0 else { return }
            written += Int64(used)
            guard written <= maxOutput else { throw ConversionError("the data unpacks to more than the archive declares") }
            try output(Data(buffer[0..<used]))
            used = 0
        }

        try tt.withUnsafeBufferPointer { links in
            let table = Self.blockCrcTable
            var position = length == 0 ? 0 : Int(links[origPtr] >> 8)
            var previous = -1
            var repeatCount = 0

            func emit(_ value: UInt8) throws {
                crc = (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(value))]
                buffer[used] = value
                used += 1
                if used == buffer.count { try flush() }
            }

            for _ in 0..<length {
                let entry = links[position]
                let b = Int(entry & 0xFF)
                position = Int(entry >> 8)
                if repeatCount == 4 {
                    for _ in 0..<b { try emit(UInt8(previous)) }
                    repeatCount = 0
                    previous = -1
                    continue
                }
                repeatCount = b == previous ? repeatCount + 1 : 1
                previous = b
                try emit(UInt8(b))
            }
        }
        try flush()

        if let expectedCrc, ~crc != expectedCrc { throw Self.invalid("bzip2 block checksum mismatch") }
    }

    /// Canonical Huffman decode tables as in the reference bzip2 (limit / base / perm per code length). Returns the
    /// shortest code length.
    private static func buildDecodeTable(_ lengths: [Int], _ alphaSize: Int, _ t: Int, _ limit: inout [Int],
                                         _ baseTable: inout [Int], _ perm: inout [Int]) -> Int {
        let stride = maxCodeLength + 2
        var minLength = maxCodeLength
        var maxLength = 0
        for i in 0..<alphaSize {
            minLength = min(minLength, lengths[i])
            maxLength = max(maxLength, lengths[i])
        }

        var p = 0
        if minLength <= maxLength {
            for len in minLength...maxLength {
                for symbol in 0..<alphaSize where lengths[symbol] == len {
                    perm[t * 258 + p] = symbol
                    p += 1
                }
            }
        }

        var countAtLength = [Int](repeating: 0, count: stride)
        for i in 0..<alphaSize { countAtLength[lengths[i] + 1] += 1 }
        for i in 1..<stride { countAtLength[i] += countAtLength[i - 1] }

        for i in 0..<stride {
            limit[t * stride + i] = -1 // lengths outside min..max never match, so decoding continues to longer codes
            baseTable[t * stride + i] = countAtLength[i]
        }

        var code = 0
        if minLength <= maxLength {
            for len in minLength...maxLength {
                code += countAtLength[len + 1] - countAtLength[len]
                limit[t * stride + len] = code - 1
                code <<= 1
            }
        }
        if minLength + 1 <= maxLength {
            for len in (minLength + 1)...maxLength {
                baseTable[t * stride + len] = ((limit[t * stride + len - 1] + 1) << 1) - countAtLength[len]
            }
        }
        return minLength
    }

    private func readBits(_ count: Int) throws -> UInt32 {
        guard let value = tryReadBits(count) else { throw Self.invalid("bzip2 data ends unexpectedly") }
        return value
    }

    /// Reads up to 32 bits, most significant first; nil when the input is exhausted.
    private func tryReadBits(_ count: Int) -> UInt32? {
        while bitCount < count {
            guard inPos < input.count else { return nil }
            bits = (bits << 8) | UInt64(input[inPos])
            inPos += 1
            bitCount += 8
        }
        bitCount -= count
        return UInt32(truncatingIfNeeded: (bits >> UInt64(bitCount)) & ((1 << UInt64(count)) - 1))
    }

    private static func invalid(_ message: String) -> ConversionError { ConversionError(message) }

    /// bzip2's block CRC: CRC-32 with the polynomial 0x04C11DB7, most significant bit first.
    private static func createBlockCrcTable() -> [UInt32] {
        (0..<256).map { i in
            var c = UInt32(i) << 24
            for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
            return c
        }
    }
}
