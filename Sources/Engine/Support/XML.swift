// System.Xml.Linq equivalent (XDocument / XElement / XName / XNamespace) for porting Filee's OOXML, ODF, HWPX, EPUB
// and FB2 code with the same structure. Parsing uses libxml2's text reader, which classifies whitespace exactly like
// .NET's XmlReader: whitespace-only text is dropped (LoadOptions.None) unless it is inside xml:space="preserve" or
// `preserveWhitespace` is set. Attribute order and namespace declarations are kept. No DTD or external entity is
// loaded. Serialization follows XmlWriter's defaults (2-space indent unless the element has text, "<x />", entities).

import Foundation
import libxml2

public struct XNamespace: Hashable, Sendable, CustomStringConvertible {
    public let namespaceName: String
    public init(_ namespaceName: String) { self.namespaceName = namespaceName }

    public static let none = XNamespace("")
    public static let xml = XNamespace("http://www.w3.org/XML/1998/namespace")
    public static let xmlns = XNamespace("http://www.w3.org/2000/xmlns/")

    public static func + (namespace: XNamespace, localName: String) -> XName { XName(localName, namespace: namespace.namespaceName) }
    public func callAsFunction(_ localName: String) -> XName { self + localName }
    public var description: String { namespaceName }
}

public struct XName: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let namespaceName: String
    public let localName: String

    public init(_ localName: String, namespace: String = "") {
        self.localName = localName
        self.namespaceName = namespace
    }

    /// "local" or "{namespace}local", like the implicit string conversion of .NET's XName.
    public init(stringLiteral value: String) {
        if value.hasPrefix("{"), let close = value.firstIndex(of: "}") {
            self.init(String(value[value.index(after: close)...]), namespace: String(value[value.index(after: value.startIndex)..<close]))
        } else {
            self.init(value)
        }
    }

    public var namespace: XNamespace { XNamespace(namespaceName) }
    public var description: String { namespaceName.isEmpty ? localName : "{\(namespaceName)}\(localName)" }
}

public struct XAttribute: Equatable, Sendable {
    public var name: XName
    public var value: String

    public init(_ name: XName, _ value: String) { self.name = name; self.value = value }
    public init(_ name: XName, _ value: Int) { self.init(name, String(value)) }
    public init(_ name: XName, _ value: Double) { self.init(name, XmlConvert.string(value)) }
    public init(_ name: XName, _ value: Bool) { self.init(name, value ? "true" : "false") }

    /// True for `xmlns` / `xmlns:p` declarations.
    public var isNamespaceDeclaration: Bool { name.namespaceName == XNamespace.xmlns.namespaceName || (name.namespaceName.isEmpty && name.localName == "xmlns") }
}

/// Content accepted by `XElement(name, ...)` and `add(...)`: elements, attributes, text, nodes, arrays and nil (ignored).
public protocol XContent {}
extension XElement: XContent {}
extension XAttribute: XContent {}
extension String: XContent {}
extension Substring: XContent {}
extension Int: XContent {}
extension Double: XContent {}
extension Bool: XContent {}
extension XNode: XContent {}
extension Array: XContent where Element: XContent {}
extension Optional: XContent where Wrapped: XContent {}

public enum XNode {
    case element(XElement)
    case text(String)
    case cdata(String)
    case comment(String)
    case instruction(target: String, data: String)

    public var element: XElement? { if case .element(let element) = self { element } else { nil } }
    /// Text of a text or CDATA node.
    public var text: String? {
        switch self {
        case .text(let text), .cdata(let text): text
        default: nil
        }
    }
}

public final class XElement {
    public var name: XName
    public fileprivate(set) var attributes: [XAttribute] = []
    public private(set) var nodes: [XNode] = []
    public private(set) weak var parent: XElement?

    public init(_ name: XName, _ content: XContent?...) {
        self.name = name
        for item in content { if let item { add(item) } }
    }

