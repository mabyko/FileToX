// Port of Filee.Engines/Office/Ooxml/OpcPackage.cs and OoxmlColors.cs: a minimal reader for Office Open XML
// packages (.xlsx, .pptx) with relationships resolved to zip paths, and colour resolution (theme colours, Excel
// tint and indexed palette, DrawingML colour modifiers) to "#RRGGBB".

import Foundation

/// A relationship of a package part; `target` is a zip path unless it is external.
struct OpcRelationship: Hashable {
    let type: String
    let target: String
    let external: Bool
}

/// An open OPC zip package. Parts and relationships are cached (part names compare case-insensitively).
final class OpcPackage {
    private static let packageRelationships = XNamespace("http://schemas.openxmlformats.org/package/2006/relationships")

    private let zip: ZipReader
    private var parts: [String: XDocument?] = [:]
    private var relationships: [String: [String: OpcRelationship]] = [:]
    /// Relationship ids in file order, so "first relationship of a type" matches Filee.
    private var relationshipOrder: [String: [String]] = [:]

    init(_ path: String) throws { zip = try ZipReader(path: path) }

    /// The main part (target of the package's officeDocument relationship), e.g. xl/workbook.xml.
    var mainPartPath: String? {
        orderedRelationships("").first { $0.type.hasSuffix("/officeDocument") }?.target
    }

    /// A part as XML (whitespace preserved), or nil when it doesn't exist.
    func part(_ path: String) throws -> XDocument? {
        let key = path.lowercased()
        if let cached = parts[key] { return cached }
        var xml: XDocument?
        if let entry = entry(path) { xml = try XDocument.load(data: try zip.data(for: entry), preserveWhitespace: true) }
        parts[key] = .some(xml)
        return xml
    }

    /// Relationships of a part ("" = the package), by id.
    func relationships(_ partPath: String) -> [String: OpcRelationship] {
        load(partPath)
        return relationships[partPath.lowercased()] ?? [:]
    }

    /// Zip path of the part that relationship `id` of `partPath` points to.
    func target(_ partPath: String, _ id: String?) -> String? {
        guard let id, let relationship = relationships(partPath)[id], !relationship.external else { return nil }
        return relationship.target
    }

    /// The first relationship target of a type (matched on the end of the type URI, e.g. "/theme").
    func targetOfType(_ partPath: String, _ typeSuffix: String) -> String? {
        orderedRelationships(partPath).first { !$0.external && $0.type.hasSuffix(typeSuffix) }?.target
    }

    /// Copies a binary part (a picture) to `folder`; returns the file path, or nil.
    func extract(_ partPath: String, _ folder: String) throws -> String? {
        guard let entry = entry(partPath) else { return nil }
        try FileManager.default.createDirectoryIfNeeded(folder)
        let file = FilePath.combine(folder, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + FilePath.extension(partPath))
        try zip.extract(entry, to: file)
        return file
    }

    private func entry(_ path: String) -> ZipReader.Entry? {
        zip.entry(named: path) ?? zip.entries.first { $0.name.caseInsensitiveCompare(path) == .orderedSame }
    }

    private func orderedRelationships(_ partPath: String) -> [OpcRelationship] {
        load(partPath)
        let map = relationships[partPath.lowercased()] ?? [:]
        return (relationshipOrder[partPath.lowercased()] ?? []).compactMap { map[$0] }
    }

    private func load(_ partPath: String) {
        let key = partPath.lowercased()
        guard relationships[key] == nil else { return }
        let folder = Self.folder(partPath)
        let name = partPath.lastIndex(of: "/").map { String(partPath[partPath.index(after: $0)...]) } ?? partPath
        let relsPath = partPath.isEmpty ? "_rels/.rels" : String("\(folder)/_rels/\(name).rels".drop { $0 == "/" })
        var result: [String: OpcRelationship] = [:]
        var order: [String] = []
        if let entry = entry(relsPath), let data = try? zip.data(for: entry), let document = try? XDocument.load(data: data) {
            for relationship in document.root.elements(Self.packageRelationships + "Relationship") {
                let target = relationship.attributeValue("Target") ?? ""
                let external = relationship.attributeValue("TargetMode") == "External"
                let id = relationship.attributeValue("Id") ?? ""
                if result[id] == nil { order.append(id) }
                result[id] = OpcRelationship(type: relationship.attributeValue("Type") ?? "",
                                             target: external ? target : Self.resolvePath(folder, target), external: external)
            }
        }
        relationships[key] = result
        relationshipOrder[key] = order
    }

