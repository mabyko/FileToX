// Port of DocxWriter.Objects.cs.
import Foundation

extension DocxWriter {
    func mediaTarget(_ path: String) -> String? {
        if let m = media.first(where: { $0.source.caseInsensitiveCompare(path) == .orderedSame }) {
            return String(m.path.dropFirst(5))
        }
        var ext = FilePath.extension(path).lowercased().dropFirst().description
        if ext == "jpeg" { ext = "jpg" }
        if Self.pictureTypes[ext] == nil {
            if ImageSupport.info(path) == nil { return nil }
            ext = "png"
        }
        let zip = "word/media/image\(media.count+1).\(ext)"
        media.append((path, zip, ext))
        return String(zip.dropFirst(5))
    }
    func picture(_ image: HImage) -> String {
        guard FileManager.default.fileExists(image.path), let target = mediaTarget(image.path) else { return "" }
        var w0 = image.width
        var h0 = image.height
        if w0 == nil || h0 == nil, let info = ImageSupport.info(image.path), info.width > 0 && info.height > 0 {
            let pw = Double(info.width)
            let ph = Double(info.height)
            if w0 == nil && h0 == nil {
                w0 = Int(pw * 75)
                h0 = Int(ph * 75)
            } else if let w0 {
                h0 = Int(Double(w0) * ph / pw)
            } else if let h0 {
                w0 = Int(Double(h0) * pw / ph)
            }
        }
        var w = max(1, w0 ?? 8504)
        var h = max(1, h0 ?? max(1, w0 ?? 8504))
        if image.anchor == nil && w > width {
            h = h * width / w
            w = width
        }
        let rel = part.relate(Self.relationshipBase + "image", target)
        let id = nextDrawingId
        nextDrawingId += 1
        let name = "Picture \(id)"
        let graphic =
            "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rel)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(Self.emu(w))\" cy=\"\(Self.emu(h))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>"
        return "<w:r><w:drawing>"
            + frame(image.anchor, w, h, id, name, graphic, "<a:graphicFrameLocks noChangeAspect=\"1\"/>")
            + "</w:drawing></w:r>"
    }
    func frame(
        _ anchor: HAnchor?, _ w: Int, _ h: Int, _ id: Int, _ name: String, _ graphic: String, _ locks: String = ""
    ) -> String {
        let extent =
            "<wp:extent cx=\"\(Self.emu(w))\" cy=\"\(Self.emu(h))\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
        let docPr = "<wp:docPr id=\"\(id)\" name=\"\(name)\"/><wp:cNvGraphicFramePr>\(locks)</wp:cNvGraphicFramePr>"
        guard let a = anchor else {
            return "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">\(extent)\(docPr)\(graphic)</wp:inline>"
        }
        let wrap =
            a.wrap == "SQUARE"
            ? "<wp:wrapSquare wrapText=\"bothSides\"/>"
            : a.wrap == "TOP_AND_BOTTOM" ? "<wp:wrapTopAndBottom/>" : "<wp:wrapNone/>"
        let horizontal = Self.position(
            "positionH", ["PAPER": "page", "PAGE": "margin", "PARA": "character"][a.horizontalRelativeTo] ?? "column",
            a.horizontalAlign, a.horizontalOffset, "LEFT")
        let vertical = Self.position(
            "positionV", ["PAPER": "page", "PAGE": "margin"][a.verticalRelativeTo] ?? "paragraph", a.verticalAlign,
            a.verticalOffset, "TOP")
        let height = relativeHeight
        relativeHeight += 1
        return
            "<wp:anchor distT=\"0\" distB=\"0\" distL=\"114300\" distR=\"114300\" simplePos=\"0\" relativeHeight=\"\(height)\" behindDoc=\"\(a.wrap == "BEHIND_TEXT" ? 1 : 0)\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"\(a.allowOverlap ? 1 : 0)\"><wp:simplePos x=\"0\" y=\"0\"/>\(horizontal)\(vertical)\(extent)\(wrap)\(docPr)\(graphic)</wp:anchor>"
    }
    static func position(_ element: String, _ relative: String, _ align: String, _ offset: Int, _ start: String)
        -> String
    {
        let content =
            offset == 0 && align != start && ["CENTER", "RIGHT", "BOTTOM", "INSIDE", "OUTSIDE"].contains(align)
            ? "<wp:align>\(align.lowercased())</wp:align>" : "<wp:posOffset>\(emu(offset))</wp:posOffset>"
        return "<wp:\(element) relativeFrom=\"\(relative)\">\(content)</wp:\(element)>"
    }
    func textBox(_ box: HTextBox, _ context: RunContext) throws -> String {
        if textBoxDepth > 0 {
            return try box.blocks.compactMap { $0 as? HParagraph }.map {
                try inlines($0.inlines.filter { $0 is HText || $0 is HLineBreak || $0 is HTab }, context)
            }.joined()
        }
        let w = max(1, box.width)
        let h = max(1, box.height)
        let outer = width
        width = max(1000, w - box.padding.left - box.padding.right)
        textBoxDepth += 1
        let content: String
        do { content = try blocks(box.blocks, nil, true) } catch {
            textBoxDepth -= 1
            width = outer
            throw error
        }
        textBoxDepth -= 1
        width = outer
        let geometry = box.shape == .ellipse ? "ellipse" : box.cornerRatio > 0 ? "roundRect" : "rect"
        let anchor = box.verticalAlign == .center ? "ctr" : box.verticalAlign == .bottom ? "b" : "t"
        let shape =
            "<wps:wsp><wps:cNvSpPr txBox=\"1\"/>"
            + Self.shapeProperties(w, h, geometry, box.cornerRatio, box.fill, box.gradient, box.line, false, false)
            + "<wps:txbx><w:txbxContent>\(content)</w:txbxContent></wps:txbx><wps:bodyPr rot=\"0\" vert=\"horz\" wrap=\"square\" lIns=\"\(Self.emu(box.padding.left))\" tIns=\"\(Self.emu(box.padding.top))\" rIns=\"\(Self.emu(box.padding.right))\" bIns=\"\(Self.emu(box.padding.bottom))\" anchor=\"\(anchor)\" anchorCtr=\"0\"><a:noAutofit/></wps:bodyPr></wps:wsp>"
        return drawingRun(box.anchor, w, h, "Text Box", shape)
    }
    func shapeXml(_ s: HShape) -> String {
        let w = max(1, s.width)
        let h = max(1, s.height)
        let geometry =
            s.kind == .ellipse ? "ellipse" : s.kind == .line ? "line" : s.cornerRatio > 0 ? "roundRect" : "rect"
        let line = s.kind == .line
        let xml =
            "<wps:wsp><wps:cNvSpPr/>"
            + Self.shapeProperties(
                w, h, geometry, s.cornerRatio, line ? nil : s.fill, line ? nil : s.gradient, s.line, s.flipHorizontal,
                s.flipVertical) + "<wps:bodyPr/></wps:wsp>"
        return drawingRun(s.anchor, w, h, "Shape", xml)
    }
    func drawingRun(_ a: HAnchor?, _ w: Int, _ h: Int, _ kind: String, _ shape: String) -> String {
        let id = nextDrawingId
        nextDrawingId += 1
        let graphic =
            "<a:graphic><a:graphicData uri=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\">\(shape)</a:graphicData></a:graphic>"
        return "<w:r><mc:AlternateContent><mc:Choice Requires=\"wps\"><w:drawing>"
            + frame(a, w, h, id, "\(kind) \(id)", graphic) + "</w:drawing></mc:Choice></mc:AlternateContent></w:r>"
    }
    static func shapeProperties(
        _ w: Int, _ h: Int, _ geometry: String, _ ratio: Int, _ fill: String?, _ gradient: HGradient?, _ line: HBorder,
        _ flipH: Bool, _ flipV: Bool
    ) -> String {
        var s =
            "<wps:spPr><a:xfrm\(flipH ? " flipH=\"1\"" : "")\(flipV ? " flipV=\"1\"" : "")><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(emu(w))\" cy=\"\(emu(h))\"/></a:xfrm>"
        s +=
            geometry == "roundRect"
            ? "<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val \(min(max(ratio,0),50)*1000)\"/></a:avLst></a:prstGeom>"
            : "<a:prstGeom prst=\"\(geometry)\"><a:avLst/></a:prstGeom>"
        if let g = gradient, g.colors.count >= 2 {
            s += "<a:gradFill rotWithShape=\"1\"><a:gsLst>"
            for (i, c) in g.colors.enumerated() {
                let pos = Int((100000.0 * Double(i) / Double(g.colors.count - 1)).rounded(.toNearestOrEven))
                s += "<a:gs pos=\"\(pos)\"><a:srgbClr val=\"\(hex(c) ?? "FFFFFF")\"/></a:gs>"
            }
            s += "</a:gsLst><a:lin ang=\"\(((g.angle%360+360)%360)*60000)\" scaled=\"0\"/></a:gradFill>"
        } else if let solid = hex(fill) {
            s += "<a:solidFill><a:srgbClr val=\"\(solid)\"/></a:solidFill>"
        } else if geometry != "line" {
            s += "<a:noFill/>"
        }
        if line.style == .none {
            s += "<a:ln><a:noFill/></a:ln>"
        } else {
            let dash =
                line.style == .dash
                ? "<a:prstDash val=\"dash\"/>"
                : line.style == .dot
                    ? "<a:prstDash val=\"sysDot\"/>" : line.style == .dashDot ? "<a:prstDash val=\"dashDot\"/>" : ""
            let n = max(3175, Int((line.widthMm * 36000).rounded(.toNearestOrEven)))
            s +=
                "<a:ln w=\"\(n)\"\(line.style == .double ? " cmpd=\"dbl\"" : "")><a:solidFill><a:srgbClr val=\"\(hex(line.color) ?? "000000")\"/></a:solidFill>\(dash)</a:ln>"
        }
        return s + "</wps:spPr>"
    }
    func hyperlink(_ link: HLink, _ c: RunContext) throws -> String {
        let content = try inlines(link.content, RunContext(styleBold: c.styleBold, link: true))
        if content.isEmpty { return "" }
        if link.target.hasPrefix("#") {
            return
                "<w:hyperlink w:anchor=\"\(Self.escape(bookmarkName(String(link.target.dropFirst()))))\" w:history=\"1\">\(content)</w:hyperlink>"
        }
        if !link.target.isEmpty {
            let id = part.relate(Self.relationshipBase + "hyperlink", Self.safeUri(link.target), true)
            return "<w:hyperlink r:id=\"\(id)\" w:history=\"1\">\(content)</w:hyperlink>"
        }
        return content
    }
    static func safeUri(_ target: String) -> String {
        if let url = URL(string: target), let scheme = url.scheme, !url.isFileURL {
            guard var components = URLComponents(url: url.standardized, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }
            components.scheme = scheme.lowercased()
            components.host = components.host?.lowercased()
            let defaultPorts = [
                "http": 80, "https": 443, "ftp": 21, "ws": 80, "wss": 443, "gopher": 70, "nntp": 119, "telnet": 23,
            ]
            if let port = components.port, port == defaultPorts[scheme.lowercased()] { components.port = nil }
            if components.host != nil && components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
            return components.string ?? url.absoluteString
        }
        return target.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: " ", with: "%20")
    }

    func bookmarkName(_ name: String) -> String {
        if let n = bookmarks[name] { return n }
        var clean = name.utf16.map {
            DocumentXML.isLetter($0) || DocumentXML.isDigit($0) || $0 == 95 ? String(UnicodeScalar($0)!) : "_"
        }.joined()
        if clean.isEmpty || !clean.utf16.first.map(DocumentXML.isLetter)! { clean = "b" + clean }
        let base = String(decoding: clean.utf16.prefix(36), as: UTF16.self)
        var result = base
        var i = 2
        while !bookmarkNames.insert(result.lowercased()).inserted {
            result = base + String(i)
            i += 1
        }
        bookmarks[name] = result
        return result
    }
}
