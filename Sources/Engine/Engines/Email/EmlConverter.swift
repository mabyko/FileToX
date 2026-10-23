// Port of Filee.Engines/Email/EmlConverter.cs: e-mail messages (.eml, RFC 5322 / MIME) as a web page (the headers and
// the HTML body, or the plain text; pictures sent inline with "cid:" links become data URIs), as plain text, or their
// attachments as a ZIP. The MIME parsing that MimeKitLite did is ported in EmlMessage / EmlMime / EmlCharsets:
// transfer encodings (quoted-printable, base64), encoded headers (RFC 2047 / 2231) and charsets, including the Korean
// ones (EUC-KR / CP949, ISO-2022-KR); header text in raw 8-bit that is not UTF-8 is read as CP949, as older Korean mail
// programs wrote it.

import Foundation

/// EML → HTML, TXT and ZIP (attachments).
final class EmlConverter: Converter {
    let id = "email"
    let displayName = "E-mail (built-in)"
    let maxParallelism = 0
    let edges = [ConversionEdge("eml", "html"), ConversionEdge("eml", "txt"), ConversionEdge("eml", "zip")]

    init() {}

    func status() -> EngineStatus {
        .available(detail: "EML → HTML, TXT, ZIP (attachments)", version: EngineVersions.builtIn)
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        try await Self.onLargeStack { checkCancellation in
            progress?(0.1)
            let message = try Self.load(step.inputPath)
            progress?(0.5)
            if step.to == "zip" {
                let attachments = Self.attachments(message)
                if attachments.isEmpty { throw ConversionError("The e-mail has no attachments.") }
                guard let zip = try step.output.allocate("zip") else { return [] }
                try Self.writeZip(attachments, zip, checkCancellation)
                progress?(1)
                return [zip]
            }

            guard let output = try step.output.allocate(step.to) else { return [] }
            let text = step.to == "html" ? Self.html(message) : Self.plainText(message)
            try ((step.to == "txt" ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)).write(to: URL(fileURLWithPath: output))
            progress?(1)
            return [output]
        }
    }

    /// Parses a message; 8-bit header text that is not UTF-8 is read as CP949 (Korean).
    static func load(_ path: String) throws -> EmlMessage {
        try EmlMessage.parse([UInt8](Data(contentsOf: URL(fileURLWithPath: path))))
    }

    /// Runs the work on a thread with a 16 MB stack (MIME trees nest up to 1024 levels) and checks for cancellation
    /// where Filee checked its token.
    private static func onLargeStack<T>(_ work: @escaping (_ checkCancellation: () throws -> Void) throws -> T) async throws -> T {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    continuation.resume(with: Result { try work { if cancelled.isSet { throw CancellationError() } } })
                }
                thread.stackSize = 16 << 20
                thread.start()
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: Headers

    /// The headers shown above the body: name and value, only those the message has.
    static func headers(_ message: EmlMessage) -> [(name: String, value: String)] {
        var headers: [(String, String)] = []
        func add(_ name: String, _ value: String?) {
            guard let value, !value.utf16.allSatisfy(EmlMime.isDotNetWhiteSpace) else { return }
            headers.append((name, EmlMime.trim(value)))
        }
        add("From", addresses(message.mailboxes("From")))
        add("To", addresses(message.mailboxes("To")))
        add("Cc", addresses(message.mailboxes("Cc")))
        if message.hasDate { add("Date", message.date.formatted) }
        add("Subject", message.subject)
        let attachments = attachments(message).map(\.name)
        if !attachments.isEmpty { add("Attachments", attachments.joined(separator: ", ")) }
        return headers
    }

    private static func addresses(_ list: [EmlMime.Mailbox]) -> String {
        list.map { $0.name.utf16.allSatisfy(EmlMime.isDotNetWhiteSpace) ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: ", ")
    }

    // MARK: HTML

    /// A standalone web page: the headers in a table, then the HTML body (or the text body, escaped).
    static func html(_ message: EmlMessage) -> String {
        var styles = ""
        let body: String
        if let original = message.htmlBody {
            let html = removeScripts(inlinePictures(original, message))
            // Keep the style sheets of the message's own <head>, and the content of its <body>.
            for match in matches(styleBlock, html) { styles += match.text(0) }
            if let match = matches(bodyContent, html).first {
                body = match.text(1)
            } else {
                body = replace(headBlock, html, "")
            }
        } else {
            body = "<pre class=\"filee-mail-text\">\(htmlEncode(message.textBody ?? ""))</pre>"
        }

        var page = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
        page += "<title>\(htmlEncode(message.subject ?? ""))</title>\n"
        page += "<style>\n.filee-mail-headers { border-collapse: collapse; margin: 0 0 12px 0; font-family: sans-serif; font-size: 14px; }\n"
        page += ".filee-mail-headers th { text-align: left; vertical-align: top; padding: 2px 16px 2px 0; color: #555; font-weight: 600; }\n"
        page += ".filee-mail-headers td { padding: 2px 0; }\n"
        page += ".filee-mail-text { white-space: pre-wrap; font-family: inherit; }\n</style>\n"
        page += styles
        page += "</head>\n<body>\n<table class=\"filee-mail-headers\">\n"
        for (name, value) in headers(message) { page += "<tr><th>\(name)</th><td>\(htmlEncode(value))</td></tr>\n" }
        page += "</table>\n<hr>\n"
        page += body
        page += "\n</body>\n</html>\n"
        return page
    }

