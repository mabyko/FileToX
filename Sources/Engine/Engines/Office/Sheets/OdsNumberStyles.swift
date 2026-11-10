// Port of Filee.Engines/Office/Sheets/OdsNumberStyles.cs.
import Foundation

enum OdsNumberStyles {
    static let number = XNamespace("urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0")
    static let style = XNamespace("urn:oasis:names:tc:opendocument:xmlns:style:1.0")
    static let fo = XNamespace("urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0")
    private static let colors = [
        ("Black", "#000000"), ("Blue", "#0000FF"), ("Cyan", "#00FFFF"), ("Green", "#00FF00"), ("Magenta", "#FF00FF"),
        ("Red", "#FF0000"), ("White", "#FFFFFF"), ("Yellow", "#FFFF00"),
    ]
    static func toExcel(_ element: XElement, _ find: (String) -> XElement?) -> String? {
        guard let main = sectionCode(element) else { return nil }
        func mapped(_ condition: String) -> String? {
            guard
                let m = element.elements(style + "map").first(where: {
                    ($0.attributeValue(style + "condition") ?? "").replacingOccurrences(of: " ", with: "") == condition
                }), let target = find(m.attributeValue(style + "apply-style-name") ?? "")
            else { return nil }
            return sectionCode(target)
        }
        if let plus = mapped("value()>=0") { return plus + ";" + main }
        if let plus = mapped("value()>0"), let minus = mapped("value()<0") { return plus + ";" + minus + ";" + main }
        return main
    }
    private static func sectionCode(_ element: XElement) -> String? {
        let kind = element.name.localName
        let isDate = kind == "date-style" || kind == "time-style"
        let elapsed = element.attributeValue(number + "truncate-on-overflow") == "false"
        var sb = ""
        if let color = element.element(style + "text-properties")?.attributeValue(fo + "color"),
            let name = colors.first(where: { $0.1.caseInsensitiveCompare(color) == .orderedSame })?.0
        {
            sb += "[\(name)]"
        }
        for part in element.elements() where part.name.namespace == number {
            let long = part.attributeValue(number + "style") == "long"
            switch part.name.localName {
            case "text":
                sb +=
                    kind == "percentage-style"
                    ? part.value.components(separatedBy: "%").map { literal($0, false) }.joined(separator: "%")
                    : literal(part.value, isDate)
            case "number": sb += digits(part)
            case "scientific-number":
                sb += String(repeating: "0", count: max(1, int(part, "min-integer-digits") ?? 1))
                let places = int(part, "decimal-places") ?? 0
                if places > 0 { sb += "." + String(repeating: "0", count: places) }
                sb += "E+" + String(repeating: "0", count: max(1, int(part, "min-exponent-digits") ?? 2))
            case "fraction":
                if (int(part, "min-integer-digits") ?? 0) > 0 { sb += "# " }
                sb += String(repeating: "?", count: max(1, int(part, "min-numerator-digits") ?? 1)) + "/"
                sb +=
                    int(part, "denominator-value").map(String.init)
                    ?? String(repeating: "?", count: max(1, int(part, "min-denominator-digits") ?? 1))
            case "currency-symbol": sb += literal(part.value, false)
            case "year": sb += long ? "yyyy" : "yy"
            case "month":
                sb += part.attributeValue(number + "textual") == "true" ? (long ? "mmmm" : "mmm") : (long ? "mm" : "m")
            case "day": sb += long ? "dd" : "d"
            case "day-of-week": sb += long ? "dddd" : "ddd"
            case "hours":
                let h = long ? "hh" : "h"
                sb += elapsed ? "[\(h)]" : h
            case "minutes": sb += long ? "mm" : "m"
            case "seconds":
                sb += long ? "ss" : "s"
                if let d = int(part, "decimal-places"), d > 0 { sb += "." + String(repeating: "0", count: d) }
            case "am-pm": sb += "AM/PM"
            case "text-content": sb += "@"
            case "fill-character": break
            default: return nil
            }
        }
        return sb
    }
    private static func int(_ el: XElement, _ attr: String) -> Int? {
        SheetXML.int(el.attributeValue(number + attr)).map { min(max($0, 0), 1000) }
    }
    private static func digits(_ el: XElement) -> String {
        guard let places = int(el, "decimal-places") else { return "General" }
        let lo = XNamespace("urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0")
        let minPlaces = min(
            places,
            int(el, "min-decimal-places") ?? SheetXML.int(el.attributeValue(lo + "min-decimal-places")) ?? places)
        let minInteger = int(el, "min-integer-digits") ?? 1
        var sb: String
        if el.attributeValue(number + "grouping") == "true" {
            let integer =
                String(repeating: "#", count: max(0, 4 - minInteger)) + String(repeating: "0", count: minInteger)
            sb = String(integer.dropLast(3)) + "," + integer.suffix(3)
        } else {
            sb = minInteger > 0 ? String(repeating: "0", count: minInteger) : "#"
        }
        if places > 0 {
            sb +=
                "." + String(repeating: "0", count: max(0, minPlaces))
                + String(repeating: "#", count: max(0, places - minPlaces))
        }
        var factor = SheetXML.double(el.attributeValue(number + "display-factor")) ?? 0
        while factor >= 1000 && factor.isFinite {
            sb += ","
            factor /= 1000
        }
        return sb
    }
    private static func literal(_ text: String, _ isDate: Bool) -> String {
        let plain = isDate ? " -/:.,()$+" : " -:()$+"
        if text.allSatisfy({ plain.contains($0) }) { return text }
        return text.components(separatedBy: "\"").map { $0.isEmpty ? "" : "\"\($0)\"" }.joined(separator: "\\\"")
    }
    private enum Kind {
        case literal, digit, point, comma, percent, exponent, slash, year, month, minute, day, hour, second, ampm, text,
            color, currency, general, unsupported
    }
    private struct Token {
        var kind: Kind
        var text: String
        var elapsed = false
    }
    private struct Section {
        let element: String
        let body: String
        let color: String?
        let elapsed: Bool
    }
    static func toOdf(_ code: String?, _ name: String) -> (xml: String, valueType: String)? {
        guard let code, !NumberFormatter.isGeneral(code) else { return nil }
        let parts = NumberFormatter.splitSections(code)
        guard parts.count <= 4 else { return nil }
        var parsed: [Section] = []
        for part in parts.prefix(3) {
            guard let section = buildSection(tokenize(part)) else { return nil }
            parsed.append(section)
        }
        guard let first = parsed.first, first.element != "text-style" else { return nil }
        let element = first.element
        if parsed.count > 1 && ["date-style", "time-style"].contains(element) { parsed = [first] }
        func xml(_ n: String, _ s: Section, _ maps: String) -> String {
            "<number:\(element) style:name=\"\(n)\"" + (n == name ? "" : " style:volatile=\"true\"")
                + (s.elapsed ? " number:truncate-on-overflow=\"false\"" : "") + ">"
                + (s.color.map { "<style:text-properties fo:color=\"\($0)\"/>" } ?? "") + s.body + maps
                + "</number:\(element)>"
        }
        let output: String
        if parsed.count == 1 {
            output = xml(name, first, "")
        } else if parsed.count == 2 {
            output =
                xml(name + "P0", first, "")
                + xml(
                    name, parsed[1],
                    "<style:map style:condition=\"value()&gt;=0\" style:apply-style-name=\"\(name)P0\"/>")
        } else {
            output =
                xml(name + "P0", first, "") + xml(name + "P1", parsed[1], "")
                + xml(
                    name, parsed[2],
                    "<style:map style:condition=\"value()&gt;0\" style:apply-style-name=\"\(name)P0\"/><style:map style:condition=\"value()&lt;0\" style:apply-style-name=\"\(name)P1\"/>"
                )
        }
        let type =
            [
                "percentage-style": "percentage", "currency-style": "currency", "date-style": "date",
                "time-style": "time",
            ][element] ?? "float"
        return (output, type)
    }
    private static func isDatePart(_ k: Kind) -> Bool {
        [.year, .month, .minute, .day, .hour, .second, .ampm].contains(k)
    }
    private static func tokenize(_ section: String) -> [Token] {
        if section.trimmingCharacters(in: .whitespaces).lowercased() == "general" {
            return [Token(kind: .general, text: "")]
        }
        let chars = Array(section)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            var token = Token(kind: .literal, text: String(ch))
            if ch == "\"" {
                let end = chars[(i + 1)...].firstIndex(of: "\"") ?? chars.count
                token.text = String(chars[(i + 1)..<end])
                i = end
            } else if ch == "\\" {
                i += 1
                if i >= chars.count { break }
                token.text = String(chars[i])
            } else if ch == "_" {
                i += 1
                token.text = " "
            } else if ch == "*" {
                i += 2
                continue
            } else if ch == "[" {
                guard let end = chars[(i + 1)...].firstIndex(of: "]") else {
                    return [Token(kind: .unsupported, text: "")]
                }
                let inner = String(chars[(i + 1)..<end])
                i = end
                if inner.hasPrefix("$") {
                    token.kind = .currency
                    token.text = String(
                        inner.dropFirst().split(separator: "-", omittingEmptySubsequences: false).first ?? "")
                    if token.text.isEmpty { token.kind = .literal }
                } else if !inner.isEmpty && inner.lowercased().allSatisfy({ $0 == inner.lowercased().first })
                    && ["h", "m", "s"].contains(String(inner.lowercased().prefix(1)))
                {
                    token.kind =
                        inner.lowercased().hasPrefix("h")
                        ? .hour : inner.lowercased().hasPrefix("m") ? .minute : .second
                    token.text = inner.lowercased()
                    token.elapsed = true
                } else if let c = colors.first(where: { $0.0.caseInsensitiveCompare(inner) == .orderedSame }) {
                    token.kind = .color
                    token.text = c.1
                } else {
                    token.kind = .unsupported
                    token.text = inner
                }
            } else if "0#?".contains(ch) {
                token.kind = .digit
            } else if ch == "." {
                token.kind = .point
            } else if ch == "," {
                token.kind = .comma
            } else if ch == "%" {
                token.kind = .percent
            } else if ch == "/" {
                token.kind = .slash
            } else if ch == "@" {
                token.kind = .text
            } else if ch.lowercased() == "e" && i + 1 < chars.count && ["+", "-"].contains(chars[i + 1]) {
                token.kind = .exponent
                i += 1
                token.text = "E" + String(chars[i])
            } else {
                let rest = String(chars[i...]).uppercased()
                if let marker = ["AM/PM", "A/P"].first(where: { rest.hasPrefix($0) }) {
                    token.kind = .ampm
                    token.text = String(chars[i..<i + marker.count])
                    i += marker.count - 1
                } else {
                    token.kind =
                        [
                            "y": .year, "m": .month, "d": .day, "h": .hour, "s": .second, "e": .unsupported,
                            "g": .unsupported, "b": .unsupported,
                        ][ch.lowercased()] ?? .literal
                    if token.kind != .literal {
                        var run = 1
                        while i + run < chars.count && chars[i + run].lowercased() == ch.lowercased() { run += 1 }
                        token.text = String(repeating: ch.lowercased(), count: run)
                        i += run - 1
                    }
                }
            }
            tokens.append(token)
            i += 1
        }
        for i in tokens.indices where tokens[i].kind == .month {
            let before = tokens.prefix(i).last { isDatePart($0.kind) }
            let after = tokens.dropFirst(i + 1).first { isDatePart($0.kind) }
            if before?.kind == .hour || after?.kind == .second { tokens[i].kind = .minute }
        }
        return tokens
    }
    private static func buildSection(_ tokens: [Token]) -> Section? {
        if tokens.contains(where: { $0.kind == .unsupported }) { return nil }
        if tokens.contains(where: { $0.kind == .text }) {
            return Section(element: "text-style", body: "", color: nil, elapsed: false)
        }
        let color = tokens.last { $0.kind == .color }?.text
        return tokens.contains(where: { isDatePart($0.kind) })
            ? dateSection(tokens, color) : numberSection(tokens, color)
    }
    private static func dateSection(_ tokens: [Token], _ color: String?) -> Section? {
        var body = ""
        var literal = ""
        var elapsed = false
        var i = 0
        func flush() {
            if !literal.isEmpty {
                body += "<number:text>\(SheetXML.escape(literal))</number:text>"
                literal = ""
            }
        }
        while i < tokens.count {
            let t = tokens[i]
            let n = t.text.count
            i += 1
            if [.literal, .point, .comma, .slash, .percent].contains(t.kind) {
                literal += t.text
                continue
            }
            if t.kind == .color { continue }
            if [.digit, .exponent, .currency, .general].contains(t.kind) { return nil }
            flush()
            switch t.kind {
            case .year: body += n > 2 ? "<number:year number:style=\"long\"/>" : "<number:year/>"
            case .month:
                body +=
                    n == 1
                    ? "<number:month/>"
                    : n == 2
                        ? "<number:month number:style=\"long\"/>"
                        : n == 3 || n == 5
                            ? "<number:month number:textual=\"true\"/>"
                            : "<number:month number:style=\"long\" number:textual=\"true\"/>"
            case .day:
                body +=
                    n == 1
                    ? "<number:day/>"
                    : n == 2
                        ? "<number:day number:style=\"long\"/>"
                        : n == 3 ? "<number:day-of-week/>" : "<number:day-of-week number:style=\"long\"/>"
            case .hour:
                elapsed = elapsed || t.elapsed
                body += n > 1 ? "<number:hours number:style=\"long\"/>" : "<number:hours/>"
            case .minute: body += n > 1 ? "<number:minutes number:style=\"long\"/>" : "<number:minutes/>"
            case .second:
                var places = 0
                if i < tokens.count && tokens[i].kind == .point {
                    while i + 1 + places < tokens.count && tokens[i + 1 + places].kind == .digit
                        && tokens[i + 1 + places].text == "0"
                    { places += 1 }
                    if places > 0 { i += 1 + places }
                }
                body +=
                    "<number:seconds" + (n > 1 ? " number:style=\"long\"" : "")
                    + (places > 0 ? " number:decimal-places=\"\(places)\"" : "") + "/>"
            case .ampm: body += "<number:am-pm/>"
            default: break
            }
        }
        flush()
        let date = tokens.contains { [.year, .month, .day].contains($0.kind) }
        return Section(element: date ? "date-style" : "time-style", body: body, color: color, elapsed: elapsed && !date)
    }
    private static func numberSection(_ tokens: [Token], _ color: String?) -> Section? {
        if tokens.contains(where: { $0.kind == .slash }) { return nil }
        let start = tokens.firstIndex { [.digit, .point, .general].contains($0.kind) }
        var end = start ?? -1
        if start != nil {
            while end + 1 < tokens.count && [.digit, .point, .comma, .exponent].contains(tokens[end + 1].kind) {
                end += 1
            }
            if tokens.dropFirst(end + 1).contains(where: { [.digit, .point, .general].contains($0.kind) }) {
                return nil
            }
        }
        var body = ""
        var literal = ""
        var percent = false
        var currency = false
        var i = 0
        func flush() {
            if !literal.isEmpty {
                body += "<number:text>\(SheetXML.escape(literal))</number:text>"
                literal = ""
            }
        }
        while i < tokens.count {
            if i == start {
                flush()
                body +=
                    tokens[i].kind == .general
                    ? "<number:number number:min-integer-digits=\"1\"/>" : digits(Array(tokens[i...end]))
                i = end + 1
                continue
            }
            let t = tokens[i]
            switch t.kind {
            case .percent:
                percent = true
                literal += "%"
            case .currency:
                currency = true
                flush()
                body += "<number:currency-symbol>\(SheetXML.escape(t.text))</number:currency-symbol>"
            case .literal, .comma, .point: literal += t.text
            default: break
            }
            i += 1
        }
        flush()
        return Section(
            element: currency ? "currency-style" : percent ? "percentage-style" : "number-style", body: body,
            color: color, elapsed: false)
    }
    private static func digits(_ digits: [Token]) -> String {
        let exponent = digits.firstIndex { $0.kind == .exponent }
        let mantissa = exponent.map { Array(digits[..<$0]) } ?? digits
        let point = mantissa.firstIndex { $0.kind == .point }
        let integer = point.map { Array(mantissa[..<$0]) } ?? mantissa
        let fraction = point.map { Array(mantissa[($0 + 1)...]) } ?? []
        let minInteger = integer.filter { $0.text == "0" }.count
        let lastInteger = integer.lastIndex { $0.kind == .digit } ?? 0
        let grouping = integer.prefix(lastInteger).contains { $0.kind == .comma }
        let scaling = mantissa.dropFirst((mantissa.lastIndex { $0.kind == .digit } ?? -1) + 1).filter {
            $0.kind == .comma
        }.count
        let places = fraction.filter { $0.kind == .digit }.count
        let minPlaces = fraction.filter { $0.text == "0" }.count
        if let exponent {
            let expDigits = digits.dropFirst(exponent + 1).filter { $0.kind == .digit }.count
            return
                "<number:scientific-number number:decimal-places=\"\(places)\" number:min-integer-digits=\"\(max(1,minInteger))\" number:min-exponent-digits=\"\(max(1,expDigits))\"/>"
        }
        return
            "<number:number number:decimal-places=\"\(places)\" number:min-decimal-places=\"\(minPlaces)\" number:min-integer-digits=\"\(minInteger)\""
            + (grouping ? " number:grouping=\"true\"" : "")
            + (scaling > 0 ? " number:display-factor=\"\(SheetXML.number(pow(1000,Double(scaling))))\"" : "") + "/>"
    }
}
