// Text primitives of the Markdown parser: UTF-16 characters, slices of the source, line groups and the character
// classes CommonMark needs.
//
// The parser reproduces Markdig 1.4.0 (BSD-2-Clause, (c) Alexandre Mutel), the library Filee used, so that Markdown
// renders to the same HTML and document model; its algorithms are followed closely. Text is handled as UTF-16 code
// units like .NET strings, so columns, positions and Unicode categories (a surrogate half is neither a letter nor
// punctuation) behave as in Markdig.

import Foundation

/// Markdown parsing and rendering (Markdig-compatible). Entry points: `parse`, `toHtml`, `toPlainText`.
enum Markdown {}

extension Markdown {
    /// One UTF-16 code unit (.NET `char`).
    struct Char: Hashable, Comparable, ExpressibleByUnicodeScalarLiteral, CustomStringConvertible {
        var value: UInt16

        init(_ value: UInt16) { self.value = value }
        init(unicodeScalarLiteral scalar: Unicode.Scalar) { value = UInt16(truncatingIfNeeded: scalar.value) }

        static func < (a: Char, b: Char) -> Bool { a.value < b.value }
        static let zero = Char(0)
        static let replacement = Char(0xFFFD)

        var description: String { String(decoding: [value], as: UTF16.self) }
        var int: Int { Int(value) }

        // MARK: CommonMark character classes (CharHelper)

        /// Unicode whitespace for CommonMark: tab, line feed, form feed, carriage return, space and the Zs category.
        var isWhitespace: Bool {
            switch value {
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: true
            default: false
            }
        }

        var isWhitespaceOrZero: Bool { value == 0 || isWhitespace }
        var isSpace: Bool { value == 0x20 }
        var isTab: Bool { value == 0x09 }
        var isSpaceOrTab: Bool { value == 0x20 || value == 0x09 }
        var isNewLine: Bool { value == 0x0A || value == 0x0D }
        var isZero: Bool { value == 0 }
        var isDigit: Bool { value >= 0x30 && value <= 0x39 }
        var isAlpha: Bool { (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A) }
        var isAlphaUpper: Bool { value >= 0x41 && value <= 0x5A }
        var isAlphaNumeric: Bool { isAlpha || isDigit }
        var isHighSurrogate: Bool { value >= 0xD800 && value <= 0xDBFF }
        var isLowSurrogate: Bool { value >= 0xDC00 && value <= 0xDFFF }
        var isSurrogate: Bool { value >= 0xD800 && value <= 0xDFFF }

        var isAsciiPunctuation: Bool {
            switch value {
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: true
            default: false
            }
        }

        var isAsciiPunctuationOrZero: Bool { value == 0 || isAsciiPunctuation }
        /// `char.IsControl`: the Cc category.
        var isControl: Bool { value < 0x20 || (value >= 0x7F && value <= 0x9F) }
        /// Characters a backslash can escape (ASCII punctuation and, in Markdig, the bullet "•").
        var isEscapableSymbol: Bool { isAsciiPunctuation || value == 0x2022 }

        /// The Unicode general category like .NET's `CharUnicodeInfo.GetUnicodeCategory(char)`.
        var category: Unicode.GeneralCategory {
            Unicode.Scalar(UInt32(value))?.properties.generalCategory ?? .surrogate
        }

        /// `char.IsLetterOrDigit`.
        var isLetterOrDigit: Bool {
            switch category {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
            default: false
            }
        }

        var isLetter: Bool {
            switch category {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
            default: false
            }
        }

        /// `char.ToLowerInvariant` (simple case mapping).
        var lowerInvariant: Char {
            if value < 0x80 { return value >= 0x41 && value <= 0x5A ? Char(value + 32) : self }
            if value == 0x130 { return "i" }
            guard let scalar = Unicode.Scalar(UInt32(value)) else { return self }
            let mapped = scalar.properties.lowercaseMapping.unicodeScalars
            guard mapped.count == 1, let first = mapped.first, first.value <= 0xFFFF else { return self }
            return Char(UInt16(first.value))
        }

