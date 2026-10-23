import Foundation

struct EngineCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
extension CodingUserInfoKey {
    static let engineWire = CodingUserInfoKey(rawValue: "FileToX.wire")!
    static let engineStrict = CodingUserInfoKey(rawValue: "FileToX.strict")!
}
extension KeyedDecodingContainer where Key == EngineCodingKey {
    func engineField<T: Decodable>(_ name: String, _ fallback: T) throws -> T {
        let key = EngineCodingKey(name)
        return contains(key) ? try decode(T.self, forKey: key) : fallback
    }
    func engineValidate(_ decoder: Decoder, fields: [String], getters: [String] = []) throws {
        guard decoder.userInfo[.engineStrict] as? Bool == true else { return }
        for field in fields where !contains(EngineCodingKey(field)) {
            throw DecodingError.keyNotFound(EngineCodingKey(field), .init(codingPath: codingPath, debugDescription: "Missing required property \(field)."))
        }
        for key in allKeys where !fields.contains(key.stringValue) && !getters.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Unknown property \(key.stringValue).")
        }
    }
}
extension KeyedEncodingContainer where Key == EngineCodingKey {
    mutating func engineField<T: Encodable>(_ name: String, _ value: T) throws { try encode(value, forKey: EngineCodingKey(name)) }
    mutating func engineOptional<T: Encodable>(_ name: String, _ value: T?, _ encoder: Encoder) throws {
        if encoder.userInfo[.engineWire] as? Bool == true { try encode(value, forKey: EngineCodingKey(name)) }
        else { try encodeIfPresent(value, forKey: EngineCodingKey(name)) }
    }
}
protocol EngineStringEnum: RawRepresentable, CaseIterable, Codable where RawValue == String {}
extension EngineStringEnum {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self), let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) { self = match; return }
        if decoder.userInfo[.engineStrict] as? Bool != true {
            let index = (try? c.decode(Int.self)) ?? (try? c.decode(String.self)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let index, index >= 0, index < Self.allCases.count { self = Array(Self.allCases)[index]; return }
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid \(Self.self) enum name.")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        let value = encoder.userInfo[.engineWire] as? Bool == true ? String(rawValue.prefix(1)).lowercased() + rawValue.dropFirst() : rawValue
        try c.encode(value)
    }
}
extension ModifierKeys: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if decoder.userInfo[.engineStrict] as? Bool != true, let n = try? c.decode(Int.self) { self.init(rawValue: n); return }
        let s = try c.decode(String.self)
        var keys: ModifierKeys = []
        for raw in s.split(separator: ",", omittingEmptySubsequences: false) {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "none": break
            case "ctrl": keys.insert(.ctrl)
            case "alt": keys.insert(.alt)
            case "shift": keys.insert(.shift)
            case "meta": keys.insert(.meta)
            default: throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ModifierKeys enum name.")
            }
        }
        self = keys
    }
    public func encode(to encoder: Encoder) throws {
        let wire = encoder.userInfo[.engineWire] as? Bool == true
        if rawValue & ~15 != 0 {
            if wire { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Undefined ModifierKeys flags.")) }
            var c = encoder.singleValueContainer(); try c.encode(rawValue); return
        }
        let names = [(Self.ctrl, "Ctrl"), (.alt, "Alt"), (.shift, "Shift"), (.meta, "Meta")].filter { contains($0.0) }.map { wire ? $0.1.lowercased() : $0.1 }
        var c = encoder.singleValueContainer(); try c.encode(names.isEmpty ? (wire ? "none" : "None") : names.joined(separator: ", "))
    }
}

public enum FileeJson {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // JSONSerialization accepts trailing commas; strip comments without touching quoted text.
        let clean = stripComments(data)
        let object = try JSONSerialization.jsonObject(with: clean, options: [.fragmentsAllowed])
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: normalized)
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return EngineJsonEscaping.encode(try encoder.encode(value))
    }
    private static func stripComments(_ data: Data) -> Data {
        let bytes = Array(data); var out: [UInt8] = [], i = 0, quoted = false, escape = false
        while i < bytes.count {
            let b = bytes[i]
            if quoted { out.append(b); if b == 34 && !escape { quoted = false }; if b == 92 { escape.toggle() } else { escape = false }; i += 1; continue }
            if b == 34 { quoted = true; out.append(b); i += 1; continue }
            if b == 47 && i + 1 < bytes.count && bytes[i + 1] == 47 { i += 2; while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }; continue }
            if b == 47 && i + 1 < bytes.count && bytes[i + 1] == 42 { i += 2; while i + 1 < bytes.count && !(bytes[i] == 42 && bytes[i + 1] == 47) { if bytes[i] == 10 { out.append(10) }; i += 1 }; if i + 1 >= bytes.count { out.append(0); return Data(out) }; i += 2; continue }
            out.append(b); i += 1
        }
        return Data(out)
    }
}

/// System.Text.Json's default encoder escapes non-ASCII and HTML-sensitive characters. This also keeps wire size
/// limits identical for Unicode-heavy messages; JSONEncoder/JSONSerialization otherwise emit raw UTF-8.
enum EngineJsonEscaping {
    static func encode(_ data: Data) -> Data {
        let bytes = Array(data), hex = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []; result.reserveCapacity(bytes.count)
        var quoted = false, i = 0
        func appendEscape(_ value: UInt32) {
            result.append(92); result.append(117)
            result.append(hex[Int((value >> 12) & 15)]); result.append(hex[Int((value >> 8) & 15)])
            result.append(hex[Int((value >> 4) & 15)]); result.append(hex[Int(value & 15)])
        }
        while i < bytes.count {
            let byte = bytes[i]
            if !quoted {
                if byte == 34 { quoted = true }
                if byte == 58 && result.last == 32 { result.removeLast() }
                result.append(byte); i += 1; continue
            }
            if byte == 92 && i + 1 < bytes.count {
                let next = bytes[i + 1]
                if next == 34 { appendEscape(34) }
                else { result.append(byte); result.append(next) }
                i += 2; continue
            }
            if byte == 34 { quoted = false; result.append(byte); i += 1; continue }
            if byte < 127 {
                switch byte {
                case 38, 60, 62, 39, 43, 96: appendEscape(UInt32(byte))
                default: result.append(byte)
                }
                i += 1; continue
            }
            var scalar: UInt32, length: Int
            if byte == 127 { scalar = 127; length = 1 }
            else if byte < 224 { scalar = UInt32(byte & 31); length = 2 }
            else if byte < 240 { scalar = UInt32(byte & 15); length = 3 }
            else { scalar = UInt32(byte & 7); length = 4 }
            for j in 1..<length { scalar = scalar << 6 | UInt32(bytes[i + j] & 63) }
            if scalar <= 0xffff { appendEscape(scalar) }
            else { let pair = scalar - 0x10000; appendEscape(0xd800 + (pair >> 10)); appendEscape(0xdc00 + (pair & 1023)) }
            i += length
        }
        return Data(result)
    }
}
