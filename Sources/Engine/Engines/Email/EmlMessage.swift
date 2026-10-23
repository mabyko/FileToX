// The e-mail message model and parser: the parts of MimeKit 4.18 Filee uses. MimeParser (header blocks, multipart
// trees with preamble / epilogue, attached message/rfc822 parts), MimeMessage / MimeEntity / MimePart / TextPart
// (decoded headers, Content-ID, attachment flags, file names, the text MimeKit picks as TextBody / HtmlBody) and
// MimeMessage.WriteTo for attached messages, re-written with .NET's macOS line endings (LF).

import Foundation

/// One raw header (MimeKit Header): "Field: value" with its folds, kept byte for byte.
struct EmlHeader {
    /// `Header.Field`; for an invalid header the whole line.
    let field: String
    let rawField: [UInt8]
    /// The bytes after the colon, including the final line break.
    let rawValue: [UInt8]
    let isInvalid: Bool

    /// Header.TryParse (lenient): the field name runs to blanks and ':'; a line without one is an invalid header.
    init(raw: [UInt8]) {
        var p = 0
        while p < raw.count && EmlMime.isFieldText(raw[p]) { p += 1 }
        while p < raw.count && EmlMime.isBlank(raw[p]) { p += 1 }
        if p == raw.count || raw[p] != 0x3A {
            rawField = raw
            rawValue = []
            isInvalid = true
            field = EmlCharsets.latin1(raw[...])
        } else {
            rawField = Array(raw[..<p])
            rawValue = Array(raw[(p + 1)...])
            isInvalid = false
            field = EmlCharsets.latin1(raw[..<(raw[..<p].firstIndex(where: EmlMime.isBlank) ?? p)])
        }
    }

    /// `Header.Value`: encoded words decoded, unfolded.
    var value: String { EmlMime.unfold(EmlMime.decodeText(rawValue).text) }

    func named(_ name: String) -> Bool { field.caseInsensitiveCompare(name) == .orderedSame }

    var isContentHeader: Bool { field.count >= 8 && field.prefix(8).caseInsensitiveCompare("Content-") == .orderedSame }
}

/// A MIME entity: its headers and Content-Type.
class EmlEntity {
    let headers: [EmlHeader]
    let contentType: EmlMime.ContentType

    init(headers: [EmlHeader], contentType: EmlMime.ContentType) {
        self.headers = headers
        self.contentType = contentType
    }

    /// The first header with this name (MimeKit HeaderList lookups).
    final func header(_ name: String) -> EmlHeader? { headers.first { $0.named(name) } }

    final lazy var contentDisposition: EmlMime.ContentDisposition? =
        header("Content-Disposition").flatMap { EmlMime.parseContentDisposition($0.rawValue) }

    /// `MimeEntity.ContentId`: the msg-id without angle brackets.
    final lazy var contentId: String? = header("Content-Id").flatMap { header in
        var index = 0
        return EmlMime.tryParseMsgId(header.rawValue, &index, header.rawValue.count, requireAngleAddr: false)
    }

    final var isAttachment: Bool { contentDisposition?.isAttachment ?? false }

    /// MimeEntity.WriteTo: the headers and the blank line, unless `contentOnly`; subclasses add the content.
    func write(to output: inout [UInt8], contentOnly: Bool) {
        if !contentOnly {
            EmlMessage.writeHeaders(headers, to: &output)
            output.append(0x0A)
        }
    }
}

/// A leaf part (MimePart; TextPart when `isText`) with its content as it stood between the boundaries.
final class EmlPart: EmlEntity {
    let isText: Bool
    /// The raw (transfer-encoded) content; nil when the part had none.
    var content: ArraySlice<UInt8>?

    init(headers: [EmlHeader], contentType: EmlMime.ContentType, isText: Bool) {
        self.isText = isText
        super.init(headers: headers, contentType: contentType)
    }

    lazy var transferEncoding = EmlMime.parseTransferEncoding(header("Content-Transfer-Encoding")?.value)

    /// `MimePart.FileName`: the Content-Disposition file name, else the Content-Type name, trimmed.
    var fileName: String? { (contentDisposition?.fileName ?? contentType.name).map(EmlMime.trim) }

    /// `MimeContent.DecodeTo`.
    func decodedContent() -> [UInt8] { content.map { EmlMime.decode($0, transferEncoding) } ?? [] }

    var isPlain: Bool { contentType.isMimeType("text", "plain") }
    var isHtml: Bool { contentType.isMimeType("text", "html") }

