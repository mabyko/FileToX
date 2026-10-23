// Port of HwpxWriter.Objects.cs; XML literals retain Filee's attribute and child order.
import Foundation

extension HwpxWriter {
    static let hyperlinkFieldId = "627600491"
    static let identityRendering =
        "<hp:renderingInfo><hc:transMatrix e1=\"1\" e2=\"0\" e3=\"0\" e4=\"0\" e5=\"1\" e6=\"0\"/><hc:scaMatrix e1=\"1\" e2=\"0\" e3=\"0\" e4=\"0\" e5=\"1\" e6=\"0\"/><hc:rotMatrix e1=\"1\" e2=\"0\" e3=\"0\" e4=\"0\" e5=\"1\" e6=\"0\"/></hp:renderingInfo>"
    func picture(_ image: HImage) -> String? {
        guard FileManager.default.fileExists(image.path) else { return nil }
        var w0 = image.width
        var h0 = image.height
        if w0 == nil || h0 == nil, let info = ImageSupport.info(image.path), info.width > 0 && info.height > 0 {
            let pw = Double(info.width)
            let ph = Double(info.height)
            if w0 == nil && h0 == nil {
                w0 = Int(pw * HwpxUnits.perPixel)
                h0 = Int(ph * HwpxUnits.perPixel)
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
        var ext = FilePath.extension(image.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if ext == "jpeg" || ext == "jpe" { ext = "jpg" }
        let existing = images.firstIndex { $0.path == image.path }
        let binaryId = existing.map { images[$0].id } ?? "image\(images.count + 1)"
        if existing == nil { images.append((binaryId, image.path, ext)) }
        let id = nextId()
        let wrap = image.anchor?.wrap ?? "TOP_AND_BOTTOM"
        return
            "<hp:pic id=\"\(id)\" zOrder=\"\(nextZ())\" numberingType=\"\((image.anchor == nil ? "NONE" : "PICTURE"))\" textWrap=\"\(wrap)\" textFlow=\"BOTH_SIDES\" lock=\"0\" dropcapstyle=\"None\" href=\"\" groupLevel=\"0\" instid=\"\(id)\" reverse=\"0\">"
            + "<hp:offset x=\"0\" y=\"0\"/>"
            + "<hp:orgSz width=\"\(w)\" height=\"\(h)\"/><hp:curSz width=\"\(w)\" height=\"\(h)\"/>"
            + "<hp:flip horizontal=\"0\" vertical=\"0\"/>"
            + "<hp:rotationInfo angle=\"0\" centerX=\"\(w / 2)\" centerY=\"\(h / 2)\" rotateimage=\"1\"/>"
            + Self.identityRendering
            + "<hc:img binaryItemIDRef=\"\(binaryId)\" bright=\"0\" contrast=\"0\" effect=\"REAL_PIC\" alpha=\"0\"/>"
            + "<hp:imgRect><hc:pt0 x=\"0\" y=\"0\"/><hc:pt1 x=\"\(w)\" y=\"0\"/><hc:pt2 x=\"\(w)\" y=\"\(h)\"/><hc:pt3 x=\"0\" y=\"\(h)\"/></hp:imgRect>"
            + "<hp:imgClip left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/><hp:inMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/>"
            + "<hp:imgDim dimwidth=\"0\" dimheight=\"0\"/><hp:effects/>"
            + "<hp:sz width=\"\(w)\" widthRelTo=\"ABSOLUTE\" height=\"\(h)\" heightRelTo=\"ABSOLUTE\" protect=\"0\"/>"
            + position(image.anchor) + "<hp:outMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/><hp:shapeComment/>"
            + "</hp:pic>"
    }
    func position(_ value: HAnchor?) -> String {
        guard let value else {
            return
                "<hp:pos treatAsChar=\"1\" affectLSpacing=\"0\" flowWithText=\"1\" allowOverlap=\"1\" holdAnchorAndSO=\"0\" vertRelTo=\"PARA\" horzRelTo=\"COLUMN\" vertAlign=\"TOP\" horzAlign=\"LEFT\" vertOffset=\"0\" horzOffset=\"0\"/>"
        }
        let anchor = nonNegative(value)
        let flowWithText = anchorFlow(value)
        return
            "<hp:pos treatAsChar=\"0\" affectLSpacing=\"0\" flowWithText=\"\(flowWithText)\" allowOverlap=\"\((anchor.allowOverlap ? 1 : 0))\" holdAnchorAndSO=\"0\" "
            + "vertRelTo=\"\(anchor.verticalRelativeTo)\" horzRelTo=\"\(anchor.horizontalRelativeTo)\" vertAlign=\"\(anchor.verticalAlign)\" horzAlign=\"\(anchor.horizontalAlign)\" "
            + "vertOffset=\"\(anchor.verticalOffset)\" horzOffset=\"\(anchor.horizontalOffset)\"/>"
    }
    private func anchorFlow(_ a: HAnchor) -> Int { a.verticalRelativeTo == "PARA" ? 1 : 0 }
    func nonNegative(_ value: HAnchor) -> HAnchor {
        var a = value
        if a.horizontalOffset < 0 {
            if ["PAGE", "COLUMN"].contains(a.horizontalRelativeTo) && a.horizontalAlign == "LEFT" {
                a.horizontalRelativeTo = "PAPER"
                a.horizontalOffset = max(0, pageLeft + a.horizontalOffset)
            } else {
                a.horizontalOffset = 0
            }
        }
        if a.verticalOffset < 0 {
            if a.verticalRelativeTo == "PAGE" && a.verticalAlign == "TOP" {
                a.verticalRelativeTo = "PAPER"
                a.verticalOffset = max(0, pageTop + a.verticalOffset)
            } else {
                a.verticalOffset = 0
            }
        }
        return a
    }
    func textBox(_ box: HTextBox) throws -> String {
        let id = nextId()
        let w = box.width
        let h = box.height
        let verticalAlign = box.verticalAlign == .center ? "CENTER" : box.verticalAlign == .bottom ? "BOTTOM" : "TOP"
        let outer = width
        width = max(1000, w - box.padding.left - box.padding.right)
        let content = try subList(box.blocks, verticalAlign, width, max(0, h - box.padding.top - box.padding.bottom))
        width = outer
        let ellipse = box.shape == .ellipse
        let element = ellipse ? "ellipse" : "rect"
        let extra = ellipse ? " intervalDirty=\"0\" hasArcPr=\"0\" arcType=\"NORMAL\"" : " ratio=\"\(box.cornerRatio)\""
        var sb = ""
        sb +=
            "<hp:\(element) id=\"\(id)\" zOrder=\"\(nextZ())\" numberingType=\"NONE\" textWrap=\"\(box.anchor?.wrap ?? "TOP_AND_BOTTOM")\" textFlow=\"BOTH_SIDES\" lock=\"0\" dropcapstyle=\"None\" href=\"\" groupLevel=\"0\" instid=\"\(id)\"\(extra)>"
        sb += "<hp:offset x=\"0\" y=\"0\"/>"
        sb += "<hp:orgSz width=\"\(w)\" height=\"\(h)\"/><hp:curSz width=\"0\" height=\"0\"/>"
        sb += "<hp:flip horizontal=\"0\" vertical=\"0\"/>"
        sb += "<hp:rotationInfo angle=\"0\" centerX=\"\(w / 2)\" centerY=\"\(h / 2)\" rotateimage=\"1\"/>"
        sb += Self.identityRendering
        sb += Self.lineShape(box.line)
        sb += Self.fillBrush(box.fill, box.gradient)
        sb += "<hp:shadow type=\"NONE\" color=\"#B2B2B2\" offsetX=\"0\" offsetY=\"0\" alpha=\"0\"/>"
        sb += "<hp:drawText lastWidth=\"\(w)\" name=\"\" editable=\"0\">"
        sb += content
        sb +=
            "<hp:textMargin left=\"\(box.padding.left)\" right=\"\(box.padding.right)\" top=\"\(box.padding.top)\" bottom=\"\(box.padding.bottom)\"/>"
        sb += "</hp:drawText>"
        sb += ellipse ? Self.ellipseGeometry(w, h) : Self.rectangleGeometry(w, h)
        sb += "<hp:sz width=\"\(w)\" widthRelTo=\"ABSOLUTE\" height=\"\(h)\" heightRelTo=\"ABSOLUTE\" protect=\"0\"/>"
        sb += position(box.anchor)
        sb += "<hp:outMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/>"
        sb += "</hp:\(element)>"
        return sb
    }
    static func rectangleGeometry(_ w: Int, _ h: Int) -> String {
        "<hc:pt0 x=\"0\" y=\"0\"/><hc:pt1 x=\"\(w)\" y=\"0\"/><hc:pt2 x=\"\(w)\" y=\"\(h)\"/><hc:pt3 x=\"0\" y=\"\(h)\"/>"
    }
    static func ellipseGeometry(_ w: Int, _ h: Int) -> String {
        "<hc:center x=\"\(w / 2)\" y=\"\(h / 2)\"/><hc:ax1 x=\"\(w)\" y=\"\(h / 2)\"/><hc:ax2 x=\"\(w / 2)\" y=\"0\"/>"
            + "<hc:start1 x=\"0\" y=\"0\"/><hc:end1 x=\"0\" y=\"0\"/><hc:start2 x=\"0\" y=\"0\"/><hc:end2 x=\"0\" y=\"0\"/>"
    }
    func shape(_ shape: HShape) -> String {
        let id = nextId()
        let w = max(1, shape.width)
        let h = max(1, shape.height)
        let element = shape.kind == .ellipse ? "ellipse" : shape.kind == .line ? "line" : "rect"
        let extra =
            shape.kind == .ellipse
            ? " intervalDirty=\"0\" hasArcPr=\"0\" arcType=\"NORMAL\""
            : shape.kind == .line ? " isReverseHV=\"0\"" : " ratio=\"\(shape.cornerRatio)\""
        var sb = ""
        sb +=
            "<hp:\(element) id=\"\(id)\" zOrder=\"\(nextZ())\" numberingType=\"NONE\" textWrap=\"\(shape.anchor?.wrap ?? "TOP_AND_BOTTOM")\" textFlow=\"BOTH_SIDES\" lock=\"0\" dropcapstyle=\"None\" href=\"\" groupLevel=\"0\" instid=\"\(id)\"\(extra)>"
        sb += "<hp:offset x=\"0\" y=\"0\"/>"
        sb += "<hp:orgSz width=\"\(w)\" height=\"\(h)\"/><hp:curSz width=\"0\" height=\"0\"/>"
        sb += "<hp:flip horizontal=\"0\" vertical=\"0\"/>"
        sb += "<hp:rotationInfo angle=\"0\" centerX=\"\(w / 2)\" centerY=\"\(h / 2)\" rotateimage=\"1\"/>"
        sb += Self.identityRendering
        sb += Self.lineShape(shape.line)
        if shape.kind != .line { sb += Self.fillBrush(shape.fill, shape.gradient) }
        sb += "<hp:shadow type=\"NONE\" color=\"#B2B2B2\" offsetX=\"0\" offsetY=\"0\" alpha=\"0\"/>"
        if shape.kind == .line {
            let x1 = shape.flipHorizontal ? shape.width : 0
            let x2 = shape.flipHorizontal ? 0 : shape.width
            let y1 = shape.flipVertical ? shape.height : 0
            let y2 = shape.flipVertical ? 0 : shape.height
            sb += "<hc:startPt x=\"\(x1)\" y=\"\(y1)\"/><hc:endPt x=\"\(x2)\" y=\"\(y2)\"/>"
        } else {
            sb += shape.kind == .ellipse ? Self.ellipseGeometry(w, h) : Self.rectangleGeometry(w, h)
        }
        sb += "<hp:sz width=\"\(w)\" widthRelTo=\"ABSOLUTE\" height=\"\(h)\" heightRelTo=\"ABSOLUTE\" protect=\"0\"/>"
        sb += position(shape.anchor)
        sb += "<hp:outMargin left=\"0\" right=\"0\" top=\"0\" bottom=\"0\"/>"
        sb += "</hp:\(element)>"
        return sb
    }
    static func lineShape(_ line: HBorder) -> String {
        let none = line.style == .none
        let width = line.style == .none ? 0 : max(1, Int((line.widthMm * HwpxUnits.perMm).rounded(.toNearestOrEven)))
        return
            "<hp:lineShape color=\"\(line.color)\" width=\"\(width)\" style=\"\((none ? "NONE" : Self.lineType(line.style)))\" endCap=\"FLAT\" headStyle=\"NORMAL\" tailStyle=\"NORMAL\" headfill=\"1\" tailfill=\"1\" headSz=\"MEDIUM_MEDIUM\" tailSz=\"MEDIUM_MEDIUM\" outlineStyle=\"NORMAL\" alpha=\"0\"/>"
    }
    static func fillBrush(_ fill: String?, _ gradient: HGradient?) -> String {
        if let gradient, gradient.colors.count >= 2 {
            let colors = gradient.colors.map { "<hc:color value=\"\($0)\"/>" }.joined()
            return
                "<hc:fillBrush><hc:gradation type=\"LINEAR\" angle=\"\(gradient.angle)\" centerX=\"50\" centerY=\"50\" step=\"255\" colorNum=\"\(gradient.colors.count)\" stepCenter=\"50\" alpha=\"0\">\(colors)</hc:gradation></hc:fillBrush>"
        }
        return fill.map {
            "<hc:fillBrush><hc:winBrush faceColor=\"\($0)\" hatchColor=\"#000000\" alpha=\"0\"/></hc:fillBrush>"
        } ?? ""
    }
    func note(_ note: HNote) throws -> String {
        let kind = note.endnote ? "endNote" : "footNote"
        if note.endnote { endnotes += 1 } else { footnotes += 1 }
        let number = note.endnote ? endnotes : footnotes
        let previous = base
        base = footnoteStyle ?? base
        defer { base = previous }
        let run =
            "<hp:run charPrIDRef=\"\(base.char)\">"
            + Self.autoNumber(note.endnote ? "ENDNOTE" : "FOOTNOTE", number, ")") + "<hp:t> </hp:t></hp:run>"
        let content = try subList(note.blocks, "TOP", 0, 0, run)
        return
            "<hp:ctrl><hp:\(kind) number=\"\(number)\" suffixChar=\"41\" instId=\"\(nextId())\">\(content)</hp:\(kind)></hp:ctrl>"
    }
    static func autoNumber(_ type: String, _ number: Int, _ suffix: String) -> String {
        "<hp:ctrl><hp:autoNum num=\"\(number)\" numType=\"\(type)\">"
            + "<hp:autoNumFormat type=\"DIGIT\" userChar=\"\" prefixChar=\"\" suffixChar=\"\(Self.escape(suffix))\" supscript=\"0\"/>"
            + "</hp:autoNum></hp:ctrl>"
    }
    static func fieldBegin(_ id: Int, _ target: String) -> String {
        func escaped(_ s: String) -> String { s.map { ":?;#".contains($0) ? "\\\($0)" : String($0) }.joined() }
        let command: String
        let category: String
        var path: String?
        if target.hasPrefix("#") {
            command = "?" + escaped(String(target.dropFirst())) + ";0;0;0;"
            category = "HWPHYPERLINK_TYPE_HWP"
        } else if target.lowercased().hasPrefix("mailto:") {
            command = target + ";2;0;0"
            path = target
            category = "HWPHYPERLINK_TYPE_EMAIL"
        } else {
            command = escaped(target) + ";1;0;0;"
            path = target
            category = "HWPHYPERLINK_TYPE_URL"
        }
        var parameters =
            "<hp:integerParam name=\"Prop\">0</hp:integerParam><hp:stringParam name=\"Command\">\(escape(command))</hp:stringParam>"
        if let path { parameters += "<hp:stringParam name=\"Path\">\(escape(path))</hp:stringParam>" }
        parameters +=
            "<hp:stringParam name=\"Category\">\(category)</hp:stringParam><hp:stringParam name=\"TargetType\">HWPHYPERLINK_TARGET_BOOKMARK</hp:stringParam><hp:stringParam name=\"DocOpenType\">HWPHYPERLINK_JUMP_CURRENTTAB</hp:stringParam>"
        return
            "<hp:ctrl><hp:fieldBegin id=\"\(id)\" type=\"HYPERLINK\" name=\"\" editable=\"0\" dirty=\"1\" zorder=\"-1\" fieldid=\"\(Self.hyperlinkFieldId)\">"
            + "<hp:parameters cnt=\"\((path == nil ? 5 : 6))\" name=\"\">\(parameters)</hp:parameters></hp:fieldBegin></hp:ctrl>"
    }
}
