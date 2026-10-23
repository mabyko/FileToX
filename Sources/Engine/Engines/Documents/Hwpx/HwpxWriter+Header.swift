// Port of HwpxWriter.Header.cs: definitions are allocated on demand, in encounter order.
import Foundation

extension HwpxWriter {
    static let charPrOrder = [
        "fontRef", "ratio", "spacing", "relSz", "offset", "italic", "bold", "underline", "strikeout", "outline",
        "shadow", "emboss", "engrave", "supscript", "subscript",
    ]
    static let lineWidths: [Double] = [0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1, 1.5, 2, 3, 4, 5]
    static let languages = ["HANGUL", "LATIN", "HANJA", "JAPANESE", "OTHER", "SYMBOL", "USER"]
    func refList(_ name: String) throws -> XElement {
        guard let node = head.descendants(Self.hh + name).first else {
            throw ConversionError("header.xml has no \(name).")
        }
        return node
    }
    func initializeHeader() throws {
        let hh = Self.hh
        maxCharPr = Self.maxId(head.descendants(hh + "charPr"))
        maxParaPr = Self.maxId(head.descendants(hh + "paraPr"))
        if head.descendants(hh + "numberings").isEmpty {
            let list = head.element(hh + "refList") ?? head
            let node = XElement(hh + "numberings", XAttribute("itemCnt", 0))
            if let p = list.element(hh + "paraProperties") { p.addBeforeSelf(node) } else { list.add(node) }
        }
        let styles = head.descendants(hh + "style")
        func ids(_ s: XElement) -> StyleIds {
            (
                s.attributeValue("id") ?? normal.style, s.attributeValue("paraPrIDRef") ?? normal.para,
                s.attributeValue("charPrIDRef") ?? normal.char
            )
        }
        if let s = styles.first(where: { $0.attributeValue("id") == "0" }) ?? styles.first { normal = ids(s) }
        for s in styles {
            let name = s.attributeValue("engName") ?? ""
            if name.lowercased().hasPrefix("heading "), let level = Int(name.dropFirst(8)), (1...9).contains(level) {
                headings[level] = ids(s)
            } else if name.lowercased().contains("footnote") {
                footnoteStyle = ids(s)
            }
        }
        if headings.isEmpty {
            for p in head.descendants(hh + "paraPr") {
                guard let h = p.element(hh + "heading"), h.attributeValue("type") == "OUTLINE",
                    let level = DocumentXML.int(h.attributeValue("level"))
                else { continue }
                if let s = styles.first(where: { $0.attributeValue("paraPrIDRef") == (p.attributeValue("id") ?? "0") }),
                    headings[level + 1] == nil
                {
                    headings[level + 1] = ids(s)
                }
            }
        }
    }
    func serializeHeader(_ count: Int) throws -> String {
        for (container, item) in [
            ("charProperties", "charPr"), ("paraProperties", "paraPr"), ("numberings", "numbering"),
            ("borderFills", "borderFill"), ("tabProperties", "tabPr"),
        ] {
            if let e = head.descendants(Self.hh + container).first {
                DocumentXML.set(e, "itemCnt", e.elements(Self.hh + item).count)
            }
        }
        DocumentXML.set(head, "secCnt", count)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + (try head.toString(indent: false))
    }
    func fontId(_ language: String, _ face: String) -> Int {
        let key = language + "\u{0}" + face
        if let id = fontIds[key] { return id }
        guard let list = head.descendants(Self.hh + "fontface").first(where: { $0.attributeValue("lang") == language })
        else { return 0 }
        let id: Int
        if let e = list.elements(Self.hh + "font").first(where: {
            $0.attributeValue("face")?.caseInsensitiveCompare(face) == .orderedSame
        }) {
            id = DocumentXML.int(e.attributeValue("id")) ?? 0
        } else {
            id = list.elements(Self.hh + "font").count
            list.add(
                XElement(
                    Self.hh + "font", XAttribute("id", id), XAttribute("face", face), XAttribute("type", "TTF"),
                    XAttribute("isEmbedded", 0)))
            DocumentXML.set(list, "fontCnt", id + 1)
        }
        fontIds[key] = id
        return id
    }
    func charPr(_ baseId: String, _ f: HCharFormat, _ isLink: Bool = false) throws -> String {
        let hh = Self.hh
        let link = isLink && f.color == nil
        if f.isEmpty && !link { return baseId }
        let key = CharKey(base: baseId, format: f, link: link)
        if let id = charPrCache[key] { return id }
        let list = head.descendants(hh + "charPr")
        guard let source = list.first(where: { $0.attributeValue("id") == baseId }) ?? list.first else { return baseId }
        let node = XElement(copying: source)
        maxCharPr += 1
        let id = String(maxCharPr)
        node.setAttributeValue("id", id)
        if let size = f.size { DocumentXML.set(node, "height", min(max(size, 100), 409600)) }
        if let color = f.color { node.setAttributeValue("textColor", color) }
        if link { node.setAttributeValue("textColor", "#0000FF") }
        if let shade = f.shade { node.setAttributeValue("shadeColor", shade) }
        if f.font != nil || f.eastAsianFont != nil {
            let ref = Self.ensureChild(node, "fontRef")
            for language in Self.languages {
                let east = ["HANGUL", "HANJA", "JAPANESE"].contains(language)
                if let face = east ? f.eastAsianFont ?? f.font : f.font ?? f.eastAsianFont {
                    DocumentXML.set(ref, XName(language.lowercased()), fontId(language, face))
                }
            }
        }
        if let spacing = f.spacing {
            let e = Self.ensureChild(node, "spacing")
            for l in Self.languages { DocumentXML.set(e, XName(l.lowercased()), spacing) }
        }
        Self.setFlag(node, "bold", f.bold)
        Self.setFlag(node, "italic", f.italic)
        if f.underline != nil || link {
            let e = Self.ensureChild(node, "underline")
            e.setAttributeValue("type", link || f.underline == true ? "BOTTOM" : "NONE")
            e.setAttributeValue("shape", "SOLID")
            e.setAttributeValue("color", link ? "#0000FF" : f.color ?? "#000000")
        }
        if let strike = f.strike {
            let e = Self.ensureChild(node, "strikeout")
            e.setAttributeValue("shape", strike ? "SOLID" : "NONE")
            e.setAttributeValue("color", f.color ?? "#000000")
        }
        if f.superscript == true {
            node.element(hh + "subscript")?.remove()
            _ = Self.ensureChild(node, "supscript")
        } else if f.subscript == true {
            node.element(hh + "supscript")?.remove()
            _ = Self.ensureChild(node, "subscript")
        } else if f.superscript == false || f.subscript == false {
            node.element(hh + "supscript")?.remove()
            node.element(hh + "subscript")?.remove()
        }
        try refList("charProperties").add(node)
        charPrCache[key] = id
        return id
    }
    static func setFlag(_ node: XElement, _ name: String, _ flag: Bool?) {
        if flag == true { _ = ensureChild(node, name) } else if flag == false { node.element(hh + name)?.remove() }
    }
    @discardableResult static func ensureChild(_ node: XElement, _ name: String) -> XElement {
        if let e = node.element(hh + name) { return e }
        let e = XElement(hh + name)
        let rank = charPrOrder.firstIndex(of: name) ?? -1
        if let after = node.elements().last(where: {
            let r = charPrOrder.firstIndex(of: $0.name.localName) ?? -1
            return r >= 0 && r < rank
        }) {
            after.addAfterSelf(e)
        } else {
            node.addFirst(e)
        }
        return e
    }
    func paraPr(_ baseId: String, _ f: HParaFormat, _ list: HListRef?) throws -> String {
        let hh = Self.hh
        let numbering = try list.map { try numberingId($0.numbering) }
        let key = ParaKey(
            base: baseId, format: f, numbering: numbering, level: list?.level ?? 0, numbered: list?.numbered ?? false)
        if f.isEmpty && list == nil { return baseId }
        if let id = paraPrCache[key] { return id }
        let choices = head.descendants(hh + "paraPr")
        guard let source = choices.first(where: { $0.attributeValue("id") == baseId }) ?? choices.first else {
            throw ConversionError("header.xml has no paraPr.")
        }
        let node = XElement(copying: source)
        maxParaPr += 1
        let id = String(maxParaPr)
        node.setAttributeValue("id", id)
        if let align = f.align {
            let e =
                node.element(hh + "align")
                ?? Self.addFirst(node, XElement(hh + "align", XAttribute("vertical", "BASELINE")))
            e.setAttributeValue("horizontal", Self.align(align))
        }
        if let list {
            let e: XElement
            if let existing = node.element(hh + "heading") {
                e = existing
            } else {
                e = XElement(hh + "heading")
                if let a = node.element(hh + "align") { a.addAfterSelf(e) } else { node.addFirst(e) }
            }
            e.setAttributeValue("type", list.numbered ? "NUMBER" : "NONE")
            e.setAttributeValue("idRef", list.numbered ? numbering : "0")
            DocumentXML.set(e, "level", list.numbered ? list.level : 0)
        }
        if let e = node.element(hh + "breakSetting") {
            for (name, value) in [
                ("keepWithNext", f.keepWithNext), ("keepLines", f.keepLines), ("widowOrphan", f.widowOrphan),
            ] { if let value { DocumentXML.set(e, XName(name), value ? 1 : 0) } }
        }
        var left = f.left
        var first = f.firstLine
        if let list, left == nil {
            left = (list.level + 1) * 2000
            if first == nil { first = list.numbered ? -2000 : 0 }
        }
        Self.setSpacing(node, left, f.right, first, f.before, f.after, f.lineSpacing)
        if let tabs = f.tabs, !tabs.isEmpty { node.setAttributeValue("tabPrIDRef", try tabPrId(tabs)) }
        try refList("paraProperties").add(node)
        paraPrCache[key] = id
        return id
    }
    static func align(_ value: HAlign) -> String {
        switch value {
        case .left: return "LEFT"
        case .center: return "CENTER"
        case .right: return "RIGHT"
        case .justify: return "JUSTIFY"
        case .distribute: return "DISTRIBUTE"
        }
    }
    static func addFirst(_ parent: XElement, _ child: XElement) -> XElement {
        parent.addFirst(child)
        return child
    }
    static func setSpacing(
        _ p: XElement, _ left: Int?, _ right: Int?, _ first: Int?, _ before: Int?, _ after: Int?, _ ls: HLineSpacing?
    ) {
        let existing = p.descendants(hp + "case").first
        func current(_ name: String) -> Int {
            DocumentXML.int(existing?.descendants(hc + name).first?.attributeValue("value")) ?? 0
        }
        let line = existing?.element(hh + "lineSpacing") ?? p.descendants(hh + "lineSpacing").first
        var hwpLeft = left ?? current("left")
        if left != nil, let first, first < 0 { hwpLeft += first }
        let values = [
            ("intent", first ?? current("intent")), ("left", hwpLeft), ("right", right ?? current("right")),
            ("prev", before ?? current("prev")), ("next", after ?? current("next")),
        ]
        let type =
            ls.map { $0.kind == .fixed ? "FIXED" : $0.kind == .atLeast ? "AT_LEAST" : "PERCENT" } ?? line?
            .attributeValue("type") ?? "PERCENT"
        let value = ls?.value ?? DocumentXML.int(line?.attributeValue("value")) ?? 160
        func branch(_ name: XName, _ factor: Int) -> XElement {
            XElement(
                name,
                XElement(
                    hh + "margin",
                    values.map {
                        XElement(hc + $0.0, XAttribute("value", $0.1 * factor), XAttribute("unit", "HWPUNIT"))
                    }),
                XElement(
                    hh + "lineSpacing", XAttribute("type", type),
                    XAttribute("value", type == "PERCENT" ? value : value * factor), XAttribute("unit", "HWPUNIT")))
        }
        let c = branch(hp + "case", 1)
        c.setAttributeValue(hp + "required-namespace", hwpUnitCharNamespace)
        let sw = XElement(hp + "switch", c, branch(hp + "default", 2))
        for e in p.elements(hp + "switch") + p.elements(hh + "margin") + p.elements(hh + "lineSpacing") { e.remove() }
        if let a = p.element(hh + "autoSpacing") ?? p.element(hh + "breakSetting") ?? p.element(hh + "heading")
            ?? p.element(hh + "align")
        {
            a.addAfterSelf(sw)
        } else {
            p.addFirst(sw)
        }
    }
    func numberingId(_ numbering: HNumbering) throws -> String {
        let key = ObjectIdentifier(numbering)
        if let id = numberingIds[key] { return id }
        let c = try refList("numberings")
        let id = String(Self.maxId(c.elements(Self.hh + "numbering")) + 1)
        let e = XElement(
            Self.hh + "numbering", XAttribute("id", id), XAttribute("start", numbering.levels.first?.start ?? 1))
        for (i, l) in numbering.levels.prefix(10).enumerated() {
            e.add(
                XElement(
                    Self.hh + "paraHead", XAttribute("start", l.start), XAttribute("level", i + 1),
                    XAttribute("align", "LEFT"), XAttribute("useInstWidth", 1), XAttribute("autoIndent", 0),
                    XAttribute("widthAdjust", 0), XAttribute("textOffsetType", "PERCENT"), XAttribute("textOffset", 50),
                    XAttribute("numFormat", l.format), XAttribute("charPrIDRef", "4294967295"),
                    XAttribute("checkable", 0), l.text))
        }
        c.add(e)
        numberingIds[key] = id
        return id
    }
    func borderFillId(_ borders: HBorders, _ fill: String?) throws -> String {
        let key = BorderKey(borders: borders, fill: fill)
        if let id = borderFills[key] { return id }
        let hh = Self.hh
        let hc = Self.hc
        let c = try refList("borderFills")
        let id = String(Self.maxId(c.elements(Self.hh + "borderFill")) + 1)
        func line(_ name: String, _ b: HBorder) -> XElement {
            XElement(
                hh + name, XAttribute("type", Self.lineType(b.style)), XAttribute("width", Self.lineWidth(b.widthMm)),
                XAttribute("color", b.color))
        }
        let e = XElement(
            hh + "borderFill", XAttribute("id", id), XAttribute("threeD", 0), XAttribute("shadow", 0),
            XAttribute("centerLine", "NONE"), XAttribute("breakCellSeparateLine", 0),
            XElement(hh + "slash", XAttribute("type", "NONE"), XAttribute("Crooked", 0), XAttribute("isCounter", 0)),
            XElement(
                hh + "backSlash", XAttribute("type", "NONE"), XAttribute("Crooked", 0), XAttribute("isCounter", 0)),
            line("leftBorder", borders.left), line("rightBorder", borders.right), line("topBorder", borders.top),
            line("bottomBorder", borders.bottom),
            XElement(
                hh + "diagonal", XAttribute("type", "SOLID"), XAttribute("width", "0.1 mm"),
                XAttribute("color", "#000000")),
            XElement(
                hc + "fillBrush",
                XElement(
                    hc + "winBrush", XAttribute("faceColor", fill ?? "none"), XAttribute("hatchColor", "#000000"),
                    XAttribute("alpha", 0))))
        c.add(e)
        borderFills[key] = id
        return id
    }
    static func lineType(_ s: HBorderStyle) -> String {
        switch s {
        case .none: return "NONE"
        case .dash: return "DASH"
        case .dot: return "DOT"
        case .dashDot: return "DASH_DOT"
        case .double: return "DOUBLE_SLIM"
        default: return "SOLID"
        }
    }
    static func lineWidth(_ mm: Double) -> String {
        let v = lineWidths.enumerated().min { a, b in
            let x = abs(a.element - mm)
            let y = abs(b.element - mm)
            return x == y ? a.offset < b.offset : x < y
        }!.element
        return (v >= 1 ? String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v) : String(v)) + " mm"
    }
    func tabPrId(_ tabs: [HTabStop]) throws -> String {
        let key = tabs.map { "\($0.position),\($0.kind),\($0.leader)" }.joined(separator: ";")
        if let id = tabPrIds[key] { return id }
        let c = try refList("tabProperties")
        let id = String(Self.maxId(c.elements(Self.hh + "tabPr")) + 1)
        let hh = Self.hh
        let hp = Self.hp
        let e = XElement(
            hh + "tabPr", XAttribute("id", id), XAttribute("autoTabLeft", 0), XAttribute("autoTabRight", 0))
        for tab in tabs {
            let type =
                tab.kind == .right
                ? "RIGHT" : tab.kind == .center ? "CENTER" : tab.kind == .decimal ? "DECIMAL" : "LEFT"
            e.add(
                XElement(
                    hp + "switch",
                    XElement(
                        hp + "case", XAttribute(hp + "required-namespace", Self.hwpUnitCharNamespace),
                        XElement(
                            hh + "tabItem", XAttribute("pos", tab.position), XAttribute("type", type),
                            XAttribute("leader", tab.leader), XAttribute("unit", "HWPUNIT"))),
                    XElement(
                        hp + "default",
                        XElement(
                            hh + "tabItem", XAttribute("pos", tab.position * 2), XAttribute("type", type),
                            XAttribute("leader", tab.leader)))))
        }
        c.add(e)
        tabPrIds[key] = id
        return id
    }
}