    var isFlowed: Bool {
        guard isPlain, let format = contentType.parameters["format"] else { return false }
        return EmlMime.trim(format).caseInsensitiveCompare("flowed") == .orderedSame
    }

    /// `TextPart.Text`: the charset parameter, a byte order mark, an HTML <meta> charset, else UTF-8 (ISO-8859-1 when
    /// that fails); line breaks become LF.
    var text: String {
        guard content != nil else { return "" }
        let bytes = decodedContent()[...]
        var decoded: String?
        if let charset = contentType.charset, case let codePage = EmlCharsets.codePage(charset), codePage != -1 {
            decoded = EmlCharsets.decode(bytes, codePage: codePage)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            decoded = EmlCharsets.decode(bytes, codePage: 1200)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            decoded = EmlCharsets.decode(bytes, codePage: 1201)
        } else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            decoded = String(validating: bytes, as: UTF8.self)
        } else if isHtml, let codePage = EmlMime.htmlMetaCodePage(bytes), codePage != 1200, codePage != 1201 {
            decoded = EmlCharsets.decode(bytes, codePage: codePage)
        } else {
            decoded = String(validating: bytes, as: UTF8.self)
        }
        return EmlMime.dos2unix(decoded ?? EmlCharsets.latin1(bytes))
    }

    /// MultipartAlternative.GetText: flowed text is joined back into paragraphs.
    var bodyText: String {
        guard isFlowed else { return text }
        let deleteSpace = contentType.parameters["delsp"].map { $0.caseInsensitiveCompare("yes") == .orderedSame } ?? false
        return EmlMime.flowedToText(text, deleteSpace: deleteSpace)
    }

    func isFormat(html: Bool) -> Bool { html ? isHtml : isPlain }

    override func write(to output: inout [UInt8], contentOnly: Bool) {
        super.write(to: &output, contentOnly: contentOnly)
        guard let content else { return }
        if transferEncoding == .binary { output += content } else { output += EmlMime.dos2unix(content) }
    }
}

/// multipart/*: subparts between boundaries, and the text before / after them.
final class EmlMultipart: EmlEntity {
    var children: [EmlEntity] = []
    var rawPreamble: [UInt8]?
    var rawEpilogue: [UInt8]?
    /// The end boundary was found (MimeKit RawEndBoundary == null): it is written back, with the epilogue.
    var endBoundaryFound = false

    var boundary: String? { contentType.boundary }

    private func isSubtype(_ subtype: String) -> Bool { contentType.mediaSubtype.caseInsensitiveCompare(subtype) == .orderedSame }

    /// Multipart / MultipartAlternative / MultipartRelated `TryGetValue`: the body text part in plain text or HTML.
    func textPart(html: Bool) -> EmlPart? {
        if isSubtype("alternative") {
            // from the most faithful alternative (the last) to the least
            for child in children.reversed() {
                if let multipart = child as? EmlMultipart, let part = multipart.textPart(html: html) { return part }
                if let part = child as? EmlPart, part.isText, part.isFormat(html: html) { return part }
            }
            return nil
        }
        if isSubtype("related") {
            guard let root else { return nil }
            if let part = root as? EmlPart, part.isText { return part.isFormat(html: html) ? part : nil }
            return (root as? EmlMultipart)?.textPart(html: html)
        }
        for child in children {
            if let multipart = child as? EmlMultipart { return multipart.textPart(html: html) }
            // the first text part of a multipart/mixed is the body: if it has another format, there is none
            if let part = child as? EmlPart, part.isText, !part.isAttachment { return part.isFormat(html: html) ? part : nil }
        }
        return nil
    }

    /// MultipartRelated.Root: the part the "start" parameter names, the first of the "type", else the first part.
    private var root: EmlEntity? {
        var index = -1
        if let start = contentType.parameters["start"] {
            let bytes = Array(start.utf8)
            var position = 0
            var reference: String?
            while position < bytes.count && reference == nil {
                guard EmlMime.skipCommentsAndWhiteSpace(bytes, &position, bytes.count), position < bytes.count else { break }
                if bytes[position] == 0x3C {
                    reference = EmlMime.tryParseMsgId(bytes, &position, bytes.count, requireAngleAddr: true)
                } else if !EmlMime.skipWord(bytes, &position, bytes.count) {
                    position += 1
                }
            }
            let contentId = reference ?? start
            index = children.firstIndex { $0.contentId == contentId } ?? -1
        } else if let type = contentType.parameters["type"] {
            index = children.firstIndex { $0.contentType.mimeType.caseInsensitiveCompare(type) == .orderedSame } ?? -1
        }
        if index < 0 && children.isEmpty { return nil }
        return children[max(index, 0)]
    }

