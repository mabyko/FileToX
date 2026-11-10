// MIME syntax as MimeKit 4.18 parses it, on raw header bytes: character classes (ByteExtensions), comments / quoted
// strings / msg-ids (ParseUtils), encoded words (Rfc2047), parameters with RFC 2231 (ParameterList), Content-Type,
// Content-Disposition, dates (DateUtils), address lists (InternetAddressList), the transfer decoders and FlowedToText.
// Kept close to MimeKit's code, including its lenient ("Loose") recovery rules, so headers decode the same way.

import Foundation

enum EmlMime {
    // MARK: Character classes (MimeKit ByteExtensions)

    private struct CharType: OptionSet {
        let rawValue: UInt16
        static let ascii = CharType(rawValue: 1 << 0)
        static let atom = CharType(rawValue: 1 << 1)
        static let attrChar = CharType(rawValue: 1 << 2)
        static let blank = CharType(rawValue: 1 << 3)
        static let control = CharType(rawValue: 1 << 4)
        static let domainSafe = CharType(rawValue: 1 << 5)
        static let tokenSpecial = CharType(rawValue: 1 << 11)
        static let whitespace = CharType(rawValue: 1 << 12)
        static let xdigit = CharType(rawValue: 1 << 13)
        static let phraseAtom = CharType(rawValue: 1 << 14)
        static let fieldText = CharType(rawValue: 1 << 15)
    }

    private static let table: [CharType] = {
        var table = [CharType](repeating: [], count: 256)
        func isAlnum(_ i: Int) -> Bool { (48...57).contains(i) || (97...122).contains(i) || (65...90).contains(i) }
        for i in 0..<256 {
            if i < 127 {
                if i < 32 { table[i].formUnion([.control, .tokenSpecial]) }
                if i > 32 { table[i].insert(.attrChar) }
                if isAlnum(i) { table[i].formUnion([.atom, .phraseAtom]) }
                if (48...57).contains(i) || (97...102).contains(i) || (65...70).contains(i) { table[i].insert(.xdigit) }
                if i >= 33 && i != 58 { table[i].insert(.fieldText) }
                if (i >= 33 && i <= 90) || i >= 94 { table[i].insert(.domainSafe) }
                table[i].insert(.ascii)
            } else {
                if i == 127 { table[i].insert(.ascii) } else { table[i].formUnion([.atom, .phraseAtom]) }
                table[i].formUnion([.control, .tokenSpecial])
            }
        }
        func set(_ characters: String, _ flags: CharType) { for c in characters.utf8 { table[Int(c)].formUnion(flags) } }
        func remove(_ characters: String, _ flags: CharType) { for c in characters.utf8 { table[Int(c)].subtract(flags) } }
        table[9].insert(.blank)
        table[32].insert(.blank)
        set(" \t\r\n", .whitespace)
        set("!#$%&'*+-/=?^_`{|}~", [.atom, .phraseAtom])
        set("()<>@,;:\\\"/[]?=", .tokenSpecial)
        remove("()<>[]:;@\\,.\"", [.atom, .phraseAtom])
        remove("*'%" + "()<>@,;:\\\"/[]?=", .attrChar)
        set("[])", .phraseAtom)
        return table
    }()

    static func isAtom(_ c: UInt8) -> Bool { table[Int(c)].contains(.atom) }
    static func isAsciiAtom(_ c: UInt8) -> Bool { table[Int(c)].isSuperset(of: [.ascii, .atom]) }
    static func isPhraseAtom(_ c: UInt8) -> Bool { table[Int(c)].contains(.phraseAtom) }
    static func isAttr(_ c: UInt8) -> Bool { table[Int(c)].contains(.attrChar) }
    static func isBlank(_ c: UInt8) -> Bool { table[Int(c)].contains(.blank) }
    static func isControl(_ c: UInt8) -> Bool { table[Int(c)].contains(.control) }
    static func isDomain(_ c: UInt8) -> Bool { table[Int(c)].contains(.domainSafe) }
    static func isFieldText(_ c: UInt8) -> Bool { table[Int(c)].contains(.fieldText) }
    static func isToken(_ c: UInt8) -> Bool { table[Int(c)].isDisjoint(with: [.tokenSpecial, .whitespace, .control]) }
    static func isWhitespace(_ c: UInt8) -> Bool { table[Int(c)].contains(.whitespace) }
    static func isXDigit(_ c: UInt8) -> Bool { table[Int(c)].contains(.xdigit) }

    static func xdigitValue(_ c: UInt8) -> UInt8 { c >= 0x61 ? c - 0x57 : c >= 0x41 ? c - 0x37 : c - 0x30 }

    // MARK: ParseUtils

    @discardableResult
    static func skipWhiteSpace(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        let start = index
        while index < end && isWhitespace(text[index]) { index += 1 }
        return index > start
    }

    /// Skips a comment starting at the "(" under `index`; false when it is not closed.
    static func skipComment(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        var escaped = false
        var depth = 1
        index += 1
        while index < end && depth > 0 {
            if text[index] == 0x5C {
                escaped.toggle()
            } else if !escaped {
                if text[index] == 0x28 { depth += 1 } else if text[index] == 0x29 { depth -= 1 }
            } else {
                escaped = false
            }
            index += 1
        }
        return depth == 0
    }

