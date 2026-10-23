// Port of Filee.Engines/Office/OoxmlConverter.cs: keep the package, remove macros for macro-free targets.
import Foundation

final class OoxmlConverter: Converter {
    private static let ct = XNamespace("http://schemas.openxmlformats.org/package/2006/content-types")
    private static let rel = XNamespace("http://schemas.openxmlformats.org/package/2006/relationships")
    private static let r = XNamespace("http://schemas.openxmlformats.org/officeDocument/2006/relationships")
    private static let s = XNamespace("http://schemas.openxmlformats.org/spreadsheetml/2006/main")
    struct Variant {
        let family: String
        let contentType: String
        let macros: Bool
    }
    static let variantOrder = ["docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "pptx", "pptm", "potx", "ppsx"]
    static let variants: [String: Variant] = [
        "docx": Variant(
            family: "word",
            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
            macros: false),
        "docm": Variant(
            family: "word", contentType: "application/vnd.ms-word.document.macroEnabled.main+xml", macros: true),
        "dotx": Variant(
            family: "word",
            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml",
            macros: false),
        "dotm": Variant(
            family: "word", contentType: "application/vnd.ms-word.template.macroEnabledTemplate.main+xml", macros: true),
        "xlsx": Variant(
            family: "excel", contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
            macros: false),
        "xlsm": Variant(
            family: "excel", contentType: "application/vnd.ms-excel.sheet.macroEnabled.main+xml", macros: true),
        "xltx": Variant(
            family: "excel",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.template.main+xml", macros: false),
        "pptx": Variant(
            family: "powerpoint",
            contentType: "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
            macros: false),
        "pptm": Variant(
            family: "powerpoint", contentType: "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml",
            macros: true),
        "potx": Variant(
            family: "powerpoint",
            contentType: "application/vnd.openxmlformats-officedocument.presentationml.template.main+xml", macros: false
        ),
        "ppsx": Variant(
            family: "powerpoint",
            contentType: "application/vnd.openxmlformats-officedocument.presentationml.slideshow.main+xml",
            macros: false),
    ]
    static let macroContentTypes = Set(
        [
            "application/vnd.ms-office.vbaProject", "application/vnd.ms-office.vbaProjectSignature",
            "application/vnd.ms-office.vbaProjectSignatureAgile", "application/vnd.ms-office.vbaProjectSignatureV3",
            "application/vnd.ms-word.vbaData+xml", "application/vnd.ms-word.keyMapCustomizations+xml",
            "application/vnd.ms-excel.macrosheet+xml", "application/vnd.ms-excel.intlmacrosheet+xml",
        ].map { $0.lowercased() })
    let id = "ooxml", displayName = "Office Open XML (built-in)", maxParallelism = 0
    let edges = variantOrder.flatMap { source in
        variantOrder.filter { $0 != source && variants[$0]?.family == variants[source]?.family }.map {
            ConversionEdge(source, $0)
        }
    }
    func status() -> EngineStatus {
        .available(
            detail: "DOCM, DOTX, DOTM ↔ DOCX; XLSM, XLTX ↔ XLSX; PPTM, POTX, PPSX ↔ PPTX",
            version: EngineVersions.builtIn)
    }
    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        try Task.checkCancellation()
        progress?(0.1)
        guard let output = try step.output.allocate(step.to) else { return [] }
        let temp = output + ".tmp"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try Self.rewrite(step.inputPath, temp, step.to)
        if FileManager.default.fileExists(output) { try FileManager.default.removeItem(atPath: output) }
        try FileManager.default.moveItem(atPath: temp, toPath: output)
        progress?(1)
        return [output]
    }
    static func rewrite(_ input: String, _ output: String, _ to: String) throws {
        guard let target = variants[to.lowercased()] else {
            throw ConversionError("Unknown Office Open XML variant: \(to)")
        }
        let source = try ZipReader(path: input)
        func load(_ name: String) throws -> XDocument? {
            try source.data(named: name).map { try XDocument.load(data: $0) }
        }
        guard let types = try load("[Content_Types].xml") else {
            throw ConversionError("The file is not an Office Open XML package (no [Content_Types].xml).")
        }
        let root = types.root
        guard
            let main = try load("_rels/.rels")?.root.elements(rel + "Relationship").first(where: {
                $0.attributeValue("Type")?.hasSuffix("/officeDocument") == true
            })?.attributeValue("Target").map({ String($0.drop(while: { $0 == "/" })) })
        else { throw ConversionError("The package has no main document part.") }
        let mainOverride: XElement
        if let existing = root.elements(ct + "Override").first(where: {
            String(($0.attributeValue("PartName") ?? "").drop(while: { $0 == "/" })).caseInsensitiveCompare(main)
                == .orderedSame
        }) {
            mainOverride = existing
        } else {
            mainOverride = XElement(ct + "Override", XAttribute("PartName", "/" + main))
            root.add(mainOverride)
        }
        mainOverride.setAttributeValue("ContentType", target.contentType)
        var removed = Set<String>()
        if !target.macros {
            for entry in source.entries {
                if let type = contentTypeOf(root, entry.name), macroContentTypes.contains(type.lowercased()) {
                    removed.insert(entry.name.lowercased())
                }
            }
            for part in Array(removed) { removed.insert(relationshipsPartOf(part).lowercased()) }
            for el in root.elements(ct + "Override")
            where removed.contains(
                String((el.attributeValue("PartName") ?? "").drop(while: { $0 == "/" })).lowercased())
            { el.remove() }
            for el in root.elements(ct + "Default")
            where macroContentTypes.contains((el.attributeValue("ContentType") ?? "").lowercased()) { el.remove() }
        }
        // Collect first so workbook cleanup is independent of ZIP entry order (Filee performs a second ZIP pass).
        var replacements: [String: Data] = [:]
        var removedIds: [String: Set<String>] = [:]
        for entry in source.entries
        where !removed.isEmpty && entry.name.lowercased().hasSuffix(".rels")
            && !removed.contains(entry.name.lowercased())
        {
            guard let rels = try load(entry.name) else { continue }
            let owner = ownerOf(entry.name)
            let dropped = rels.root.elements(rel + "Relationship").filter {
                $0.attributeValue("TargetMode") != "External"
                    && removed.contains(resolve(owner, $0.attributeValue("Target") ?? "").lowercased())
            }
            if !dropped.isEmpty { removedIds[owner.lowercased()] = Set(dropped.map { $0.attributeValue("Id") ?? "" }) }
            for el in dropped { el.remove() }
            replacements[entry.name] = try xmlBytes(rels)
        }
        replacements["[Content_Types].xml"] = try xmlBytes(types)
        var updatedWorkbook: (String, Data)?
        if target.family == "excel", let ids = removedIds[main.lowercased()], !ids.isEmpty,
            let workbook = try load(main)
        {
            removeSheets(workbook, ids)
            updatedWorkbook = (main, try xmlBytes(workbook))
        }
        let zip = try ZipWriter(path: output)
        for entry in source.entries where !removed.contains(entry.name.lowercased()) && !entry.isDirectory {
            try Task.checkCancellation()
            if entry.name == updatedWorkbook?.0 { continue }  // .NET ZipArchive.Update appends the replaced workbook.
            try zip.add(entry.name, data: try replacements[entry.name] ?? source.data(for: entry))
        }
        if let (name, data) = updatedWorkbook { try zip.add(name, data: data) }
        try zip.close()
    }
    // XDocument.Save(Stream) uses UTF-8 with a BOM; the shared XML writer intentionally has no BOM.
    private static func xmlBytes(_ document: XDocument) throws -> Data {
        try Data([0xef, 0xbb, 0xbf]) + document.data(indent: false)
    }
    private static func removeSheets(_ workbook: XDocument, _ ids: Set<String>) {
        let sheets = workbook.root.element(s + "sheets")?.elements(s + "sheet") ?? []
        var kept: [Int] = []
        for (i, sheet) in sheets.enumerated() {
            if ids.contains(sheet.attributeValue(r + "id") ?? "") { sheet.remove() } else { kept.append(i) }
        }
        for name in workbook.root.element(s + "definedNames")?.elements(s + "definedName") ?? [] {
            guard let local = SheetXML.int(name.attributeValue("localSheetId")) else { continue }
            if let i = kept.firstIndex(of: local) {
                name.setAttributeValue("localSheetId", String(i))
            } else {
                name.remove()
            }
        }
        for view in workbook.root.descendants(s + "workbookView") {
            view.setAttributeValue("activeTab", nil)
            view.setAttributeValue("firstSheet", nil)
        }
    }
    private static func contentTypeOf(_ types: XElement, _ part: String) -> String? {
        if let over = types.elements(ct + "Override").first(where: {
            ($0.attributeValue("PartName") ?? "").caseInsensitiveCompare("/" + part) == .orderedSame
        }) {
            return over.attributeValue("ContentType")
        }
        let ext = String(FilePath.extension(part).dropFirst())
        return types.elements(ct + "Default").first {
            ($0.attributeValue("Extension") ?? "").caseInsensitiveCompare(ext) == .orderedSame
        }?.attributeValue("ContentType")
    }
    private static func relationshipsPartOf(_ part: String) -> String {
        guard let slash = part.lastIndex(of: "/") else { return "_rels/\(part).rels" }
        return String(part[..<slash]) + "/_rels/" + part[part.index(after: slash)...] + ".rels"
    }
    private static func ownerOf(_ path: String) -> String {
        guard let range = path.range(of: "_rels/") else { return "" }
        return String(path[..<range.lowerBound]) + FilePath.fileName(path).dropLast(5)
    }
    private static func resolve(_ owner: String, _ target: String) -> String {
        if target.hasPrefix("/") { return String(target.drop(while: { $0 == "/" })) }
        var parts = owner.split(separator: "/").dropLast().map(String.init)
        for s in (target.removingPercentEncoding ?? target).split(separator: "/") {
            if s == ".." { if !parts.isEmpty { parts.removeLast() } } else if s != "." { parts.append(String(s)) }
        }
        return parts.joined(separator: "/")
    }
}