        /// `char.ToUpperInvariant` (simple case mapping).
        var upperInvariant: Char {
            if value < 0x80 { return value >= 0x61 && value <= 0x7A ? Char(value - 32) : self }
            guard let scalar = Unicode.Scalar(UInt32(value)) else { return self }
            let mapped = scalar.properties.uppercaseMapping.unicodeScalars
            guard mapped.count == 1, let first = mapped.first, first.value <= 0xFFFF else { return self }
            return Char(UInt16(first.value))
        }

        /// U+0000 becomes U+FFFD (CommonMark's insecure characters).
        var escapedInsecure: Char { value == 0 ? .replacement : self }
    }

    // MARK: Conversions

    static func chars(_ text: String) -> [Char] { text.utf16.map(Char.init) }
    static func chars(_ text: Substring) -> [Char] { text.utf16.map(Char.init) }

    static func string(_ chars: some Collection<Char>) -> String {
        String(decoding: chars.map(\.value), as: UTF16.self)
    }

    // MARK: Character helpers (CharHelper)

    static let tabSize = 4

    static func addTab(_ column: Int) -> Int { tabSize + (column & ~(tabSize - 1)) }
    static func isAcrossTab(_ column: Int) -> Bool { column & (tabSize - 1) != 0 }

    /// Space / punctuation of a character for emphasis flanking: '\0' (start or end of text) counts as both.
    static func unicodeCategory(of scalar: Unicode.Scalar) -> (space: Bool, punctuation: Bool) {
        let value = scalar.value
        if value <= 0xFFFF && Char(UInt16(value)).isWhitespace { return (true, false) }
        if value <= 127 { return (value == 0, Char(UInt16(value)).isAsciiPunctuationOrZero) }
        return (false, isCommonMarkPunctuation(scalar.properties.generalCategory))
    }

    static func unicodeCategory(of char: Char) -> (space: Bool, punctuation: Bool) {
        if char.isWhitespace { return (true, false) }
        if char.value <= 127 { return (char.value == 0, char.isAsciiPunctuationOrZero) }
        return (false, isCommonMarkPunctuation(char.category))
    }

    /// Unicode P (punctuation) and S (symbol) categories.
    static func isCommonMarkPunctuation(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
        default: false
        }
    }

    private static func isPunctuationException(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{2212}" || scalar == "-" || scalar == "+" || scalar == "\u{2020}" || scalar == "\u{2021}"
    }

    /// Whether a delimiter run between `previous` and `next` can open and close emphasis (CommonMark flanking rules).
    static func checkOpenCloseDelimiter(_ previous: Unicode.Scalar, _ next: Unicode.Scalar, enableWithinWord: Bool) -> (canOpen: Bool, canClose: Bool) {
        let (prevIsWhiteSpace, prevIsPunctuation) = unicodeCategory(of: previous)
        let (nextIsWhiteSpace, nextIsPunctuation) = unicodeCategory(of: next)
        let prevIsExcepted = prevIsPunctuation && isPunctuationException(previous)
        let nextIsExcepted = nextIsPunctuation && isPunctuationException(next)
        var canOpen = !nextIsWhiteSpace && ((!nextIsPunctuation || nextIsExcepted) || prevIsWhiteSpace || prevIsPunctuation)
        var canClose = !prevIsWhiteSpace && ((!prevIsPunctuation || prevIsExcepted) || nextIsWhiteSpace || nextIsPunctuation)
        if !enableWithinWord {
            let temp = canOpen
            canOpen = canOpen && (!canClose || prevIsPunctuation)
            canClose = canClose && (!temp || nextIsPunctuation)
        }
        return (canOpen, canClose)
    }

    /// GitHub's notion of a character that ends an autolinked domain: ASCII punctuation or whitespace, '\0', and
    /// Unicode punctuation or space separators.
    static func isSpaceOrPunctuationForGFMAutoLink(_ c: Char) -> Bool {
        if c.value <= 127 { return c.value == 0 || c.isAsciiPunctuation || c == "\t" || c == "\n" || c == "\u{0C}" || c == "\r" || c == " " }
        switch c.category {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .spaceSeparator: return true
        default: return false
        }
    }

    /// Characters an absolute URI of an autolink cannot contain: ASCII controls, space, '<' and '>'.
    static func isInvalidAutoLinkCharacter(_ c: Char) -> Bool {
        (c.value >= 1 && c.value <= 0x1F) || c == " " || c == "<" || c == ">" || c.value == 0x7F
    }

    static func isEmailUsernameSpecialChar(_ c: Char) -> Bool {
        switch c {
        case ".", "!", "#", "$", "%", "&", "'", "*", "+", "/", "=", "?", "^", "_", "`", "{", "|", "}", "~", "-": true
        default: false
        }
    }

    static func isEmailUsernameSpecialCharOrDigit(_ c: Char) -> Bool { isEmailUsernameSpecialChar(c) || c.isDigit }

    static func isRomanLetterPartial(_ c: Char) -> Bool { isRomanLetterLowerPartial(c) || isRomanLetterUpperPartial(c) }
    static func isRomanLetterLowerPartial(_ c: Char) -> Bool { c == "i" || c == "v" || c == "x" }
    static func isRomanLetterUpperPartial(_ c: Char) -> Bool { c == "I" || c == "V" || c == "X" }

    static func romanToArabic(_ text: [Char]) -> Int {
        func value(_ c: Char) -> Int {
            switch c.value | 0x20 {
            case 0x69: 1 // i
            case 0x76: 5 // v
            default: 10
            }
        }
        var result = 0
        for i in text.indices {
            let candidate = value(text[i])
            if i + 1 < text.count && candidate < value(text[i + 1]) { result -= candidate } else { result += candidate }
        }
        return result
    }

    /// `Rune.TryCreate(high, low)`: the supplementary scalar of a valid pair, else U+0000.
    static func rune(_ high: Char, _ low: Char) -> Unicode.Scalar {
        guard high.isHighSurrogate, low.isLowSurrogate else { return "\0" }
        let value = 0x10000 + ((UInt32(high.value) - 0xD800) << 10) + (UInt32(low.value) - 0xDC00)
        return Unicode.Scalar(value) ?? "\0"
    }

    /// `Rune.TryCreate(char)`: the BMP scalar, or U+0000 for a surrogate half.
    static func rune(_ c: Char) -> Unicode.Scalar? { Unicode.Scalar(UInt32(c.value)) }
}

