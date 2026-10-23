// Port of Filee.Engines/Office/Sheets/CsvFormat.cs.
import Foundation

enum CsvFormat {
    static let tab: Character = "\t"
    static func read(_ path: String) throws -> Workbook { try read(path, nil) }
    static func readTsv(_ path: String) throws -> Workbook { try read(path, tab) }
    private static func read(_ path: String, _ delimiter: Character?) throws -> Workbook {
        let text = TextEncodings.decodeText(try Data(contentsOf: URL(fileURLWithPath: path)))
        let sheet = Worksheet(FilePath.fileNameWithoutExtension(path))
        var widths: [Int: Double] = [:]
        for (r, row) in parse(text, delimiter ?? detectDelimiter(text)).enumerated() {
            if r % 1024 == 0 { try Task.checkCancellation() }
            for (c, value) in row.enumerated() where !value.isEmpty {
                sheet.set(
                    r, c,
                    SheetCell(
                        value, .default, isNumber: isNumber(value),
                        value: isNumber(value) ? Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) : nil))
                widths[c] = max(widths[c] ?? 0, displayWidth(value))
            }
        }
        for (c, width) in widths { sheet.columnWidths[c] = min(max(width + 1, 4), 50) }
        let book = Workbook()
        book.sheets.append(sheet)
        return book
    }
    static func write(_ sheet: Worksheet, _ path: String, _ delimiter: Character = ",") throws {
        var text = "\u{FEFF}"
        if let range = sheet.usedRange() {
            for r in 0...range.bottom where !sheet.hiddenRows.contains(r) {
                if r % 1024 == 0 { try Task.checkCancellation() }
                text +=
                    (0...range.right).filter { !sheet.hiddenColumns.contains($0) }.map {
                        quote(sheet.get(r, $0)?.text ?? "", delimiter)
                    }.joined(separator: String(delimiter)) + "\r\n"
            }
        }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
    static func parse(_ text: String, _ delimiter: Character) -> [[String]] {
        // UTF-16 units preserve C#'s CR/LF and surrogate semantics.
        let chars = Array(text.utf16)
        let delim = String(delimiter).utf16.first!
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt16] = []
        var quoted = false
        var i = 0
        func flush() {
            row.append(String(decoding: field, as: UTF16.self))
            field.removeAll(keepingCapacity: true)
        }
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == 34 && i + 1 < chars.count && chars[i + 1] == 34 {
                    field.append(34)
                    i += 1
                } else if ch == 34 {
                    quoted = false
                } else {
                    field.append(ch)
                }
            } else if ch == 34 && field.isEmpty {
                quoted = true
            } else if ch == delim {
                flush()
            } else if ch == 13 || ch == 10 {
                if ch == 13 && i + 1 < chars.count && chars[i + 1] == 10 { i += 1 }
                flush()
                rows.append(row)
                row.removeAll(keepingCapacity: true)
            } else {
                field.append(ch)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            flush()
            rows.append(row)
        }
        return rows
    }
    static func detectDelimiter(_ text: String) -> Character {
        let delimiters: [UInt16] = [44, 59, 9]
        var counts = [0, 0, 0]
        var quoted = false
        for ch in text.utf16.prefix(4096) {
            if ch == 34 { quoted.toggle() } else if !quoted, let i = delimiters.firstIndex(of: ch) { counts[i] += 1 }
        }
        return [Character(","), ";", tab][
            counts.indices.max(by: { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 > $1) }) ?? 0]
    }
    private static func quote(_ value: String, _ delimiter: Character) -> String {
        value.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    static func isNumber(_ value: String) -> Bool {
        let v = Array(value.utf16)
        return !v.isEmpty && v.count < 20 && !(v.count > 1 && v[0] == 48 && v[1] != 46)
            && !(v.count > 2 && v[0] == 45 && v[1] == 48 && v[2] != 46)
            && Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
    static func displayWidth(_ text: String) -> Double {
        text.components(separatedBy: "\n").map { line in
            line.utf16.reduce(0.0) { width, c in
                width
                    + (c >= 0x1100
                        && (c <= 0x115f || (0x2e80...0xa4cf).contains(c) || (0xac00...0xd7a3).contains(c)
                            || (0xf900...0xfaff).contains(c) || (0xff00...0xff60).contains(c))
                        ? 2 : 1)
            }
        }.max() ?? 0
    }
}

// Number and XML output shared only by the Office port; never use the user's locale.
enum SheetXML {
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    static func escape(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) }).replacingOccurrences(
            of: "&", with: "&amp;"
        ).replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(
            of: "\"", with: "&quot;"
        ).replacingOccurrences(of: "'", with: "&apos;")
    }
    static func number(_ value: Double) -> String {
        if value == 0 { return value.sign == .minus ? "-0" : "0" }
        var text = String(value)
        if let e = text.firstIndex(of: "e") {
            var mantissa = String(text[..<e])
            if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
            let exponent = Int(text[text.index(after: e)...]) ?? 0
            if exponent >= -4 && exponent < 17 {
                let negative = mantissa.hasPrefix("-")
                let digits = mantissa.filter { $0.isNumber }
                let pos = exponent + 1
                let sign = negative ? "-" : ""
                if pos <= 0 { return sign + "0." + String(repeating: "0", count: -pos) + digits }
                if pos >= digits.count { return sign + digits + String(repeating: "0", count: pos - digits.count) }
                return sign + String(digits.prefix(pos)) + "." + String(digits.dropFirst(pos))
            }
            return mantissa + "E" + (exponent >= 0 ? "+" : "-") + String(format: "%02d", abs(exponent))
        }
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }
    static func decimal(_ value: Double, _ places: Int = 3) -> String {
        var text = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
    static func double(_ text: String?) -> Double? {
        text.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    static func int(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}
