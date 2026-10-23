// Structured header fields as MimeKit 4.18 reads them: address lists (InternetAddressList / InternetAddress in Loose
// mode, flattened to mailboxes like InternetAddressList.Mailboxes), dates (DateUtils) and the <meta> charset prescan
// of HTML parts without a charset (TextPart.TryDetectHtmlEncoding).

import Foundation

extension EmlMime {
    // MARK: Addresses

    /// A mailbox: display name (decoded) and address.
    struct Mailbox: Equatable {
        let name: String
        let address: String
    }

    private indirect enum Address {
        case mailbox(Mailbox)
        case group([Address])

        var mailboxes: [Mailbox] {
            switch self {
            case .mailbox(let mailbox): [mailbox]
            case .group(let members): members.flatMap(\.mailboxes)
            }
        }
    }

    /// The mailboxes of an address header's raw value (groups flattened); nil when nothing parses.
    static func parseMailboxes(_ text: [UInt8]) -> [Mailbox]? {
        var index = 0
        return parseAddressList(text, &index, text.count, isGroup: false, groupDepth: 0)?.flatMap(\.mailboxes)
    }

    private static let maxGroupDepth = 3

    /// InternetAddressList.TryParse with the Internal flag: addresses that fail to parse are skipped.
    private static func parseAddressList(_ text: [UInt8], _ index: inout Int, _ end: Int, isGroup: Bool, groupDepth: Int) -> [Address]? {
        if !skipCommentsAndWhiteSpace(text, &index, end) || index == end { return nil }
        var list: [Address] = []
        while index < end {
            if isGroup && text[index] == 0x3B { break }
            let saved = index
            if let address = parseAddress(text, &index, end, groupDepth: groupDepth) {
                list.append(address)
            } else {
                index = saved
                while index < end {
                    if text[index] == 0x22 {
                        if !skipQuoted(text, &index, end) { break }
                    } else if text[index] == 0x28 {
                        if !skipComment(text, &index, end) { break }
                    } else if text[index] == 0x2C || (isGroup && text[index] == 0x3B) {
                        break
                    } else {
                        index += 1
                    }
                }
            }
            while true {
                if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
                if index >= end || (isGroup && text[index] == 0x3B) || text[index] != 0x2C { break }
                index += 1
            }
        }
        return list
    }

    /// InternetAddress.SkipQuoted: like ParseUtils.SkipQuoted, but control characters end it as invalid.
    private static func skipQuotedLocalPart(_ text: [UInt8], _ index: inout Int, _ end: Int) -> Bool {
        var escaped = false
        index += 1
        while index < end {
            let c = text[index]
            if c == 0x5C {
                escaped.toggle()
            } else if !escaped {
                if c == 0x22 { break }
                if (c < 32 && c != 9) || c == 127 { return false }
            } else {
                if (c < 32 && c != 9) || c == 127 { return false }
                escaped = false
            }
            index += 1
        }
        if index >= end { return false }
        index += 1
        return true
    }

    private static func parseLocalPart(_ text: [UInt8], _ index: inout Int, _ end: Int, skipTrailingCfws: Bool) -> String? {
        var token = ""
        repeat {
            let start = index
            if text[index] == 0x22 {
                if !skipQuotedLocalPart(text, &index, end) { return nil }
            } else if isAtom(text[index]) {
                skipAtom(text, &index, end)
            } else {
                return nil
            }
            token += String(validating: text[start..<index], as: UTF8.self) ?? EmlCharsets.latin1(text[start..<index])
            let cfws = index
            if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            if index >= end || text[index] != 0x2E {
                if !skipTrailingCfws { index = cfws }
                break
            }
            token += "."
            index += 1
            if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
        } while true
        return token
    }

    private static let addrSpecSentinels: [UInt8] = [0x2C, 0x3E, 0x3B]

    private static func parseAddrSpec(_ text: [UInt8], _ index: inout Int, _ end: Int) -> String? {
        guard let localPart = parseLocalPart(text, &index, end, skipTrailingCfws: true) else { return nil }
        if index >= end || addrSpecSentinels.contains(text[index]) { return localPart }
        guard text[index] == 0x40 else { return nil }
        index += 1
        if index >= end || !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
        guard var domain = tryParseDomain(text, &index, end, addrSpecSentinels) else { return nil }
        if domain.hasPrefix("xn--") || domain.contains(".xn--") { domain = idnToUnicode(domain) }
        return localPart + "@" + domain
    }