extension Markdown {
    /// The line ending of a line (`NewLine`); the length is that of its text.
    enum NewLine: Equatable {
        case none, carriageReturn, lineFeed, carriageReturnLineFeed

        var chars: [Char] {
            switch self {
            case .none: []
            case .carriageReturn: ["\r"]
            case .lineFeed: ["\n"]
            case .carriageReturnLineFeed: ["\r", "\n"]
            }
        }

        var length: Int {
            switch self {
            case .none: 0
            case .carriageReturn, .lineFeed: 1
            case .carriageReturnLineFeed: 2
            }
        }
    }

    /// A slice of a text: `start...end` inclusive (`StringSlice`). Characters outside the slice stay reachable through
    /// the absolute peeks, as in Markdig.
    struct Slice: CustomStringConvertible {
        var text: [Char]
        var start: Int
        var end: Int
        var newLine: NewLine

        init(_ text: [Char], newLine: NewLine = .none) {
            self.text = text
            start = 0
            end = text.count - 1
            self.newLine = newLine
        }

        init(_ text: [Char], _ start: Int, _ end: Int, _ newLine: NewLine = .none) {
            self.text = text
            self.start = start
            self.end = end
            self.newLine = newLine
        }

        init(_ string: String) { self.init(Markdown.chars(string)) }

        static let empty = Slice([Char]())

        /// Whether both slices are views of the same text (Markdig compares the string references).
        func sharesText(with other: Slice) -> Bool {
            text.withUnsafeBufferPointer { a in
                other.text.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress && a.count == b.count }
            }
        }

        var length: Int { end - start + 1 }
        var isEmpty: Bool { start > end }
        var currentChar: Char { start <= end ? text[start] : .zero }
        subscript(index: Int) -> Char { text[index] }

        /// The scalar at the start (a surrogate pair is combined), U+0000 when empty or invalid.
        var currentRune: Unicode.Scalar {
            guard start <= end else { return "\0" }
            let first = text[start]
            if let scalar = Markdown.rune(first) { return scalar }
            return start + 1 <= end ? Markdown.rune(first, text[start + 1]) : "\0"
        }

