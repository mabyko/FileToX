// Port of Filee.Engines/Cad/CadSceneBuilder.Text.cs: TEXT, ATTRIB and MTEXT for the CAD scene — justification,
// rotation, width factor, oblique angle, mirroring, and MTEXT formatting codes with word wrap. Text is measured with
// the typeface it is drawn with (see CadFonts).

import Foundation

extension CadSceneBuilder {
    /// AutoCAD's MTEXT line pitch: 5/3 of the text height at line spacing factor 1.
    private static let linePitch = 5.0 / 3.0

    /// Top of the text box above the baseline for extents, in em (covers accents and CJK glyphs).
    private static let ascentEm = 0.95

    func drawText(_ text: ACad.TextEntity, _ value: String?, _ layer: ACad.Layer, _ context: DrawContext) {
        let content = CadTextCodes.decodeText(value)
        if CadSceneBuilder.trim(content).isEmpty { return }

        let style = text.style
        var height = text.height > 0 ? text.height : style.height > 0 ? style.height : 2.5
        let typeface = CadSceneBuilder.typefaceOf(style, nil, false, false)
        let (capHeight, descent) = CadFonts.metrics(typeface)
        var em = height / capHeight
        var widthFactor = text.widthFactor > 0 ? text.widthFactor : 1
        let runs = CadFonts.layout(content, typeface)
        var width = runs.reduce(0) { $0 + $1.advance } * em * widthFactor

        // Justified text is positioned by its second alignment point; "aligned" and "fit" stretch between both.
        let horizontal = text.horizontalAlignment
        let vertical = text.verticalAlignment
        let justified = horizontal != ACad.TextHorizontalAlignment.left || vertical != ACad.TextVerticalAlignment.baseline
        var anchor = CadVec3(justified ? text.alignmentPoint : text.insertPoint)
        var rotation = text.rotation
        if (horizontal == ACad.TextHorizontalAlignment.aligned || horizontal == ACad.TextHorizontalAlignment.fit) && width > 0 {
            let first = CadVec3(text.insertPoint)
            let span = CadVec3(text.alignmentPoint) - first
            let length = (span.x * span.x + span.y * span.y).squareRoot()
            if length > 1e-12 {
                anchor = first
                rotation = atan2(span.y, span.x)
                if horizontal == ACad.TextHorizontalAlignment.aligned {
                    em *= length / width
                    height *= length / width
                } else {
                    widthFactor *= length / width
                }
                width = length
            }
        }

        let x: Double = switch horizontal {
        case ACad.TextHorizontalAlignment.center, ACad.TextHorizontalAlignment.middle: -width / 2
        case ACad.TextHorizontalAlignment.right: -width
        default: 0
        }
        let y: Double
        if horizontal == ACad.TextHorizontalAlignment.middle {
            y = -height / 2
        } else {
            switch vertical {
            case ACad.TextVerticalAlignment.bottom: y = descent * em
            case ACad.TextVerticalAlignment.middle: y = -height / 2
            case ACad.TextVerticalAlignment.top: y = -height
            default: y = 0
            }
        }

        // Mirrored text (MIRRTEXT, "backward" / "upside down" styles) flips the glyph axes around the anchor.
        let flipX: Double = text.mirror & ACad.TextMirrorFlag.backward != 0 ? -1 : 1
        let flipY: Double = text.mirror & ACad.TextMirrorFlag.upsideDown != 0 ? -1 : 1
        let frame = context.transform
            .multiply(.ocs(text.normal))
            .multiply(.translation(anchor))
            .multiply(.rotationZ(rotation))
            .multiply(.scale(flipX, flipY, 1))

        let color = resolveColor(text, layer, context)
        emitLine(runs, frame, x, y, em, widthFactor, text.obliqueAngle, color)
    }

    func drawMText(_ mtext: ACad.MText, _ layer: ACad.Layer, _ context: DrawContext) {
        let style = mtext.style
        let height = mtext.height > 0 ? mtext.height : style.height > 0 ? style.height : 2.5
        drawMTextCore(mtext.value, CadVec3(mtext.insertPoint), CadVec3(mtext.alignmentPoint), CadVec3(mtext.normal), height,
                      mtext.rectangleWidth, mtext.attachmentPoint, mtext.lineSpacing, style, resolveColor(mtext, layer, context), context)
    }

    /// One placed piece of an MTEXT line.
    private struct Piece {
        var text: String
        var format: CadMTextFormat
        var width: Double
    }