    /// Deep copy (`new XElement(other)`).
    public init(copying other: XElement) {
        name = other.name
        attributes = other.attributes
        for node in other.nodes {
            if case .element(let child) = node { append(.element(XElement(copying: child))) } else { append(node) }
        }
    }

    // MARK: Navigation

    public func elements() -> [XElement] { nodes.compactMap(\.element) }
    public func elements(_ name: XName) -> [XElement] { nodes.compactMap { $0.element.flatMap { $0.name == name ? $0 : nil } } }
    public func element(_ name: XName) -> XElement? { elements().first { $0.name == name } }
    public var hasElements: Bool { nodes.contains { $0.element != nil } }
    public var isEmpty: Bool { nodes.isEmpty }
    public var firstElement: XElement? { elements().first }

    public func descendants() -> [XElement] {
        var result: [XElement] = []
        func walk(_ element: XElement) { for child in element.elements() { result.append(child); walk(child) } }
        walk(self)
        return result
    }

    public func descendants(_ name: XName) -> [XElement] { descendants().filter { $0.name == name } }

    /// `Descendants(name).FirstOrDefault(predicate)`: document order, without walking past the first match.
    public func firstDescendant(_ name: XName, where predicate: (XElement) -> Bool = { _ in true }) -> XElement? {
        for case .element(let child) in nodes {
            if child.name == name && predicate(child) { return child }
            if let found = child.firstDescendant(name, where: predicate) { return found }
        }
        return nil
    }
    public func descendantsAndSelf() -> [XElement] { [self] + descendants() }
    public func descendantsAndSelf(_ name: XName) -> [XElement] { descendantsAndSelf().filter { $0.name == name } }

    public func ancestors() -> [XElement] {
        var result: [XElement] = []
        var current = parent
        while let element = current { result.append(element); current = element.parent }
        return result
    }

    public func ancestors(_ name: XName) -> [XElement] { ancestors().filter { $0.name == name } }

    public func elementsAfterSelf() -> [XElement] {
        guard let parent, let index = parent.index(of: self) else { return [] }
        return parent.nodes[(index + 1)...].compactMap(\.element)
    }

    public func elementsBeforeSelf() -> [XElement] {
        guard let parent, let index = parent.index(of: self) else { return [] }
        return parent.nodes[..<index].compactMap(\.element)
    }

    func index(of child: XElement) -> Int? { nodes.firstIndex { $0.element === child } }

    // MARK: Attributes

    public func attribute(_ name: XName) -> XAttribute? { attributes.first { $0.name == name } }
    /// `(string?)element.Attribute(name)`.
    public func attributeValue(_ name: XName) -> String? { attribute(name)?.value }