    /// The "<...>" of a mailbox; `index` is on the '<'.
    private static func parseAngleAddr(_ text: [UInt8], _ index: inout Int, _ end: Int, name: String) -> Address? {
        index += 1
        if index < end && text[index] == 0x3C {
            repeat { index += 1 } while index < end && text[index] == 0x3C
        }
        if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
        if text[index] == 0x40 {
            // obsolete route "@a,@b:" (DomainList.TryParse), dropped
            repeat {
                index += 1
                if index >= end { return nil }
                guard tryParseDomain(text, &index, end, [0x2C, 0x3A]) != nil else { return nil }
                repeat {
                    if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
                    if index >= end || text[index] != 0x2C { break }
                    index += 1
                } while true
                if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            } while index < end && text[index] == 0x40
            guard index < end, text[index] == 0x3A else { return nil }
            index += 1
            if !skipCommentsAndWhiteSpace(text, &index, end) || index >= end { return nil }
        }
        guard let addrSpec = parseAddrSpec(text, &index, end) else { return nil }
        if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
        if index < end && text[index] == 0x3E {
            repeat { index += 1 } while index < end && text[index] == 0x3E
        }
        return .mailbox(Mailbox(name: name, address: addrSpec))
    }

    /// InternetAddress.TryParse (Loose, unquoted commas and addresses without a domain allowed).
    private static func parseAddress(_ text: [UInt8], _ index: inout Int, _ end: Int, groupDepth: Int) -> Address? {
        if !skipCommentsAndWhiteSpace(text, &index, end) || index == end { return nil }
        var trimLeadingQuote = false
        let startIndex = index
        var length = 0
        while index < end {
            let quoted = text[index] == 0x22
            if quoted {
                let qstringIndex = index
                if !skipQuoted(text, &index, end) {
                    index = qstringIndex + 1
                    skipWhiteSpace(text, &index, end)
                    if !skipPhraseAtom(text, &index, end) { break }
                    if startIndex == qstringIndex { trimLeadingQuote = true }
                }
            } else if !skipPhraseAtom(text, &index, end) {
                break
            }
            length = index - startIndex
            repeat {
                if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
                // some clients don't quote dots in the name
                if index >= end || text[index] != 0x2E { break }
                index += 1
                length = index - startIndex
            } while true
            // some clients don't quote commas in the name
            if index < end && text[index] == 0x2C && !quoted {
                index += 1
                length = index - startIndex
                if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            }
        }
        if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }

        if index >= end || text[index] == 0x2C || text[index] == 0x3E || text[index] == 0x3B {
            // an addr-spec without a domain
            let sentinel = index < end ? text[index] : 0x2C
            index = startIndex
            guard let addrSpec = parseLocalPart(text, &index, end, skipTrailingCfws: false) else { return nil }
            skipWhiteSpace(text, &index, end)
            var name = ""
            if index < end && text[index] == 0x28 {
                let comment = index + 1
                _ = skipComment(text, &index, end)
                name = trim(decodePhrase(text, comment, (index - 1) - comment).text)
                _ = skipCommentsAndWhiteSpace(text, &index, end)
            }
            if index < end && text[index] == 0x3E { index += 1 }
            if index < end && text[index] != sentinel { return nil }
            return .mailbox(Mailbox(name: name, address: addrSpec))
        }

        if text[index] == 0x3A {
            // group "name: a, b;"
            // the group's name is not shown (only its mailboxes)
            guard groupDepth < maxGroupDepth else { return nil }
            index += 1
            while index < end && (text[index] == 0x3A || isBlank(text[index])) { index += 1 }
            let members = parseAddressList(text, &index, end, isGroup: true, groupDepth: groupDepth + 1) ?? []
            if index >= end || text[index] != 0x3B {
                while index < end && text[index] != 0x3B { index += 1 }
            } else {
                index += 1
            }
            return .group(members)
        }