    private static func folder(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func resolvePath(_ folder: String, _ target: String) -> String {
        if target.hasPrefix("/") { return String(target.drop { $0 == "/" }) }
        var parts = folder.isEmpty ? [] : folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for segment in (target.removingPercentEncoding ?? target).split(separator: "/", omittingEmptySubsequences: false) {
            if segment == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if segment != "." && !segment.isEmpty { parts.append(String(segment)) }
        }
        return parts.joined(separator: "/")
    }
}

/// Resolves Office Open XML colours to "#RRGGBB".
struct OoxmlColors {
    static let a = XNamespace("http://schemas.openxmlformats.org/drawingml/2006/main")

    /// Theme slots in clrScheme order.
    private static let slots = ["dk1", "lt1", "dk2", "lt2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]

    /// Office 2013+ default theme, used when a file has none.
    private static let defaultTheme: [String: String] = [
        "dk1": "#000000", "lt1": "#FFFFFF", "dk2": "#44546A", "lt2": "#E7E6E6",
        "accent1": "#4472C4", "accent2": "#ED7D31", "accent3": "#A5A5A5", "accent4": "#FFC000",
        "accent5": "#5B9BD5", "accent6": "#70AD47", "hlink": "#0563C1", "folHlink": "#954F72",
    ]

    /// Excel's legacy indexed colours 0-63 (8-63 is the default 56-colour palette).
    private static let indexed = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
    ]

    private let theme: [String: String]
    private let map: [String: String]?

    private init(theme: [String: String], map: [String: String]? = nil) {
        self.theme = theme
        self.map = map
    }

    /// The same colours with a PresentationML colour map (p:clrMap bg1="lt1" tx1="dk1" ...).
    func withMap(_ map: [String: String]?) -> OoxmlColors { OoxmlColors(theme: theme, map: map) }

    /// Reads the colour scheme of a theme part (nil = Office default colours).
    static func fromTheme(_ document: XDocument?) -> OoxmlColors {
        var colors = defaultTheme
        let scheme = document?.root.descendantsAndSelf(a + "clrScheme").first
        for slot in slots {
            let element = scheme?.element(a + slot)
            let value = element?.element(a + "srgbClr")?.attributeValue("val") ?? element?.element(a + "sysClr")?.attributeValue("lastClr")
            if let value, value.utf16.count == 6 { colors[slot] = "#" + value.uppercased() }
        }
        return OoxmlColors(theme: colors)
    }

    /// A theme slot or alias (tx1, bg1, ...) as "#RRGGBB".
    func theme(_ name: String) -> String {
        let slot = map?[name] ?? (["tx1": "dk1", "bg1": "lt1", "tx2": "dk2", "bg2": "lt2"][name] ?? name)
        return theme[slot] ?? "#000000"
    }

    /// A SpreadsheetML colour element (rgb="FFRRGGBB", theme="n" tint="x" or indexed="n"), or nil for "automatic".
    func spreadsheet(_ color: XElement?) -> String? {
        guard let color, !["1", "true"].contains(color.attributeValue("auto") ?? "") else { return nil }
        var hex: String?
        if let argb = color.attributeValue("rgb"), argb.utf16.count >= 6 {
            hex = "#" + String(argb.suffix(6)).uppercased()
        } else if let index = Self.int(color.attributeValue("theme")), (0..<12).contains(index) {
            // SpreadsheetML swaps the first two pairs: 0 = lt1, 1 = dk1, 2 = lt2, 3 = dk2.
            hex = theme([0: "lt1", 1: "dk1", 2: "lt2", 3: "dk2"][index] ?? Self.slots[index])
        } else if let index = Self.int(color.attributeValue("indexed")), (0..<64).contains(index) {
            hex = "#" + Self.indexed[index]
        }
        guard let hex else { return nil }
        if let tint = color.attributeValue("tint").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), tint != 0 {
            return Self.tint(hex, tint)
        }
        return hex
    }