    override func write(to output: inout [UInt8], contentOnly: Bool) {
        super.write(to: &output, contentOnly: contentOnly)
        if let rawPreamble, !rawPreamble.isEmpty { output += EmlMime.dos2unix(rawPreamble[...], ensureNewLine: !children.isEmpty) }
        let marker = EmlMessage.ascii("--" + (boundary ?? ""))
        for child in children {
            output += marker + [0x0A]
            child.write(to: &output, contentOnly: false)
            var part = child as? EmlPart, multipart = child as? EmlMultipart
            let attached = child as? EmlMessagePart
            if let body = attached?.message?.body {
                multipart = body as? EmlMultipart
                part = body as? EmlPart
            }
            if part?.content == nil && part != nil { continue }
            if let attached, attached.message?.body == nil { continue }
            if let multipart, !multipart.endBoundaryFound { continue }
            output.append(0x0A)
        }
        guard endBoundaryFound else { return }
        output += marker + [0x2D, 0x2D] + (rawEpilogue == nil ? [0x0A] : [])
        if let rawEpilogue, !rawEpilogue.isEmpty { output += EmlMime.dos2unix(rawEpilogue[...]) }
    }
}

/// message/rfc822 (and the other types MimeKit parses as messages): the attached message.
final class EmlMessagePart: EmlEntity {
    var message: EmlMessage?

    override func write(to output: inout [UInt8], contentOnly: Bool) {
        super.write(to: &output, contentOnly: contentOnly)
        guard let message else { return }
        if let marker = message.mboxMarker { output += marker }
        message.write(to: &output)
    }
}

/// A parsed message (MimeKit MimeMessage).
final class EmlMessage {
    /// Every header of the message's header block, in order (the body's Content-* ones too), for WriteTo.
    let allHeaders: [EmlHeader]
    /// The message headers (not Content-*), what MimeMessage.Headers holds.
    let headers: [EmlHeader]
    var body: EmlEntity?
    /// A line before the headers of an attached message ("From ..."), written back before it.
    var mboxMarker: [UInt8]?

    init(headers: [EmlHeader]) {
        allHeaders = headers
        self.headers = headers.filter { !$0.isContentHeader }
    }

    func header(_ name: String) -> EmlHeader? { headers.first { $0.named(name) } }

    var subject: String? { header("Subject")?.value }

    var hasDate: Bool { header("Date") != nil }

    /// `MimeMessage.Date`; DateTimeOffset.MinValue when the header does not parse.
    var date: EmlMime.MessageDate { header("Date").flatMap { EmlMime.parseDate($0.rawValue) } ?? .minValue }

    /// The mailboxes of every header with this name (From, To, Cc), groups flattened.
    func mailboxes(_ name: String) -> [EmlMime.Mailbox] {
        headers.filter { $0.named(name) }.flatMap { EmlMime.parseMailboxes($0.rawValue) ?? [] }
    }

    var textBody: String? { body(html: false) }
    var htmlBody: String? { body(html: true) }

    /// MimeMessage.GetTextBody.
    private func body(html: Bool) -> String? {
        if let multipart = body as? EmlMultipart { return multipart.textPart(html: html)?.bodyText }
        if let part = body as? EmlPart, part.isText, part.isFormat(html: html), !part.isAttachment { return part.bodyText }
        return nil
    }

    /// `MimeMessage.BodyParts`: the leaves of the MIME tree in order; attached messages are not entered.
    var bodyParts: [EmlEntity] {
        var parts: [EmlEntity] = []
        func walk(_ entity: EmlEntity) {
            if let multipart = entity as? EmlMultipart { multipart.children.forEach(walk) } else { parts.append(entity) }
        }
        if let body { walk(body) }
        return parts
    }

    /// `MimeMessage.WriteTo(stream)` with FormatOptions.Default on macOS: headers as read, line breaks as LF.
    func write(to output: inout [UInt8]) {
        Self.writeHeaders(allHeaders, to: &output)
        guard let body else { return }
        output.append(0x0A)
        body.write(to: &output, contentOnly: true)
    }