        func runeAt(_ index: Int) -> Unicode.Scalar {
            let first = text[index]
            if let scalar = Markdown.rune(first) { return scalar }
            return index + 1 < text.count ? Markdown.rune(first, text[index + 1]) : "\0"
        }

        @discardableResult
        mutating func nextChar() -> Char {
            if start >= end {
                start = end + 1
                return .zero
            }
            start += 1
            return text[start]
        }

        /// Advances by one scalar (two code units for a surrogate pair) and returns the next scalar.
        @discardableResult
        mutating func nextRune() -> Unicode.Scalar {
            var index = start
            if index >= end {
                start = end + 1
                return "\0"
            }
            let wasHigh = text[index].isHighSurrogate
            index += 1
            if wasHigh && index <= end && text[index].isLowSurrogate { index += 1 }
            start = index
            // Markdig reads past the slice here and would throw at the end of the text.
            guard index < text.count else { return "\0" }
            let first = text[index]
            if let scalar = Markdown.rune(first) { return scalar }
            return index + 1 <= end ? Markdown.rune(first, text[index + 1]) : "\0"
        }

        mutating func skipChar() {
            if start <= end { start += 1 }
        }

        mutating func countAndSkipChar(_ match: Char) -> Int {
            var current = start
            while current <= end && current < text.count && text[current] == match { current += 1 }
            let count = current - start
            start = current
            return count
        }

        func peekChar() -> Char {
            let index = start + 1
            return index <= end ? text[index] : .zero
        }

        func peekChar(_ offset: Int) -> Char {
            let index = start + offset
            return index >= start && index <= end ? text[index] : .zero
        }

        func peekCharAbsolute(_ index: Int) -> Char { index >= 0 && index < text.count ? text[index] : .zero }

        /// A character relative to the start that may lie outside the slice (but inside the text).
        func peekCharExtra(_ offset: Int) -> Char {
            let index = start + offset
            return index >= 0 && index < text.count ? text[index] : .zero
        }

        func peekRuneExtra(_ offset: Int) -> Unicode.Scalar {
            let index = start + offset
            guard index >= 0 && index < text.count else { return "\0" }
            let unit = text[index]
            if let scalar = Markdown.rune(unit) { return scalar }
            if offset < 0 {
                return index - 1 >= 0 ? Markdown.rune(text[index - 1], unit) : "\0"
            }
            return index + 1 < text.count ? Markdown.rune(unit, text[index + 1]) : "\0"
        }

        func match(_ string: String, offset: Int = 0) -> Bool { match(Markdown.chars(string), end: end, offset: offset) }

        func match(_ chars: [Char], end: Int, offset: Int) -> Bool {
            var index = start + offset
            if end - index + 1 < chars.count { return false }
            for c in chars {
                if c != text[index] { return false }
                index += 1
            }
            return true
        }

        func matchLowercase(_ string: String, offset: Int = 0) -> Bool {
            let chars = Markdown.chars(string)
            var index = start + offset
            if end - index + 1 < chars.count { return false }
            for c in chars {
                if c != text[index].lowerInvariant { return false }
                index += 1
            }
            return true
        }

        /// `IndexOf(string, offset, ignoreCase)` within the slice; ignoring case is .NET's OrdinalIgnoreCase.
        func indexOf(_ string: String, offset: Int = 0, ignoreCase: Bool = false) -> Int {
            let needle = Markdown.chars(string)
            let from = start + offset
            let length = end - from + 1
            if length <= 0 { return -1 }
            if needle.isEmpty { return from }
            let last = from + length - needle.count
            if last < from { return -1 }
            var i = from
            while i <= last {
                var matched = true
                for (k, c) in needle.enumerated() {
                    let t = text[i + k]
                    if ignoreCase ? t.upperInvariant != c.upperInvariant : t != c { matched = false; break }
                }
                if matched { return i }
                i += 1
            }
            return -1
        }

        func indexOf(_ c: Char) -> Int {
            guard start <= end else { return -1 }
            for i in start...end where text[i] == c { return i }
            return -1
        }