    /// The first DrawingML colour child of `parent` (srgbClr, schemeClr, sysClr, prstClr) with its modifiers applied;
    /// `placeholderColor` replaces schemeClr "phClr" (style references).
    func drawing(_ parent: XElement?, placeholderColor: String? = nil) -> String? {
        for element in parent?.elements() ?? [] {
            let name = element.name.localName
            guard ["srgbClr", "schemeClr", "sysClr", "prstClr", "scrgbClr", "hslClr"].contains(name) else { continue }
            var hex: String?
            switch name {
            case "srgbClr": hex = element.attributeValue("val").flatMap { $0.utf16.count == 6 ? "#" + $0.uppercased() : nil }
            case "schemeClr": hex = element.attributeValue("val") == "phClr" ? placeholderColor : theme(element.attributeValue("val") ?? "")
            case "sysClr": hex = element.attributeValue("lastClr").flatMap { $0.utf16.count == 6 ? "#" + $0.uppercased() : nil } ?? "#000000"
            case "prstClr": hex = Self.presetColor(element.attributeValue("val"))
            default: hex = nil
            }
            return hex.map { Self.modify($0, element) }
        }
        return nil
    }

    private static func int(_ text: String?) -> Int? { text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    private static func modify(_ hex: String, _ color: XElement) -> String {
        func value(_ name: String) -> Double {
            int(color.element(a + name)?.attributeValue("val")).map { Double($0) / 100000.0 } ?? .nan
        }
        let (h, s, lightness) = toHsl(hex)
        var l = lightness
        let lumMod = value("lumMod"), lumOff = value("lumOff")
        if !lumMod.isNaN || !lumOff.isNaN {
            l = min(max(l * (lumMod.isNaN ? 1 : lumMod) + (lumOff.isNaN ? 0 : lumOff), 0), 1)
        }
        var (r, g, b) = rgb(fromHsl(h, s, l))
        let tint = value("tint")
        if !tint.isNaN { (r, g, b) = (r + (1 - r) * (1 - tint), g + (1 - g) * (1 - tint), b + (1 - b) * (1 - tint)) }
        let shade = value("shade")
        if !shade.isNaN { (r, g, b) = (r * shade, g * shade, b * shade) }
        return Self.hex(r, g, b)
    }

    /// Excel's tint: lightens (tint > 0) or darkens (tint < 0) the luminance.
    static func tint(_ hex: String, _ tint: Double) -> String {
        let (h, s, l) = toHsl(hex)
        let tinted = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint
        return fromHsl(h, s, min(max(tinted, 0), 1))
    }

    private static func presetColor(_ name: String?) -> String? {
        switch name {
        case "black": "#000000"
        case "white": "#FFFFFF"
        case "red": "#FF0000"
        case "green": "#008000"
        case "blue": "#0000FF"
        case "yellow": "#FFFF00"
        case "gray", "grey": "#808080"
        case "lightGray": "#D3D3D3"
        case "darkGray": "#A9A9A9"
        case "orange": "#FFA500"
        default: nil
        }
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        let digits = Array(hex.utf8.dropFirst())
        func channel(_ i: Int) -> Double { Double(Int(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16) ?? 0) / 255.0 }
        return (channel(0), channel(2), channel(4))
    }

    private static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        // .NET Math.Round rounds half to even.
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded(.toNearestOrEven)) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    private static func toHsl(_ hex: String) -> (Double, Double, Double) {
        let (r, g, b) = rgb(hex)
        let maxV = max(r, max(g, b)), minV = min(r, min(g, b))
        let l = (maxV + minV) / 2
        if maxV == minV { return (0, 0, l) }
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        let h = maxV == r ? (g - b) / d + (g < b ? 6 : 0) : maxV == g ? (b - r) / d + 2 : (r - g) / d + 4
        return (h / 6, s, l)
    }

    private static func fromHsl(_ h: Double, _ s: Double, _ l: Double) -> String {
        if s == 0 { return hex(l, l, l) }
        func channel(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            let t = t0 < 0 ? t0 + 1 : t0 > 1 ? t0 - 1 : t0
            return t < 1 / 6.0 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2 / 3.0 ? p + (q - p) * (2 / 3.0 - t) * 6 : p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return hex(channel(p, q, h + 1 / 3.0), channel(p, q, h), channel(p, q, h - 1 / 3.0))
    }
}