    /// "cid:" references → data URIs of the parts with that Content-ID, so the page needs no other files.
    private static func inlinePictures(_ html: String, _ message: EmlMessage) -> String {
        var parts: [String: EmlPart] = [:]
        for case let part as EmlPart in message.bodyParts {
            guard let id = part.contentId, !id.isEmpty else { continue }
            let key = ignoreCaseKey(id.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
            if parts[key] == nil { parts[key] = part }
        }
        if parts.isEmpty { return html }
        let found = matches(contentIdReference, html)
        guard !found.isEmpty else { return html }
        let text = html as NSString
        var result = ""
        var position = 0
        for match in found {
            let range = match.result.range
            result += text.substring(with: NSRange(location: position, length: range.location - position))
            position = range.location + range.length
            let id = unescapeDataString(match.text(1))
            guard let part = parts[ignoreCaseKey(id)], part.content != nil else {
                result += match.text(0)
                continue
            }
            result += "data:\(part.contentType.mimeType);base64,\(Data(part.decodedContent()).base64EncodedString())"
        }
        return result + text.substring(from: position)
    }

    /// A converted page is opened in a browser: scripts of the message are not carried over.
    private static func removeScripts(_ html: String) -> String { replace(scriptBlock, html, "") }

    // MARK: Text

    /// The headers, an empty line and the text body (or the HTML body as text).
    static func plainText(_ message: EmlMessage) -> String {
        var text = ""
        for (name, value) in headers(message) { text += name + ": " + value + "\r\n" }
        text += "\r\n"
        let body = message.textBody ?? message.htmlBody.map(htmlToText) ?? ""
        text += trimEnd(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")) + "\r\n"
        return text
    }

    /// Rough text of an HTML body: blocks and line breaks become new lines, tags go, entities are decoded.
    static func htmlToText(_ html: String) -> String {
        var text = replace(scriptBlock, html, "")
        text = replace(styleBlock, text, "")
        text = replace(headBlock, text, "")
        text = replace(lineBreakTag, text, "\n")
        text = replace(blockEndTag, text, "\n")
        text = replace(anyTag, text, "")
        text = htmlDecode(text).replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { EmlMime.trim(replace(spaceRun, $0, " ")) }
        return EmlMime.trim(replace(multipleBlankLines, lines.joined(separator: "\n"), "\n\n"))
    }

    // MARK: Attachments

    /// Attached files and messages with a unique, safe file name each.
    static func attachments(_ message: EmlMessage) -> [(name: String, entity: EmlEntity)] {
        var result: [(String, EmlEntity)] = []
        var names = Set<String>()
        for entity in message.bodyParts {
            var name: String?
            if let attached = entity as? EmlMessagePart {
                name = (attached.contentDisposition?.fileName ?? attached.message?.subject ?? "message") + ".eml"
            } else if let part = entity as? EmlPart, part.isAttachment || (!(part.fileName ?? "").isEmpty && part.contentId == nil) {
                name = part.fileName ?? "attachment" + (EmlTables.extensions[part.contentType.mimeType.lowercased()] ?? ".bin")
            }
            guard let found = name else { continue }
            let safe = safeName(found)
            var unique = safe
            var i = 2
            while !names.insert(ignoreCaseKey(unique)).inserted {
                unique = "\(FilePath.fileNameWithoutExtension(safe)) (\(i))\(FilePath.extension(safe))"
                i += 1
            }
            result.append((unique, entity))
        }
        return result
    }

    private static func writeZip(_ attachments: [(name: String, entity: EmlEntity)], _ path: String, _ checkCancellation: () throws -> Void) throws {
        let temp = path + ".tmp"
        let zip = try ZipWriter(path: temp)
        for (name, entity) in attachments {
            try checkCancellation()
            var data: [UInt8] = []
            if let attached = (entity as? EmlMessagePart)?.message {
                attached.write(to: &data)
            } else if let part = entity as? EmlPart, part.content != nil {
                data = part.decodedContent()
            }
            try zip.add(name, data: Data(data), level: .optimal)
        }
        try zip.close()
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        try FileManager.default.moveItem(atPath: temp, toPath: path)
    }

    /// A file name without folders or characters Windows does not allow.
    private static func safeName(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
        var units = FilePath.fileName(last).utf16.map { unit -> UInt16 in
            unit == 0 || unit == 0x2F || unit < 0x20 || (unit >= 0x7F && unit <= 0x9F) ? 0x5F : unit
        }[...]
        while let first = units.first, first == 0x20 || first == 0x2E { units = units.dropFirst() }
        while let last = units.last, last == 0x20 || last == 0x2E { units = units.dropLast() }
        if units.isEmpty { return "attachment" }
        return String(decoding: units.count > 150 ? units.prefix(150) : units, as: UTF16.self)
    }

    // MARK: .NET text helpers

    /// A key for `StringComparer.OrdinalIgnoreCase` sets and dictionaries (simple upper-casing per character).
    private static func ignoreCaseKey(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let upper = scalar.properties.uppercaseMapping.unicodeScalars
            scalars.append(upper.count == 1 ? upper.first! : scalar)
        }
        return String(scalars)
    }

    /// `string.TrimEnd()`.
    private static func trimEnd(_ text: String) -> String {
        var units = Array(text.utf16)
        while let last = units.last, EmlMime.isDotNetWhiteSpace(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// `WebUtility.HtmlEncode`: < > " ' & as entities, U+00A0–U+00FF and characters outside the BMP as numeric ones.
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
                if (0xA0...0xFF).contains(scalar.value) || scalar.value > 0xFFFF {
                    result += "&#\(scalar.value);"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// `WebUtility.HtmlDecode`: numeric references and the HTML 4.01 entities; anything else stays as it is.
    static func htmlDecode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let units = Array(text.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let unit = units[i]
            if unit == 0x26, let end = units[(i + 1)...].firstIndex(where: { $0 == 0x3B || $0 == 0x26 }), units[end] == 0x3B {
                let entity = units[(i + 1)..<end]
                if entity.count > 1 && entity.first == 0x23 {
                    let digits = entity.dropFirst()
                    let value: UInt32?
                    if digits.first == 0x78 || digits.first == 0x58 {
                        value = hexValue(digits.dropFirst())
                    } else {
                        value = decimalValue(digits)
                    }
                    if let value, let scalar = Unicode.Scalar(value) {
                        output += Array(String(scalar).utf16)
                        i = end + 1
                        continue
                    }
                } else {
                    i = end + 1
                    if entity.count <= 8, entity.allSatisfy({ $0 <= 0xFF }),
                       let char = EmlTables.htmlEntities[String(decoding: entity, as: UTF16.self)] {
                        output.append(char)
                    } else {
                        output.append(0x26)
                        output += entity
                        output.append(0x3B)
                    }
                    continue
                }
            }
            output.append(unit)
            i += 1
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// `uint.TryParse(..., NumberStyles.AllowHexSpecifier)`: hex digits only.
    private static func hexValue(_ digits: ArraySlice<UInt16>) -> UInt32? {
        guard !digits.isEmpty, digits.allSatisfy({ $0 < 0x80 }) else { return nil }
        return UInt32(String(decoding: digits, as: UTF16.self), radix: 16)
    }

    /// `uint.TryParse(..., NumberStyles.Integer, InvariantCulture)`: optional white space around and sign ("-0" is 0).
    private static func decimalValue(_ digits: ArraySlice<UInt16>) -> UInt32? {
        var text = String(decoding: digits, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\t\n\u{0B}\u{0C}\r "))
        var negative = false
        if text.hasPrefix("+") || text.hasPrefix("-") {
            negative = text.hasPrefix("-")
            text.removeFirst()
        }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let value = UInt32(text) else { return nil }
        return negative && value != 0 ? nil : value
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

    // MARK: Patterns

    private static let ws = "\\t\\n\\x{0B}\\f\\r\\x{85}\\p{Z}" // .NET's \s

    private static let bodyContent = regex("<body[^>]*>(.*)</body>", ignoreCase: true, singleLine: true)
    private static let headBlock = regex("<head[^>]*>.*?</head>", ignoreCase: true, singleLine: true)
    private static let styleBlock = regex("<style[^>]*>.*?</style>", ignoreCase: true, singleLine: true)
    private static let scriptBlock = regex("<script[^>]*>.*?</script>", ignoreCase: true, singleLine: true)
    private static let contentIdReference = regex("cid:([^\"'\(ws))>]+)", ignoreCase: true)
    private static let lineBreakTag = regex("<br[\(ws)]*/?>", ignoreCase: true)
    private static let blockEndTag = regex("</(p|div|tr|li|h[1-6]|table|blockquote)>", ignoreCase: true)
    private static let anyTag = regex("<[^>]+>")
    private static let spaceRun = regex("[ \\t]+")
    private static let multipleBlankLines = regex("\\n{3,}")

    private static func regex(_ pattern: String, ignoreCase: Bool = false, singleLine: Bool = false) -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if singleLine { options.insert(.dotMatchesLineSeparators) }
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    private struct Match {
        let result: NSTextCheckingResult
        let source: NSString
        func text(_ group: Int) -> String {
            let range = result.range(at: group)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [Match] {
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { Match(result: $0, source: source) }
    }

    private static func replace(_ regex: NSRegularExpression, _ text: String, _ replacement: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