        /// Whether only spaces remain up to a line ending (or the end).
        func skipSpacesToEndOfLineOrEndOfDocument() -> Bool {
            var i = start
            while i <= end {
                let c = text[i]
                if c.isWhitespace {
                    if c == "\n" || (c == "\r" && i + 1 <= end && text[i + 1] != "\n") { return true }
                    i += 1
                    continue
                }
                return false
            }
            return true
        }

        @discardableResult
        mutating func trimStart() -> Bool {
            var i = start
            while i <= end && i < text.count && text[i].isWhitespace { i += 1 }
            start = i
            return i > end
        }

        mutating func trimStartCounting() -> Int {
            var i = start
            while i <= end && i < text.count && text[i].isWhitespace { i += 1 }
            let count = i - start
            start = i
            return count
        }

        @discardableResult
        mutating func trimEnd() -> Bool {
            var i = end
            while start <= i && i < text.count && text[i].isWhitespace { i -= 1 }
            end = i
            return start > i
        }

        mutating func trim() {
            var s = start, e = end
            while s <= e && s < text.count && text[s].isWhitespace { s += 1 }
            while s <= e && e < text.count && e >= 0 && text[e].isWhitespace { e -= 1 }
            start = s
            end = e
        }

        var chars: ArraySlice<Char> {
            let length = end - start + 1
            guard length > 0, start >= 0, start + length <= text.count else { return [] }
            return text[start...end]
        }

        var description: String { Markdown.string(chars) }

        func isEmptyOrWhitespace() -> Bool {
            var i = start
            while i <= end && i < text.count {
                if !text[i].isWhitespace { return false }
                i += 1
            }
            return true
        }