    /// `SetAttributeValue`: adds, replaces in place, or removes with nil.
    public func setAttributeValue(_ name: XName, _ value: String?) {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
            if let value { attributes[index].value = value } else { attributes.remove(at: index) }
        } else if let value {
            attributes.append(XAttribute(name, value))
        }
    }

    public func removeAttributes() { attributes.removeAll() }

    // MARK: Value

    /// Concatenated text of all descendant text and CDATA nodes; setting replaces the content with one text node.
    public var value: String {
        get {
            var result = ""
            func collect(_ element: XElement) {
                for node in element.nodes {
                    switch node {
                    case .text(let text), .cdata(let text): result += text
                    case .element(let child): collect(child)
                    default: break
                    }
                }
            }
            collect(self)
            return result
        }
        set {
            removeNodes()
            if !newValue.isEmpty { nodes = [.text(newValue)] }
        }
    }

    /// `SetElementValue`: sets the text of the first child `name`, adds it, or removes it with nil.
    public func setElementValue(_ name: XName, _ value: String?) {
        if let child = element(name) {
            if let value { child.value = value } else { child.remove() }
        } else if let value {
            add(XElement(name, value))
        }
    }

    // MARK: Mutation

    public func add(_ content: XContent?...) { for item in content { if let item { add(item) } } }

    public func add(_ content: XContent) {
        switch content {
        case let element as XElement:
            let child = element.parent == nil ? element : XElement(copying: element)
            append(.element(child))
        case let attribute as XAttribute:
            if attributes.contains(where: { $0.name == attribute.name }) {
                preconditionFailure("Duplicate attribute \(attribute.name)")
            }
            attributes.append(attribute)
        case let text as String: appendText(text)
        case let text as Substring: appendText(String(text))
        case let number as Int: appendText(String(number))
        case let number as Double: appendText(XmlConvert.string(number))
        case let flag as Bool: appendText(flag ? "true" : "false")
        case let node as XNode:
            if case .element(let element) = node { add(element) } else if case .text(let text) = node { appendText(text) } else { append(node) }
        case let items as [XContent]:
            for item in items { add(item) }
        default:
            let mirror = Mirror(reflecting: content)
            if mirror.displayStyle == .optional {
                if let wrapped = mirror.children.first?.value as? XContent { add(wrapped) }
            } else if mirror.displayStyle == .collection {
                for child in mirror.children { if let item = child.value as? XContent { add(item) } }
            } else {
                appendText(String(describing: content))
            }
        }
    }

    /// Inserts content at the start (`AddFirst`).
    public func addFirst(_ content: XContent...) {
        let previous = nodes
        nodes = []
        for item in content { add(item) }
        nodes += previous
    }

    /// Replaces all child nodes (attributes stay).
    public func replaceNodes(_ content: XContent...) {
        removeNodes()
        for item in content { add(item) }
    }

    public func removeNodes() {
        for node in nodes { node.element?.parent = nil }
        nodes.removeAll()
    }

    /// `RemoveAll`: nodes and attributes.
    public func removeAll() { removeNodes(); attributes.removeAll() }

    /// Removes this element from its parent.
    public func remove() {
        guard let parent, let index = parent.index(of: self) else { return }
        parent.nodes.remove(at: index)
        self.parent = nil
    }

    /// Inserts content right after this element in its parent.
    public func addAfterSelf(_ content: XElement...) {
        guard let parent, let index = parent.index(of: self) else { return }
        for (offset, element) in content.enumerated() {
            element.parent = parent
            parent.nodes.insert(.element(element), at: index + 1 + offset)
        }
    }

    public func addBeforeSelf(_ content: XElement...) {
        guard let parent, let index = parent.index(of: self) else { return }
        for (offset, element) in content.enumerated() {
            element.parent = parent
            parent.nodes.insert(.element(element), at: index + offset)
        }
    }

    /// Replaces this element in its parent.
    public func replaceWith(_ content: XElement...) {
        addAfterSelf(contentsOf: content)
        remove()
    }

    private func addAfterSelf(contentsOf content: [XElement]) {
        guard let parent, let index = parent.index(of: self) else { return }
        for (offset, element) in content.enumerated() {
            element.parent = parent
            parent.nodes.insert(.element(element), at: index + 1 + offset)
        }
    }

    func append(_ node: XNode) {
        if case .element(let element) = node { element.parent = self }
        nodes.append(node)
    }

    fileprivate func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if case .text(let previous)? = nodes.last { nodes[nodes.count - 1] = .text(previous + text) } else { nodes.append(.text(text)) }
    }

    // MARK: Parsing and output

    /// `XElement.Parse`.
    public static func parse(_ text: String, preserveWhitespace: Bool = false) throws -> XElement {
        try XDocument.parse(text, preserveWhitespace: preserveWhitespace).root
    }

    /// Serialized element without an XML declaration (`ToString()` / `ToString(SaveOptions.DisableFormatting)`).
    public func toString(indent: Bool = true) throws -> String {
        var writer = XmlTextWriter(indent: indent)
        try writer.write(self, depth: 0, inherited: [:], mixed: false)
        return writer.output
    }
}

public struct XDeclaration: Equatable, Sendable {
    public var version: String
    public var encoding: String?
    public var standalone: String?

    public init(version: String = "1.0", encoding: String? = "utf-8", standalone: String? = nil) {
        self.version = version
        self.encoding = encoding
        self.standalone = standalone
    }
}

