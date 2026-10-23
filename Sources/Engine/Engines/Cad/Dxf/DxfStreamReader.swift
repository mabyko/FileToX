// DXF group code readers (ACadSharp DxfStreamReaderBase, DxfTextReader, DxfBinaryReader, DxfBinaryReaderAC1009):
// one code / value pair at a time, typed by the code's value type.

import Foundation

extension ACad {
    /// `DxfException`.
    struct DxfException: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        init(code: Int, position: Int) { message = "Invalid dxf code with value \(code), at line \(position)." }
        var description: String { message }
    }

    /// `GroupCodeValueType`.
    enum GroupCodeValueType {
        case none, string, point3D, double, byte, int16, int32, int64, handle, objectId, bool, chunk, comment
        case extendedDataString, extendedDataChunk, extendedDataHandle, extendedDataDouble, extendedDataInt16, extendedDataInt32

        /// `GroupCodeValue.TransformValue`.
        static func of(_ code: Int) -> GroupCodeValueType {
            switch code {
            case 0...4: return .string
            case 5: return .handle
            case 6...9: return .string
            case 10...39: return .point3D
            case 40...59: return .double
            case 60...79: return .int16
            case 90...99: return .int32
            case 100, 101, 102: return .string
            case 105: return .handle
            case 110...149: return .double
            case 160...169: return .int64
            case 170...179: return .int16
            case 210...239: return .double
            case 270...279: return .int16
            case 280...289: return .byte
            case 290...299: return .bool
            case 300...309: return .string
            case 310...319: return .chunk
            case 320...329: return .handle
            case 330...369: return .objectId
            case 370...389: return .int16
            case 390...399: return .objectId
            case 400...409: return .int16
            case 410...419: return .string
            case 420...429, 440...449, 450...459: return .int32
            case 430...439: return .string
            case 460...469: return .double
            case 470...479: return .string
            case 480, 481: return .handle
            case 999: return .comment
            case 1000...1003: return .extendedDataString
            case 1004: return .extendedDataChunk
            case 1005...1009: return .extendedDataHandle
            case 1010...1059: return .extendedDataDouble
            case 1060...1070: return .extendedDataInt16
            case 1071: return .extendedDataInt32
            default: return .none
            }
        }
    }

    /// A DXF value as read (`object Value`).
    enum DxfRawValue {
        case string(String)
        case double(Double)
        case short(Int16)
        case int(Int32)
        case long(Int64)
        case handle(UInt64)
        case bool(Bool)
        case bytes(Data)

        /// .NET `Convert.ToDouble`.
        func double() throws -> Double {
            switch self {
            case let .double(v): return v
            case let .short(v): return Double(v)
            case let .int(v): return Double(v)
            case let .long(v): return Double(v)
            case let .handle(v): return Double(v)
            case let .bool(v): return v ? 1 : 0
            case let .string(s):
                guard let v = Double(s.trimmingCharacters(in: .whitespaces)) else { throw DxfException("Input string was not in a correct format.") }
                return v
            case .bytes: throw DxfException("Invalid cast from 'System.Byte[]' to 'System.Double'.")
            }
        }

        /// .NET `Convert.ToInt64` family: doubles round half to even, out of range throws.
        func integer(_ range: ClosedRange<Int64>) throws -> Int64 {
            let value: Int64
            switch self {
            case let .short(v): value = Int64(v)
            case let .int(v): value = Int64(v)
            case let .long(v): value = v
            case let .handle(v):
                guard v <= UInt64(Int64.max) else { throw DxfException("Value was either too large or too small.") }
                value = Int64(v)
            case let .bool(v): value = v ? 1 : 0
            case let .double(d):
                let r = d.rounded(.toNearestOrEven)
                guard r.isFinite, r >= -9.2e18, r <= 9.2e18 else { throw DxfException("Value was either too large or too small.") }
                value = Int64(r)
            case let .string(s):
                guard let v = Int64(s.trimmingCharacters(in: .whitespaces)) else { throw DxfException("Input string was not in a correct format.") }
                value = v
            case .bytes: throw DxfException("Invalid cast from 'System.Byte[]'.")
            }
            guard range.contains(value) else { throw DxfException("Value was either too large or too small.") }
            return value
        }

        func bool() throws -> Bool {
            switch self {
            case let .bool(v): return v
            case let .short(v): return v != 0
            case let .int(v): return v != 0
            case let .long(v): return v != 0
            case let .double(v): return v != 0
            case let .handle(v): return v != 0
            case let .string(s):
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true": return true
                case "false": return false
                default: throw DxfException("String '\(s)' was not recognized as a valid Boolean.")
                }
            case .bytes: throw DxfException("Invalid cast from 'System.Byte[]' to 'System.Boolean'.")
            }
        }

        /// `Value.ToString()`.
        var text: String {
            switch self {
            case let .string(s): return s
            case let .double(v): return DxfNumber.netString(v)
            case let .short(v): return String(v)
            case let .int(v): return String(v)
            case let .long(v): return String(v)
            case let .handle(v): return String(v)
            case let .bool(v): return v ? "True" : "False"
            case .bytes: return "System.Byte[]"
            }
        }
    }

    /// Reads code / value pairs (`IDxfStreamReader`).
    class DxfGroupReader {
        private(set) var code: Int = -9999
        private(set) var groupType: GroupCodeValueType = .none
        private(set) var value: DxfRawValue = .string("")
        /// Line number (text) or byte offset (binary), for messages.
        var position: Int = 0

        static let invalidCode = -9999

        /// `Start`: back to the first group; the current value is cleared.
        func start() throws {
            code = DxfGroupReader.invalidCode
            value = .string("")
            groupType = .none
        }
        func readCode() throws -> Int { fatalError("abstract") }
        func readStringLine() throws -> String { fatalError("abstract") }
        func lineAsBool() throws -> Bool { fatalError("abstract") }
        func lineAsDouble() throws -> Double { fatalError("abstract") }
        func lineAsShort() throws -> Int16 { fatalError("abstract") }
        func lineAsInt() throws -> Int32 { fatalError("abstract") }
        func lineAsLong() throws -> Int64 { fatalError("abstract") }
        func lineAsHandle() throws -> UInt64 { fatalError("abstract") }
        func lineAsBinaryChunk() throws -> Data { fatalError("abstract") }
        func advanced() {}

        /// `ReadNext`; comments (999) are skipped.
        func readNext() throws {
            code = try readCode()
            groupType = GroupCodeValueType.of(code)
            switch groupType {
            case .string, .comment, .extendedDataString: value = .string(try readStringLine())
            case .point3D, .double, .extendedDataDouble: value = .double(try lineAsDouble())
            case .byte, .int16, .extendedDataInt16: value = .short(try lineAsShort())
            case .int32, .extendedDataInt32: value = .int(try lineAsInt())
            case .int64: value = .long(try lineAsLong())
            case .handle, .objectId, .extendedDataHandle: value = .handle(try lineAsHandle())
            case .bool: value = .bool(try lineAsBool())
            case .chunk, .extendedDataChunk: value = .bytes(try lineAsBinaryChunk())
            case .none: throw DxfException(code: code, position: position)
            }
            advanced()
            if code == 999 { try readNext() }
        }

        /// `Find`: from the start up to the given value (or EOF).
        func find(_ entry: String) throws -> Bool {
            try start()
            repeat {
                try readNext()
            } while valueAsString != entry && valueAsString != DxfFileToken.endOfFile
            return valueAsString == entry
        }

        func expectedCode(_ expected: Int) throws {
            try readNext()
            if code != expected { throw DxfException(code: code, position: position) }
        }

        /// `ValueAsString`: the value text with ^J ^M ^I ^  decoded.
        var valueAsString: String {
            let raw = value.text
            guard raw.contains("^") else { return raw }
            return raw.replacingOccurrences(of: "^J", with: "\n").replacingOccurrences(of: "^M", with: "\r")
                .replacingOccurrences(of: "^I", with: "\t").replacingOccurrences(of: "^ ", with: "^")
        }

        var valueAsDouble: Double { get throws { try value.double() } }
        var valueAsAngle: Double { get throws { MathHelper.degToRad(try value.double()) } }
        var valueAsShort: Int16 { get throws { Int16(try value.integer(-32768...32767)) } }
        var valueAsUShort: UInt16 { get throws { UInt16(try value.integer(0...65535)) } }
        var valueAsInt: Int32 { get throws { Int32(try value.integer(-2_147_483_648...2_147_483_647)) } }
        var valueAsLong: Int64 { get throws { try value.integer(Int64.min...Int64.max) } }
        var valueAsBool: Bool { get throws { try value.bool() } }
        var valueAsHandle: UInt64 {
            get throws {
                if case let .handle(h) = value { return h }
                throw DxfException("Specified cast is not valid.")
            }
        }
        var valueAsBinaryChunk: Data? {
            if case let .bytes(d) = value { return d }
            return nil
        }
    }

    /// `DxfTextReader`: lines decoded with the drawing's encoding.
    final class DxfTextGroupReader: DxfGroupReader {
        private let bytes: [UInt8]
        private let encoding: String.Encoding
        private var offset = 0
        private let bodyStart: Int

        init(_ data: Data, encoding: String.Encoding) {
            bytes = [UInt8](data)
            self.encoding = encoding
            // StreamReader skips a byte order mark.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bodyStart = 3 }
            else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { bodyStart = 2 }
            else { bodyStart = 0 }
            super.init()
            offset = bodyStart
        }

        override func start() throws {
            try super.start()
            offset = bodyStart
            position = 0
        }

        override func advanced() { position += 2 }

        /// `StreamReader.ReadLine`: CR, LF or CR LF; nil at the end.
        private func readLine() -> [UInt8]? {
            guard offset < bytes.count else { return nil }
            let begin = offset
            while offset < bytes.count {
                let b = bytes[offset]
                if b == 0x0A {
                    let line = Array(bytes[begin..<offset])
                    offset += 1
                    return line
                }
                if b == 0x0D {
                    let line = Array(bytes[begin..<offset])
                    offset += 1
                    if offset < bytes.count, bytes[offset] == 0x0A { offset += 1 }
                    return line
                }
                offset += 1
            }
            return Array(bytes[begin..<offset])
        }

        private func decode(_ line: [UInt8]) -> String {
            if encoding == .utf8 || line.allSatisfy({ $0 < 0x80 }) { return String(decoding: line, as: UTF8.self) }
            return TextEncodings.decode(Data(line), encoding: encoding)
        }

        override func readStringLine() throws -> String {
            guard let line = readLine() else { throw DxfException("Unexpected end of the DXF file at line \(position).") }
            return decode(line)
        }

        private func trimmed() throws -> String { try readStringLine().trimmingCharacters(in: .whitespaces) }

        override func readCode() throws -> Int {
            guard let line = readLine() else { throw DxfException("Unexpected end of the DXF file at line \(position).") }
            if let value = Int(decode(line).trimmingCharacters(in: .whitespaces)), value >= Int(Int32.min), value <= Int(Int32.max) {
                return value
            }
            position += 1
            return DxfGroupReader.invalidCode
        }

        override func lineAsBool() throws -> Bool { (UInt8(try trimmed()) ?? 0) > 0 }
        override func lineAsDouble() throws -> Double { DxfNumber.parseDouble(try trimmed()) ?? 0 }
        override func lineAsShort() throws -> Int16 { Int16(try trimmed()) ?? 0 }
        override func lineAsInt() throws -> Int32 { Int32(try trimmed()) ?? 0 }
        override func lineAsLong() throws -> Int64 { Int64(try trimmed()) ?? 0 }
        override func lineAsHandle() throws -> UInt64 { UInt64(try trimmed(), radix: 16) ?? 0 }

        override func lineAsBinaryChunk() throws -> Data {
            let text = Array(try readStringLine().utf8)
            var result = Data(capacity: text.count / 2)
            var i = 0
            while i < text.count {
                guard i + 1 < text.count,
                      let byte = UInt8(String(decoding: text[i...i + 1], as: UTF8.self).trimmingCharacters(in: .whitespaces), radix: 16)
                else { return Data() }
                result.append(byte)
                i += 2
            }
            return result
        }
    }

    /// `DxfBinaryReader` (and the AC1009 variant with 1-byte codes).
    final class DxfBinaryGroupReader: DxfGroupReader {
        static let sentinel = Array("AutoCAD Binary DXF\r\n\u{1a}\0".utf8)

        private let bytes: [UInt8]
        private let encoding: String.Encoding
        private let isAC1009: Bool
        private var offset = 0

        init(_ data: Data, encoding: String.Encoding, isAC1009: Bool) {
            bytes = [UInt8](data)
            self.encoding = encoding
            self.isAC1009 = isAC1009
            super.init()
            offset = 22
        }

        override func start() throws {
            try super.start()
            offset = min(22, bytes.count)
        }

        private func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard offset + n <= bytes.count else { throw EndOfStreamError() }
            defer { offset += n; position = offset }
            return bytes[offset..<offset + n]
        }

        private func u8() throws -> UInt8 { try take(1).first! }
        private func i16() throws -> Int16 { let s = try take(2); return Int16(bitPattern: UInt16(s[s.startIndex]) | UInt16(s[s.startIndex + 1]) << 8) }
        private func i32() throws -> Int32 {
            let s = try take(4)
            var v: UInt32 = 0
            for (i, b) in s.enumerated() { v |= UInt32(b) << (8 * UInt32(i)) }
            return Int32(bitPattern: v)
        }
        private func i64() throws -> Int64 {
            let s = try take(8)
            var v: UInt64 = 0
            for (i, b) in s.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
            return Int64(bitPattern: v)
        }

        override func readStringLine() throws -> String {
            var line: [UInt8] = []
            var b = try u8()
            while b != 0 {
                line.append(b)
                b = try u8()
            }
            if encoding == .utf8 || line.allSatisfy({ $0 < 0x80 }) { return String(decoding: line, as: UTF8.self) }
            return TextEncodings.decode(Data(line), encoding: encoding)
        }

        override func readCode() throws -> Int {
            if isAC1009 {
                let b = Int(try u8())
                return b == 255 ? Int(try i16()) : b
            }
            return Int(try i16())
        }

        override func lineAsBool() throws -> Bool { try u8() > 0 }
        override func lineAsDouble() throws -> Double { Double(bitPattern: UInt64(bitPattern: try i64())) }
        override func lineAsShort() throws -> Int16 { try i16() }
        override func lineAsInt() throws -> Int32 { try i32() }
        override func lineAsLong() throws -> Int64 { try i64() }
        override func lineAsHandle() throws -> UInt64 { UInt64(try readStringLine().trimmingCharacters(in: .whitespaces), radix: 16) ?? 0 }
        override func lineAsBinaryChunk() throws -> Data { Data(try take(Int(try u8()))) }
    }

    /// Number text as .NET writes and parses it (invariant culture).
    enum DxfNumber {
        /// `double.TryParse(s, NumberStyles.Float, InvariantCulture)`.
        static func parseDouble(_ s: String) -> Double? {
            guard !s.isEmpty else { return nil }
            let lowered = s.lowercased()
            if lowered == "infinity" || lowered == "+infinity" || lowered == "∞" { return .infinity }
            if lowered == "-infinity" || lowered == "-∞" { return -.infinity }
            if lowered == "nan" { return .nan }
            // NumberStyles.Float: leading sign, decimal point, exponent; no thousands separators or hex.
            for c in s.utf8 where !(c >= 0x30 && c <= 0x39) && c != 0x2E && c != 0x2B && c != 0x2D && c != 0x45 && c != 0x65 {
                return nil
            }
            return Double(s)
        }

        /// `double.ToString("R", InvariantCulture)` (.NET Core 3.0+: shortest round-trip digits, "E" notation when the
        /// decimal exponent is below -4 or above 16, like "G17").
        static func netString(_ value: Double) -> String {
            if value.isNaN { return "NaN" }
            if value.isInfinite { return value < 0 ? "-∞" : "∞" }
            if value == 0 { return value.sign == .minus ? "-0" : "0" }
            // Swift's description is the shortest round-trip digit string; reformat it like .NET.
            var text = "\(value)"
            var negative = false
            if text.hasPrefix("-") {
                negative = true
                text.removeFirst()
            }
            var mantissa = text
            var exponent = 0
            if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                mantissa = String(text[..<e])
                exponent = Int(text[text.index(after: e)...]) ?? 0
            }
            var intPart = mantissa
            var fracPart = ""
            if let dot = mantissa.firstIndex(of: ".") {
                intPart = String(mantissa[..<dot])
                fracPart = String(mantissa[mantissa.index(after: dot)...])
            }
            var digits = intPart + fracPart
            var pointPosition = intPart.count + exponent
            while digits.hasPrefix("0"), digits.count > 1 {
                digits.removeFirst()
                pointPosition -= 1
            }
            while digits.hasSuffix("0"), digits.count > 1 { digits.removeLast() }
            let decimalExponent = pointPosition - 1
            var result: String
            if decimalExponent >= 17 || decimalExponent < -4 {
                let first = digits.prefix(1)
                let rest = digits.dropFirst()
                let e = decimalExponent < 0 ? "E-" + String(format: "%02d", -decimalExponent) : "E+" + String(format: "%02d", decimalExponent)
                result = rest.isEmpty ? first + e : first + "." + rest + e
            } else if pointPosition <= 0 {
                result = "0." + String(repeating: "0", count: -pointPosition) + digits
            } else if pointPosition >= digits.count {
                result = digits + String(repeating: "0", count: pointPosition - digits.count)
            } else {
                let index = digits.index(digits.startIndex, offsetBy: pointPosition)
                result = digits[..<index] + "." + digits[index...]
            }
            return negative ? "-" + result : result
        }
    }
}