    static func skipCommentsAndWhiteSpace(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        skipWhiteSpace(text, &index, end)
        while index < end && text[index] == 0x28 {
            if !skipComment(text, &index, end) { return false }
            skipWhiteSpace(text, &index, end)
        }
        return true
    }

    /// Skips a quoted string starting at the '"' under `index`; false when it is not closed.
    static func skipQuoted(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        var escaped = false
        index += 1
        while index < end {
            if text[index] == 0x5C {
                escaped.toggle()
            } else if !escaped {
                if text[index] == 0x22 { break }
            } else {
                escaped = false
            }
            index += 1
        }
        if index >= end { return false }
        index += 1
        return true
    }

    @discardableResult
    static func skipAtom(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        let start = index
        while index < end && isAtom(text[index]) { index += 1 }
        return index > start
    }

    static func skipPhraseAtom(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        let start = index
        while index < end && isPhraseAtom(text[index]) { index += 1 }
        return index > start
    }

    static func skipToken(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        let start = index
        while index < end && isToken(text[index]) { index += 1 }
        return index > start
    }

    static func skipWord(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        if text[index] == 0x22 { return skipQuoted(text, &index, end) }
        if isAtom(text[index]) { return skipAtom(text, &index, end) }
        return false
    }

    /// ASCII digits as an Int32 (no sign); false when there are none or on overflow.
    static func tryParseInt32(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Int? {
        let start = index
        var value = 0
        while index < end && text[index] >= 0x30 && text[index] <= 0x39 {
            value = value * 10 + Int(text[index] - 0x30)
            if value > Int(Int32.max) { return nil }
            index += 1
        }
        return index > start ? value : nil
    }

    private static func strictUtf8(_ text: [UInt8], _ range: Range<Int>) -> String? { String(validating: text[range], as: UTF8.self) }

    private static func tryParseDotAtom(_ text: [UInt8], _ index: inout Int, _ end: Int, _ sentinels: [UInt8]) -> String? {
        var token = ""
        repeat {
            guard index < end, isAtom(text[index]) else { return nil }
            let start = index
            while index < end && isAtom(text[index]) { index += 1 }
            guard let word = strictUtf8(text, start..<index) else { return nil }
            token += word
            let comment = index
            if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            if index >= end || text[index] != 0x2E { index = comment; break }
            index += 1
            if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            // a trailing '.' is dropped
            if index >= end || sentinels.contains(text[index]) { break }
            token += "."
        } while true
        return token
    }

    private static func tryParseDomainLiteral(_ text: [UInt8], _ index: inout Int, _ end: Int) -> String? {
        var token = "["
        index += 1
        skipWhiteSpace(text, &index, end)
        repeat {
            while index < end && isDomain(text[index]) {
                token.unicodeScalars.append(Unicode.Scalar(text[index]))
                index += 1
            }
            skipWhiteSpace(text, &index, end)
            if index >= end { return nil }
            if text[index] == 0x5D { break }
            if !isDomain(text[index]) { return nil }
        } while true
        index += 1
        return token + "]"
    }

    static func tryParseDomain(_ text: [UInt8], _ index: inout Int, _ end: Int, _ sentinels: [UInt8]) -> String? {
        if text[index] == 0x5B { return tryParseDomainLiteral(text, &index, end) }
        return tryParseDotAtom(text, &index, end, sentinels)
    }

    /// ParseUtils.TryParseMsgId (Content-ID): the addr-spec of "<local@domain>", loosely.
    static func tryParseMsgId(_ text: [UInt8], _ index: inout Int, _ end: Int, requireAngleAddr: Bool) -> String? {
        var squareBrackets = false
        var angleAddr = false
        if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
        if index >= end || (requireAngleAddr && text[index] != 0x3C) { return nil }
        if text[index] == 0x3C {
            angleAddr = true
            index += 1
        }
        skipWhiteSpace(text, &index, end)
        if index >= end { return nil }
        var token = ""
        if text[index] == 0x5B { squareBrackets = true }
        repeat {
            let start = index
            if text[index] == 0x22 {
                if !skipQuoted(text, &index, end) { return nil }
            } else {
                while index < end && text[index] != 0x2E && text[index] != 0x40 && text[index] != 0x3E && !isWhitespace(text[index]) {
                    index += 1
                }
            }
            guard let word = strictUtf8(text, start..<index) else { return nil }
            token += word
            skipWhiteSpace(text, &index, end)
            if index >= end {
                if angleAddr { return nil }
                break
            }
            if text[index] == 0x40 || text[index] == 0x3E { break }
            if text[index] == 0x2E {
                token += "."
                index += 1
                skipWhiteSpace(text, &index, end)
            }
            if index >= end { return nil }
        } while true
        if index < end && text[index] == 0x40 {
            token += "@"
            index += 1
            while index < end && text[index] == 0x40 { index += 1 }
            if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            if index < end && text[index] != 0x3E {
                repeat {
                    guard let domain = tryParseDomain(text, &index, end, [0x3E, 0x40]) else { return nil }
                    token += domain
                    if index >= end || text[index] != 0x40 { break }
                    token += "@"
                    index += 1
                } while index < end
                if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            }
        }
        if squareBrackets && index < end && text[index] == 0x5D {
            token += "]"
            index += 1
        }
        if angleAddr && (index >= end || text[index] != 0x3E) { return nil }
        if index < end && text[index] == 0x3E { index += 1 }
        return token
    }

    // MARK: Unquoting (MimeUtils.Unquote)

    static func unquote(_ text: [UInt8], _ start: Int, _ length: Int, convertTabsToSpaces: Bool = false) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(length)
        var escaped = false
        for i in start..<start + length {
            switch text[i] {
            case 0x0D, 0x0A: escaped = false
            case 0x09:
                output.append(convertTabsToSpaces ? 0x20 : 0x09)
                escaped = false
            case 0x5C:
                if escaped { output.append(0x5C) }
                escaped.toggle()
            case 0x22:
                if escaped {
                    output.append(0x22)
                    escaped = false
                }
            default:
                output.append(text[i])
                escaped = false
            }
        }
        return output
    }