public enum XmlError: LocalizedError, Sendable {
    case parse(String)
    case invalidCharacter(String)

    public var errorDescription: String? {
        switch self {
        case .parse(let message): message
        case .invalidCharacter(let message): message
        }
    }
}

public final class XDocument {
    public var declaration: XDeclaration?
    public var root: XElement

    public init(_ declaration: XDeclaration? = nil, root: XElement) {
        self.declaration = declaration
        self.root = root
    }

    public static func load(_ path: String, preserveWhitespace: Bool = false) throws -> XDocument {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw XmlError.parse("Could not read \(FilePath.fileName(path)): \(error.localizedDescription)") }
        return try load(data: data, preserveWhitespace: preserveWhitespace)
    }

    public static func parse(_ text: String, preserveWhitespace: Bool = false) throws -> XDocument {
        try load(data: Data(text.utf8), preserveWhitespace: preserveWhitespace)
    }

    public static func load(data: Data, preserveWhitespace: Bool = false) throws -> XDocument {
        guard !data.isEmpty else { throw XmlError.parse("Root element is missing.") }
        guard data.count < Int(Int32.max) else { throw XmlError.parse("The XML document is too large.") }
        let options = Int32(XML_PARSE_NONET.rawValue | XML_PARSE_HUGE.rawValue | XML_PARSE_COMPACT.rawValue)
        // libxml2 reads from this buffer while parsing, so it must outlive the reader.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 1)
        defer { buffer.deallocate() }
        data.copyBytes(to: buffer)
        guard let reader = xmlReaderForMemory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), nil, nil, options) else {
            throw XmlError.parse("The XML parser could not start.")
        }
        defer { xmlFreeTextReader(reader) }
        // Collect the first error instead of letting libxml2 print to stderr.
        let errors = XmlErrorSink()
        let sink = Unmanaged.passRetained(errors)
        defer { sink.release() }
        xmlTextReaderSetErrorHandler(reader, { context, message, _, _ in
            guard let context, let message else { return }
            let box = Unmanaged<XmlErrorSink>.fromOpaque(context).takeUnretainedValue()
            if box.first == nil { box.first = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines) }
        }, sink.toOpaque())

        var stack: [XElement] = []
        // xml:space of each open element (true = preserve), inherited from the parent when the element has none.
        var preserving: [Bool] = []
        var root: XElement?
        var declaration: XDeclaration?
        func string(_ pointer: UnsafePointer<xmlChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }

        while true {
            let status = xmlTextReaderRead(reader)
            if status == 0 { break }
            guard status == 1 else { throw XmlError.parse(errors.first ?? "Malformed XML.") }
            if declaration == nil, let version = xmlTextReaderConstXmlVersion(reader) {
                let standalone = xmlTextReaderStandalone(reader)
                declaration = XDeclaration(version: String(cString: version), encoding: xmlTextReaderConstEncoding(reader).map { String(cString: $0) },
                                           standalone: standalone == 1 ? "yes" : standalone == 0 ? "no" : nil)
            }
            switch xmlReaderTypes(rawValue: UInt32(xmlTextReaderNodeType(reader))) {
            case XML_READER_TYPE_ELEMENT:
                let element = XElement(XName(string(xmlTextReaderConstLocalName(reader)), namespace: string(xmlTextReaderConstNamespaceUri(reader))))
                if xmlTextReaderMoveToFirstAttribute(reader) == 1 {
                    repeat {
                        let local = string(xmlTextReaderConstLocalName(reader))
                        var namespace = string(xmlTextReaderConstNamespaceUri(reader))
                        if xmlTextReaderIsNamespaceDecl(reader) == 1 { namespace = local == "xmlns" && string(xmlTextReaderConstPrefix(reader)).isEmpty ? "" : XNamespace.xmlns.namespaceName }
                        element.attributes.append(XAttribute(XName(local, namespace: namespace), string(xmlTextReaderConstValue(reader))))
                    } while xmlTextReaderMoveToNextAttribute(reader) == 1
                    xmlTextReaderMoveToElement(reader)
                }
                if let parent = stack.last { parent.append(.element(element)) } else { root = element }
                if xmlTextReaderIsEmptyElement(reader) != 1 {
                    let space = element.attributeValue(XNamespace.xml + "space")
                    preserving.append(space == "preserve" ? true : space == "default" ? false : (preserving.last ?? false))
                    stack.append(element)
                }
            case XML_READER_TYPE_END_ELEMENT:
                _ = stack.popLast()
                _ = preserving.popLast()
            case XML_READER_TYPE_TEXT, XML_READER_TYPE_SIGNIFICANT_WHITESPACE, XML_READER_TYPE_WHITESPACE:
                // .NET's rule (libxml2 calls whitespace "significant" whenever no xml:space is declared): whitespace-only
                // text is kept inside xml:space="preserve" or with preserveWhitespace, otherwise dropped.
                let text = string(xmlTextReaderConstValue(reader))
                if preserveWhitespace || (preserving.last ?? false) || !text.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
                    stack.last?.appendText(text)
                }
            case XML_READER_TYPE_CDATA:
                stack.last?.appendText(string(xmlTextReaderConstValue(reader)))
            case XML_READER_TYPE_COMMENT:
                stack.last?.append(.comment(string(xmlTextReaderConstValue(reader))))
            case XML_READER_TYPE_PROCESSING_INSTRUCTION:
                stack.last?.append(.instruction(target: string(xmlTextReaderConstLocalName(reader)), data: string(xmlTextReaderConstValue(reader))))
            default:
                break
            }
        }
        guard let root else { throw XmlError.parse("Root element is missing.") }
        return XDocument(declaration, root: root)
    }

    /// UTF-8 bytes with an XML declaration (`Save`). Without a declaration, `<?xml version="1.0" encoding="utf-8"?>`.
    public func data(indent: Bool = true) throws -> Data {
        var writer = XmlTextWriter(indent: indent)
        let declared = declaration ?? XDeclaration()
        writer.output += "<?xml version=\"\(declared.version)\" encoding=\"utf-8\""
        if let standalone = declared.standalone { writer.output += " standalone=\"\(standalone)\"" }
        writer.output += "?>"
        if indent { writer.output += "\n" }
        try writer.write(root, depth: 0, inherited: [:], mixed: false)
        return Data(writer.output.utf8)
    }

    public func save(_ path: String, indent: Bool = true) throws {
        try data(indent: indent).write(to: URL(fileURLWithPath: path))
    }

    /// The document without its declaration (`ToString()`).
    public func toString(indent: Bool = true) throws -> String { try root.toString(indent: indent) }
}