    /// Lays out MTEXT: paragraphs are word-wrapped at `wrapWidth` (CJK text breaks between characters), lines are
    /// stacked with AutoCAD's line pitch and the block is placed by its attachment point.
    func drawMTextCore(_ value: String?, _ insert: CadVec3, _ direction: CadVec3, _ normal: CadVec3, _ height: Double, _ wrapWidth: Double,
                       _ attachment: Int16, _ lineSpacing: Double, _ style: ACad.TextStyle?, _ color: CadColor, _ context: DrawContext) {
        guard let value, !value.isEmpty else { return }
        let styleFlags = style?.trueType ?? ACad.FontFlags.regular
        let initial = CadMTextFormat(
            height: height,
            colorIndex: nil,
            trueColor: nil,
            fontFamily: nil,
            bold: styleFlags & ACad.FontFlags.bold != 0,
            italic: styleFlags & ACad.FontFlags.italic != 0,
            widthFactor: (style?.width ?? 0) > 0 ? style!.width : 1,
            obliqueDegrees: style.map { $0.obliqueAngle * 180 / Double.pi } ?? 0)
        let paragraphs = CadTextCodes.parseMText(value, initial)

        let limit = wrapWidth > 0 ? wrapWidth : Double.infinity
        var lines: [[Piece]] = []
        for paragraph in paragraphs { CadSceneBuilder.wrapParagraph(paragraph, limit, style, &lines) }
        if lines.allSatisfy({ $0.allSatisfy { CadSceneBuilder.trim($0.text).isEmpty } }) { return }

        // Baselines from the top: the first line's caps touch the top, then one pitch per line.
        var baselines = [Double](repeating: 0, count: lines.count)
        var y = 0.0
        let spacing = lineSpacing > 0 ? lineSpacing : 1
        for i in lines.indices {
            let lineHeight = lines[i].isEmpty ? height : lines[i].map(\.format.height).max()!
            y -= i == 0 ? lineHeight : lineHeight * CadSceneBuilder.linePitch * spacing
            baselines[i] = y
        }
        let totalHeight = -y
        let shiftY: Double = switch attachment {
        case ACad.AttachmentPoint.middleLeft, ACad.AttachmentPoint.middleCenter, ACad.AttachmentPoint.middleRight: totalHeight / 2
        case ACad.AttachmentPoint.bottomLeft, ACad.AttachmentPoint.bottomCenter, ACad.AttachmentPoint.bottomRight: totalHeight
        default: 0
        }

        // MTEXT's direction vector is in WCS; a zero vector means the OCS X axis.
        let ocs = CadAffine3.ocs(normal)
        let xAxis = direction.length > 1e-12 ? direction.normalized() : ocs.x
        let zAxis = ocs.z
        let yAxis = CadVec3.cross(zAxis, xAxis).normalized()
        let frame = context.transform.multiply(CadAffine3(xAxis, yAxis, zAxis, insert))

        for i in lines.indices {
            let line = CadSceneBuilder.trimEnd(lines[i])
            let lineWidth = line.reduce(0) { $0 + $1.width }
            var x: Double = switch attachment {
            case ACad.AttachmentPoint.topCenter, ACad.AttachmentPoint.middleCenter, ACad.AttachmentPoint.bottomCenter: -lineWidth / 2
            case ACad.AttachmentPoint.topRight, ACad.AttachmentPoint.middleRight, ACad.AttachmentPoint.bottomRight: -lineWidth
            default: 0
            }
            for piece in line {
                let format = piece.format
                let typeface = CadSceneBuilder.typefaceOf(style, format.fontFamily, format.bold, format.italic)
                let em = format.height / CadFonts.metrics(typeface).capHeight
                let pieceColor: CadColor
                if let rgb = format.trueColor {
                    pieceColor = CadColor(r: UInt8(truncatingIfNeeded: rgb >> 16), g: UInt8(truncatingIfNeeded: rgb >> 8), b: UInt8(truncatingIfNeeded: rgb))
                } else if let index = format.colorIndex, index != 256 {
                    pieceColor = index == 0 ? context.blockColor : resolveColor(ACad.Color(index: index), ACad.Layer.makeDefault(), context)
                } else {
                    pieceColor = color
                }
                emitLine(CadFonts.layout(piece.text, typeface), frame, x, baselines[i] + shiftY, em, format.widthFactor,
                         format.obliqueDegrees * Double.pi / 180, pieceColor)
                x += piece.width
            }
        }
    }

    /// Greedy word wrap of one paragraph into `lines`.
    private static func wrapParagraph(_ paragraph: [CadMTextRun], _ limit: Double, _ style: ACad.TextStyle?, _ lines: inout [[Piece]]) {
        var line: [Piece] = []
        var width = 0.0
        for run in paragraph {
            let typeface = typefaceOf(style, run.format.fontFamily, run.format.bold, run.format.italic)
            let em = run.format.height / CadFonts.metrics(typeface).capHeight * run.format.widthFactor
            for word in words(run.text) {
                let wordWidth = CadFonts.layout(word, typeface).reduce(0) { $0 + $1.advance } * em
                let inkWidth = CadFonts.layout(trimEnd(word), typeface).reduce(0) { $0 + $1.advance } * em
                if !line.isEmpty && width + inkWidth > limit {
                    lines.append(line)
                    line = []
                    width = 0
                    if trim(word).isEmpty { continue } // spaces at a line break disappear
                }
                line.append(Piece(text: word, format: run.format, width: wordWidth))
                width += wordWidth
            }
        }
        lines.append(merge(line))
    }

