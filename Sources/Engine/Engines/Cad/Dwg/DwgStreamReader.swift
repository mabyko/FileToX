// The DWG bit stream (ACadSharp 3.8.0 IDwgStreamReader, DwgStreamReaderBase and its AC12 … AC24 variants, and
// DwgMergedReader for the R2007+ object / text / handle streams), over an in-memory MemoryStream equivalent.

import Foundation

extension ACad {
    /// An exception of the DWG reader, with the message .NET would give.
    struct DwgError: Error, CustomStringConvertible, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
        var errorDescription: String? { message }

        /// `EndOfStreamException`.
        static let endOfStream = DwgError("Unable to read beyond the end of the stream.")
        /// `NotImplementedException`.
        static let notImplemented = DwgError("The method or operation is not implemented.")
        /// `InvalidOperationException`.
        static let invalidOperation = DwgError("Operation is not valid due to the current state of the object.")
        /// `ArgumentOutOfRangeException` of `MemoryStream.Position`.
        static let negativePosition = DwgError("Non-negative number required. (Parameter 'value')")
        /// `KeyNotFoundException` of a dictionary lookup.
        static func keyNotFound(_ key: CustomStringConvertible) -> DwgError {
            DwgError("The given key '\(key)' was not present in the dictionary.")
        }
        /// `ArgumentException` of `Dictionary.Add`.
        static func duplicateKey(_ key: CustomStringConvertible) -> DwgError {
            DwgError("An item with the same key has already been added. Key: \(key)")
        }
    }

    /// A fixed-size `MemoryStream` (all of ACadSharp's DWG streams are `new MemoryStream(byte[])` or
    /// `HugeMemoryStream.Create(length)`): bytes shared copy-on-write between readers, a position that may lie past
    /// the end, writes that cannot grow it.
    final class DwgStream {
        private(set) var bytes: [UInt8]
        private var _position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// `HugeMemoryStream.Create(length)`: `length` zero bytes.
        static func create(_ length: Int64) throws -> DwgStream {
            guard length >= 0 else { throw DwgError("Arithmetic operation resulted in an overflow.") }
            // shortcut: C# switches to 1 GB chunks above 2 GB; such sections only come from damaged files here.
            guard length <= 0x7FFF_FFC7 else { throw DwgError("Array dimensions exceeded supported range.") }
            return DwgStream([UInt8](repeating: 0, count: Int(length)))
        }

        var length: Int { bytes.count }

        var position: Int { _position }

        func seek(_ value: Int) throws {
            guard value >= 0 else { throw DwgError.negativePosition }
            _position = value
        }

        /// `Stream.Read`: up to `count` bytes, fewer at the end.
        func read(_ count: Int) -> ArraySlice<UInt8> {
            guard count > 0, _position < bytes.count else { return [] }
            let end = min(bytes.count, _position + count)
            defer { _position = end }
            return bytes[_position..<end]
        }

        /// `Stream.ReadByte`: -1 at the end.
        func readByte() -> Int {
            guard _position < bytes.count else { return -1 }
            defer { _position += 1 }
            return Int(bytes[_position])
        }

        /// `MemoryStream.Write`: the stream is not expandable.
        func write<C: Collection>(_ data: C) throws where C.Element == UInt8 {
            guard _position + data.count <= bytes.count else { throw DwgError("Memory stream is not expandable.") }
            bytes.replaceSubrange(_position..<_position + data.count, with: data)
            _position += data.count
        }

        /// A stream over the same bytes with its own position (`HugeMemoryStream.Clone`, `new StreamIO(s, true)`).
        func clone() -> DwgStream { DwgStream(bytes) }
    }

    /// `IDwgStreamReader`.
    protocol DwgBitReader: AnyObject {
        var encoding: String.Encoding { get set }
        var isEmpty: Bool { get }
        var position: Int { get }
        func setPosition(_ value: Int) throws
        var stream: DwgStream { get throws }
        func advance(_ offset: Int) throws
        func advanceByte() throws
        func handleReference(_ referenceHandle: UInt64) throws -> UInt64
        func handleReference(_ referenceHandle: UInt64, _ reference: inout DwgReferenceType) throws -> UInt64
        func positionInBits() -> Int
        func read2BitDouble() throws -> XY
        func read2BitDoubleWithDefault(_ def: XY) throws -> XY
        func read2Bits() throws -> UInt8
        func read2RawDouble() throws -> XY
        func read3BitDouble() throws -> XYZ
        func read3BitDoubleWithDefault(_ def: XYZ) throws -> XYZ
        func read3RawDouble() throws -> XYZ
        func read8BitJulianDate() throws -> CadDateTime
        func readBit() throws -> Bool
        func readBitAsShort() throws -> Int16
        func readBitDouble() throws -> Double
        func readBitDoubleWithDefault(_ def: Double) throws -> Double
        func readBitExtrusion() throws -> XYZ
        func readBitLong() throws -> Int32
        func readBitLongLong() throws -> Int64
        func readBitShort() throws -> Int16
        func readBitShortAsBool() throws -> Bool
        func readBitThickness() throws -> Double
        func readByte() throws -> UInt8
        func readBytes(_ length: Int) throws -> [UInt8]
        func readCmColor(useTextStream: Bool) throws -> Color
        func readColorByIndex() throws -> Color
        func readDateTime() throws -> CadDateTime
        func readDouble() throws -> Double
        func readEnColor(_ transparency: inout Transparency, _ flag: inout Bool) throws -> Color
        func readInt() throws -> Int32
        func readModularChar() throws -> UInt64
        func readModularShort() throws -> Int32
        /// The raw object type number (`(ObjectType)value` keeps any number in C#).
        func readObjectType() throws -> Int16
        func readRawChar() throws -> UInt8
        func readRawLong() throws -> Int64
        func readRawULong() throws -> UInt64
        func readSentinel() throws -> [UInt8]
        func readShort() throws -> Int16
        func readSignedModularChar() throws -> Int64
        func readTextUnicode() throws -> String
        func readTimeSpan() throws -> CadTimeSpan
        func readUInt() throws -> UInt32
        func readVariableText() throws -> String
        func resetShift() throws -> UInt16
        func setPositionByFlag(_ position: Int) throws -> Int
        func setPositionInBits(_ position: Int) throws
    }

    /// `DwgReferenceType`.
    enum DwgReferenceType: UInt8 {
        case undefined = 0, softOwnership = 2, hardOwnership = 3, softPointer = 4, hardPointer = 5
    }

    /// `DwgStreamReaderBase` with the behaviour of `DwgStreamReaderAC12` … `DwgStreamReaderAC24` per version.
    final class DwgStreamReader: DwgBitReader {
        let version: Version
        private let _stream: DwgStream
        private(set) var bitShift = 0
        private(set) var isEmpty = false
        /// `StreamIO.Encoding` (.NET's `Encoding.Default`, UTF-8, until a reader sets the drawing's code page).
        var encoding: String.Encoding = .utf8
        private var lastByte: UInt8 = 0

        /// `DwgStreamReaderBase.GetStreamHandler`.
        init(_ version: Version, _ stream: DwgStream, encoding: String.Encoding? = nil) throws {
            switch version {
            case .unknown, .mc0_0, .ac1_2, .ac1_4, .ac1_50, .ac2_10, .ac1002, .ac1003, .ac1004, .ac1006, .ac1009:
                throw CadNotSupportedError(version: version)
            default: break
            }
            self.version = version
            _stream = stream
            if let encoding { self.encoding = encoding }
        }

        var stream: DwgStream { _stream }
        var position: Int { _stream.position }

        func setPosition(_ value: Int) throws {
            try _stream.seek(value)
            bitShift = 0
        }

        /// `StreamIO.ReadByte` (no shift).
        private func baseReadByte() throws -> UInt8 {
            let b = _stream.readByte()
            guard b >= 0 else { throw DwgError.endOfStream }
            return UInt8(b)
        }

        func readByte() throws -> UInt8 {
            if bitShift == 0 {
                lastByte = try baseReadByte()
                return lastByte
            }
            let lastValues = UInt8(truncatingIfNeeded: UInt32(lastByte) << UInt32(bitShift))
            lastByte = try baseReadByte()
            return lastValues | UInt8(truncatingIfNeeded: UInt32(lastByte) >> UInt32(8 - bitShift))
        }

        func readBytes(_ length: Int) throws -> [UInt8] {
            // `new byte[length]` with a negative length.
            guard length >= 0 else { throw DwgError("Arithmetic operation resulted in an overflow.") }
            var arr = Array(_stream.read(length))
            guard arr.count == length else { throw DwgError.endOfStream }
            guard bitShift > 0 else { return arr }
            let shift = UInt32(8 - bitShift)
            for i in 0..<length {
                let lastByteValue = UInt8(truncatingIfNeeded: UInt32(lastByte) << UInt32(bitShift))
                lastByte = arr[i]
                arr[i] = lastByteValue | UInt8(truncatingIfNeeded: UInt32(lastByte) >> shift)
            }
            return arr
        }

        func setPositionByFlag(_ position: Int) throws -> Int {
            try setPositionInBits(position)
            // String stream present bit (last bit in pre-handles section).
            let flag = try readBit()
            var startPosition = position
            if flag {
                let (length, size) = try applyFlagToPosition(position)
                startPosition = length - size
                try setPositionInBits(startPosition)
            } else {
                isEmpty = true
                try setPosition(_stream.length)
            }
            return startPosition
        }

        // ───────────────────────── Bit codes ─────────────────────────

        func readBit() throws -> Bool {
            if bitShift == 0 {
                try advanceByte()
                bitShift = 1
                return lastByte & 128 == 128
            }
            let value = (UInt32(lastByte) << UInt32(bitShift)) & 128 == 128
            bitShift = (bitShift + 1) & 7
            return value
        }

        func readBitAsShort() throws -> Int16 { try readBit() ? 1 : 0 }

        func read2Bits() throws -> UInt8 {
            var value: UInt8
            if bitShift == 0 {
                try advanceByte()
                value = lastByte >> 6
                bitShift = 2
            } else if bitShift == 7 {
                let lastValue = UInt8(truncatingIfNeeded: UInt32(lastByte) << 1) & 2
                try advanceByte()
                value = lastValue | (lastByte >> 7)
                bitShift = 1
            } else {
                value = UInt8(truncatingIfNeeded: UInt32(lastByte) >> UInt32(6 - bitShift)) & 3
                bitShift = (bitShift + 2) & 7
            }
            return value
        }

        func readBitShort() throws -> Int16 {
            switch try read2Bits() {
            case 0: return try readShort()
            case 1:
                if bitShift == 0 {
                    try advanceByte()
                    return Int16(lastByte)
                }
                return Int16(try applyShiftToLastByte())
            case 2: return 0
            default: return 256
            }
        }

        func readBitShortAsBool() throws -> Bool { try readBitShort() != 0 }

        func readBitLong() throws -> Int32 {
            switch try read2Bits() {
            case 0: return try readInt()
            case 1:
                if bitShift == 0 {
                    try advanceByte()
                    return Int32(lastByte)
                }
                return Int32(try applyShiftToLastByte())
            case 2: return 0
            default: throw DwgError("Failed to read ReadBitLong")
            }
        }

        func readBitLongLong() throws -> Int64 {
            var value: UInt64 = 0
            let size = try read3Bits()
            for i in 0..<Int(size) {
                value &+= UInt64(try readByte()) << UInt64(i << 3)
            }
            return Int64(bitPattern: value)
        }

        func readBitDouble() throws -> Double {
            switch try read2Bits() {
            case 0: return try readDouble()
            case 1: return 1.0
            case 2: return 0.0
            default: throw DwgError("Failed to read ReadBitDouble")
            }
        }

        func read2BitDouble() throws -> XY { XY(try readBitDouble(), try readBitDouble()) }
        func read3BitDouble() throws -> XYZ { XYZ(try readBitDouble(), try readBitDouble(), try readBitDouble()) }

        func readRawChar() throws -> UInt8 { try readByte() }
        func readRawLong() throws -> Int64 { Int64(try readInt()) }
        func readRawULong() throws -> UInt64 { UInt64(littleEndianBytes: try readBytes(8)) }
        func read2RawDouble() throws -> XY { XY(try readDouble(), try readDouble()) }
        func read3RawDouble() throws -> XYZ { XYZ(try readDouble(), try readDouble(), try readDouble()) }

        func readModularChar() throws -> UInt64 {
            var shift: UInt64 = 0
            let first = try readByte()
            var value = UInt64(first & 0b0111_1111)
            if first & 0b1000_0000 != 0 {
                while true {
                    shift += 7
                    let last = try readByte()
                    value |= UInt64(last & 0b0111_1111) << shift
                    if last & 0b1000_0000 == 0 { break }
                }
            }
            return value
        }

        func readSignedModularChar() throws -> Int64 {
            var value: Int64
            if bitShift == 0 {
                try advanceByte()
                if lastByte & 0b1000_0000 == 0 {
                    value = Int64(lastByte & 0b0011_1111)
                    if lastByte & 0b0100_0000 > 0 { value = -value }
                } else {
                    var totalShift: Int64 = 0
                    var sum = Int64(lastByte & 0x7F)
                    while true {
                        totalShift += 7
                        try advanceByte()
                        if lastByte & 0b1000_0000 != 0 {
                            sum |= Int64(lastByte & 0x7F) << totalShift
                        } else {
                            break
                        }
                    }
                    value = sum | (Int64(lastByte & 0b0011_1111) << totalShift)
                    if lastByte & 0b0100_0000 > 0 { value = -value }
                }
            } else {
                let first = try applyShiftToLastByte()
                if first & 0b1000_0000 == 0 {
                    value = Int64(first & 0b0011_1111)
                    if first & 0b0100_0000 > 0 { value = -value }
                } else {
                    // C# sums in an int here: shifts are taken modulo 32 and the result wraps.
                    var totalShift: Int32 = 0
                    var sum = Int32(first & 0x7F)
                    var current: UInt8
                    while true {
                        totalShift += 7
                        current = try applyShiftToLastByte()
                        if current & 0b1000_0000 != 0 {
                            sum |= Int32(current & 0x7F) << (totalShift & 31)
                        } else {
                            break
                        }
                    }
                    value = Int64(sum | (Int32(current & 0b0011_1111) << (totalShift & 31)))
                    if current & 0b0100_0000 > 0 { value = -value }
                }
            }
            return value
        }

        func readModularShort() throws -> Int32 {
            var shift: Int32 = 0b1111
            var b1 = try readByte()
            var b2 = try readByte()
            var flag = b2 & 0b1000_0000 == 0
            var value = Int32(b1) | (Int32(b2 & 0b111_1111) << 8)
            while !flag {
                b1 = try readByte()
                b2 = try readByte()
                flag = b2 & 0b1000_0000 == 0
                value |= Int32(b1) << (shift & 31)
                shift += 8
                value |= Int32(b2 & 0b111_1111) << (shift & 31)
                shift += 7
            }
            return value
        }

        // ───────────────────────── Handle references ─────────────────────────

        func handleReference(_ referenceHandle: UInt64) throws -> UInt64 {
            var type = DwgReferenceType.undefined
            return try handleReference(referenceHandle, &type)
        }

        func handleReference(_ referenceHandle: UInt64, _ reference: inout DwgReferenceType) throws -> UInt64 {
            // |CODE (4 bits)|COUNTER (4 bits)|HANDLE or OFFSET|
            let form = try readByte()
            let code = form >> 4
            let counter = Int(form & 0b0000_1111)
            reference = DwgReferenceType(rawValue: code & 0b0011) ?? .undefined
            switch code {
            case 0...5: return try readHandle(counter)
            case 6: return referenceHandle &+ 1
            case 8: return referenceHandle &- 1
            case 0xA: return referenceHandle &+ (try readHandle(counter))
            case 0xC: return referenceHandle &- (try readHandle(counter))
            default: throw DwgError("[HandleReference] invalid reference code with value: \(code)")
            }
        }

        private func readHandle(_ length: Int) throws -> UInt64 {
            let raw = Array(_stream.read(length))
            guard raw.count == length else { throw DwgError.endOfStream }
            var arr = [UInt8](repeating: 0, count: 8)
            if bitShift == 0 {
                for i in 0..<length where length - 1 - i < 8 { arr[length - 1 - i] = raw[i] }
            } else {
                let shift = UInt32(8 - bitShift)
                for i in 0..<length {
                    let lastByteValue = UInt8(truncatingIfNeeded: UInt32(lastByte) << UInt32(bitShift))
                    lastByte = raw[i]
                    let value = lastByteValue | UInt8(truncatingIfNeeded: UInt32(lastByte) >> shift)
                    if length - 1 - i < 8 { arr[length - 1 - i] = value }
                }
            }
            // C# indexes an 8-byte array: a counter above 8 throws IndexOutOfRangeException.
            guard length <= 8 else { throw DwgError("Index was outside the bounds of the array.") }
            return UInt64(littleEndianBytes: arr)
        }

        // ───────────────────────── Texts ─────────────────────────

        func readTextUnicode() throws -> String {
            if version >= .ac1021 {
                let textLength = try readShort()
                guard textLength != 0 else { return "" }
                let length = Int(Int16(truncatingIfNeeded: Int32(textLength) << 1))
                return try readString(length, .utf16LittleEndian).replacingOccurrences(of: "\0", with: "")
            }
            let textLength = Int(try readShort())
            let encodingKey = try readByte()
            guard textLength != 0 else { return "" }
            // TextEncoding.GetListedEncoding((CodePage)key): IBM037 (37) is listed without an encoding (null), every
            // other byte gives Encoding.Default.
            if encodingKey == 37 { throw DwgError("Object reference not set to an instance of an object.") }
            return try readString(textLength, .utf8)
        }

        func readVariableText() throws -> String {
            if version >= .ac1021 {
                let textLength = Int32(try readBitShort())
                guard textLength != 0 else { return "" }
                let length = Int(Int16(truncatingIfNeeded: textLength << 1))
                return try readString(length, .utf16LittleEndian).replacingOccurrences(of: "\0", with: "")
            }
            let length = Int(try readBitShort())
            guard length > 0 else { return "" }
            return try readString(length, encoding).replacingOccurrences(of: "\0", with: "")
        }

        /// `StreamIO.ReadString`: the bytes through the shift, decoded like `Encoding.GetString`.
        func readString(_ length: Int, _ encoding: String.Encoding) throws -> String {
            if length == 0 { return "" }
            return DwgText.decode(try readBytes(length), encoding)
        }

        func readSentinel() throws -> [UInt8] { try readBytes(16) }

        func read2BitDoubleWithDefault(_ def: XY) throws -> XY {
            XY(try readBitDoubleWithDefault(def.x), try readBitDoubleWithDefault(def.y))
        }

        func read3BitDoubleWithDefault(_ def: XYZ) throws -> XYZ {
            XYZ(try readBitDoubleWithDefault(def.x), try readBitDoubleWithDefault(def.y), try readBitDoubleWithDefault(def.z))
        }

        // ───────────────────────── Colours ─────────────────────────

        func readCmColor(useTextStream: Bool = false) throws -> Color {
            guard version >= .ac1018 else {
                // R15 and earlier: BS color index
                return try Color.checked(index: try readBitShort())
            }
            _ = try readBitShort()
            let rgb = UInt32(bitPattern: try readBitLong())
            let color: Color
            if rgb == 0xC000_0000 {
                color = .byLayer
            } else if rgb & 0x0100_0000 != 0 {
                color = Color(index: Int16(rgb & 0xFF))
            } else {
                color = Color(UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
            }
            let id = try readByte()
            if id & 1 == 1 { _ = try readVariableText() }
            if id & 2 == 2 { _ = try readVariableText() }
            return color
        }

        func readEnColor(_ transparency: inout Transparency, _ flag: inout Bool) throws -> Color {
            guard version >= .ac1018 else {
                flag = false
                let colorNumber = try readBitShort()
                transparency = .byLayer
                return try Color.checked(index: colorNumber)
            }
            transparency = .byLayer
            flag = false
            let size = try readBitShort()
            guard size != 0 else {
                transparency = .opaque
                return .byBlock
            }
            let flags = UInt16(bitPattern: size) & 0b1111_1111_0000_0000
            var color: Color
            if flags & 0x4000 > 0 {
                color = .byBlock
                flag = true
            } else if flags & 0x8000 > 0 {
                let rgb = UInt32(bitPattern: try readBitLong())
                color = Color(UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
            } else {
                color = try Color.checked(index: size & 0b1111_1111_1111)
            }
            if flags & 0x2000 > 0 {
                transparency = Transparency.fromAlphaValue(try readBitLong())
            } else {
                transparency = .byLayer
            }
            return color
        }

        func readColorByIndex() throws -> Color { try Color.checked(index: try readBitShort()) }

        func readObjectType() throws -> Int16 {
            guard version >= .ac1024 else { return try readBitShort() }
            switch try read2Bits() {
            case 0: return Int16(try readByte())
            case 1: return Int16(0x1F0 + Int(try readByte()))
            default: return try readShort()
            }
        }

        func readBitExtrusion() throws -> XYZ {
            guard version >= .ac1015 else { return try read3BitDouble() }
            return try readBit() ? .axisZ : try read3BitDouble()
        }

        func readBitThickness() throws -> Double {
            guard version >= .ac1015 else { return try readBitDouble() }
            return try readBit() ? 0.0 : try readBitDouble()
        }

        func readBitDoubleWithDefault(_ def: Double) throws -> Double {
            var arr = withUnsafeBytes(of: def.bitPattern.littleEndian) { Array($0) }
            func patch(_ indices: [Int]) throws {
                if bitShift == 0 {
                    for i in indices {
                        try advanceByte()
                        arr[i] = lastByte
                    }
                } else {
                    let shift = UInt32(8 - bitShift)
                    for i in indices {
                        arr[i] = UInt8(truncatingIfNeeded: UInt32(lastByte) << UInt32(bitShift))
                        try advanceByte()
                        arr[i] |= UInt8(truncatingIfNeeded: UInt32(lastByte) >> shift)
                    }
                }
            }
            switch try read2Bits() {
            case 0: return def
            case 1:
                try patch([0, 1, 2, 3])
                return Double(bitPattern: UInt64(littleEndianBytes: arr))
            case 2:
                try patch([4, 5, 0, 1, 2, 3])
                return Double(bitPattern: UInt64(littleEndianBytes: arr))
            default: return try readDouble()
            }
        }

        // ───────────────────────── Raw values (StreamIO through ReadBytes) ─────────────────────────

        func readShort() throws -> Int16 { Int16(bitPattern: try readUShort()) }

        func readUShort() throws -> UInt16 {
            let b = try readBytes(2)
            return UInt16(b[0]) | UInt16(b[1]) << 8
        }

        func readShortBigEndian() throws -> Int16 {
            let b = try readBytes(2)
            return Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
        }

        func readInt() throws -> Int32 { Int32(bitPattern: try readUInt()) }

        func readUInt() throws -> UInt32 {
            let b = try readBytes(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        func readDouble() throws -> Double { Double(bitPattern: UInt64(littleEndianBytes: try readBytes(8))) }

        // ───────────────────────── Dates ─────────────────────────

        func read8BitJulianDate() throws -> CadDateTime {
            try CadDateTime.fromDwg(jdate: try readInt(), milliseconds: try readInt())
        }

        func readDateTime() throws -> CadDateTime {
            try CadDateTime.fromDwg(jdate: try readBitLong(), milliseconds: try readBitLong())
        }

        func readTimeSpan() throws -> CadTimeSpan {
            CadTimeSpan.fromDwg(hours: try readBitLong(), milliseconds: try readBitLong())
        }

        // ───────────────────────── Position ─────────────────────────

        func positionInBits() -> Int {
            var bitPosition = _stream.position * 8
            if bitShift > 0 { bitPosition += bitShift - 8 }
            return bitPosition
        }

        func setPositionInBits(_ position: Int) throws {
            try setPosition(position >> 3)
            bitShift = position & 7
            if bitShift > 0 { try advanceByte() }
        }

        func advanceByte() throws { lastByte = try baseReadByte() }

        func advance(_ offset: Int) throws {
            if offset > 1 { try _stream.seek(_stream.position + offset - 1) }
            _ = try readByte()
        }

        func resetShift() throws -> UInt16 {
            if bitShift > 0 { bitShift = 0 }
            try advanceByte()
            let num = UInt16(lastByte)
            try advanceByte()
            return num | UInt16(lastByte) << 8
        }

        private func applyFlagToPosition(_ lastPos: Int) throws -> (length: Int, size: Int) {
            var length = lastPos - 16
            try setPositionInBits(length)
            var strDataSize = Int(try readUShort())
            if strDataSize & 0x8000 > 0 {
                length -= 16
                try setPositionInBits(length)
                strDataSize &= Int(Int16.max)
                let hiSize = Int(try readUShort())
                strDataSize += (hiSize & 0xFFFF) << 15
            }
            return (length, strDataSize)
        }

        private func applyShiftToLastByte() throws -> UInt8 {
            let value = UInt8(truncatingIfNeeded: UInt32(lastByte) << UInt32(bitShift))
            try advanceByte()
            return value | UInt8(truncatingIfNeeded: UInt32(lastByte) >> UInt32(8 - bitShift))
        }

        private func read3Bits() throws -> UInt8 {
            var b: UInt8 = try readBit() ? 1 : 0
            b = b << 1 | (try readBit() ? 1 : 0)
            b = b << 1 | (try readBit() ? 1 : 0)
            return b
        }
    }

    /// `DwgMergedReader`: object data from the main stream, texts from the string stream, handles from the handle
    /// stream (R2007+).
    final class DwgMergedReader: DwgBitReader {
        private let main: DwgBitReader
        private let text: DwgBitReader
        private let handles: DwgBitReader?

        init(_ main: DwgBitReader, _ text: DwgBitReader, _ handles: DwgBitReader?) {
            self.main = main
            self.text = text
            self.handles = handles
        }

        var encoding: String.Encoding {
            get { main.encoding }
            set {
                main.encoding = newValue
                text.encoding = newValue
                handles?.encoding = newValue
            }
        }

        var isEmpty: Bool { false }
        var position: Int { main.position }
        func setPosition(_ value: Int) throws { throw DwgError.invalidOperation }
        var stream: DwgStream { get throws { throw DwgError.invalidOperation } }

        private var handleReader: DwgBitReader {
            get throws {
                guard let handles else { throw DwgError("Object reference not set to an instance of an object.") }
                return handles
            }
        }

        func advance(_ offset: Int) throws { try main.advance(offset) }
        func advanceByte() throws { throw DwgError.invalidOperation }
        func handleReference(_ referenceHandle: UInt64) throws -> UInt64 { try handleReader.handleReference(referenceHandle) }
        func handleReference(_ referenceHandle: UInt64, _ reference: inout DwgReferenceType) throws -> UInt64 {
            try handleReader.handleReference(referenceHandle, &reference)
        }
        func positionInBits() -> Int { main.positionInBits() }
        func read2Bits() throws -> UInt8 { try main.read2Bits() }
        func read2RawDouble() throws -> XY { try main.read2RawDouble() }
        func read3RawDouble() throws -> XYZ { try main.read3RawDouble() }
        func read3BitDouble() throws -> XYZ { try main.read3BitDouble() }
        func readBit() throws -> Bool { try main.readBit() }
        func readBitAsShort() throws -> Int16 { try main.readBitAsShort() }
        func readBitDouble() throws -> Double { try main.readBitDouble() }
        func read2BitDouble() throws -> XY { try main.read2BitDouble() }
        func readBitLong() throws -> Int32 { try main.readBitLong() }
        func readBitLongLong() throws -> Int64 { try main.readBitLongLong() }
        func readBitShort() throws -> Int16 { try main.readBitShort() }
        func readBitShortAsBool() throws -> Bool { try main.readBitShortAsBool() }
        func readByte() throws -> UInt8 { try main.readByte() }
        func readBytes(_ length: Int) throws -> [UInt8] { try main.readBytes(length) }
        func read2BitDoubleWithDefault(_ def: XY) throws -> XY { try main.read2BitDoubleWithDefault(def) }
        func read3BitDoubleWithDefault(_ def: XYZ) throws -> XYZ { try main.read3BitDoubleWithDefault(def) }

        func readCmColor(useTextStream: Bool = false) throws -> Color {
            if let reader = main as? DwgStreamReader, reader.version < .ac1018, !useTextStream {
                return try main.readCmColor(useTextStream: false)
            }
            // The colour and book names come from the string stream.
            _ = try readBitShort()
            let rgb = UInt32(bitPattern: try readBitLong())
            let color: Color
            if rgb == 0xC000_0000 {
                color = .byLayer
            } else if rgb & 0x0100_0000 != 0 {
                color = Color(index: Int16(rgb & 0xFF))
            } else {
                color = Color(UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
            }
            let id = try readByte()
            if id & 1 == 1 { _ = try readVariableText() }
            if id & 2 == 2 { _ = try readVariableText() }
            return color
        }

        func readEnColor(_ transparency: inout Transparency, _ flag: inout Bool) throws -> Color {
            try main.readEnColor(&transparency, &flag)
        }
        func read8BitJulianDate() throws -> CadDateTime { throw DwgError.notImplemented }
        func readDateTime() throws -> CadDateTime { try main.readDateTime() }
        func readDouble() throws -> Double { throw DwgError.notImplemented }
        func readInt() throws -> Int32 { throw DwgError.notImplemented }
        func readModularChar() throws -> UInt64 { throw DwgError.notImplemented }
        func readSignedModularChar() throws -> Int64 { throw DwgError.notImplemented }
        func readModularShort() throws -> Int32 { throw DwgError.notImplemented }
        /// `new Color((byte)ReadBitShort())`: the index is truncated to a byte.
        func readColorByIndex() throws -> Color { Color(index: Int16(UInt8(truncatingIfNeeded: try readBitShort()))) }
        func readObjectType() throws -> Int16 { throw DwgError.notImplemented }
        func readBitExtrusion() throws -> XYZ { try main.readBitExtrusion() }
        func readBitDoubleWithDefault(_ def: Double) throws -> Double { try main.readBitDoubleWithDefault(def) }
        func readBitThickness() throws -> Double { try main.readBitThickness() }
        func readRawChar() throws -> UInt8 { try main.readRawChar() }
        func readRawLong() throws -> Int64 { try main.readRawLong() }
        func readRawULong() throws -> UInt64 { try main.readRawULong() }
        func readSentinel() throws -> [UInt8] { try main.readSentinel() }
        func readShort() throws -> Int16 { try main.readShort() }
        func readTextUnicode() throws -> String { text.isEmpty ? "" : try text.readTextUnicode() }
        func readTimeSpan() throws -> CadTimeSpan { try main.readTimeSpan() }
        func readUInt() throws -> UInt32 { throw DwgError.notImplemented }
        func readVariableText() throws -> String { text.isEmpty ? "" : try text.readVariableText() }
        func resetShift() throws -> UInt16 { try main.resetShift() }
        func setPositionInBits(_ position: Int) throws { try main.setPositionInBits(position) }
        func setPositionByFlag(_ position: Int) throws -> Int { throw DwgError.invalidOperation }
    }

    /// Decoding of DWG strings like .NET's `Encoding.GetString`.
    enum DwgText {
        static func decode(_ bytes: [UInt8], _ encoding: String.Encoding) -> String {
            if encoding == .utf16LittleEndian {
                // .NET keeps unpaired surrogates; Swift strings cannot, so they become U+FFFD.
                var units = [UInt16]()
                units.reserveCapacity(bytes.count / 2)
                var i = 0
                while i + 1 < bytes.count {
                    units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
                    i += 2
                }
                var text = String(decoding: units, as: UTF16.self)
                if bytes.count % 2 == 1 { text += "\u{FFFD}" }
                return text
            }
            return TextEncodings.decode(Data(bytes), encoding: encoding)
        }

        /// CSUtilities' own Windows-1252 table (`TextEncoding.Windows1252()`): the five unassigned bytes stay C1
        /// controls.
        static func windows1252(_ bytes: [UInt8]) -> String {
            String(String.UnicodeScalarView(bytes.map { b in
                guard b >= 0x80 && b < 0xA0 else { return Unicode.Scalar(b) }
                return Unicode.Scalar(cp1252High[Int(b - 0x80)])!
            }))
        }

        private static let cp1252High: [UInt32] = [
            0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D,
            0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
            0x0153, 0x9D, 0x017E, 0x0178,
        ]
    }
}

extension ACad.Color {
    /// `new Color(short index)`: throws outside 0 … 257.
    static func checked(index: Int16) throws -> ACad.Color {
        guard index >= 0, index <= 257 else {
            throw ACad.DwgError("True index must be a value between 0 and 257. (Parameter 'index')")
        }
        return ACad.Color(index: index)
    }
}

fileprivate extension UInt64 {
    /// `LittleEndianConverter.ToUInt64` of the first 8 bytes.
    init(littleEndianBytes b: [UInt8]) {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[i]) << UInt64(8 * i) }
        self = v
    }
}
