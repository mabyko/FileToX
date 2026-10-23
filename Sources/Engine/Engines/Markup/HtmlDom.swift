// A small read-only DOM over libxml2's HTML parser: what Filee's HtmlReader used from AngleSharp. libxml2 (2.9) builds
// an HTML 4 tree, so the conversion below repairs the places where it differs from the HTML5 tree AngleSharp builds
// and the reader would lose or add text: the newline after <pre>, cells without a row, content after </body>, stray
// content inside tables (moved in front, like HTML5's foster parenting), <image> outside SVG, prefixed names such as
// mbp:pagebreak and o:p, and C1 numeric references (&#150;), which HTML5 reads as Windows-1252.

import Foundation
import libxml2

enum HtmlDom {
    class Node {
        fileprivate(set) weak var parent: Element?
    }

    final class Text: Node {
        let data: String
        init(_ data: String) { self.data = data }
    }

    final class Element: Node {
        /// Lower-case name, with its prefix ("mbp:pagebreak").
        fileprivate(set) var localName: String
        let attributes: [(name: String, value: String)]
        fileprivate(set) var childNodes: [Node] = []

        init(_ localName: String, _ attributes: [(name: String, value: String)]) {
            self.localName = localName
            self.attributes = attributes
        }

        func getAttribute(_ name: String) -> String? {
            let wanted = name.lowercased()
            return attributes.first { $0.name == wanted }?.value
        }

        func hasAttribute(_ name: String) -> Bool { getAttribute(name) != nil }

        var id: String? { getAttribute("id") }

        /// The class attribute's tokens (split on ASCII white space, duplicates removed).
        var classList: [String] {
            var tokens: [String] = []
            var token = String.UnicodeScalarView()
            for scalar in (getAttribute("class") ?? "").unicodeScalars + [" "] {
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
                    if !token.isEmpty, !tokens.contains(String(token)) { tokens.append(String(token)) }
                    token = String.UnicodeScalarView()
                } else {
                    token.append(scalar)
                }
            }
            return tokens
        }

        /// Element children.
        var children: [Element] { childNodes.compactMap { $0 as? Element } }

        /// Every descendant element in document order.
        func descendants() -> [Element] {
            var result: [Element] = []
            var stack = children.reversed() as [Element]
            while let element = stack.popLast() {
                result.append(element)
                stack.append(contentsOf: element.children.reversed())
            }
            return result
        }

        /// The text of every descendant text node.
        var textContent: String {
            var result = ""
            var stack = childNodes.reversed() as [Node]
            while let node = stack.popLast() {
                if let text = node as? Text { result += text.data }
                else if let element = node as? Element { stack.append(contentsOf: element.childNodes.reversed()) }
            }
            return result
        }

        fileprivate func append(_ node: Node) {
            node.parent = self
            childNodes.append(node)
        }

        fileprivate func insert(_ nodes: [Node], at index: Int) {
            for node in nodes { node.parent = self }
            childNodes.insert(contentsOf: nodes, at: index)
        }

