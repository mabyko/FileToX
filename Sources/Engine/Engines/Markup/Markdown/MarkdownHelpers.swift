// Scanners shared by the parsers: link destinations, titles and labels, autolinks, raw HTML tags, entities and
// heading identifiers (Markdig's LinkHelper, HtmlHelper, EntityHelper and CharNormalizer).

import Foundation

extension Markdown {
    /// Something characters are read from: a slice, or the lines of a paragraph (`ICharIterator`).
    protocol CharIterator {
        var start: Int { get }
        var end: Int { get }
        var currentChar: Char { get }
        var isEmpty: Bool { get }
        @discardableResult mutating func nextChar() -> Char
        mutating func skipChar()
        func peekChar() -> Char
        func peekChar(_ offset: Int) -> Char
        @discardableResult mutating func trimStart() -> Bool
    }

    // MARK: Entities

    private static let entities: [String: String] = {
        var map: [String: String] = [:]
        for entry in entityData.split(separator: "\u{1}", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: "\u{2}", maxSplits: 1, omittingEmptySubsequences: false)
            map[String(parts[0])] = String(parts[1])
        }
        return map
    }()

    private static let asciiTransliterations: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        for entry in asciiData.split(separator: "\u{1}", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: "\u{2}", maxSplits: 1, omittingEmptySubsequences: false)
            if let unit = parts[0].utf16.first { map[unit] = String(parts[1]) }
        }
        return map
    }()

    enum EntityHelper {
        /// The text of a named character reference (without '&' and ';'), or nil.
        static func decodeEntity(_ name: String) -> String? { Markdown.entities[name] }

        /// The character of a numeric reference; 0 and invalid scalars give U+FFFD.
        static func decodeEntity(_ value: Int) -> String {
            guard value != 0, value >= 0, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value), let scalar = Unicode.Scalar(UInt32(value)) else {
                return "\u{FFFD}"
            }
            return String(Character(scalar))
        }
    }

    /// `CharNormalizer.ConvertToAscii`: an ASCII spelling of a letter with diacritics, or nil.
    static func convertToAscii(_ c: Char) -> String? {
        c.value >= 160 ? asciiTransliterations[c.value] : nil
    }

    // MARK: HTML helpers

    enum HtmlHelper {
        private static let escapeUrlsForAscii: [String?] = (0..<128).map { i in
            if i <= 32 || "\"'<>[\\]^`{|}~".unicodeScalars.contains(where: { $0.value == UInt32(i) }) || i == 127 {
                return String(format: "%%%02X", i)
            }
            return i == 0x26 ? "&amp;" : nil
        }

        static func escapeUrlCharacter(_ c: Char) -> String? { c.value < 128 ? escapeUrlsForAscii[Int(c.value)] : nil }

        static func tryParseHtmlTag(_ text: inout Slice) -> String? {
            var builder: [Char] = []
            return tryParseHtmlTag(&text, &builder) ? Markdown.string(builder) : nil
        }

        private static func tryParseHtmlTag(_ text: inout Slice, _ builder: inout [Char]) -> Bool {
            var c = text.currentChar
            if c != "<" { return false }
            c = text.nextChar()
            builder.append("<")
            switch c {
            case "/": return tryParseHtmlCloseTag(&text, &builder)
            case "?": return tryParseHtmlTagProcessingInstruction(&text, &builder)
            case "!":
                builder.append(c)
                c = text.nextChar()
                if c == "-" { return tryParseHtmlTagHtmlComment(&text, &builder) }
                if c == "[" { return tryParseHtmlTagCData(&text, &builder) }
                return tryParseHtmlTagDeclaration(&text, &builder)
            default:
                return tryParseHtmlTagOpenTag(&text, &builder)
            }
        }

        static func tryParseHtmlTagOpenTag(_ text: inout Slice, _ builder: inout [Char]) -> Bool {
            var c = text.currentChar
            if !c.isAlpha { return false }
            builder.append(c)
            while true {
                c = text.nextChar()
                if c.isAlphaNumeric || c == "-" { builder.append(c) } else { break }
            }
            var hasAttribute = false
            while true {
                var hasWhitespaces = false
                while c.isWhitespace {
                    builder.append(c)
                    c = text.nextChar()
                    hasWhitespaces = true
                }
                switch c {
                case .zero:
                    return false
                case ">":
                    text.skipChar()
                    builder.append(c)
                    return true
                case "/":
                    builder.append("/")
                    c = text.nextChar()
                    if c != ">" { return false }
                    text.skipChar()
                    builder.append(">")
                    return true
                case "=":
                    if !hasAttribute { return false }
                    builder.append("=")
                    c = text.nextChar()
                    while c.isWhitespace {
                        builder.append(c)
                        c = text.nextChar()
                    }
                    if c == "'" || c == "\"" {
                        builder.append(c)
                        let opening = c
                        while true {
                            c = text.nextChar()
                            if c == .zero { return false }
                            if c != opening { builder.append(c) } else { break }
                        }
                        builder.append(c)
                        c = text.nextChar()
                    } else {
                        var matchCount = 0
                        while true {
                            if c == .zero { return false }
                            if isSpaceOrSpecialHtmlChar(c) { break }
                            matchCount += 1
                            builder.append(c)
                            c = text.nextChar()
                        }
                        if matchCount == 0 { return false }
                    }
                    hasAttribute = false
                    continue
                default:
                    if !hasWhitespaces { return false }
                    if !(c.isAlpha || c == "_" || c == ":") { return false }
                    builder.append(c)
                    while true {
                        c = text.nextChar()
                        if c.isAlphaNumeric || c == "_" || c == ":" || c == "." || c == "-" { builder.append(c) } else { break }
                    }
                    hasAttribute = true
                }
            }
        }

        private static func isSpaceOrSpecialHtmlChar(_ c: Char) -> Bool {
            switch c {
            case " ", "\n", "\"", "'", "=", "<", ">", "`": true
            default: false
            }
        }

        private static func tryParseHtmlTagDeclaration(_ text: inout Slice, _ builder: inout [Char]) -> Bool {
            var c = text.currentChar
            var hasAlpha = false
            while c.isAlphaUpper {
                builder.append(c)
                c = text.nextChar()
                hasAlpha = true
            }
            if !hasAlpha || !c.isWhitespace { return false }
            while true {
                builder.append(c)
                c = text.nextChar()
                if c == .zero { return false }
                if c == ">" {
                    text.skipChar()
                    builder.append(">")
                    return true
                }
            }
        }

        private static func tryParseHtmlTagCData(_ text: inout Slice, _ builder: inout [Char]) -> Bool {
            guard text.match("[CDATA[") else { return false }
            builder += Markdown.chars("[CDATA[")
            text.start += 6
            var c = Char.zero
            while true {
                let previous = c
                c = text.nextChar()
                if c == .zero { return false }
                builder.append(c)
                if c == "]" && previous == "]" && text.peekChar() == ">" {
                    text.skipChar()
                    text.skipChar()
                    builder.append(">")
                    return true
                }
            }
        }

        static func tryParseHtmlCloseTag(_ text: inout Slice, _ builder: inout [Char]) -> Bool {
            builder.append("/")
            var c = text.nextChar()
            if !c.isAlpha { return false }
            builder.append(c)
            var skipSpaces = false
            while true {
                c = text.nextChar()
                if c == ">" {
                    text.skipChar()
                    builder.append(">")
                    return true
                }
                if skipSpaces {
                    if c != " " { break }
                } else if c == " " {
                    skipSpaces = true
                } else if !(c.isAlphaNumeric || c == "-") {
                    break
                }
                builder.append(c)
            }
            return false
        }

        private static func tryParseHtmlTagHtmlComment(_ text: inout Slice, _ builder: inout [Char]) -> Bool {
            var c = text.nextChar()
            if c != "-" { return false }
            c = text.nextChar()
            if c == ">" {
                builder += Markdown.chars("-->")
                text.skipChar()
                return true
            }
            if c == "-" && text.peekChar() == ">" {
                builder += Markdown.chars("--->")
                text.skipChar()
                text.skipChar()
                return true
            }
            let index = text.indexOf("-->")
            if index < 0 { return false }
            builder += Markdown.chars("--")
            let length = index - text.start + 3
            builder += text.text[text.start..<text.start + length]
            text.start += length
            return true
        }

        private static func tryParseHtmlTagProcessingInstruction(_ text: inout Slice, _ builder: inout [Char]) -> Bool {
            builder.append("?")
            var previous = Char.zero
            while true {
                let c = text.nextChar()
                if c == .zero { return false }
                if c == ">" && previous == "?" {
                    builder.append(">")
                    text.skipChar()
                    return true
                }
                previous = c
                builder.append(c)
            }
        }

        /// Removes backslash escapes (when asked) and decodes entities.
        static func unescape(_ text: String?, removeBackSlash: Bool = true) -> String {
            guard let text, !text.isEmpty else { return "" }
            let chars = Markdown.chars(text)
            var searchPos = 0
            var lastPos = 0
            var c = Char.zero
            var result: [Char] = []
            while let found = chars[searchPos...].firstIndex(where: { ($0 == "\\" && removeBackSlash) || $0 == "&" }) {
                searchPos = found
                c = chars[searchPos]
                if removeBackSlash && c == "\\" {
                    searchPos += 1
                    if chars.count == searchPos { break }
                    c = chars[searchPos]
                    if c.isEscapableSymbol {
                        result += chars[lastPos..<(searchPos - 1)]
                        lastPos = searchPos
                    }
                } else if c == "&" {
                    let scan = scanEntity(Slice(chars, searchPos, chars.count - 1))
                    if scan.match == 0 {
                        searchPos += 1
                    } else {
                        searchPos += scan.match
                        if scan.nameLength > 0 {
                            if let decoded = EntityHelper.decodeEntity(Markdown.string(chars[scan.nameStart..<(scan.nameStart + scan.nameLength)])) {
                                result += chars[lastPos..<(searchPos - scan.match)]
                                result += Markdown.chars(decoded)
                                lastPos = searchPos
                            }
                        } else if scan.numeric >= 0 {
                            result += chars[lastPos..<(searchPos - scan.match)]
                            result += Markdown.chars(EntityHelper.decodeEntity(scan.numeric))
                            lastPos = searchPos
                        }
                    }
                }
                if searchPos >= chars.count { break }
            }
            if c == .zero { return text }
            result += chars[lastPos...]
            return Markdown.string(result)
        }

        /// Scans "&name;", "&#123;" or "&#x1F;" at the iterator: the matched length (0 = none), the numeric value or
        /// the position and length of the name.
        static func scanEntity<T: CharIterator>(_ iterator: T) -> (match: Int, numeric: Int, nameStart: Int, nameLength: Int) {
            var slice = iterator
            var numeric = 0
            var nameStart = 0
            var nameLength = 0
            if slice.currentChar != "&" || slice.peekChar(3) == .zero { return (0, numeric, nameStart, nameLength) }
            let start = slice.start
            var c = slice.nextChar()
            var counter = 0
            if c == "#" {
                c = slice.peekChar()
                if c.value | 0x20 == 0x78 { // x
                    c = slice.nextChar()
                    while c != .zero {
                        c = slice.nextChar()
                        if c.isDigit {
                            counter += 1
                            if counter == 7 { return (0, numeric, nameStart, nameLength) }
                            numeric = numeric * 16 + (c.int - 0x30)
                            continue
                        } else if (c.value | 0x20) >= 0x61 && (c.value | 0x20) <= 0x66 && c.isAlpha {
                            counter += 1
                            if counter == 7 { return (0, numeric, nameStart, nameLength) }
                            numeric = numeric * 16 + (Int(c.value | 0x20) - 0x61 + 10)
                            continue
                        }
                        if c == ";" { return (counter == 0 ? 0 : slice.start - start + 1, numeric, nameStart, nameLength) }
                        return (0, numeric, nameStart, nameLength)
                    }
                } else {
                    while c != .zero {
                        c = slice.nextChar()
                        if c.isDigit {
                            counter += 1
                            if counter == 8 { return (0, numeric, nameStart, nameLength) }
                            numeric = numeric * 10 + (c.int - 0x30)
                            continue
                        }
                        if c == ";" { return (counter == 0 ? 0 : slice.start - start + 1, numeric, nameStart, nameLength) }
                        return (0, numeric, nameStart, nameLength)
                    }
                }
            } else {
                if !c.isAlpha { return (0, numeric, nameStart, nameLength) }
                nameStart = slice.start
                nameLength += 1
                while c != .zero {
                    c = slice.nextChar()
                    if c.isAlphaNumeric {
                        counter += 1
                        if counter == 32 { return (0, numeric, nameStart, nameLength) }
                        nameLength += 1
                        continue
                    }
                    if c == ";" { return (counter == 0 ? 0 : slice.start - start + 1, numeric, nameStart, nameLength) }
                    return (0, numeric, nameStart, nameLength)
                }
            }
            return (0, numeric, nameStart, nameLength)
        }
    }

    // MARK: Links

    /// A parsed link reference definition.
    struct ParsedDefinition {
        var label: String
        var url: String
        var title: String?
        var labelSpan: SourceSpan
        var urlSpan: SourceSpan
        var titleSpan: SourceSpan
    }

    enum LinkHelper {
        /// `<scheme:...>` or `<user@domain>` at the slice.
        static func tryParseAutolink(_ text: inout Slice) -> (link: String, isEmail: Bool)? {
            var c = text.currentChar
            if c != "<" { return nil }
            c = text.nextChar()
            var state = 0
            if !c.isAlpha {
                if Markdown.isEmailUsernameSpecialCharOrDigit(c) { state = -1 } else { return nil }
            }
            var builder: [Char] = [c]
            while true {
                c = text.nextChar()
                let isSpecialChar = c == "+" || c == "." || c == "-"
                var isValidChar = c.isAlphaNumeric || isSpecialChar
                if state <= 0 && Markdown.isEmailUsernameSpecialChar(c) {
                    isValidChar = true
                    if !isSpecialChar { state = -1 }
                }
                if isValidChar {
                    if state > 0 && builder.count >= 32 { return nil }
                    builder.append(c)
                } else if c == ":" {
                    if state < 0 || builder.count <= 2 { return nil }
                    state = 1
                    break
                } else if c == "@" {
                    if state > 0 { return nil }
                    state = -1
                    break
                } else {
                    return nil
                }
            }
            builder.append(c)
            if state < 0 {
                var hasMinus = false
                var domainCharCount = 0
                var previous = Char.zero
                while true {
                    c = text.nextChar()
                    if c == ">" {
                        if domainCharCount == 0 || hasMinus { break }
                        text.skipChar()
                        return (Markdown.string(builder), true)
                    }
                    var accepted = false
                    if c.isAlphaNumeric {
                        accepted = true
                    } else if domainCharCount > 0 {
                        hasMinus = c == "-"
                        accepted = hasMinus
                    }
                    if accepted {
                        domainCharCount += 1
                        if domainCharCount > 63 { break }
                    } else if c == "." {
                        if previous == "." || previous == "-" { break }
                        domainCharCount = 0
                        hasMinus = false
                    } else {
                        break
                    }
                    builder.append(c)
                    previous = c
                }
            } else {
                text.skipChar()
                var index = text.start
                while index <= text.end && !Markdown.isInvalidAutoLinkCharacter(text.text[index]) { index += 1 }
                if index <= text.end && text.text[index] == ">" {
                    builder += text.text[text.start..<index]
                    text.start = index + 1
                    return (Markdown.string(builder), false)
                }
            }
            return nil
        }

        /// `(destination "title")` after a link text.
        static func tryParseInlineLink(_ text: inout Slice) -> (link: String?, title: String?, linkSpan: SourceSpan, titleSpan: SourceSpan)? {
            var isValid = false
            var c = text.currentChar
            var link: String?
            var title: String?
            var linkSpan = SourceSpan.empty
            var titleSpan = SourceSpan.empty
            if c == "(" {
                text.skipChar()
                text.trimStart()
                var position = text.start
                if let url = tryParseUrl(&text) {
                    link = url.link
                    linkSpan = SourceSpan(position, text.start - 1)
                    if linkSpan.end < linkSpan.start { linkSpan = .empty }
                    let spaceCount = text.trimStartCounting()
                    let hasWhiteSpaces = spaceCount > 0
                    c = text.currentChar
                    if c == ")" {
                        isValid = true
                    } else if hasWhiteSpaces {
                        c = text.currentChar
                        position = text.start
                        if c == ")" {
                            isValid = true
                        } else if let parsedTitle = tryParseTitle(&text) {
                            title = parsedTitle.title
                            titleSpan = SourceSpan(position, text.start - 1)
                            if titleSpan.end < titleSpan.start { titleSpan = .empty }
                            text.trimStart()
                            c = text.currentChar
                            if c == ")" { isValid = true }
                        }
                    }
                }
            }
            if isValid {
                text.skipChar()
                return (link, title, linkSpan, titleSpan)
            }
            return nil
        }

        static func tryParseTitle<T: CharIterator>(_ text: inout T) -> (title: String, enclosing: Char)? {
            var buffer: [Char] = []
            var c = text.currentChar
            if c == "'" || c == "\"" || c == "(" {
                let enclosing = c
                let closingQuote: Char = c == "(" ? ")" : c
                var hasEscape = false
                var isLineBlank = false
                while true {
                    c = text.nextChar()
                    if c == .zero { break }
                    if c == "\r" || c == "\n" {
                        if isLineBlank { break }
                        if hasEscape {
                            hasEscape = false
                            buffer.append("\\")
                        }
                        buffer.append(c)
                        if c == "\r" && text.peekChar() == "\n" {
                            buffer.append("\n")
                            text.skipChar()
                        }
                        isLineBlank = true
                    } else if hasEscape {
                        hasEscape = false
                        if !c.isAsciiPunctuation { buffer.append("\\") }
                        buffer.append(c)
                    } else if c == closingQuote {
                        text.skipChar()
                        return (Markdown.string(buffer), enclosing)
                    } else if c == "\\" {
                        hasEscape = true
                        isLineBlank = false
                    } else {
                        if isLineBlank && !c.isSpaceOrTab { isLineBlank = false }
                        buffer.append(c)
                    }
                }
            }
            return nil
        }

        static func tryParseUrl<T: CharIterator>(_ text: inout T, isAutoLink: Bool = false) -> (link: String, hasPointyBrackets: Bool)? {
            var isValid = false
            var hasPointyBrackets = false
            var buffer: [Char] = []
            var c = text.currentChar
            if c == "<" {
                var hasEscape = false
                repeat {
                    c = text.nextChar()
                    if !hasEscape && c == ">" {
                        text.skipChar()
                        hasPointyBrackets = true
                        isValid = true
                        break
                    }
                    if !hasEscape && c == "<" { break }
                    if hasEscape {
                        hasEscape = false
                        if !c.isAsciiPunctuation { buffer.append("\\") }
                    } else if c == "\\" {
                        hasEscape = true
                        continue
                    }
                    if c.isNewLine { break }
                    buffer.append(c)
                } while c != .zero
            } else {
                var hasEscape = false
                var openedParent = 0
                while true {
                    if c == "(" && !hasEscape { openedParent += 1 }
                    if c == ")" && !hasEscape {
                        openedParent -= 1
                        if openedParent < 0 {
                            isValid = true
                            break
                        }
                    }
                    if !isAutoLink {
                        if hasEscape {
                            hasEscape = false
                            if !c.isAsciiPunctuation { buffer.append("\\") }
                        } else if c == "\\" {
                            hasEscape = true
                            c = text.nextChar()
                            continue
                        }
                    }
                    if isEndOfUri(c, isAutoLink) {
                        isValid = true
                        break
                    }
                    if isAutoLink {
                        if c == "&" && HtmlHelper.scanEntity(text).match > 0 {
                            isValid = true
                            break
                        }
                        if isTrailingUrlStopCharacter(c) && isEndOfUri(text.peekChar(), true) {
                            isValid = true
                            break
                        }
                    }
                    buffer.append(c)
                    c = text.nextChar()
                }
                if openedParent > 0 { isValid = false }
            }
            return isValid ? (Markdown.string(buffer), hasPointyBrackets) : nil
        }

        private static func isTrailingUrlStopCharacter(_ c: Char) -> Bool {
            c == "?" || c == "!" || c == "." || c == "," || c == ":" || c == "*" || c == "_" || c == "~"
        }

        private static func isEndOfUri(_ c: Char, _ isAutoLink: Bool) -> Bool {
            c == .zero || c.isSpaceOrTab || c.isControl || (isAutoLink && c == "<")
        }

        /// GitHub's extended autolink domain rule (letters, digits, '_', '-', '.'; non-ASCII allowed unless space or
        /// punctuation; a dot required and no '_' in the last two segments).
        static func isValidDomain(_ link: String, _ prefixLength: Int, allowDomainWithoutPeriod: Bool = false) -> Bool {
            let chars = Markdown.chars(link)
            var segmentCount = 1
            var segmentHasCharacters = false
            var lastUnderscoreSegment = -1
            var i = prefixLength
            while i >= 0 && i < chars.count {
                let c = chars[i]
                if !c.isAlphaNumeric {
                    if c == "." {
                        if !segmentHasCharacters { return false }
                        segmentCount += 1
                        segmentHasCharacters = false
                        i += 1
                        continue
                    }
                    if c == "/" || c == "?" || c == "#" || c == ":" { break }
                    if c == "_" {
                        lastUnderscoreSegment = segmentCount
                    } else if c != "-" && Markdown.isSpaceOrPunctuationForGFMAutoLink(c) {
                        return false
                    }
                }
                segmentHasCharacters = true
                i += 1
            }
            return (segmentCount != 1 || allowDomainWithoutPeriod) && segmentHasCharacters && segmentCount - lastUnderscoreSegment >= 2
        }

        static func tryParseLinkReferenceDefinition<T: CharIterator>(_ text: inout T) -> ParsedDefinition? {
            guard let label = tryParseLabel(&text) else { return nil }
            if text.currentChar != ":" { return nil }
            text.skipChar()
            text.trimStart()
            var urlSpan = SourceSpan.empty
            var titleSpan = SourceSpan.empty
            urlSpan.start = text.start
            let isAngleBracketsUrl = text.currentChar == "<"
            guard let url = tryParseUrl(&text)?.link, isAngleBracketsUrl || !url.isEmpty else { return nil }
            urlSpan.end = text.start - 1
            let saved = text
            let (hasWhiteSpaces, newLineCount) = trimStartAndCountNewLines(&text)
            var c = text.currentChar
            var title: String?
            if c == "'" || c == "\"" || c == "(" {
                titleSpan.start = text.start
                guard let parsed = tryParseTitle(&text) else { return nil }
                title = parsed.title
                titleSpan.end = text.start - 1
                if !hasWhiteSpaces { return nil }
            } else if text.isEmpty || newLineCount > 0 {
                return ParsedDefinition(label: label.label, url: url, title: nil, labelSpan: label.span, urlSpan: urlSpan, titleSpan: titleSpan)
            }
            c = text.currentChar
            while c.isSpaceOrTab { c = text.nextChar() }
            if c != .zero && c != "\n" && c != "\r" {
                if newLineCount > 0 && title != nil {
                    text = saved
                    return ParsedDefinition(label: label.label, url: url, title: nil, labelSpan: label.span, urlSpan: urlSpan, titleSpan: titleSpan)
                }
                return nil
            }
            if c == "\r" && text.peekChar() == "\n" { text.skipChar() }
            return ParsedDefinition(label: label.label, url: url, title: title, labelSpan: label.span, urlSpan: urlSpan, titleSpan: titleSpan)
        }

        /// Skips whitespace; returns whether there was any and how many line endings it had.
        static func trimStartAndCountNewLines<T: CharIterator>(_ iterator: inout T) -> (Bool, Int) {
            var count = 0
            var c = iterator.currentChar
            var hasWhitespaces = false
            while c.isWhitespace {
                if c == "\n" || c == "\r" {
                    if c == "\r" && iterator.peekChar() == "\n" { iterator.skipChar() }
                    count += 1
                }
                hasWhitespaces = true
                c = iterator.nextChar()
            }
            return (hasWhitespaces, count)
        }

        /// A link label `[...]`: whitespace runs collapse to one space, escapes stay; at most 999 characters.
        static func tryParseLabel<T: CharIterator>(_ lines: inout T, allowEmpty: Bool = false) -> (label: String, span: SourceSpan)? {
            var c = lines.currentChar
            if c != "[" { return nil }
            var buffer: [Char] = []
            var startLabel = -1
            var endLabel = -1
            var hasEscape = false
            var previousWhitespace = true
            var hasNonWhiteSpace = false
            while true {
                c = lines.nextChar()
                if c == .zero { break }
                if hasEscape {
                    if c != "[" && c != "]" && c != "\\" { break }
                } else {
                    if c == "[" { break }
                    if c == "]" {
                        lines.skipChar()
                        if allowEmpty || hasNonWhiteSpace {
                            var i = buffer.count - 1
                            while i >= 0 {
                                if !buffer[i].isWhitespace { break }
                                buffer.removeLast(buffer.count - i)
                                endLabel -= 1
                                i -= 1
                            }
                            if buffer.count <= 999 {
                                var span = SourceSpan(startLabel, endLabel)
                                if span.start > span.end { span = .empty }
                                return (Markdown.string(buffer), span)
                            }
                        }
                        break
                    }
                }
                let isWhitespace = c.isWhitespace
                if isWhitespace { c = " " }
                if !hasEscape && c == "\\" {
                    if startLabel < 0 { startLabel = lines.start }
                    hasEscape = true
                } else {
                    hasEscape = false
                    if !previousWhitespace || !isWhitespace {
                        if startLabel < 0 { startLabel = lines.start }
                        endLabel = lines.start
                        buffer.append(c)
                        if !isWhitespace { hasNonWhiteSpace = true }
                    }
                }
                previousWhitespace = isWhitespace
            }
            return nil
        }

        /// A heading identifier from its text (`Urilize`): lower-case letters and digits, spaces as '-', and with
        /// `allowOnlyAscii` diacritics removed and letters transliterated.
        static func urilize(_ headingText: String, allowOnlyAscii: Bool, keepOpeningDigits: Bool = false) -> String {
            let original = Markdown.chars(headingText)
            var buffer: [Char] = []
            var hasLetter = keepOpeningDigits && !original.isEmpty && original[0].isLetterOrDigit
            var previousIsSpace = false
            // ASCII has no canonical decompositions (nor letters to spell out below).
            let decompose = allowOnlyAscii && !headingText.utf8.allSatisfy { $0 < 0x80 }
            let text = decompose ? Markdown.chars(headingText.decomposedStringWithCanonicalMapping) : original
            for var c in text {
                if allowOnlyAscii && c.category == .nonspacingMark { continue }
                var normalized: [Char] = []
                if allowOnlyAscii, c.value >= 0x80, let special = scandinavianOrGerman[c] {
                    normalized = Markdown.chars(special)
                } else if allowOnlyAscii, let ascii = Markdown.convertToAscii(c) {
                    normalized = Markdown.chars(ascii)
                }
                for j in 0..<max(1, normalized.count) {
                    if !normalized.isEmpty { c = normalized[j] }
                    if c.isLetter {
                        if allowOnlyAscii && (c.value < 0x20 || c.value >= 127) { continue }
                        c = c.category == .uppercaseLetter ? c.lowerInvariant : c
                        buffer.append(c)
                        hasLetter = true
                        previousIsSpace = false
                    } else if hasLetter {
                        if isReservedPunctuation(c) {
                            if previousIsSpace { buffer.removeLast() }
                            if buffer.last != c { buffer.append(c) }
                            previousIsSpace = false
                        } else if c.isDigit {
                            buffer.append(c)
                            previousIsSpace = false
                        } else if !previousIsSpace && c.isWhitespace {
                            if let last = buffer.last, !isReservedPunctuation(last) { buffer.append("-") }
                            previousIsSpace = true
                        }
                    }
                }
            }
            while let last = buffer.last, isReservedPunctuation(last) { buffer.removeLast() }
            return Markdown.string(buffer)
        }

        static func urilizeAsGfm(_ headingText: String) -> String {
            var buffer: [Char] = []
            for c in Markdown.chars(headingText) {
                if c.isLetterOrDigit || c == "-" || c == "_" { buffer.append(c.lowerInvariant) } else if c == " " { buffer.append("-") }
            }
            return Markdown.string(buffer)
        }

        private static func isReservedPunctuation(_ c: Char) -> Bool { c == "_" || c == "-" || c == "." }

        private static let scandinavianOrGerman: [Char: String] = [
            "\u{E4}": "ae", "\u{F6}": "oe", "\u{FC}": "ue", "\u{C4}": "Ae", "\u{D6}": "Oe", "\u{DC}": "Ue", "\u{DF}": "ss",
            "\u{E6}": "ae", "\u{F8}": "oe", "\u{E5}": "aa", "\u{C6}": "Ae", "\u{D8}": "Oe", "\u{C5}": "Aa",
            "\u{FE}": "th", "\u{DE}": "Th", "\u{F0}": "d", "\u{D0}": "D",
        ]
    }
}

extension Markdown.Slice: Markdown.CharIterator {}
extension Markdown.LineGroup.Iterator: Markdown.CharIterator {}