    static func writeHeaders(_ headers: [EmlHeader], to output: inout [UInt8]) {
        var raw: [UInt8] = []
        for header in headers {
            raw += header.rawField
            if !header.isInvalid {
                raw.append(0x3A)
                raw += header.rawValue
            }
        }
        output += EmlMime.dos2unix(raw[...])
    }

    /// `Encoding.ASCII.GetBytes`: other characters become "?".
    static func ascii(_ text: String) -> [UInt8] { text.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : 0x3F } }

    // MARK: Parsing

    /// `MimeMessage.Load`: parses a whole message; errors carry MimeKit's messages.
    static func parse(_ data: [UInt8]) throws -> EmlMessage {
        var parser = Parser(input: data)
        return try parser.parseMessage()
    }

    /// A port of MimeParser for whole, in-memory messages (Entity format, no mbox, Content-Length ignored).
    private struct Parser {
        enum BoundaryType { case none, eos, immediateBoundary, immediateEndBoundary, parentBoundary, parentEndBoundary }
        enum HeaderEnd { case content, boundary, error }

        let input: [UInt8]
        var index = 0
        /// Boundary markers "--boundary--", innermost last.
        var boundaries: [[UInt8]] = []
        var boundaryType = BoundaryType.none
        /// Which boundary the last check matched (index into `boundaries`).
        var currentBoundary: Int?
        var toplevel = true

        init(input: [UInt8]) { self.input = input }

        static let maxMimeDepth = 1024

        mutating func parseMessage() throws -> EmlMessage {
            // byte order mark: a cut one, or nothing after it, is the end of the stream
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            var skipped = 0
            while skipped < 3 && skipped < input.count && input[skipped] == bom[skipped] { skipped += 1 }
            if input.isEmpty || skipped == input.count || (skipped != 0 && skipped != 3) { throw ConversionError("End of stream.") }
            index = skipped

            let (headers, end, _) = stepHeaders()
            if end == .error { throw ConversionError("Failed to parse message headers.") }
            let message = EmlMessage(headers: headers)
            let entity = Self.createEntity(contentType(headers, parent: nil), headers, toplevel: true, depth: 0)
            message.body = entity
            construct(entity, depth: 0)
            return message
        }

        private func endOfLine(_ from: Int) -> Int? { input[from...].firstIndex(of: 0x0A) }

        private func isEoln(_ at: Int) -> Bool {
            if input[at] == 0x0D { return at + 1 >= input.count || input[at + 1] == 0x0A }
            return input[at] == 0x0A
        }

        private func isMboxMarker(_ at: Int) -> Bool {
            var p = at
            if p < input.count && input[p] == 0x3E { p += 1 }
            return p + 5 <= input.count && Array(input[p..<p + 5]) == Array("From ".utf8)
        }

        /// MimeParser.StepHeaders over complete lines; `preHeader` is the first invalid line before any header.
        mutating func stepHeaders() -> (headers: [EmlHeader], end: HeaderEnd, preHeader: [UInt8]?) {
            var headers: [EmlHeader] = []
            var pending: [UInt8] = []
            var scanningFieldName = true, checkFolded = false, blank = false, valid = true
            var preHeader: [UInt8]?
            boundaryType = .none
            currentBoundary = nil
            defer { toplevel = false }
            func flush() {
                if !pending.isEmpty { headers.append(EmlHeader(raw: pending)) }
                pending.removeAll()
            }
            while true {
                guard index < input.count else {
                    flush()
                    return (headers, .content, preHeader)
                }
                let start = index
                if checkFolded && !EmlMime.isBlank(input[start]) {
                    flush()
                    scanningFieldName = true
                    checkFolded = false
                    blank = false
                    valid = true
                }
                if scanningFieldName && !isEoln(start) {
                    var p = start
                    if input[p] != 0x3A {
                        while p < input.count && input[p] != 0x3A {
                            if EmlMime.isBlank(input[p]) {
                                blank = true
                            } else if blank || EmlMime.isControl(input[p]) {
                                valid = false
                                break
                            }
                            p += 1
                        }
                        if p == input.count {
                            // the input ends inside a field name
                            if toplevel { return (headers, .error, preHeader) }
                            pending += input[start...]
                            index = input.count
                            flush()
                            return (headers, .content, preHeader)
                        }
                    } else {
                        valid = false
                    }
                    if !valid && headers.isEmpty && toplevel && (p - start < 5 || !isMboxMarker(start)) {
                        index = start
                        return (headers, .error, preHeader)
                    }
                }
                scanningFieldName = false
                guard let newline = endOfLine(start) else {
                    pending += input[start...]
                    index = input.count
                    flush()
                    return (headers, .content, preHeader)
                }
                if isEoln(start) {
                    index = newline + 1
                    flush()
                    return (headers, .content, preHeader)
                }
                let type = checkBoundary(start, newline + 1 - start)
                if type != .none {
                    boundaryType = type
                    index = start
                    return (headers, .boundary, preHeader)
                }
                if !valid && headers.isEmpty {
                    if preHeader == nil { preHeader = Array(input[start...newline]) }
                    scanningFieldName = true
                    checkFolded = false
                    blank = false
                    valid = true
                } else {
                    pending += input[start...newline]
                    checkFolded = true
                }
                index = newline + 1
            }
        }

        /// MimeParser.CheckBoundary: a line (trailing white space ignored) that is "--boundary" or "--boundary--" of
        /// the innermost multipart or one of its parents.
        mutating func checkBoundary(_ start: Int, _ length: Int) -> BoundaryType {
            guard length >= 2, input[start] == 0x2D, input[start + 1] == 0x2D, !boundaries.isEmpty else { return .none }
            var end = start + length
            if input[end - 1] == 0x0D { end -= 1 }
            while end > start && EmlMime.isWhitespace(input[end - 1]) { end -= 1 }
            let line = input[start..<end]
            for position in stride(from: boundaries.count - 1, through: 0, by: -1) {
                let marker = boundaries[position]
                let final: Bool
                if line.count == marker.count {
                    final = true
                } else if line.count == marker.count - 2 {
                    final = false
                } else {
                    continue
                }
                guard line.elementsEqual(marker[..<line.count]) else { continue }
                currentBoundary = position
                if position == boundaries.count - 1 { return final ? .immediateEndBoundary : .immediateBoundary }
                return final ? .parentEndBoundary : .parentBoundary
            }
            return .none
        }

        /// MimeParser.ScanContent: up to the next boundary line (or the end); `trimNewLine` drops the line break that
        /// belongs to the boundary.
        mutating func scanContent(trimNewLine: Bool) -> (range: Range<Int>, isEmpty: Bool) {
            let start = index
            var p = index
            boundaryType = .none
            while true {
                guard p < input.count else {
                    boundaryType = .eos
                    break
                }
                let newline = endOfLine(p)
                let type = checkBoundary(p, (newline ?? input.count) - p)
                if type != .none {
                    boundaryType = type
                    break
                }
                p = newline.map { $0 + 1 } ?? input.count
            }
            index = p
            var end = p
            if boundaryType != .eos && trimNewLine && end > start {
                end -= end - start >= 2 && input[p - 2] == 0x0D ? 2 : 1
            }
            return (start..<end, p == start)
        }

        /// MimeParser.SkipLine.
        mutating func skipLine(consumeNewLine: Bool) -> Bool {
            guard let newline = endOfLine(index) else {
                index = input.count
                return false
            }
            if consumeNewLine {
                index = newline + 1
            } else {
                index = newline > 0 && input[newline - 1] == 0x0D ? newline - 1 : newline
            }
            return true
        }

        /// MimeParser.GetContentType: the first Content-Type header, application/octet-stream when unreadable,
        /// text/plain (message/rfc822 in a multipart/digest) without one.
        func contentType(_ headers: [EmlHeader], parent: EmlMime.ContentType?) -> EmlMime.ContentType {
            if let header = headers.first(where: { $0.named("Content-Type") }) {
                let raw = header.rawValue
                var position = 0
                let (type, _) = EmlMime.parseContentType(raw, &position, raw.count)
                if let type { return type }
                var recovered = EmlMime.ContentType("application", "octet-stream")
                while position < raw.count && raw[position] != 0x3B { position += 1 }
                position += 1
                if position < raw.count, let parameters = EmlMime.parseParameters(raw, &position, raw.count) {
                    recovered.parameters = parameters
                }
                return recovered
            }
            if let parent, parent.isMimeType("multipart", "digest") { return EmlMime.ContentType("message", "rfc822") }
            return EmlMime.ContentType("text", "plain")
        }

        /// ParserOptions.CreateEntity: the MimeKit class for a Content-Type.
        static func createEntity(_ type: EmlMime.ContentType, _ headers: [EmlHeader], toplevel: Bool, depth: Int) -> EmlEntity {
            let own = toplevel ? headers.filter(\.isContentHeader) : headers
            func equals(_ a: String, _ values: String...) -> Bool { values.contains { a.caseInsensitiveCompare($0) == .orderedSame } }
            let encoded: Bool = {
                guard let header = headers.first(where: { $0.named("Content-Transfer-Encoding") }) else { return false }
                return EmlMime.isEncoded(EmlMime.parseTransferEncoding(header.value))
            }()
            let subtype = type.mediaSubtype
            switch type.mediaType.lowercased() {
            case "text":
                if depth < maxMimeDepth && equals(subtype, "rfc822-headers") && !encoded {
                    return EmlMessagePart(headers: own, contentType: type)
                }
                return EmlPart(headers: own, contentType: type, isText: true)
            case "multipart":
                if depth >= maxMimeDepth { return EmlPart(headers: own, contentType: type, isText: false) }
                return EmlMultipart(headers: own, contentType: type)
            case "message":
                if equals(subtype, "rfc822", "global", "news", "external-body", "rfc2822", "global-headers") && depth < maxMimeDepth && !encoded {
                    return EmlMessagePart(headers: own, contentType: type)
                }
            case "application":
                if equals(subtype, "rtf") { return EmlPart(headers: own, contentType: type, isText: true) }
            default:
                break
            }
            return EmlPart(headers: own, contentType: type, isText: false)
        }

        mutating func construct(_ entity: EmlEntity, depth: Int) {
            if let multipart = entity as? EmlMultipart {
                constructMultipart(multipart, depth: depth)
            } else if let attached = entity as? EmlMessagePart {
                constructMessagePart(attached, depth: depth)
            } else if let part = entity as? EmlPart {
                let (range, isEmpty) = scanContent(trimNewLine: true)
                if !isEmpty { part.content = input[range] }
            }
        }

        mutating func constructMessagePart(_ attached: EmlMessagePart, depth: Int) {
            if !boundaries.isEmpty {
                guard index < input.count else {
                    boundaryType = .eos
                    return
                }
                let type = checkBoundary(index, (endOfLine(index) ?? input.count) - index)
                if type != .none {
                    boundaryType = type
                    return
                }
            }
            let (headers, _, preHeader) = stepHeaders()
            let message = EmlMessage(headers: headers)
            message.mboxMarker = preHeader
            let entity = Self.createEntity(contentType(headers, parent: nil), headers, toplevel: true, depth: depth + 1)
            message.body = entity
            construct(entity, depth: depth + 1)
            attached.message = message
        }

        mutating func constructMultipart(_ multipart: EmlMultipart, depth: Int) {
            guard let boundary = multipart.boundary else {
                // without a boundary everything is preamble
                multipart.rawPreamble = Array(input[scanContent(trimNewLine: false).range])
                return
            }
            boundaries.append(Array(("--" + boundary + "--").utf8))
            multipart.rawPreamble = Array(input[scanContent(trimNewLine: false).range])
            if boundaryType == .immediateBoundary { scanSubparts(multipart, depth: depth) }
            if boundaryType == .immediateEndBoundary {
                _ = skipLine(consumeNewLine: false)
                multipart.endBoundaryFound = true
                popBoundary()
                let (range, isEmpty) = scanContent(trimNewLine: true)
                multipart.rawEpilogue = isEmpty ? nil : Array(input[range])
                return
            }
            popBoundary()
        }

        mutating func scanSubparts(_ multipart: EmlMultipart, depth: Int) {
            repeat {
                if !skipLine(consumeNewLine: true) {
                    boundaryType = .eos
                    return
                }
                let (headers, end, _) = stepHeaders()
                if end == .boundary && headers.isEmpty {
                    // two boundaries in a row: no part
                    if boundaryType == .immediateBoundary { continue }
                    return
                }
                let entity = Self.createEntity(contentType(headers, parent: multipart.contentType), headers, toplevel: false, depth: depth + 1)
                construct(entity, depth: depth + 1)
                multipart.children.append(entity)
            } while boundaryType == .immediateBoundary
        }

        mutating func popBoundary() {
            boundaries.removeLast()
            let top = boundaries.count - 1
            switch boundaryType {
            case .parentEndBoundary:
                if currentBoundary == top { boundaryType = .immediateEndBoundary }
            case .parentBoundary:
                if currentBoundary == top { boundaryType = .immediateBoundary }
            case .immediateEndBoundary, .immediateBoundary:
                boundaryType = .none
                currentBoundary = nil
            default:
                break
            }
        }
    }
}