        if text[index] == 0x40 {
            // an addr-spec, possibly followed by "(name)" or by "<...>" when the name itself has an '@'
            index = startIndex
            guard let addrSpec = parseAddrSpec(text, &index, end) else { return nil }
            skipWhiteSpace(text, &index, end)
            var name = ""
            if index < end && text[index] == 0x28 {
                var comment = index
                if !skipComment(text, &index, end) { return nil }
                comment += 1
                name = trim(decodePhrase(text, comment, (index - 1) - comment).text)
            }
            if !skipCommentsAndWhiteSpace(text, &index, end) { return nil }
            if index >= end { return .mailbox(Mailbox(name: name, address: addrSpec)) }
            if text[index] == 0x3C {
                var nameEnd = index
                while nameEnd > startIndex && isWhitespace(text[nameEnd - 1]) { nameEnd -= 1 }
                length = nameEnd - startIndex
            } else {
                if text[index] == 0x3E { index += 1 }
                return .mailbox(Mailbox(name: name, address: addrSpec))
            }
        }

        if text[index] == 0x3C {
            var nameIndex = startIndex
            if trimLeadingQuote {
                nameIndex += 1
                length -= 1
            }
            var name = ""
            if length > 0 {
                let unquoted = unquote(text, nameIndex, length, convertTabsToSpaces: true)
                name = decodePhrase(unquoted).text
            }
            return parseAngleAddr(text, &index, end, name: name)
        }
        return nil
    }

    /// IdnMapping.GetUnicode for the domains MimeKit decodes: punycode labels decoded, ASCII lower-cased; the original
    /// domain when a label does not decode. shortcut: no full UTS #46 validation, upgrade if invalid IDNs matter.
    static func idnToUnicode(_ domain: String) -> String {
        var labels: [String] = []
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            let lower = label.lowercased()
            if lower.hasPrefix("xn--") {
                guard let decoded = punycodeDecode(String(lower.dropFirst(4))) else { return domain }
                labels.append(decoded)
            } else {
                labels.append(lower)
            }
        }
        return labels.joined(separator: ".")
    }

    /// RFC 3492 decoding.
    private static func punycodeDecode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var output: [Unicode.Scalar] = []
        var scalars = Array(input.unicodeScalars)
        if let delimiter = scalars.lastIndex(of: "-") {
            for scalar in scalars[..<delimiter] {
                guard scalar.isASCII else { return nil }
                output.append(scalar)
            }
            scalars = Array(scalars[(delimiter + 1)...])
        }
        var n = 128, i = 0, bias = 72
        var position = 0
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / count
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        while position < scalars.count {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard position < scalars.count else { return nil }
                let c = scalars[position].value
                position += 1
                let digit: Int
                switch c {
                case 0x30...0x39: digit = Int(c) - 22
                case 0x41...0x5A: digit = Int(c) - 0x41
                case 0x61...0x7A: digit = Int(c) - 0x61
                default: return nil
                }
                guard digit <= (Int(Int32.max) - i) / w else { return nil }
                i += digit * w
                let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                if digit < t { break }
                guard w <= Int(Int32.max) / (base - t) else { return nil }
                w *= base - t
                k += base
            }
            bias = adapt(i - oldI, output.count + 1, oldI == 0)
            guard i / (output.count + 1) <= Int(Int32.max) - n else { return nil }
            n += i / (output.count + 1)
            i %= output.count + 1
            guard let scalar = Unicode.Scalar(n) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: output)
        return String(view)
    }

    // MARK: Dates (MimeKit DateUtils)

    /// A DateTimeOffset as MimeKit returns it; `minValue` when the Date header does not parse.
    struct MessageDate: Equatable {
        var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
        /// Offset from UTC in minutes.
        var offset: Int

        static let minValue = MessageDate(year: 1, month: 1, day: 1, hour: 0, minute: 0, second: 0, offset: 0)

        /// `ToString("yyyy-MM-dd HH:mm:ss zzz", InvariantCulture)`.
        var formatted: String {
            func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
            let sign = offset < 0 ? "-" : "+"
            let year = String(repeating: "0", count: max(0, 4 - String(self.year).count)) + String(self.year)
            return "\(year)-\(two(month))-\(two(day)) \(two(hour)):\(two(minute)):\(two(second)) \(sign)\(two(abs(offset) / 60)):\(two(abs(offset) % 60))"
        }

        /// The DateTimeOffset constructor's checks: a real date and time, offset within ±14 h, UTC time in range.
        init?(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, offset: Int) {
            guard (1...9999).contains(year), (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute),
                  (0...59).contains(second), abs(offset) <= 14 * 60 else { return nil }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            guard (1...days).contains(day) else { return nil }
            let utcMinutes = MessageDate.daysFromCivil(year, month, day) * 1440 + hour * 60 + minute - offset
            guard utcMinutes >= MessageDate.daysFromCivil(1, 1, 1) * 1440,
                  utcMinutes < (MessageDate.daysFromCivil(9999, 12, 31) + 1) * 1440 else { return nil }
            self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset)
        }

        private init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int) {
            self.year = year; self.month = month; self.day = day; self.hour = hour; self.minute = minute; self.second = second
            self.offset = offset
        }

        private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146097 + doe
        }
    }

    private struct DateToken {
        var flags: UInt8
        var start: Int
        var length: Int

        static let nonNumeric: UInt8 = 1 << 0, nonWeekday: UInt8 = 1 << 1, nonMonth: UInt8 = 1 << 2, nonTime: UInt8 = 1 << 3
        static let nonAlphaZone: UInt8 = 1 << 4, nonNumericZone: UInt8 = 1 << 5, hasColon: UInt8 = 1 << 6, hasSign: UInt8 = 1 << 7

        var isNumeric: Bool { flags & Self.nonNumeric == 0 }
        var isWeekday: Bool { flags & Self.nonWeekday == 0 }
        var isMonth: Bool { flags & Self.nonMonth == 0 }
        var isTimeOfDay: Bool { flags & Self.nonTime == 0 && flags & Self.hasColon != 0 }
        var isNumericZone: Bool { flags & Self.nonNumericZone == 0 && flags & Self.hasSign != 0 }
        var isAlphaZone: Bool { flags & Self.nonAlphaZone == 0 }
        var isTimeZone: Bool { isNumericZone || isAlphaZone }
    }

    private static let dateCharFlags: [UInt8] = {
        let months = Set("JanuaryFebruaryMarchAprilMayJuneJulyAugustSeptemberOctoberNovemberDecember".utf8)
        let weekdays = Set("SundayMondayTuesdayWednesdayThursdayFridaySaturday".utf8)
        var flags = [UInt8](repeating: 0, count: 256)
        for c in 0..<256 {
            let byte = UInt8(c)
            let isLetter = (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
            let pair: [UInt8] = isLetter ? [byte & 0xDF, byte | 0x20] : []
            if !"+-0123456789".utf8.contains(byte) { flags[c] |= DateToken.nonNumericZone }
            if !(0x41...0x5A).contains(c) { flags[c] |= DateToken.nonAlphaZone }
            if !pair.contains(where: weekdays.contains) { flags[c] |= DateToken.nonWeekday }
            if !(0x30...0x39).contains(c) { flags[c] |= DateToken.nonNumeric }
            if !pair.contains(where: months.contains) { flags[c] |= DateToken.nonMonth }
            if !"0123456789:".utf8.contains(byte) { flags[c] |= DateToken.nonTime }
        }
        flags[0x3A] |= DateToken.hasColon
        flags[0x2B] |= DateToken.hasSign
        flags[0x2D] |= DateToken.hasSign
        return flags
    }()

    private static let timeZones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "EDT": -400, "EST": -500, "CDT": -500, "CST": -600, "MDT": -600, "MST": -700, "PDT": -700,
        "PST": -800, "A": 100, "B": 200, "C": 300, "D": 400, "E": 500, "F": 600, "G": 700, "H": 800, "I": 900, "K": 1000,
        "L": 1100, "M": 1200, "N": -100, "O": -200, "P": -300, "Q": -400, "R": -500, "S": -600, "T": -700, "U": -800,
        "V": -900, "W": -1000, "X": -1100, "Y": -1200, "Z": 0, "JST": 900, "KST": 900,
    ]

    private static func tokenizeDate(_ text: [UInt8]) -> [DateToken] {
        var tokens: [DateToken] = []
        var index = 0
        let end = text.count
        while index < end {
            if !skipCommentsAndWhiteSpace(text, &index, end) { break }
            if index >= end { break }
            var mask = dateCharFlags[Int(text[index])]
            if mask != 0 {
                let start = index
                index += 1
                while index < end {
                    let c = text[index]
                    if c == 0x2D || c == 0x2F || c == 0x2C || isWhitespace(c) { break }
                    mask |= dateCharFlags[Int(c)]
                    index += 1
                }
                tokens.append(DateToken(flags: mask, start: start, length: index - start))
            }
            index += 1
        }
        return tokens
    }

    private static func ascii3(_ text: [UInt8], _ token: DateToken) -> String { EmlCharsets.latin1(text[token.start..<token.start + 3]).lowercased() }

    private static func weekday(_ token: DateToken, _ text: [UInt8]) -> Bool {
        token.isWeekday && token.length >= 3 && ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].contains(ascii3(text, token))
    }

    private static func month(_ token: DateToken, _ text: [UInt8]) -> Int? {
        guard token.isMonth, token.length >= 3 else { return nil }
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: ascii3(text, token)).map { $0 + 1 }
    }

    private static func number(_ token: DateToken, _ text: [UInt8]) -> Int? {
        var index = token.start
        return tryParseInt32(text, &index, token.start + token.length)
    }

    private static func dayOfMonth(_ token: DateToken, _ text: [UInt8]) -> Int? {
        guard token.isNumeric, let day = number(token, text), day > 0, day <= 31 else { return nil }
        return day
    }

    private static func year(_ token: DateToken, _ text: [UInt8]) -> Int? {
        guard token.isNumeric, var year = number(token, text) else { return nil }
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        return year >= 1969 ? year : nil
    }

    private static func timeOfDay(_ token: DateToken, _ text: [UInt8]) -> (Int, Int, Int)? {
        guard token.isTimeOfDay else { return nil }
        var index = token.start
        let end = token.start + token.length
        guard let hour = tryParseInt32(text, &index, end), hour <= 23 else { return nil }
        guard index < end, text[index] == 0x3A else { return nil }
        index += 1
        guard let minute = tryParseInt32(text, &index, end), minute <= 59 else { return nil }
        guard index < end, text[index] == 0x3A else { return (hour, minute, 0) }
        index += 1
        guard var second = tryParseInt32(text, &index, end), second <= 60 else { return nil }
        if hour == 23 && minute == 59 && second == 60 { second = 59 } else if second == 60 { return nil }
        return index == end ? (hour, minute, second) : nil
    }

    private static func amPm(_ token: DateToken, _ text: [UInt8], _ hour: inout Int) -> Bool {
        guard token.isAlphaZone, token.length == 2, text[token.start + 1] | 0x20 == 0x6D else { return false }
        switch text[token.start] | 0x20 {
        case 0x61:
            if hour == 12 { hour = 0 }
            return true
        case 0x70:
            if hour < 12 { hour += 12 }
            return true
        default:
            return false
        }
    }

    private static func timeZone(_ token: DateToken, _ text: [UInt8]) -> Int? {
        var zone: Int
        if token.isNumericZone {
            var index = token.start + 1
            let end = token.start + token.length
            let sign: Int
            switch text[token.start] {
            case 0x2D: sign = -1
            case 0x2B: sign = 1
            default: return nil
            }
            guard let value = tryParseInt32(text, &index, end), index == end else { return nil }
            zone = value * sign
        } else if token.isAlphaZone {
            guard token.length <= 3, let value = timeZones[EmlCharsets.latin1(text[token.start..<token.start + token.length])] else { return nil }
            zone = value
        } else if token.isNumeric {
            var index = token.start
            guard let value = tryParseInt32(text, &index, token.start + token.length), index == token.start + token.length else { return nil }
            zone = value
        } else {
            zone = 0
        }
        return zone < -1200 || zone > 1400 ? nil : zone
    }

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, zone: Int) -> MessageDate? {
        MessageDate(year, month, day, hour, minute, second, offset: (zone / 100) * 60 + zone % 100)
    }

    /// DateUtils.TryParse: the standard RFC 822 layout first, then a lenient scan of the tokens.
    static func parseDate(_ text: [UInt8]) -> MessageDate? {
        let tokens = tokenizeDate(text)
        return parseStandardDate(tokens, text) ?? parseUnknownDate(tokens, text)
    }

    private static func parseStandardDate(_ tokens: [DateToken], _ text: [UInt8]) -> MessageDate? {
        guard tokens.count >= 5 else { return nil }
        var n = 0
        if weekday(tokens[n], text) {
            guard tokens.count >= 6 else { return nil }
            n += 1
        }
        guard let day = dayOfMonth(tokens[n], text) else { return nil }
        n += 1
        guard let month = EmlMime.month(tokens[n], text) else { return nil }
        n += 1
        guard let year = EmlMime.year(tokens[n], text) else { return nil }
        n += 1
        guard let time = timeOfDay(tokens[n], text) else { return nil }
        var hour = time.0
        n += 1
        if n < tokens.count, amPm(tokens[n], text, &hour) { n += 1 }
        let zone = n < tokens.count ? timeZone(tokens[n], text) ?? 0 : 0
        return makeDate(year, month, day, hour, time.1, time.2, zone: zone)
    }

    private static func parseUnknownDate(_ tokens: [DateToken], _ text: [UInt8]) -> MessageDate? {
        var day: Int?, month: Int?, year: Int?, zone: Int?
        var hour = 0, minute = 0, second = 0
        var numericMonth = false, haveWeekday = false, haveTime = false, haveAmPm = false
        for token in tokens {
            if !haveWeekday && weekday(token, text) {
                haveWeekday = true
                continue
            }
            if month == nil || numericMonth, let value = EmlMime.month(token, text) {
                if numericMonth {
                    numericMonth = false
                    day = month
                }
                month = value
                continue
            }
            if !haveTime, let time = timeOfDay(token, text) {
                (hour, minute, second) = time
                haveTime = true
                continue
            }
            if haveTime && zone == nil && !haveAmPm && amPm(token, text, &hour) {
                haveAmPm = true
                continue
            }
            if zone == nil && token.isTimeZone, let value = timeZone(token, text) {
                zone = value
                continue
            }
            if token.isNumeric {
                if token.length == 4 {
                    if year == nil {
                        if let value = EmlMime.year(token, text) { year = value }
                    } else if zone == nil, let value = timeZone(token, text) {
                        zone = value
                    }
                    continue
                }
                if token.length > 2 { continue }
                let value = number(token, text) ?? 0
                if month == nil && value > 0 && value <= 12 {
                    numericMonth = true
                    month = value
                    continue
                }
                if day == nil && value > 0 && value <= 31 {
                    day = value
                    continue
                }
                if year == nil && value >= 69 {
                    year = 1900 + value
                    continue
                }
            }
        }
        guard let year, let month, let day else { return nil }
        if !haveTime { hour = 0; minute = 0; second = 0 }
        return makeDate(year, month, day, hour, minute, second, zone: zone ?? 0)
    }

    // MARK: <meta> charset prescan (TextPart.TryDetectHtmlEncoding)

    /// The code page an HTML part declares in <html><head><meta ...> within its first 1024 bytes, or nil.
    /// shortcut: a small tag scanner instead of MimeKit's HtmlTokenizer (no entity decoding in attribute values).
    static func htmlMetaCodePage(_ content: ArraySlice<UInt8>) -> Int? {
        let text = Array(content.prefix(1024))
        var index = 0
        var state = 0 // 0 none, 1 html, 2 head
        func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D }
        func starts(_ prefix: String, at position: Int) -> Bool {
            let bytes = Array(prefix.utf8)
            guard position + bytes.count <= text.count else { return false }
            return (0..<bytes.count).allSatisfy { lower(text[position + $0]) == bytes[$0] }
        }
        while index < text.count {
            guard text[index] == 0x3C else { index += 1; continue }
            if starts("<!--", at: index) {
                guard let close = find("-->", in: text, from: index + 4) else { return nil }
                index = close + 3
                continue
            }
            if index + 1 < text.count, text[index + 1] == 0x21 || text[index + 1] == 0x3F {
                guard let close = text[index...].firstIndex(of: 0x3E) else { return nil }
                index = close + 1
                continue
            }
            var p = index + 1
            let endTag = p < text.count && text[p] == 0x2F
            if endTag { p += 1 }
            let nameStart = p
            while p < text.count, !isSpace(text[p]), text[p] != 0x2F, text[p] != 0x3E { p += 1 }
            guard p > nameStart, isLetter(text[nameStart]) else { index += 1; continue }
            let name = String(decoding: text[nameStart..<p].map(lower), as: UTF8.self)
            // attributes
            var attributes: [(String, String?)] = []
            var selfClosing = false
            var closed = false
            while p < text.count {
                while p < text.count && isSpace(text[p]) { p += 1 }
                guard p < text.count else { break }
                if text[p] == 0x3E { closed = true; p += 1; break }
                if text[p] == 0x2F { selfClosing = true; p += 1; continue }
                let attributeStart = p
                while p < text.count, !isSpace(text[p]), text[p] != 0x2F, text[p] != 0x3E, text[p] != 0x3D { p += 1 }
                let attribute = String(decoding: text[attributeStart..<p].map(lower), as: UTF8.self)
                while p < text.count && isSpace(text[p]) { p += 1 }
                var value: String?
                if p < text.count && text[p] == 0x3D {
                    p += 1
                    while p < text.count && isSpace(text[p]) { p += 1 }
                    if p < text.count && (text[p] == 0x22 || text[p] == 0x27) {
                        let quote = text[p]
                        guard let close = text[(p + 1)...].firstIndex(of: quote) else { p = text.count; break }
                        value = EmlCharsets.latin1(text[(p + 1)..<close])
                        p = close + 1
                    } else {
                        let valueStart = p
                        while p < text.count && !isSpace(text[p]) && text[p] != 0x3E { p += 1 }
                        value = EmlCharsets.latin1(text[valueStart..<p])
                    }
                } else {
                    value = ""
                }
                attributes.append((attribute, value))
                selfClosing = false
            }
            guard closed else { return nil }
            index = p
            switch name {
            case "html":
                if state == 0 { state = endTag || selfClosing ? -1 : 1 }
            case "head":
                if state == 1 { state = endTag || selfClosing ? -1 : 2 }
            case "meta":
                guard state == 2, !endTag else { break }
                var seen = Set<String>()
                var needPragma: Bool?
                var gotPragma = false
                var charset: String?
                for (attribute, value) in attributes {
                    guard let value, seen.insert(attribute).inserted else { continue }
                    switch attribute {
                    case "http-equiv":
                        if value.caseInsensitiveCompare("Content-Type") == .orderedSame { gotPragma = true }
                    case "content":
                        if charset == nil, let type = parseContentType(value), let declared = type.charset, !declared.isEmpty {
                            charset = trim(declared)
                            needPragma = true
                        }
                    case "charset":
                        if !value.isEmpty {
                            charset = trim(value)
                            needPragma = false
                        }
                    default:
                        break
                    }
                }
                if let needPragma, var charset, !needPragma || gotPragma {
                    if charset.caseInsensitiveCompare("x-user-defined") == .orderedSame { charset = "windows-1252" }
                    let codePage = EmlCharsets.codePage(charset)
                    if codePage != -1 { return codePage == 1200 || codePage == 1201 ? 65001 : codePage }
                }
            case "body":
                state = -1
            case "script", "style", "title", "textarea":
                // raw text: skip to the end tag
                if !endTag && !selfClosing {
                    guard let close = find("</" + name, in: text, from: index) else { return nil }
                    index = close
                }
            default:
                break
            }
            if state == -1 { return nil }
        }
        return nil
    }

    private static func isLetter(_ c: UInt8) -> Bool { (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }

    private static func find(_ needle: String, in text: [UInt8], from start: Int) -> Int? {
        let bytes = Array(needle.utf8)
        guard bytes.count <= text.count else { return nil }
        var index = start
        while index + bytes.count <= text.count {
            if (0..<bytes.count).allSatisfy({ (text[index + $0] | (isLetter(text[index + $0]) ? 0x20 : 0)) == bytes[$0] }) { return index }
            index += 1
        }
        return nil
    }
}
