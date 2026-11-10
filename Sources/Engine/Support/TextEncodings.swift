// System.Text.Encoding equivalents: code pages (949, 1252, 437 ...) and IANA names through CoreFoundation, with
// .NET's lossy behaviour (invalid bytes become U+FFFD instead of failing), plus Filee's text-file detection.

import CoreFoundation
import Foundation

public enum TextEncodings {
    /// The Foundation encoding for a Windows code page (949, 1252, 932, 65001 ...), or nil.
    public static func encoding(codePage: Int) -> String.Encoding? {
        switch codePage {
        case 65001: return .utf8
        case 1200: return .utf16LittleEndian
        case 1201: return .utf16BigEndian
        case 20127: return .ascii
        case 28591: return .isoLatin1
        default:
            let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codePage))
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    /// The Foundation encoding for an IANA / WHATWG name ("euc-kr", "windows-1252", "shift_jis", "utf-8"), or nil.
    public static func encoding(name: String) -> String.Encoding? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf-16le", "unicode": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "ks_c_5601-1987", "ksc5601", "cp949", "uhc", "windows-949": return encoding(codePage: 949)
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    /// Decodes like .NET's `Encoding.GetString`: never fails, invalid sequences become U+FFFD.
    public static func decode(_ bytes: Data, encoding: String.Encoding) -> String {
        if encoding == .utf8 { return String(decoding: bytes, as: UTF8.self) }
        if let text = String(data: bytes, encoding: encoding) { return text }
        // Lossy fallback: the longest decodable sequence (1–4 bytes) at each position.
        var result = ""
        var index = bytes.startIndex
        outer: while index < bytes.endIndex {
            for length in 1...4 where index + length <= bytes.endIndex {
                if let piece = String(data: bytes[index..<index + length], encoding: encoding), !piece.isEmpty {
                    result += piece
                    index += length
                    continue outer
                }
            }
            result += "\u{FFFD}"
            index += 1
        }
        return result
    }

    public static func decode(_ bytes: Data, codePage: Int) -> String {
        decode(bytes, encoding: encoding(codePage: codePage) ?? .isoLatin1)
    }

    /// Encodes like .NET: unencodable characters become "?".
    public static func encode(_ text: String, encoding: String.Encoding) -> Data {
        text.data(using: encoding, allowLossyConversion: true) ?? Data(text.utf8)
    }

    /// Filee's `DocumentReaders.DecodeText`: UTF-8 (with or without BOM) or UTF-16 with BOM; anything else is read as
    /// CP949, common for Korean text.
    public static func decodeText(_ bytes: Data) -> String {
        if bytes.count >= 2 {
            let b0 = bytes[bytes.startIndex], b1 = bytes[bytes.startIndex + 1]
            if b0 == 0xFF && b1 == 0xFE { return decode(bytes.dropFirst(2), encoding: .utf16LittleEndian) }
            if b0 == 0xFE && b1 == 0xFF { return decode(bytes.dropFirst(2), encoding: .utf16BigEndian) }
        }
        if let text = String(data: bytes, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        return decode(bytes, codePage: 949)
    }
}
