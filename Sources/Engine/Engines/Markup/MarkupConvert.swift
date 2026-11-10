// .NET number conversions the Markup readers rely on, so lengths and sizes come out as in Filee, and their other
// shared helpers.

import Foundation

enum MarkupConvert {
    /// `(int)value` in .NET: truncates toward zero and saturates to the Int32 range (NaN → 0).
    static func int32(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= 2_147_483_647 { return 2_147_483_647 }
        if value <= -2_147_483_648 { return -2_147_483_648 }
        return Int(value)
    }

    /// `int.TryParse(text, out var n)` with the default style: optional surrounding white space (tab, line feeds,
    /// space) and sign, ASCII digits, within the Int32 range.
    static func tryParseInt(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int32(text.trimmingCharacters(in: whiteSpace)).map(Int.init)
    }

    private static let whiteSpace = CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r ")

    /// `string.Equals(a, b, StringComparison.OrdinalIgnoreCase)`: UTF-16 units compared after simple upper-casing.
    static func equalsOrdinalIgnoreCase(_ a: String, _ b: String) -> Bool {
        let left = Markdown.chars(a), right = Markdown.chars(b)
        return left.count == right.count && zip(left, right).allSatisfy { $0 == $1 || $0.upperInvariant == $1.upperInvariant }
    }

    /// `WebUtility.HtmlEncode`: `< > " ' &` as entities, U+00A0–U+00FF and characters outside the BMP as decimal
    /// references.
    static func htmlEncode(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "&": result += "&amp;"
            default:
                if (0xA0...0xFF).contains(scalar.value) || scalar.value >= 0x10000 {
                    result += "&#\(scalar.value);"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// `Uri.UnescapeDataString`: %XX sequences that form UTF-8 are decoded, others stay escaped.
    static func unescapeDataString(_ text: String) -> String {
        guard text.contains("%") else { return text }
        let units = Array(text.utf16)
        var output = ""
        var i = 0
        func hex(_ unit: UInt16) -> UInt8? {
            switch unit {
            case 0x30...0x39: UInt8(unit - 0x30)
            case 0x41...0x46: UInt8(unit - 0x37)
            case 0x61...0x66: UInt8(unit - 0x57)
            default: nil
            }
        }
        while i < units.count {
            var bytes: [UInt8] = []
            var escapes: [String] = []
            while i + 2 < units.count, units[i] == 0x25, let high = hex(units[i + 1]), let low = hex(units[i + 2]) {
                bytes.append(high << 4 | low)
                escapes.append(String(decoding: units[i..<i + 3], as: UTF16.self))
                i += 3
            }
            if !bytes.isEmpty {
                var parser = Unicode.UTF8.ForwardParser()
                var iterator = bytes.makeIterator()
                var consumed = 0
                loop: while true {
                    switch parser.parseScalar(from: &iterator) {
                    case .valid(let encoded):
                        output.unicodeScalars.append(Unicode.UTF8.decode(encoded))
                        consumed += encoded.count
                    case .error(let length):
                        output += escapes[consumed..<consumed + length].joined()
                        consumed += length
                    case .emptyInput:
                        break loop
                    }
                }
                continue
            }
            output += String(decoding: [units[i]], as: UTF16.self)
            i += 1
        }
        return output
    }

    /// `new Uri(path).AbsoluteUri` for an absolute macOS path: "file://" and the path with characters outside the URI
    /// path set percent-encoded as UTF-8, without Unicode normalization (Foundation's file URLs decompose Hangul).
    /// .NET also unescapes some "%XX" sequences in the name ("%41", or "%20" when another "%" is stray) and escapes
    /// characters outside RFC 3987's ranges twice ("\u{80}" → "%25C2%2580"), so its link misses such files; here every
    /// "%" and character is escaped once.
    static func fileUri(_ path: String) -> String {
        var result = "file://"
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "!"), UInt8(ascii: "$"),
                 UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                 UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "="), UInt8(ascii: ":"), UInt8(ascii: "@"), UInt8(ascii: "/"),
                 UInt8(ascii: "["), UInt8(ascii: "]"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// Runs `work` on a thread with a 16 MB stack and waits for it: the readers recurse per nesting level, and deep
    /// input would exhaust the stack of a pool thread (smaller than .NET's), which ends the helper.
    static func onLargeStack(_ work: @escaping () throws -> Void) throws {
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            do { try work() } catch { outcome.error = error }
            done.signal()
        }
        thread.stackSize = 16 * 1024 * 1024
        thread.start()
        done.wait()
        if let error = outcome.error { throw error }
    }
}