private final class XmlErrorSink { var first: String? }

/// XmlConvert.ToString for doubles: shortest round-trip form, "INF", "-INF", "NaN".
public enum XmlConvert {
    public static func string(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-INF" : "INF" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)".replacingOccurrences(of: "e+", with: "E+").replacingOccurrences(of: "e-", with: "E-")
    }
}

private struct XmlTextWriter {
    let indent: Bool
    var output = ""
    private var generated = 0

    init(indent: Bool) { self.indent = indent }

    /// Writes `element`; `inherited` maps prefixes in scope to namespaces ("" = default namespace).
    mutating func write(_ element: XElement, depth: Int, inherited: [String: String], mixed: Bool) throws {
        var scope = inherited
        var declarations: [(String, String)] = []
        for attribute in element.attributes where attribute.isNamespaceDeclaration {
            let prefix = attribute.name.namespaceName.isEmpty ? "" : attribute.name.localName
            scope[prefix] = attribute.value
        }
        let elementPrefix: String
        let namespace = element.name.namespaceName
        if namespace.isEmpty {
            elementPrefix = ""
            if let current = scope[""], !current.isEmpty { scope[""] = ""; declarations.append(("xmlns", "")) }
        } else if let prefix = Self.prefix(for: namespace, in: scope, allowDefault: true) {
            elementPrefix = prefix
        } else {
            elementPrefix = ""
            scope[""] = namespace
            declarations.append(("xmlns", namespace))
        }
        var attributeText = ""
        for attribute in element.attributes {
            let name: String
            if attribute.isNamespaceDeclaration {
                name = attribute.name.namespaceName.isEmpty ? "xmlns" : "xmlns:\(attribute.name.localName)"
            } else if attribute.name.namespaceName.isEmpty {
                name = attribute.name.localName
            } else if attribute.name.namespaceName == XNamespace.xml.namespaceName {
                name = "xml:\(attribute.name.localName)"
            } else if let prefix = Self.prefix(for: attribute.name.namespaceName, in: scope, allowDefault: false) {
                name = "\(prefix):\(attribute.name.localName)"
            } else {
                generated += 1
                let prefix = "p\(generated)"
                scope[prefix] = attribute.name.namespaceName
                declarations.append(("xmlns:\(prefix)", attribute.name.namespaceName))
                name = "\(prefix):\(attribute.name.localName)"
            }
            attributeText += " \(name)=\"\(try Self.escapeAttribute(attribute.value))\""
        }
        for (name, value) in declarations { attributeText += " \(name)=\"\(try Self.escapeAttribute(value))\"" }

        let qualified = elementPrefix.isEmpty ? element.name.localName : "\(elementPrefix):\(element.name.localName)"
        if indent && !mixed && depth > 0 { output += "\n" + String(repeating: "  ", count: depth) }
        output += "<\(qualified)\(attributeText)"
        if element.nodes.isEmpty { output += " />"; return }
        output += ">"
        let childMixed = mixed || element.nodes.contains { if case .element = $0 { false } else { true } }
        for node in element.nodes {
            switch node {
            case .element(let child):
                try write(child, depth: depth + 1, inherited: scope, mixed: childMixed)
            case .text(let text):
                output += try Self.escapeText(text)
            case .cdata(let text):
                output += "<![CDATA[" + text.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>") + "]]>"
            case .comment(let text):
                if indent && !childMixed { output += "\n" + String(repeating: "  ", count: depth + 1) }
                output += "<!--\(text)-->"
            case .instruction(let target, let data):
                if indent && !childMixed { output += "\n" + String(repeating: "  ", count: depth + 1) }
                output += "<?\(target) \(data)?>"
            }
        }
        if indent && !childMixed { output += "\n" + String(repeating: "  ", count: depth) }
        output += "</\(qualified)>"
    }

    private static func prefix(for namespace: String, in scope: [String: String], allowDefault: Bool) -> String? {
        if namespace == XNamespace.xml.namespaceName { return "xml" }
        if allowDefault, scope[""] == namespace { return "" }
        return scope.filter { !$0.key.isEmpty && $0.value == namespace }.keys.sorted().first
    }

    private static func check(_ scalar: Unicode.Scalar) throws {
        let value = scalar.value
        let valid = value == 0x9 || value == 0xA || value == 0xD || (0x20...0xD7FF).contains(value)
            || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
        if !valid { throw XmlError.invalidCharacter(String(format: "'\\u%04X' is an invalid XML character.", value)) }
    }

    static func escapeText(_ text: String) throws -> String {
        // Most text nodes need no change: one validating scan instead of rebuilding the string scalar by scalar.
        var plain = true
        for scalar in text.unicodeScalars {
            try check(scalar)
            if scalar == "&" || scalar == "<" || scalar == ">" || scalar == "\r" || scalar == "\n" { plain = false; break }
        }
        if plain { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var previousCR = false
        for scalar in text.unicodeScalars {
            try check(scalar)
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\r": result += "\n"; previousCR = true; continue
            case "\n": if !previousCR { result += "\n" }
            default: result.unicodeScalars.append(scalar)
            }
            previousCR = false
        }
        return result
    }

    static func escapeAttribute(_ text: String) throws -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            try check(scalar)
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t": result += "&#x9;"
            case "\n": result += "&#xA;"
            case "\r": result += "&#xD;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