        fileprivate func remove(at index: Int) -> Node {
            let node = childNodes.remove(at: index)
            node.parent = nil
            return node
        }
    }

    final class Document {
        let documentElement: Element?

        init(_ documentElement: Element?) { self.documentElement = documentElement }

        /// The first body (or frameset) child of the root element.
        var body: Element? {
            documentElement?.children.first { $0.localName == "body" || $0.localName == "frameset" }
        }

        /// AngleSharp's `Document.Title`: the first HTML title's text, white space collapsed and stripped; "" without one.
        var title: String {
            guard let root = documentElement else { return "" }
            let title = root.descendants().first { $0.localName == "title" && !$0.isForeign }
            return title.map { collapseAndStrip($0.textContent) } ?? ""
        }

        /// The elements with one of `names`, in document order (`QuerySelectorAll("style, link")`).
        func elements(_ names: Set<String>) -> [Element] {
            guard let root = documentElement else { return [] }
            return ([root] + root.descendants()).filter { names.contains($0.localName) }
        }

        /// Takes the tree apart iteratively: releasing a deep tree recursively could exhaust a thread's stack.
        func dispose() {
            guard let root = documentElement else { return }
            var stack: [Element] = [root]
            while let element = stack.popLast() {
                stack.append(contentsOf: element.children)
                element.childNodes = []
            }
        }
    }

    /// Parses HTML text (already decoded) into a document. Never loads anything from the network.
    static func parse(_ html: String) -> Document {
        // HTML5 input preprocessing: CR LF and lone CR become LF.
        var text = rawText(html.contains("\r") ? html.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : html)
        // libxml2 drops control characters XML does not allow (the form feeds of licence texts); HTML5 keeps them.
        // They pass through as the noncharacters U+FDD0 + code and come back in `cleaned`.
        if text.utf8.contains(where: { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0 }) {
            text = String(String.UnicodeScalarView(text.unicodeScalars.map {
                $0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0A && $0.value != 0x0D && $0.value != 0 ? Unicode.Scalar(0xFDD0 + $0.value)! : $0
            }))
        }
        let options = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue
            | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NODEFDTD.rawValue | HTML_PARSE_IGNORE_ENC.rawValue
            | XML_PARSE_HUGE.rawValue)
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count < Int(Int32.max), let context = htmlNewParserCtxt() else { return Document(nil) }
        defer { htmlFreeParserCtxt(context) }
        context.pointee.sax.pointee.startElement = { parser, name, attributes in
            xmlSAX2StartElement(parser, name, attributes)
            guard let name, let context = parser?.assumingMemoryBound(to: xmlParserCtxt.self), let node = context.pointee.node else { return }
            let tag = UnsafeRawPointer(name).assumingMemoryBound(to: CChar.self)
            if strchr(tag, 0x3A) != nil {
                // libxml2 drops an undeclared prefix ("mbp:pagebreak" becomes "pagebreak"); HTML5 keeps the full name.
                xmlNodeSetName(node, name)
            } else if strcmp(tag, "p") == 0, attributes == nil, let cursor = context.pointee.input?.pointee.cur,
                      cursor.pointee != 0x3E, cursor.pointee != 0x2F {
                // A <p> libxml2 opened for text outside any element (no tag ends at the cursor); HTML5 has none.
                node.pointee._private = UnsafeMutableRawPointer(bitPattern: 1) // marks the implied <p> for convert()
            }
        }
        let parsed = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                htmlCtxtReadMemory(context, $0, Int32(buffer.count), nil, "UTF-8", options)
            }
        }
        guard let parsed else { return Document(nil) }
        defer { xmlFreeDoc(parsed) }
        guard let root = xmlDocGetRootElement(parsed) else { return Document(nil) }
        let document = Document(convert(root))
        if let root = document.documentElement { repair(root) }
        return document
    }

    // MARK: libxml2 → DOM

    private static func string(_ pointer: UnsafePointer<xmlChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    /// "prefix:name": libxml2 splits prefixed HTML names into a namespace prefix and a local name.
    private static func qualifiedName(_ name: UnsafePointer<xmlChar>?, _ namespace: xmlNsPtr?) -> String {
        let local = string(name)
        guard !local.contains(":"), let prefix = namespace?.pointee.prefix else { return local }
        return string(prefix) + ":" + local
    }

    private static func element(_ node: xmlNodePtr) -> Element {
        var attributes: [(name: String, value: String)] = []
        var attribute = node.pointee.properties
        while let current = attribute {
            var value = ""
            var child = current.pointee.children
            while let text = child {
                value += string(text.pointee.content)
                child = text.pointee.next
            }
            let name = qualifiedName(current.pointee.name, current.pointee.ns).lowercased()
            if !attributes.contains(where: { $0.name == name }) { attributes.append((name, cleaned(value))) }
            attribute = current.pointee.next
        }
        return Element(qualifiedName(node.pointee.name, node.pointee.ns).lowercased(), attributes)
    }

    /// Converts the libxml2 tree without recursion (deeply nested pages are expected).
    private static func convert(_ root: xmlNodePtr) -> Element {
        let top = element(root)
        var stack: [(xmlNodePtr?, Element)] = [(root.pointee.children, top)]
        while !stack.isEmpty {
            guard let node = stack[stack.count - 1].0 else { stack.removeLast(); continue }
            let parent = stack[stack.count - 1].1
            stack[stack.count - 1].0 = node.pointee.next
            switch node.pointee.type {
            case XML_ELEMENT_NODE where node.pointee._private == UnsafeMutableRawPointer(bitPattern: 1): // implied <p>: keep only its content
                stack.append((node.pointee.children, parent))
            case XML_ELEMENT_NODE:
                let child = element(node)
                parent.append(child)
                stack.append((node.pointee.children, child))
            case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                let data = cleaned(string(node.pointee.content))
                if !data.isEmpty { parent.append(Text(data)) }
            default:
                break // comments, processing instructions
            }
        }
        return top
    }

    // MARK: HTML5 repairs

    /// The text of <title> (RCDATA) and <xmp> (RAWTEXT) is not markup in HTML5, and </br> is a line break.
    private static func rawText(_ html: String) -> String {
        guard ["<title", "<xmp", "</br"].contains(where: { html.range(of: $0, options: .caseInsensitive) != nil }) else { return html }
        var result = endBreak.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "<br>")
        for (pattern, escapeAmpersands) in [(titleElement, false), (xmpElement, true)] {
            for match in pattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range(at: 2), in: result) else { continue }
                var content = String(result[range])
                if escapeAmpersands { content = content.replacingOccurrences(of: "&", with: "&amp;", options: .literal) }
                result.replaceSubrange(range, with: content.replacingOccurrences(of: "<", with: "&lt;", options: .literal))
            }
        }
        return result
    }

    private static let endBreak = try! NSRegularExpression(pattern: #"</br\s*>"#, options: .caseInsensitive)
    private static let titleElement = try! NSRegularExpression(pattern: #"(<title\b[^>]*>)(.*?)(</title\s*>)"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let xmpElement = try! NSRegularExpression(pattern: #"(<xmp\b[^>]*>)(.*?)(</xmp\s*>)"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static func repair(_ root: Element) {
        moveAfterBodyContent(root)
        for element in [root] + root.descendants() {
            switch element.localName {
            case "dd", "dt":
                // A dd or dt start tag closes the open one (libxml2 nests them).
                if let index = element.childNodes.firstIndex(where: { ["dd", "dt"].contains(($0 as? Element)?.localName ?? "") }) {
                    moveOut(element, from: index)
                }
            case "source", "track", "wbr", "keygen":
                // Void in HTML5; libxml2 (HTML 4) does not know them and nests what follows inside.
                if !element.childNodes.isEmpty { moveOut(element, from: 0) }
            case "pre", "listing", "textarea":
                // HTML5 drops a newline right after the start tag.
                if let first = element.childNodes.first as? Text, first.data.hasPrefix("\n") {
                    let rest = String(first.data.dropFirst())
                    _ = element.remove(at: 0)
                    if !rest.isEmpty { element.insert([Text(rest)], at: 0) }
                }
            case "image" where !element.isForeign:
                element.localName = "img" // HTML5 reads <image> as <img>
            case "table":
                fosterParent(element)
            default:
                break
            }
        }
    }

    /// Moves the children of `element` from `index` on to right after it.
    private static func moveOut(_ element: Element, from index: Int) {
        guard let parent = element.parent, let position = parent.childNodes.firstIndex(where: { $0 === element }) else { return }
        var moved: [Node] = []
        while element.childNodes.count > index { moved.append(element.remove(at: index)) }
        parent.insert(moved, at: position + 1)
    }

    /// HTML5 puts everything after </body> or </html> into the body; libxml2 leaves it beside the body.
    private static func moveAfterBodyContent(_ root: Element) {
        guard let bodyIndex = root.childNodes.firstIndex(where: { ($0 as? Element)?.localName == "body" }),
              let body = root.childNodes[bodyIndex] as? Element else { return }
        while root.childNodes.count > bodyIndex + 1 {
            let node = root.remove(at: bodyIndex + 1)
            // libxml2 opens a second <html> for content after </html>.
            if let nested = node as? Element, nested.localName == "html" || nested.localName == "body" {
                let inner = nested.childNodes
                nested.childNodes = []
                root.insert(inner, at: bodyIndex + 1)
            } else {
                body.append(node)
            }
        }
    }

    /// Rows without <tr> get one, and content that is not part of the table goes in front of it (HTML5 foster
    /// parenting); libxml2 keeps both inside the table, where the reader would skip them.
    private static func fosterParent(_ table: Element) {
        var fostered: [Node] = []
        func isWhitespace(_ node: Node) -> Bool {
            (node as? Text)?.data.unicodeScalars.allSatisfy { " \t\n\r\u{0C}".unicodeScalars.contains($0) } ?? false
        }
        func wrapCells(_ section: Element) {
            var index = 0
            while index < section.childNodes.count {
                guard let cell = section.childNodes[index] as? Element, cell.localName == "td" || cell.localName == "th" else { index += 1; continue }
                let row = Element("tr", [])
                row.append(section.remove(at: index))
                while index < section.childNodes.count {
                    let next = section.childNodes[index]
                    guard isWhitespace(next) || ["td", "th"].contains((next as? Element)?.localName ?? "") else { break }
                    row.append(section.remove(at: index))
                }
                section.insert([row], at: index)
                index += 1
            }
        }
        /// Walks the table in document order, so fostered content keeps its order.
        func sweep(_ parent: Element) {
            let allowed: Set<String> = switch parent.localName {
            case "table": ["caption", "colgroup", "col", "thead", "tbody", "tfoot", "tr"]
            case "thead", "tbody", "tfoot": ["tr"]
            default: ["td", "th"]
            }
            if parent.localName != "tr" { wrapCells(parent) }
            var index = 0
            while index < parent.childNodes.count {
                let node = parent.childNodes[index]
                if let element = node as? Element, allowed.contains(element.localName) || ["script", "style", "template"].contains(element.localName) {
                    if ["thead", "tbody", "tfoot", "tr"].contains(element.localName) { sweep(element) }
                    index += 1
                } else if isWhitespace(node) {
                    index += 1
                } else {
                    fostered.append(parent.remove(at: index))
                }
            }
        }
        sweep(table)
        guard !fostered.isEmpty, let parent = table.parent, let index = parent.childNodes.firstIndex(where: { $0 === table }) else { return }
        parent.insert(fostered, at: index)
    }

    /// Text as HTML5 reads it: U+0080–U+009F from numeric references (&#150;) are the Windows-1252 characters, and
    /// the control characters passed through as U+FDD1–U+FDEF come back.
    private static func cleaned(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x80...0x9F).contains($0.value) || (0xFDD1...0xFDEF).contains($0.value) }) else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if (0x80...0x9F).contains(scalar.value), let mapped = c1Map[Int(scalar.value - 0x80)], let replacement = Unicode.Scalar(mapped) {
                result.append(replacement)
            } else if (0xFDD1...0xFDEF).contains(scalar.value), let control = Unicode.Scalar(scalar.value - 0xFDD0) {
                result.append(control)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static let c1Map: [UInt32?] = [
        0x20AC, nil, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil, 0x017D, nil,
        nil, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, nil, 0x017E, 0x0178,
    ]

    /// AngleSharp's CollapseAndStrip: runs of HTML white space become one space, none at the ends.
    static func collapseAndStrip(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var hasSpace = true
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
                if !hasSpace { hasSpace = true; result.append(" ") }
            } else {
                hasSpace = false
                result.append(scalar)
            }
        }
        if hasSpace, !result.isEmpty { result.removeLast() }
        return String(result)
    }
}

private extension HtmlDom.Element {
    /// Inside <svg> or <math>, where HTML5 keeps names such as <image> and <title> as they are.
    var isForeign: Bool {
        var current = parent
        while let element = current {
            if element.localName == "svg" || element.localName == "math" { return true }
            current = element.parent
        }
        return false
    }
}
