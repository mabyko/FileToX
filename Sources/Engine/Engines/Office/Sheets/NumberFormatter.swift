// Filee's NumberFormatter plus a Swift implementation of ExcelNumberFormat's MIT formatting behavior.
// Reference: andersnm/ExcelNumberFormat (Parser, Evaluator, Formatter, ExcelDateTime); no runtime dependency.
/*
ExcelNumberFormat algorithm attribution:
The MIT License (MIT)

Copyright (c) 2017 andersnm

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
import Foundation

final class NumberFormatter {
    static let builtInFormats: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?",
        13: "# ??/??", 14: "yyyy-mm-dd", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM",
        19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "yyyy-mm-dd h:mm", 37: "#,##0 ;(#,##0)",
        38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)", 45: "mm:ss",
        46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@",
    ]
    private let date1904: Bool
    private var cache: [String: [Section]] = [:]
    init(_ date1904: Bool = false) { self.date1904 = date1904 }
    static func isGeneral(_ format: String?) -> Bool {
        format == nil || format == "" || format?.lowercased() == "general"
    }
    static let epoch = Date(timeIntervalSince1970: -2_209_161_600)  // 1899-12-30 UTC
    static func toSerial(_ date: Date) -> Double {
        var oa = date.timeIntervalSince(epoch) / 86400
        // OLE Automation uses an absolute time fraction on negative days.
        if oa < 0 {
            let days = floor(oa)
            oa = days - (oa - days)
        }
        return oa >= 1 && oa < 61 ? oa - 1 : oa
    }
    static func fromSerial(_ serial: Double) -> Date {
        let oa = serial >= 0 && serial < 60 ? serial + 1 : serial
        let days = oa < 0 ? ceil(oa) + abs(oa - ceil(oa)) : oa
        return epoch.addingTimeInterval((days * 86_400_000).rounded(.toNearestOrAwayFromZero) / 1000)
    }
    static func general(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if !value.isFinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == floor(value) && abs(value) < 1e11 {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let text = String(format: "%.10G", locale: Locale(identifier: "en_US_POSIX"), value)
        if text.contains("E") {
            let parts = String(format: "%.5E", locale: Locale(identifier: "en_US_POSIX"), value).components(
                separatedBy: "E")
            var base = parts[0]
            while base.hasSuffix("0") { base.removeLast() }
            if base.hasSuffix(".") { base.removeLast() }
            return base + "E" + parts[1]
        }
        return text
    }
    func format(_ value: Double, _ format: String?) -> String {
        guard value.isFinite, let format, !Self.isGeneral(format), let sections = parsed(format) else {
            return Self.general(value)
        }
        guard let selected = select(sections, value) else { return Self.compatible(value) }
        let tokens = selected.tokens
        if tokens.contains(where: Self.datePart) { return dateText(value, tokens) ?? Self.general(value) }
        if !tokens.contains(where: Self.placeholder)
            || tokens.contains(where: { $0 == "@" || $0.lowercased() == "general" })
        {
            return tokens.map { $0 == "@" || $0.lowercased() == "general" ? Self.compatible(value) : Self.literal($0) }
                .joined()
        }
        if let slash = tokens.firstIndex(of: "/"), tokens.contains(where: Self.placeholder) {
            return Self.fraction(value, tokens, slash) ?? Self.general(value)
        }
        if let exponent = tokens.firstIndex(where: { $0.lowercased() == "e+" || $0.lowercased() == "e-" }) {
            let before = Array(tokens[..<exponent])
            let power = Array(tokens[(exponent + 1)...])
            let digits = before.prefix(while: { $0 != "." }).filter(Self.placeholder).count
            guard digits > 0, value != 0 else { return Self.general(value) }
            var exp = floor(log10(abs(value)))
            var mantissa = value / pow(10, exp)
            var shift = Int(abs(exp)) % digits
            if shift > 0 {
                if exp < 0 { shift = digits - shift }
                mantissa *= pow(10, Double(shift))
                exp -= Double(shift)
            }
            return Self.decimal(mantissa, before, false) + String(tokens[exponent].prefix(1))
                + (exp < 0 ? "-" : tokens[exponent].hasSuffix("+") ? "+" : "")
                + Self.thousands(String(format: "%.0f", abs(exp)), power, false)
        }
        var number = value
        if (selected.index == 0 && selected.condition != nil) || selected.index == 1 { number = abs(number) }
        let last = tokens.lastIndex(where: Self.placeholder)
        var divisor = 1.0
        if let last {
            for t in tokens.dropFirst(last + 1) {
                if t != "," { break }
                divisor *= 1000
            }
        }
        if tokens.contains("%") { number *= 100 }
        let grouping = last.map { tokens.prefix($0).contains(",") } ?? false
        return Self.decimal(number / divisor, tokens, grouping)
    }
    func isDate(_ format: String?) -> Bool {
        guard let format, !Self.isGeneral(format), let sections = parsed(format) else { return false }
        return sections.contains { $0.tokens.contains(where: Self.datePart) }
            && !sections.contains { $0.tokens.contains { $0.hasPrefix("[") } }
    }
    private static func compatible(_ value: Double) -> String {
        String(format: "%.15G", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func int32(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value.rounded(.towardZero), Double(Int32.min)), Double(Int32.max))
    }
    private struct Section {
        let tokens: [String]
        let condition: String?
        let index: Int
    }
    private func parsed(_ code: String) -> [Section]? {
        if let value = cache[code] { return value.isEmpty ? nil : value }
        var sections: [Section] = []
        for (i, part) in Self.splitSections(code).enumerated() {
            guard let raw = Self.tokenize(part) else {
                cache[code] = []
                return nil
            }
            var condition: String?
            var tokens: [String] = []
            for token in raw {
                if token.hasPrefix("[") && !Self.datePart(token) {
                    let inner = String(token.dropFirst().dropLast())
                    if ["<", ">", "="].contains(String(inner.prefix(1))) {
                        condition = inner
                    } else if inner.hasPrefix("$") {
                        let symbol =
                            inner.dropFirst().split(separator: "-", omittingEmptySubsequences: false).first ?? ""
                        tokens.append("\"" + symbol + "\"")
                    }
                } else {
                    tokens.append(token)
                }
            }
            // ExcelNumberFormat stops parsing when an empty section is encountered.
            if tokens.isEmpty { break }
            let date = tokens.contains(where: Self.datePart)
            let text = tokens.contains("@")
            let general = tokens.contains { $0.lowercased() == "general" }
            if (date && (text || general)) || (text && general) {
                cache[code] = []
                return nil
            }
            sections.append(Section(tokens: tokens, condition: condition, index: i))
        }
        cache[code] = sections
        return sections.isEmpty ? nil : sections
    }
    private func select(_ sections: [Section], _ value: Double) -> Section? {
        let first = sections[0]
        if let c = first.condition {
            if Self.matches(c, value) { return first }
        } else if sections.count == 1 || (sections.count == 2 && value >= 0) || (sections.count > 2 && value > 0) {
            return first
        }
        guard sections.count > 1 else { return nil }
        let second = sections[1]
        if let c = second.condition {
            if Self.matches(c, value) { return second }
        } else if value < 0 || (sections.count == 2 && first.condition != nil) {
            return second
        }
        return sections.count >= 3 ? sections[2] : nil
    }
    private static func matches(_ condition: String, _ v: Double) -> Bool {
        for op in ["<=", ">=", "<>", "<", ">", "="] where condition.hasPrefix(op) {
            guard let rhs = Double(condition.dropFirst(op.count)) else { return false }
            switch op {
            case "<=": return v <= rhs
            case ">=": return v >= rhs
            case "<>": return v != rhs
            case "<": return v < rhs
            case ">": return v > rhs
            default: return v == rhs
            }
        }
        return false
    }
    static func splitSections(_ code: String) -> [String] {
        var result: [String] = []
        var part = ""
        var quoted = false
        var bracket = false
        var escaped = false
        for c in code {
            if escaped {
                part.append(c)
                escaped = false
                continue
            }
            if c == "\\" && !quoted {
                escaped = true
                part.append(c)
                continue
            }
            if c == "\"" { quoted.toggle() }
            if !quoted {
                if c == "[" { bracket = true }
                if c == "]" { bracket = false }
            }
            if c == ";" && !quoted && !bracket {
                result.append(part)
                part = ""
            } else {
                part.append(c)
            }
        }
        result.append(part)
        return result
    }
    static func tokenize(_ code: String) -> [String]? {
        let chars = Array(code)
        var result: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let lower = c.lowercased()
            if c == "\"" || c == "[" {
                let end: Character = c == "\"" ? "\"" : "]"
                guard let close = chars[(i + 1)...].firstIndex(of: end) else { return nil }
                result.append(String(chars[i...close]))
                i = close + 1
                continue
            }
            if c == "\\" || c == "_" || c == "*" {
                guard i + 1 < chars.count else { return nil }
                result.append(String(chars[i...i + 1]))
                i += 2
                continue
            }
            let remaining = String(chars[i...]).lowercased()
            if let marker = ["general", "am/pm", "a/p", "e+", "e-"].first(where: { remaining.hasPrefix($0) }) {
                result.append(String(chars[i..<i + marker.count]))
                i += marker.count
                continue
            }
            if ["y", "m", "d", "h", "s", "g"].contains(lower) {
                var end = i + 1
                while end < chars.count && chars[end] == c { end += 1 }
                result.append(String(chars[i..<end]))
                i = end
                continue
            }
            guard "#?,!&%+-$€£0123456789{}():;/.@ ".contains(c) else { return nil }
            result.append(String(c))
            i += 1
        }
        return result
    }
    static func placeholder(_ t: String) -> Bool { t == "0" || t == "#" || t == "?" }
    static func datePart(_ t: String) -> Bool {
        let low = t.lowercased()
        if low.hasPrefix("[") {
            let inner = low.dropFirst().dropLast()
            return !inner.isEmpty && inner.allSatisfy { $0 == inner.first }
                && ["h", "m", "s"].contains(String(inner.prefix(1)))
        }
        return ["y", "m", "d", "h", "s", "g"].contains(String(low.prefix(1))) && low.allSatisfy { $0 == low.first }
            || low == "am/pm" || low == "a/p"
    }
    static func literal(_ t: String) -> String {
        if t == "," { return "" }
        if t.hasPrefix("\"") { return String(t.dropFirst().dropLast()) }
        if t.hasPrefix("_") { return " " }
        if t.hasPrefix("\\") || t.hasPrefix("*") { return String(t.dropFirst()) }
        return t
    }
    private static func put(_ t: String, _ c: Character, _ significant: Bool) -> String {
        t == "0" ? (significant ? String(c) : "0") : significant ? String(c) : t == "?" ? " " : ""
    }
    private static func thousands(_ text: String, _ tokens: [String], _ grouping: Bool, _ significantZero: Bool = false)
        -> String
    {
        let count = tokens.filter(placeholder).count
        let digits = Array(String(repeating: "0", count: max(0, count - text.count)) + text)
        var result = ""
        var t = 0
        var d = 0
        var significant = false
        func separator(_ i: Int) -> String {
            grouping && digits.count - i - 1 > 0 && (digits.count - i - 1) % 3 == 0 ? "," : ""
        }
        while t < tokens.count && !placeholder(tokens[t]) {
            result += literal(tokens[t])
            t += 1
        }
        while d < digits.count - count {
            significant = true
            result.append(digits[d])
            result += separator(d)
            d += 1
        }
        while t < tokens.count {
            if placeholder(tokens[t]), d < digits.count {
                if digits[d] != "0" || (significantZero && d == digits.count - 1) { significant = true }
                result += put(tokens[t], digits[d], significant)
                if significant || tokens[t] == "0" { result += separator(d) }
                d += 1
            } else {
                result += literal(tokens[t])
            }
            t += 1
        }
        return result
    }
    private static func decimal(_ value: Double, _ tokens: [String], _ grouping: Bool) -> String {
        let point = tokens.firstIndex(of: ".")
        let before = point.map { Array(tokens[..<$0]) } ?? tokens
        let after = point.map { Array(tokens[($0 + 1)...]) } ?? []
        let places = min(100, after.filter(placeholder).count)
        let fixed = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, abs(value)).components(
            separatedBy: ".")
        var result = (value < 0 ? "-" : "") + thousands(fixed[0], before, grouping)
        if point != nil { result += "." }
        var fraction = fixed.count > 1 ? fixed[1] : ""
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let raw = Array(fraction)
        let digits = raw + Array(repeating: Character("0"), count: max(0, places - raw.count))
        var i = 0
        for t in after {
            if placeholder(t), i < digits.count {
                result += put(t, digits[i], i < raw.count)
                i += 1
            } else {
                result += literal(t)
            }
        }
        return result
    }
    private static func fraction(_ v: Double, _ tokens: [String], _ slash: Int) -> String? {
        let before = Array(tokens[..<slash])
        let after = Array(tokens[(slash + 1)...])
        var numeratorStart = 0
        var sawDigit = false
        var sawSpace = false
        for i in before.indices.reversed() {
            if placeholder(before[i]) {
                if sawSpace { break }
                sawDigit = true
            } else if sawDigit && !sawSpace {
                numeratorStart = i + 1
                sawSpace = true
            }
        }
        if !before.prefix(numeratorStart).contains(where: placeholder) { numeratorStart = 0 }
        let integer = Array(before.prefix(numeratorStart))
        let numeratorTokens = Array(before.dropFirst(numeratorStart))
        guard let denStart = after.firstIndex(where: { placeholder($0) || Int($0) != nil }) else { return nil }
        let constant = !placeholder(after[denStart])
        var denEnd = denStart
        while denEnd < after.count && (constant ? Int(after[denEnd]) != nil : placeholder(after[denEnd])) {
            denEnd += 1
        }
        let denominatorTokens = Array(after[denStart..<denEnd])
        let maxDen = Int(pow(10, Double(min(7, denominatorTokens.count)))) - 1
        let integral = integer.isEmpty ? 0 : int32(v)
        let value = integer.isEmpty ? v : abs(v - integral)
        var numerator = 0.0
        var denominator = 1.0
        if constant, let den = Double(denominatorTokens.joined()), den > 0 {
            denominator = den
            let rounded = (value * den).rounded(.toNearestOrEven)
            numerator = rounded - floor(rounded / den) * den
        } else {
            var b = abs(value)
            var p2 = 0.0
            var p1 = 1.0
            var q2 = 1.0
            var q1 = 0.0
            for _ in 0..<100 {
                let a = floor(b)
                let p = a * p1 + p2
                let q = a * q1 + q2
                numerator = p
                denominator = q
                if q > Double(maxDen) {
                    numerator = q1 > Double(maxDen) ? p2 : p1
                    denominator = q1 > Double(maxDen) ? q2 : q1
                    break
                }
                if b - a < 0.00000005 { break }
                b = 1 / (b - a)
                p2 = p1
                p1 = p
                q2 = q1
                q1 = q
            }
        }
        guard numerator.isFinite && denominator.isFinite && denominator > 0 else { return nil }
        numerator = int32(numerator)
        denominator = int32(denominator)
        let hidden = !integer.isEmpty && numerator == 0 && !numeratorTokens.contains("0")
        var result =
            (v < 0 ? "-" : "")
            + (integer.isEmpty ? "" : thousands(String(format: "%.0f", abs(integral)), integer, false, hidden))
        var frac =
            thousands(String(format: "%.0f", numerator), numeratorTokens, false, true) + "/"
            + after.prefix(denStart).map(literal).joined()
        let denText = String(format: "%.0f", denominator)
        if constant {
            frac += denText
        } else {
            // Denominators are left aligned; '?' consumes insignificant leading zeros.
            let digits = Array(String(repeating: "0", count: max(0, denominatorTokens.count - denText.count)) + denText)
            var i = 0
            var sig = false
            for t in denominatorTokens {
                var c: Character = "0"
                if i < digits.count {
                    c = digits[i]
                    i += 1
                    if c != "0" { sig = true }
                    if t == "?" && !sig {
                        while i < digits.count {
                            c = digits[i]
                            i += 1
                            if c != "0" { break }
                        }
                    }
                } else {
                    sig = false
                }
                if c != "0" { sig = true }
                frac += put(t, c, sig)
            }
        }
        var fractionSuffix = after.count
        while fractionSuffix > denEnd && !placeholder(after[fractionSuffix - 1]) { fractionSuffix -= 1 }
        if denEnd < fractionSuffix { frac += thousands("", Array(after[denEnd..<fractionSuffix]), false) }
        result += hidden ? String(repeating: " ", count: frac.count) : frac
        if fractionSuffix < after.count { result += thousands("", Array(after[fractionSuffix...]), false) }
        return result
    }
    private func dateText(_ serial: Double, _ raw: [String]) -> String? {
        var tokens: [String] = []
        var i = 0
        while i < raw.count {
            if raw[i] == "." && i + 1 < raw.count && raw[i + 1] == "0" {
                var ms = "."
                i += 1
                while i < raw.count && raw[i] == "0" {
                    ms += "0"
                    i += 1
                }
                tokens.append(ms)
            } else {
                tokens.append(raw[i])
                i += 1
            }
        }
        let elapsed = tokens.contains { $0.hasPrefix("[") }
        let ampm = tokens.contains { ["am/pm", "a/p"].contains($0.lowercased()) }
        if elapsed && abs(serial) > 10_675_199 { return nil }
        let input = serial + (date1904 && !elapsed ? 1462 : 0)
        // ExcelNumberFormat uses unchecked .NET OA arithmetic, including saturating casts and wrapping ticks.
        let rawMillis = input * 86_400_000 + (input >= 0 ? 0.5 : -0.5)
        var millis =
            rawMillis >= Double(Int64.max) ? Int64.max : rawMillis <= Double(Int64.min) ? Int64.min : Int64(rawMillis)
        if millis < 0 { millis = millis &- ((millis % 86_400_000) &* 2) }
        let ticks = (millis &+ 59_926_435_200_000) &* 10000
        guard ticks >= 0 && ticks <= 3_155_378_975_999_999_999 else { return nil }
        var date = Self.epoch.addingTimeInterval(Double(ticks - 599_264_352_000_000_000) / 10_000_000)
        var adjust = 0
        if !date1904 && !elapsed {
            let days = date.timeIntervalSince(Self.epoch) / 86400
            if days < 0 {
                date = date.addingTimeInterval(172800)
            } else if days < 1 {
                date = date.addingTimeInterval(172800)
                adjust = -1
            } else if days < 60 {
                date = date.addingTimeInterval(86400)
            } else if days < 61 {
                adjust = 1
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond, .weekday], from: date)
        let months = [
            "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
            "November", "December",
        ]
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        func padded(_ n: Int, _ count: Int) -> String {
            let str = String(abs(n))
            return (n < 0 ? "-" : "") + String(repeating: "0", count: max(0, count - str.count)) + str
        }
        func neighbor(_ idx: Int, _ step: Int) -> String? {
            var n = idx + step
            while n >= 0 && n < tokens.count {
                if Self.datePart(tokens[n]) { return tokens[n].lowercased() }
                n += step
            }
            return nil
        }
        var result = ""
        var totalMillis = (serial * 86_400_000).rounded(.towardZero)
        for (idx, t) in tokens.enumerated() {
            let low = t.lowercased()
            let n = t.count
            if elapsed {
                if low.hasPrefix("[") {
                    let unit = low.dropFirst().first!
                    let factor = unit == "h" ? 3600000.0 : unit == "m" ? 60000.0 : 1000.0
                    let v = Int(Self.int32(totalMillis / factor))
                    result += padded(v, n - 2)
                    totalMillis = abs(totalMillis.truncatingRemainder(dividingBy: factor))
                    continue
                }
                if low.hasPrefix("m") {
                    result += padded(Int(totalMillis / 60000).quotientAndRemainder(dividingBy: 60).remainder, n)
                    continue
                }
                if low.hasPrefix("s") {
                    let sec = totalMillis.truncatingRemainder(dividingBy: 60000) / 1000
                    result += padded(
                        Int(
                            tokens.contains { $0.hasPrefix(".0") }
                                ? sec.rounded(.towardZero) : sec.rounded(.toNearestOrAwayFromZero)), n)
                    continue
                }
                if low.hasPrefix(".0") {
                    result += "." + padded(Int(totalMillis.truncatingRemainder(dividingBy: 1000)), n - 1)
                    continue
                }
            }
            if low == "am/pm" {
                result += (c.hour ?? 0) < 12 ? "AM" : "PM"
            } else if low == "a/p" {
                let ch = (c.hour ?? 0) < 12 ? "A" : "P"
                result += t.hasPrefix("a") ? ch.lowercased() : ch
            } else if low.hasPrefix("y") {
                let digits = n < 2 ? 2 : n == 3 ? 4 : n
                result += padded(digits == 2 ? (c.year ?? 0) % 100 : c.year ?? 0, digits)
            } else if low.hasPrefix("m") {
                if neighbor(idx, -1)?.hasPrefix("h") == true || neighbor(idx, 1)?.hasPrefix("s") == true {
                    result += padded(c.minute ?? 0, n)
                } else {
                    let month = c.month ?? 1
                    if n == 3 {
                        result += String(months[month - 1].prefix(3))
                    } else if n == 4 {
                        result += months[month - 1]
                    } else if n == 5 {
                        result += String(months[month - 1].prefix(1))
                    } else {
                        result += padded(month, n)
                    }
                }
            } else if low.hasPrefix("d") {
                if n == 3 || n == 4 {
                    let weekday = weekdays[(c.weekday ?? 1) - 1]
                    result += n == 3 ? String(weekday.prefix(3)) : weekday
                } else {
                    result += padded((c.day ?? 0) + adjust, n)
                }
            } else if low.hasPrefix("h") {
                result += padded(ampm ? ((c.hour ?? 0) + 11) % 12 + 1 : c.hour ?? 0, n)
            } else if low.hasPrefix("s") {
                result += padded(c.second ?? 0, n)
            } else if low.hasPrefix("g") {
                result += "A.D."
            } else if low.hasPrefix(".0") {
                result += "." + padded(Int(((Double(c.nanosecond ?? 0) / 1_000_000).rounded())), n - 1)
            } else if t == "," {
                if idx == 0 || tokens[idx - 1] != "," { result += "," }
            } else {
                result += Self.literal(t)
            }
        }
        return result
    }
}