        func overlaps(_ other: Slice) -> Bool {
            if isEmpty || other.isEmpty { return false }
            return start <= other.end && end >= other.start
        }
    }

    /// A line of a leaf block: its slice and where it was in the source (`StringLine`).
    struct Line {
        var slice: Slice
        var line = 0
        var position = 0
        var column = 0
        var newLine: NewLine

        init(_ slice: Slice) {
            self.slice = slice
            newLine = slice.newLine
        }

        init(_ slice: Slice, line: Int, column: Int, position: Int, newLine: NewLine) {
            self.slice = slice
            self.line = line
            self.column = column
            self.position = position
            self.newLine = newLine
        }
    }

    /// The lines of a leaf block (`StringLineGroup`). A reference type: Markdig's struct shares its line array.
    final class LineGroup {
        var lines: [Line] = []
        /// Length of Markdig's pooled line array: its iterator moves past a final line ending only while a slot is
        /// left, so this decides whether a definition that ends a paragraph leaves an empty line behind.
        var capacity: Int

        init(capacity: Int = 4) { self.capacity = capacity }
        init(_ text: [Char]) {
            lines = [Line(Slice(text))]
            capacity = 1
        }

        var count: Int { lines.count }
        subscript(index: Int) -> Line {
            get { lines[index] }
            set { lines[index] = newValue }
        }

        func add(_ line: Line) {
            if capacity == 0 { capacity = 4 } else if lines.count == capacity { capacity *= 2 }
            lines.append(line)
        }

        func add(_ slice: Slice) { add(Line(slice)) }
        func clear() { lines.removeAll() }
        func removeAt(_ index: Int) { lines.remove(at: index) }
        func removeStartRange(_ count: Int) { lines.removeFirst(count) }

        /// The lines joined with their own line endings; a single line is its slice into the source.
        func toSlice() -> Slice {
            if lines.count == 1 { return lines[0].slice }
            if lines.isEmpty { return .empty }
            var builder: [Char] = []
            var newLine = NewLine.none
            for (i, line) in lines.enumerated() {
                if i > 0 { builder += newLine.chars }
                if !line.slice.isEmpty { builder += line.slice.chars }
                newLine = line.newLine
            }
            return Slice(builder)
        }

        var description: String { toSlice().description }

        func trim() {
            for i in lines.indices { lines[i].slice.trim() }
        }

        /// Iterates the characters of all lines, line endings included (`StringLineGroup.Iterator`).
        struct Iterator {
            private let group: LineGroup
            private var currentSlice: Slice
            private var offset = -1
            private(set) var start = -1
            private(set) var end = -1
            private(set) var currentChar = Char.zero
            private(set) var sliceIndex = 0

            init(_ group: LineGroup) {
                self.group = group
                for line in group.lines { end += line.slice.length + line.slice.newLine.length }
                currentSlice = group.lines.first?.slice ?? .empty
                skipChar()
            }

            var isEmpty: Bool { start > end }

            /// The lines not read yet; the first one starts at the current character.
            func remaining() -> LineGroup {
                if isEmpty {
                    group.clear()
                } else {
                    group.removeStartRange(sliceIndex)
                    if group.count > 0 && offset > 0 {
                        group.lines[0].column += offset
                        group.lines[0].slice.start += offset
                    }
                }
                return group
            }

            @discardableResult
            mutating func nextChar() -> Char {
                start += 1
                if start <= end {
                    offset += 1
                    let index = currentSlice.start + offset
                    if index <= currentSlice.end && index < currentSlice.text.count {
                        currentChar = currentSlice.text[index]
                        return currentChar
                    }
                    return nextCharNewLine()
                }
                currentChar = .zero
                start = end + 1
                sliceIndex = group.count
                return .zero
            }

            private mutating func nextCharNewLine() -> Char {
                let sliceLength = currentSlice.length
                let newLine = currentSlice.newLine
                var moveToNewLine = false
                if offset == sliceLength {
                    switch newLine {
                    case .lineFeed: currentChar = "\n"; moveToNewLine = true
                    case .carriageReturn: currentChar = "\r"; moveToNewLine = true
                    case .carriageReturnLineFeed: currentChar = "\r"
                    case .none: break
                    }
                } else if offset - 1 == sliceLength && newLine == .carriageReturnLineFeed {
                    currentChar = "\n"
                    moveToNewLine = true
                }
                if moveToNewLine && sliceIndex < group.capacity - 1 {
                    sliceIndex += 1
                    offset = -1
                    currentSlice = sliceIndex < group.lines.count ? group.lines[sliceIndex].slice : Slice([Char](), 0, -1)
                }
                return currentChar
            }

            mutating func skipChar() { nextChar() }

            func peekChar() -> Char { peekChar(1) }

            func peekChar(_ requested: Int) -> Char {
                if start + requested > end { return .zero }
                var offset = requested + self.offset
                var index = sliceIndex
                var slice = group.lines[index].slice
                let newLine = slice.newLine
                if !(newLine == .carriageReturnLineFeed && offset == slice.length + 1) {
                    while offset > slice.length {
                        offset -= slice.length + 1
                        index += 1
                        slice = group.lines[index].slice
                    }
                } else if slice.newLine == .carriageReturnLineFeed {
                    return "\n"
                }
                if offset == slice.length {
                    switch newLine {
                    case .lineFeed: return "\n"
                    case .carriageReturn: return "\r"
                    case .carriageReturnLineFeed: return "\r"
                    case .none: break
                    }
                }
                return slice[slice.start + offset]
            }

            @discardableResult
            mutating func trimStart() -> Bool {
                var c = currentChar
                while c.isWhitespace { c = nextChar() }
                return isEmpty
            }
        }
    }

    /// Splits a text into lines on "\n", "\r\n" and "\r" (`LineReader`).
    struct LineReader {
        private let text: [Char]
        private(set) var sourcePosition = 0

        init(_ text: [Char]) { self.text = text }

        /// The next line, or nil at the end of the text.
        mutating func readLine() -> Slice? {
            let position = sourcePosition
            guard position < text.count else { return nil }
            var end = text.count
            var next = Int.max
            var newLine = NewLine.none
            var i = position
            while i < text.count && text[i] != "\r" && text[i] != "\n" { i += 1 }
            if i < text.count {
                end = i
                next = end + 1
                if text[end] == "\r" {
                    if next < text.count && text[next] == "\n" {
                        newLine = .carriageReturnLineFeed
                        next += 1
                    } else {
                        newLine = .carriageReturn
                    }
                } else {
                    newLine = .lineFeed
                }
            }
            sourcePosition = next
            return Slice(text, position, end - 1, newLine)
        }
    }
}