    static func unquote(_ text: String, convertTabsToSpaces: Bool = false) -> String {
        guard text.utf16.contains(where: { $0 == 0x0D || $0 == 0x0A || $0 == 0x09 || $0 == 0x5C || $0 == 0x22 }) else { return text }
        var output = String.UnicodeScalarView()
        var escaped = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r", "\n": escaped = false
            case "\t":
                output.append(convertTabsToSpaces ? " " : "\t")
                escaped = false
            case "\\":
                if escaped { output.append("\\") }
                escaped.toggle()
            case "\"":
                if escaped {
                    output.append("\"")
                    escaped = false
                }
            default:
                output.append(scalar)
                escaped = false
            }
        }
        return String(output)
    }

    /// Header.Unfold: trims .NET white space at both ends and drops CR / LF.
    static func unfold(_ text: String) -> String {
        let units = Array(text.utf16)
        var start = 0
        while start < units.count && isDotNetWhiteSpace(units[start]) { start += 1 }
        if start == units.count { return "" }
        var end = start
        for i in start..<units.count where !isDotNetWhiteSpace(units[i]) { end = i + 1 }
        return String(decoding: units[start..<end].filter { $0 != 0x0D && $0 != 0x0A }, as: UTF16.self)
    }

    /// `char.IsWhiteSpace`.
    static func isDotNetWhiteSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    /// `string.Trim()`.
    static func trim(_ text: String) -> String {
        let units = Array(text.utf16)
        var start = 0, end = units.count
        while start < end && isDotNetWhiteSpace(units[start]) { start += 1 }
        while end > start && isDotNetWhiteSpace(units[end - 1]) { end -= 1 }
        return start == 0 && end == units.count ? text : String(decoding: units[start..<end], as: UTF16.self)
    }

    // MARK: Encoded words (MimeKit Rfc2047)

    private struct Token {
        var start: Int
        var length: Int
        /// 0 = not encoded; otherwise the charset's code page (-1 = unknown charset).
        var codePage = 0
        /// 'B' / 'Q' for encoded words, '8' for raw 8-bit text, '7' for ASCII.
        var encoding: UInt8 = 0x37
    }

    /// TokenDecoder: joins runs of encoded words with the same charset and encoding before converting them.
    private struct TokenDecoder {
        let input: [UInt8]
        var output = ""
        var pending: [UInt8] = []
        var active = false
        var codePage = 0
        var encoding: UInt8 = 0
        var codePages: [(codePage: Int, count: Int)] = []

        init(_ input: [UInt8]) { self.input = input }

        mutating func write(_ token: Token) {
            if active && (token.codePage != codePage || upper(token.encoding) != encoding) { flush() }
            if token.codePage != 0 {
                encoding = upper(token.encoding)
                codePage = token.codePage
                active = true
                if let index = codePages.firstIndex(where: { $0.codePage == codePage }) { codePages[index].count += 1 } else { codePages.append((codePage, 1)) }
                pending += input[token.start..<token.start + token.length]
            } else if token.encoding == 0x38 {
                output += EmlCharsets.convertToUnicode(input[token.start..<token.start + token.length])
            } else {
                output += EmlCharsets.latin1(input[token.start..<token.start + token.length])
            }
        }

        mutating func flush() {
            guard active else { return }
            active = false
            let decoded = encoding == 0x51 ? EmlMime.decodeQuotedPrintable(pending[...], rfc2047: true) : EmlMime.decodeBase64(pending[...])
            pending.removeAll()
            if !decoded.isEmpty { output += EmlCharsets.convertToUnicode(decoded[...], codePage: codePage) }
        }

        var mostCommonCodePage: Int {
            var best = 65001, max = 0
            for (codePage, count) in codePages where count > max { best = codePage; max = count }
            return best
        }

        private func upper(_ c: UInt8) -> UInt8 { c >= 0x61 && c <= 0x7A ? c - 0x20 : c }
    }

    private static func isBbQq(_ c: UInt8) -> Bool { c == 0x42 || c == 0x62 || c == 0x51 || c == 0x71 }

    /// An "=?charset?B?payload?=" token of `length` bytes at `word`.
    private static func encodedWordToken(_ input: [UInt8], _ word: Int, _ length: Int) -> Token? {
        guard length >= 7 else { return nil }
        let close = word + length - 2
        guard input[word] == 0x3D, input[word + 1] == 0x3F, input[close] == 0x3F, input[close + 1] == 0x3D else { return nil }
        var p = word + 2
        if input[p] == 0x3F || input[p] == 0x2A { return nil }
        var charset = String.UnicodeScalarView()
        while input[p] != 0x3F && input[p] != 0x2A {
            if !isAsciiAtom(input[p]) { return nil }
            charset.append(Unicode.Scalar(input[p]))
            p += 1
        }
        if input[p] == 0x2A {
            p += 1
            while input[p] != 0x3F {
                if !isAsciiAtom(input[p]) { return nil }
                p += 1
            }
        }
        p += 1
        guard isBbQq(input[p]) else { return nil }
        let encoding = input[p]
        p += 1
        if input[p] != 0x3F || p == close { return nil }
        p += 1
        return Token(start: p, length: close - p, codePage: EmlCharsets.codePage(String(charset)), encoding: encoding)
    }

    /// The end of a word in Loose mode: an encoded word, or text up to white space (`phrase`: atom characters) or the
    /// next "=?". `ascii` tells whether it was all 7-bit.
    private static func scanWord(_ input: [UInt8], _ index: inout Int, _ end: Int, phrase: Bool) -> Bool {
        let word = index
        var ascii = true
        var rfc2047 = false
        scan: if index + 2 < end && input[index] == 0x3D && input[index + 1] == 0x3F {
            index += 2
            while index < end && input[index] != 0x3F {
                ascii = ascii && input[index] < 0x80
                index += 1
            }
            if index + 3 >= end || input[index] != 0x3F || !isBbQq(input[index + 1]) || input[index + 2] != 0x3F {
                ascii = true
                break scan
            }
            index += 3
            while index + 2 < end && !(input[index] == 0x3F && input[index + 1] == 0x3D) {
                ascii = ascii && input[index] < 0x80
                index += 1
            }
            if index + 2 > end || input[index] != 0x3F || input[index + 1] != 0x3D {
                index = word + 2
                ascii = true
                break scan
            }
            rfc2047 = true
            index += 2
        }
        if !rfc2047 {
            while index < end && (phrase ? isAtom(input[index]) : !isWhitespace(input[index])) {
                if index + 2 < end && input[index] == 0x3D && input[index + 1] == 0x3F { break }
                ascii = ascii && input[index] < 0x80
                index += 1
            }
        }
        return ascii
    }

    private static func tokenize(_ input: [UInt8], _ start: Int, _ length: Int, phrase: Bool, _ decoder: inout TokenDecoder) {
        var index = start
        let end = start + length
        var encoded = false
        while index < end {
            let text = index
            while index < end && isWhitespace(input[index]) { index += 1 }
            let lwsp = Token(start: text, length: index - text)
            if index < end && (!phrase || isAsciiAtom(input[index])) {
                let word = index
                let ascii = scanWord(input, &index, end, phrase: phrase)
                let n = index - word
                if let token = encodedWordToken(input, word, n) {
                    // white space between encoded words is dropped
                    if !encoded && lwsp.length > 0 { decoder.write(lwsp) }
                    decoder.write(token)
                    encoded = true
                } else {
                    if lwsp.length > 0 { decoder.write(lwsp) }
                    decoder.write(Token(start: word, length: n, encoding: ascii ? 0x37 : 0x38))
                    encoded = false
                }
            } else if phrase {
                if lwsp.length > 0 { decoder.write(lwsp) }
                let word = index
                var ascii = true
                while index < end && !isWhitespace(input[index]) && !isAsciiAtom(input[index]) {
                    ascii = ascii && input[index] < 0x80
                    index += 1
                }
                decoder.write(Token(start: word, length: index - word, encoding: ascii ? 0x37 : 0x38))
                encoded = false
            } else {
                if lwsp.length > 0 { decoder.write(lwsp) }
                break
            }
        }
        decoder.flush()
    }

    /// Rfc2047.DecodeText: unstructured text (Subject, parameter values) and the most common charset of its words.
    static func decodeText(_ text: [UInt8], _ start: Int = 0, _ count: Int? = nil) -> (text: String, codePage: Int) {
        let count = count ?? text.count - start
        if count == 0 { return ("", 65001) }
        var decoder = TokenDecoder(text)
        tokenize(text, start, count, phrase: false, &decoder)
        return (decoder.output, decoder.mostCommonCodePage)
    }

    /// Rfc2047.DecodePhrase: a display name.
    static func decodePhrase(_ text: [UInt8], _ start: Int = 0, _ count: Int? = nil) -> (text: String, codePage: Int) {
        let count = count ?? text.count - start
        if count == 0 { return ("", 65001) }
        var decoder = TokenDecoder(text)
        tokenize(text, start, count, phrase: true, &decoder)
        return (decoder.output, decoder.mostCommonCodePage)
    }

    // MARK: Parameters (MimeKit ParameterList, RFC 2231)

    /// Parameter name → value, in order; names compare case-insensitively.
    struct Parameters {
        private(set) var items: [(name: String, value: String)] = []

        subscript(name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func contains(_ name: String) -> Bool { self[name] != nil }

        mutating func set(_ name: String, _ value: String) {
            if let index = items.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                items[index].value = value
            } else {
                items.append((name, value))
            }
        }
    }

    private struct NameValuePair {
        let value: [UInt8]
        let valueStart: Int
        let valueLength: Int
        let encoded: Bool
        let name: String
        let id: Int?
    }

    private static func parseNameValuePair(_ text: [UInt8], _ index: inout Int, _ end: Int) -> NameValuePair? {
        var encoded = false
        var id: Int?
        if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
        let nameStart = index
        while index < end && isAttr(text[index]) { index += 1 }
        guard index > nameStart else { return nil }
        let name = EmlCharsets.latin1(text[nameStart..<index])
        if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
        if text[index] == 0x2A {
            index += 1
            if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
            if let identifier = tryParseInt32(text, &index, end) {
                if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
                if text[index] == 0x2A {
                    encoded = true
                    index += 1
                    if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
                }
                id = identifier
            } else {
                encoded = true
            }
        }
        guard text[index] == 0x3D else { return nil }
        index += 1
        if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
        var valueIndex = index
        var value = text
        var valueLength: Int
        if text[index] == 0x22 {
            _ = skipQuoted(text, &index, end)
            valueLength = index - valueIndex
        } else {
            // Loose: unquoted values run to ';' or the end of the line (Google Docs does not quote names with spaces).
            while index < end && text[index] != 0x3B && text[index] != 0x0D && text[index] != 0x0A { index += 1 }
            valueLength = index - valueIndex
            if index < end && text[index] != 0x3B {
                var buffer = Array(text[valueIndex..<valueIndex + valueLength])
                repeat {
                    while index < end && (text[index] == 0x0D || text[index] == 0x0A) { index += 1 }
                    valueIndex = index
                    while index < end && text[index] != 0x3B && text[index] != 0x0D && text[index] != 0x0A { index += 1 }
                    buffer += text[valueIndex..<index]
                } while index < end && text[index] != 0x3B
                value = buffer
                valueLength = buffer.count
                valueIndex = 0
            }
            // MimeKit's trailing white space trim compares the length with the start index (only trims when the value
            // starts at 0), kept as is so values come out the same.
            while valueLength > valueIndex && isWhitespace(value[valueLength - 1]) { valueLength -= 1 }
        }
        return NameValuePair(value: value, valueStart: valueIndex, valueLength: valueLength, encoded: encoded, name: name, id: id)
    }

    /// Hex-decodes "%XX" (RFC 2231); a cut sequence at the end is dropped like MimeKit's HexDecoder.
    private static func hexDecode(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let c = bytes[index]
            index += 1
            guard c == 0x25 else { output.append(c); continue }
            guard index + 1 < bytes.endIndex else { break }
            let saved = bytes[index], next = bytes[index + 1]
            index += 2
            if isXDigit(next) && isXDigit(saved) { output.append(xdigitValue(saved) << 4 | xdigitValue(next)) } else { output += [0x25, saved, next] }
        }
        return output
    }

    /// The charset of "charset'language'value"; nil without the two quotes.
    private static func rfc2231Charset(_ bytes: ArraySlice<UInt8>) -> (charset: String, valueStart: Int)? {
        guard let first = bytes.firstIndex(of: 0x27), first != bytes.startIndex else { return nil }
        guard let second = bytes[(first + 1)...].firstIndex(of: 0x27) else { return nil }
        return (EmlCharsets.latin1(bytes[bytes.startIndex..<first]), second + 1)
    }

    /// ParameterList.TryParse; nil when the list is malformed (MimeKit then keeps the header without parameters).
    static func parseParameters(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Parameters? {
        var pairs: [NameValuePair] = []
        var continuations: [String: [NameValuePair]] = [:]
        repeat {
            if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            if index >= end { break }
            if text[index] == 0x3B {
                index += 1
                continue
            }
            guard let pair = parseNameValuePair(text, &index, end) else { return nil }
            if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            if pair.id != nil {
                let key = pair.name.lowercased()
                if continuations[key] != nil { continuations[key]!.append(pair) } else { continuations[key] = [pair]; pairs.append(pair) }
            } else {
                pairs.append(pair)
            }
            if index >= end { break }
            if text[index] == 0x3B { index += 1 }
        } while true

        var parameters = Parameters()
        for pair in pairs {
            var value: String
            if pair.id != nil {
                // RFC 2231 continuations: encoded segments share one charset decoder, plain ones are added as they are.
                let parts = continuations[pair.name.lowercased()]!.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
                value = ""
                var charset: Int?
                var encodedRun: [UInt8] = []
                func flushRun() {
                    guard let codePage = charset, !encodedRun.isEmpty || codePage != 0 else { return }
                    value += decodeRfc2231(hexDecode(encodedRun[...]), codePage: codePage)
                    encodedRun.removeAll()
                }
                for part in parts {
                    var start = part.valueStart, length = part.valueLength
                    if part.encoded {
                        if length >= 2 && part.value[start] == 0x22 && part.value[start + length - 1] == 0x22 {
                            start += 1
                            length -= 2
                        }
                        var segment = part.value[start..<start + length]
                        if charset == nil {
                            if let found = rfc2231Charset(segment) {
                                charset = rfc2231CodePage(found.charset)
                                segment = segment[found.valueStart...]
                            } else {
                                charset = 28591
                            }
                        }
                        encodedRun += segment
                    } else {
                        flushRun()
                        if length >= 2 && part.value[start] == 0x22 {
                            value += unquote(EmlCharsets.convertToUnicode(part.value[start..<start + length]))
                        } else if length > 0 {
                            value += EmlCharsets.convertToUnicode(part.value[start..<start + length])
                        }
                    }
                }
                flushRun()
            } else if pair.encoded {
                var start = pair.valueStart, length = pair.valueLength
                if length >= 2 && pair.value[start] == 0x22 {
                    if pair.value[start + length - 1] == 0x22 { length -= 1 }
                    start += 1
                    length -= 1
                }
                let segment = pair.value[start..<start + length]
                if let found = rfc2231Charset(segment) {
                    value = decodeRfc2231(hexDecode(segment[found.valueStart...]), codePage: rfc2231CodePage(found.charset))
                } else {
                    value = decodeRfc2231(hexDecode(segment), codePage: 28591)
                }
            } else if !parameters.contains(pair.name) {
                let start = pair.valueStart, length = pair.valueLength
                if length >= 2 && text[start] == 0x22 {
                    value = decodeText(unquote(pair.value, start, length)).text
                } else if length > 0 {
                    value = decodeText(pair.value, start, length).text
                } else {
                    value = ""
                }
            } else {
                continue
            }
            parameters.set(pair.name, value)
        }
        return parameters
    }

    /// CharsetUtils.GetEncoding(charset, "?") for RFC 2231 values: ISO-8859-1 when the charset is unknown.
    private static func rfc2231CodePage(_ charset: String) -> Int {
        let codePage = EmlCharsets.codePage(charset)
        return codePage == -1 ? 28591 : codePage
    }

    /// The decoder of `CharsetUtils.GetEncoding(charset, "?")`: invalid bytes become "?", also for UTF-8.
    private static func decodeRfc2231(_ bytes: [UInt8], codePage: Int) -> String {
        guard codePage == 65001 else { return EmlCharsets.decode(bytes[...], codePage: codePage) }
        var scalars = String.UnicodeScalarView()
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = bytes.makeIterator()
        loop: while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded): scalars.append(Unicode.UTF8.decode(encoded))
            case .error: scalars.append("?")
            case .emptyInput: break loop
            }
        }
        return String(scalars)
    }

    // MARK: Content-Type / Content-Disposition

    struct ContentType {
        var mediaType: String
        var mediaSubtype: String
        var parameters = Parameters()

        init(_ mediaType: String, _ mediaSubtype: String) {
            self.mediaType = mediaType
            self.mediaSubtype = mediaSubtype
        }

        var mimeType: String { "\(mediaType)/\(mediaSubtype)" }
        var charset: String? { parameters["charset"] }
        var boundary: String? { parameters["boundary"] }
        var name: String? { parameters["name"] }

        func isMimeType(_ type: String, _ subtype: String) -> Bool {
            (type == "*" || type.caseInsensitiveCompare(mediaType) == .orderedSame)
                && (subtype == "*" || subtype.caseInsensitiveCompare(mediaSubtype) == .orderedSame)
        }
    }

    /// ContentType.TryParse: the type (nil when even "type/subtype" is unreadable) and whether the whole value parsed.
    static func parseContentType(_ text: [UInt8], _ index: inout Int, _ end: Int) -> (type: ContentType?, complete: Bool) {
        if !skipCommentsAndWhiteSpace(text, &index, end) { return (nil, false) }
        var start = index
        while index < end && isAsciiAtom(text[index]) && text[index] != 0x2F { index += 1 }
        guard index > start else { return (nil, false) }
        let type = EmlCharsets.latin1(text[start..<index])
        if !skipCommentsAndWhiteSpace(text, &index, end) { return (nil, false) }
        guard index < end, text[index] == 0x2F else { return (nil, false) }
        index += 1
        if !skipCommentsAndWhiteSpace(text, &index, end) { return (nil, false) }
        start = index
        while index < end && (isToken(text[index]) || text[index] == 0x2F) { index += 1 }
        guard index > start else { return (nil, false) }
        let subtype = EmlCharsets.latin1(text[start..<index])
        if !skipCommentsAndWhiteSpace(text, &index, end) { return (nil, false) }
        var contentType = ContentType(type, subtype)
        if index >= end { return (contentType, true) }
        guard text[index] == 0x3B else { return (contentType, false) }
        index += 1
        if !skipCommentsAndWhiteSpace(text, &index, end) { return (contentType, false) }
        if index >= end { return (contentType, true) }
        guard let parameters = parseParameters(text, &index, end) else { return (contentType, false) }
        contentType.parameters = parameters
        return (contentType, true)
    }

    /// ContentType.TryParse(string) (HTML meta content attributes).
    static func parseContentType(_ text: String) -> ContentType? {
        let bytes = Array(text.utf8)
        var index = 0
        let result = parseContentType(bytes, &index, bytes.count)
        return result.complete ? result.type : nil
    }

    struct ContentDisposition {
        var disposition: String
        var parameters = Parameters()

        var isAttachment: Bool { disposition.caseInsensitiveCompare("attachment") == .orderedSame }
        var fileName: String? { parameters["filename"] }
    }

    /// ContentDisposition.TryParse as MimeEntity uses it: a disposition whose parameters fail to parse is kept without
    /// them; nil when even the disposition is unreadable.
    static func parseContentDisposition(_ text: [UInt8]) -> ContentDisposition? {
        var index = 0
        let end = text.count
        if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
        let atom = index
        var type: String
        if text[index] == 0x22 {
            if !skipQuoted(text, &index, end) { return nil }
            type = unquote(EmlCharsets.convertToUnicode(text[atom..<index]))
            if type.isEmpty { type = "attachment" }
        } else if skipAtom(text, &index, end) {
            type = EmlCharsets.latin1(text[atom..<index])
        } else {
            // broken mailers that leave the disposition out: "; filename=x"
            if index > atom || text[index] != 0x3B { return nil }
            type = "attachment"
        }
        var disposition = ContentDisposition(disposition: type)
        if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return disposition }
        guard text[index] == 0x3B else { return disposition }
        index += 1
        if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return disposition }
        if let parameters = parseParameters(text, &index, end) { disposition.parameters = parameters }
        return disposition
    }

    // MARK: Content-Transfer-Encoding

    enum TransferEncoding { case `default`, sevenBit, eightBit, binary, base64, quotedPrintable, uuencode }

    /// MimeUtils.TryParse(string, out ContentEncoding): the first word, before ';' or white space.
    static func parseTransferEncoding(_ text: String?) -> TransferEncoding {
        guard let text else { return .default }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count && isDotNetWhiteSpace(units[i]) { i += 1 }
        let start = i
        while i < units.count && units[i] != 0x3B && !isDotNetWhiteSpace(units[i]) { i += 1 }
        switch String(decoding: units[start..<i], as: UTF16.self).lowercased() {
        case "7bit": return .sevenBit
        case "8bit": return .eightBit
        case "binary": return .binary
        case "base64": return .base64
        case "quoted-printable": return .quotedPrintable
        case "x-uuencode", "uuencode", "x-uue": return .uuencode
        default: return .default
        }
    }

    static func isEncoded(_ encoding: TransferEncoding) -> Bool {
        switch encoding {
        case .sevenBit, .eightBit, .binary, .default: false
        default: true
        }
    }

    // MARK: Decoders

    private static let base64Rank: [UInt8] = {
        var rank = [UInt8](repeating: 0xFF, count: 256)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() { rank[Int(c)] = UInt8(i) }
        rank[Int(UInt8(ascii: "="))] = 0
        return rank
    }()

    /// MimeKit's Base64Decoder: skips other characters, honours '=' padding, drops an incomplete quartet.
    static func decodeBase64(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 3 / 4)
        var previous: UInt32 = 0, saved: UInt32 = 0, count = 0
        for c in input {
            let rank = base64Rank[Int(c)]
            guard rank != 0xFF else { continue }
            previous = previous << 8 | UInt32(c)
            saved = saved << 6 | UInt32(rank)
            count += 1
            if count == 4 {
                if (previous & 0xFF0000) != 0x3D << 16 {
                    output.append(UInt8((saved >> 16) & 0xFF))
                    if (previous & 0xFF00) != 0x3D << 8 {
                        output.append(UInt8((saved >> 8) & 0xFF))
                        if (previous & 0xFF) != 0x3D { output.append(UInt8(saved & 0xFF)) }
                    }
                }
                saved = 0
                count = 0
            }
        }
        return output
    }

    /// MimeKit's QuotedPrintableDecoder (`rfc2047`: '_' is a space); invalid sequences pass through.
    static func decodeQuotedPrintable(_ input: ArraySlice<UInt8>, rfc2047: Bool = false) -> [UInt8] {
        enum State { case passThrough, equalSign, softBreak, decodeByte }
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var state = State.passThrough
        var saved: UInt8 = 0
        for c in input {
            switch state {
            case .passThrough:
                if c == 0x3D { state = .equalSign } else if rfc2047 && c == 0x5F { output.append(0x20) } else { output.append(c) }
            case .equalSign:
                if isXDigit(c) {
                    state = .decodeByte
                    saved = c
                } else if c == 0x3D {
                    output.append(0x3D)
                } else if c == 0x0D {
                    state = .softBreak
                } else if c == 0x0A {
                    state = .passThrough
                } else {
                    state = .passThrough
                    output += [0x3D, c]
                }
            case .softBreak:
                state = .passThrough
                if c != 0x0A { output += [0x3D, 0x0D, c] }
            case .decodeByte:
                if isXDigit(c) { output.append(xdigitValue(saved) << 4 | xdigitValue(c)) } else { output += [0x3D, saved, c] }
                state = .passThrough
            }
        }
        return output
    }

    /// MimeKit's UUDecoder: content after the "begin " line, until a zero-length line.
    static func decodeUU(_ input: ArraySlice<UInt8>) -> [UInt8] {
        func rank(_ c: UInt8) -> UInt8 { (c &- 0x20) & 0x3F }
        var output: [UInt8] = []
        var index = input.startIndex
        // find "begin " at the start of a line, then skip the rest of that line
        var lineStart = true
        var found = false
        while index < input.endIndex {
            if lineStart, input.endIndex - index >= 6, Array(input[index..<index + 6]) == Array("begin ".utf8) {
                index += 6
                while index < input.endIndex && input[index] != 0x0A { index += 1 }
                guard index < input.endIndex else { return [] }
                index += 1
                found = true
                break
            }
            lineStart = input[index] == 0x0A
            index += 1
        }
        guard found else { return [] }
        var uulen: UInt8 = 0
        var lastWasEoln = true
        var saved: [UInt8] = []
        while index < input.endIndex {
            let c = input[index]
            index += 1
            if c == 0x0D { continue }
            if c == 0x0A { lastWasEoln = true; continue }
            if uulen == 0 || lastWasEoln {
                uulen = rank(c)
                lastWasEoln = false
                if uulen == 0 { break }
                continue
            }
            guard uulen > 0 else { break }
            saved.append(c)
            if saved.count == 4 {
                let b0 = rank(saved[0]), b1 = rank(saved[1]), b2 = rank(saved[2]), b3 = rank(saved[3])
                if uulen >= 3 {
                    output += [b0 << 2 | b1 >> 4, b1 << 4 | b2 >> 2, b2 << 6 | b3]
                    uulen -= 3
                } else {
                    if uulen >= 1 { output.append(b0 << 2 | b1 >> 4); uulen -= 1 }
                    if uulen >= 1 { output.append(b1 << 4 | b2 >> 2); uulen -= 1 }
                }
                saved.removeAll()
            }
        }
        return output
    }

    static func decode(_ content: ArraySlice<UInt8>, _ encoding: TransferEncoding) -> [UInt8] {
        switch encoding {
        case .base64: decodeBase64(content)
        case .quotedPrintable: decodeQuotedPrintable(content)
        case .uuencode: decodeUU(content)
        default: Array(content)
        }
    }

    /// MimeKit's Dos2UnixFilter over a whole buffer: CRLF → LF; a CR at the very end is dropped.
    static func dos2unix(_ input: ArraySlice<UInt8>, ensureNewLine: Bool = false) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count + 1)
        var previous: UInt8 = 0
        for c in input {
            if c == 0x0A {
                output.append(c)
            } else {
                if previous == 0x0D { output.append(previous) }
                if c != 0x0D { output.append(c) }
            }
            previous = c
        }
        if ensureNewLine && previous != 0x0A { output.append(0x0A) }
        return output
    }

    // MARK: Text

    /// The same CRLF → LF rule on decoded text (TextPart.GetText runs Dos2UnixFilter after the charset conversion).
    static func dos2unix(_ text: String) -> String {
        guard text.utf16.contains(0x0D) else { return text }
        var output: [UInt16] = []
        var previous: UInt16 = 0
        for c in text.utf16 {
            if c == 0x0A {
                output.append(c)
            } else {
                if previous == 0x0D { output.append(previous) }
                if c != 0x0D { output.append(c) }
            }
            previous = c
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// MimeKit FlowedToText (format=flowed, RFC 3676): joins soft-broken lines; `deleteSpace` for delsp=yes.
    static func flowedToText(_ text: String, deleteSpace: Bool) -> String {
        var output = ""
        var paragraph: [UInt16] = []
        var paragraphDepth = -1
        func writeLine() {
            if paragraphDepth > 0 { output += String(repeating: ">", count: paragraphDepth) + " " }
            output += String(decoding: paragraph, as: UTF16.self) + "\n"
        }
        for line in readLines(text) {
            var unquoted = line[...]
            var depth = 0
            while unquoted.first == 0x3E {
                depth += 1
                unquoted = unquoted.dropFirst()
            }
            if depth > 0, unquoted.first == 0x20 { unquoted = unquoted.dropFirst() }
            if depth == 0, unquoted.first == 0x20 { unquoted = unquoted.dropFirst() }
            if paragraphDepth == -1 {
                paragraphDepth = depth
            } else if depth != paragraphDepth {
                writeLine()
                paragraphDepth = depth
                paragraph.removeAll()
            }
            paragraph += unquoted
            if unquoted.last != 0x20 {
                writeLine()
                paragraphDepth = -1
                paragraph.removeAll()
            } else if deleteSpace {
                paragraph.removeLast()
            }
        }
        if !paragraph.isEmpty {
            if paragraphDepth > 0 { output += String(repeating: ">", count: paragraphDepth) + " " }
            output += String(decoding: paragraph, as: UTF16.self)
        }
        return output
    }

    /// StringReader.ReadLine over a whole text: lines split at CRLF, CR or LF; no empty line after a final break.
    private static func readLines(_ text: String) -> [[UInt16]] {
        var lines: [[UInt16]] = []
        var current: [UInt16] = []
        var units = Array(text.utf16)[...]
        while let c = units.popFirst() {
            if c == 0x0D || c == 0x0A {
                if c == 0x0D, units.first == 0x0A { units = units.dropFirst() }
                lines.append(current)
                current.removeAll()
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