    /// Splits text into wrap units: words with their trailing spaces, and single CJK characters.
    private static func words(_ text: String) -> [String] {
        let units = Array(text.utf16)
        var result: [String] = []
        func piece(_ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }
        var start = 0
        var i = 0
        while i < units.count {
            let ch = units[i]
            if isCjk(ch) {
                if i > start { result.append(piece(start..<i)) }
                var end = i + 1
                while end < units.count && units[end] == 0x20 { end += 1 }
                result.append(piece(i..<end))
                start = end
                i = end - 1
            } else if ch == 0x20 && (i + 1 >= units.count || units[i + 1] != 0x20) {
                result.append(piece(start..<(i + 1)))
                start = i + 1
            }
            i += 1
        }
        if start < units.count { result.append(piece(start..<units.count)) }
        return result
    }

    private static func isCjk(_ ch: UInt16) -> Bool {
        (0x1100...0x11FF).contains(ch) || (0x2E80...0x9FFF).contains(ch) || (0xAC00...0xD7AF).contains(ch)
            || (0xF900...0xFAFF).contains(ch) || (0xFF00...0xFFEF).contains(ch)
    }

    /// Joins neighbouring pieces with the same format so each becomes one text run.
    private static func merge(_ line: [Piece]) -> [Piece] {
        var merged: [Piece] = []
        for piece in line {
            if let last = merged.last, last.format == piece.format {
                merged[merged.count - 1] = Piece(text: last.text + piece.text, format: last.format, width: last.width + piece.width)
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    /// Drops trailing spaces so right and centre alignment use the visible width.
    private static func trimEnd(_ line: [Piece]) -> [Piece] {
        var result = merge(line)
        if let last = result.last {
            let trimmed = trimEnd(last.text)
            let length = last.text.utf16.count
            if trimmed.utf16.count != length {
                let ratio = length == 0 ? 0 : Double(trimmed.utf16.count) / Double(length)
                result[result.count - 1] = Piece(text: trimmed, format: last.format, width: last.width * ratio)
            }
        }
        return result
    }

    /// Emits the runs of one text line with its baseline starting at (`x`, `y`) in `frame`'s XY plane.
    private func emitLine(_ runs: [CadGlyphRun], _ frame: CadAffine3, _ x: Double, _ y: Double, _ em: Double, _ widthFactor: Double,
                          _ oblique: Double, _ color: CadColor) {
        // Oblique angles are stored in [0, 2π): 345° leans left like -15°. Steeper than ±85° is not allowed.
        let shear = tan(min(max(oblique.remainder(dividingBy: 2 * Double.pi), -1.48), 1.48))
        let xAxis = frame.vector(em * widthFactor, 0)
        let yAxis = frame.vector(-em * shear, -em)
        var x = x
        for run in runs {
            let advance = run.advance * em * widthFactor
            if !CadSceneBuilder.trim(run.text).isEmpty && reserve() {
                scene.items.append(CadTextPrimitive(text: run.text, typeface: run.typeface, origin: frame.point(x, y), xAxis: xAxis,
                                                    yAxis: yAxis, color: color))
                for rise in [-0.2 * em, CadSceneBuilder.ascentEm * em] {
                    scene.extents.add(frame.point(x + rise * shear, y + rise))
                    scene.extents.add(frame.point(x + advance + rise * shear, y + rise))
                }
            }
            x += advance
        }
    }

    /// The typeface of an MTEXT font code, else of the text style.
    private static func typefaceOf(_ style: ACad.TextStyle?, _ family: String?, _ bold: Bool, _ italic: Bool) -> CadTypeface {
        if let family { return CadFonts.resolve(family, bold, italic) }
        let flags = style?.trueType ?? ACad.FontFlags.regular
        return CadFonts.resolve(style?.filename, bold || flags & ACad.FontFlags.bold != 0, italic || flags & ACad.FontFlags.italic != 0)
    }

    /// `string.Trim()`: .NET white space on both ends.
    static func trim(_ text: String) -> String { trimStart(trimEnd(text)) }

    private static func trimEnd(_ text: String) -> String {
        var units = Array(text.utf16)
        while let last = units.last, CadFonts.isWhiteSpace(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    private static func trimStart(_ text: String) -> String {
        let units = Array(text.utf16)
        guard let first = units.firstIndex(where: { !CadFonts.isWhiteSpace($0) }) else { return "" }
        return String(decoding: units[first...], as: UTF16.self)
    }
}
