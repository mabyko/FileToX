// ACadSharp 3.8.0 `Dimension.UpdateBlock` and what it needs (Dimension.cs helpers, the UpdateBlock overrides of the
// dimension types, `GetMeasurementText` with style overrides, `UnitStyleFormat`): the dimension picture generated for
// drawings whose writer left it out. Vector math follows CSMath (normalising a zero vector gives NaN).

import Foundation

extension ACad.Dimension {
    /// `UpdateBlock`: regenerates the anonymous block that shows the dimension.
    func updateBlock() throws {
        switch self {
        case let linear as ACad.DimensionLinear:
            try linear.updateLinearBlock()
        case let aligned as ACad.DimensionAligned:
            try aligned.updateAlignedBlock()
        case let radius as ACad.DimensionRadius:
            try radius.updateRadiusBlock()
        case let diameter as ACad.DimensionDiameter:
            try diameter.updateDiameterBlock()
        case is ACad.DimensionAngular2Line:
            return // "Needs a lot more investigation": ACadSharp returns before creating a block
        case let ordinate as ACad.DimensionOrdinate:
            try ordinate.updateOrdinateBlock()
        default:
            createBlock() // angular 3 points and arc dimensions: an empty block
        }
    }

    // ───────────────────────── Dimension.cs helpers ─────────────────────────

    /// `createBlock`: the dimension's block (a new anonymous `*D<handle>` record if it has none), emptied.
    @discardableResult
    func createBlock() -> ACad.BlockRecord {
        if block == nil {
            let record = ACad.BlockRecord(name: "*D\(handle)")
            record.isAnonymous = true
            block = record
        }
        if let document { block = document.blockRecords.resolve(block!) }
        let record = block!
        _ = record.entities.removeAll { _ in true }
        return record
    }

    func createDefinitionPoint(_ location: ACad.XYZ) -> ACad.Point {
        let point = ACad.Point(location)
        point.layer = ACad.Layer.makeDefpoints()
        return point
    }

    func createTextEntity(_ insertPoint: ACad.XYZ, _ text: String) -> ACad.MText {
        let mtext = ACad.MText(text)
        mtext.attachmentPoint = ACad.AttachmentPoint.middleCenter
        mtext.insertPoint = insertPoint
        mtext.height = style.textHeight
        return mtext
    }

    static func dimensionLine(_ start: ACad.XYZ, _ end: ACad.XYZ, _ style: ACad.DimensionStyle) -> ACad.Line {
        let line = ACad.Line(start, end)
        line.color = style.dimensionLineColor
        line.lineType = style.lineType ?? ACad.LineType.makeByLayer()
        line.lineWeight = style.dimensionLineWeight
        return line
    }

    static func extensionLine(_ start: ACad.XYZ, _ end: ACad.XYZ, _ style: ACad.DimensionStyle, _ lineType: ACad.LineType?) -> ACad.Line {
        let line = ACad.Line(start, end)
        line.color = style.extensionLineColor
        line.lineType = lineType ?? ACad.LineType.makeByLayer()
        line.lineWeight = style.extensionLineWeight
        return line
    }

    func dimensionArrow(_ insertPoint: ACad.XYZ, _ dir: ACad.XYZ, _ style: ACad.DimensionStyle, _ record: ACad.BlockRecord?) -> ACad.Entity {
        let scale = style.arrowSize * style.scaleFactor
        let rotation = atan2(dir.y, dir.x)
        guard let record else {
            let p = CSMathPort.normalize(ACad.XYZ.cross(normal, dir))
            let arrow = ACad.Solid()
            arrow.firstCorner = insertPoint
            arrow.secondCorner = insertPoint - dir * scale - p * (scale / 6)
            arrow.thirdCorner = insertPoint - dir * scale + p * (scale / 6)
            arrow.fourthCorner = arrow.thirdCorner
            return arrow
        }
        // shortcut: ACadSharp's Insert(BlockRecord) also adds the block's attribute definitions as attributes; arrow
        // blocks have none in practice, add them if one shows up.
        let arrow = ACad.Insert()
        arrow.block = record
        arrow.insertPoint = insertPoint
        arrow.color = style.dimensionLineColor
        arrow.xScale = scale
        arrow.yScale = scale
        arrow.zScale = scale
        arrow.rotation = rotation
        arrow.lineWeight = style.dimensionLineWeight
        arrow.normal = normal
        return arrow
    }

    func dimensionRadialLine(_ start: ACad.XY, _ end: ACad.XY, _ rotation: Double, _ reversed: Int16) -> ACad.Line {
        let style = self.style
        let ext = -style.arrowSize * style.scaleFactor
        let tip = CSMathPort.polar(end, Double(reversed) * ext, rotation)
        let line = ACad.Line(ACad.XYZ(start.x, start.y, 0), ACad.XYZ(tip.x, tip.y, 0))
        line.color = style.dimensionLineColor
        line.lineType = style.lineType ?? ACad.LineType.makeByLayer()
        line.lineWeight = style.dimensionLineWeight
        return line
    }

    func centerCross(_ center: ACad.XYZ, _ radius: Double, _ style: ACad.DimensionStyle) -> [ACad.Entity] {
        var lines: [ACad.Entity] = []
        if CSMathPort.isZero(style.centerMarkSize) { return lines }
        let dist = abs(style.centerMarkSize * style.scaleFactor)
        func line(_ a: ACad.XYZ, _ b: ACad.XYZ) {
            let l = ACad.Line(a + center, b + center)
            l.color = style.extensionLineColor
            l.lineWeight = style.extensionLineWeight
            lines.append(l)
        }
        // center mark
        line(ACad.XYZ(0, -dist, 0), ACad.XYZ(0, dist, 0))
        line(ACad.XYZ(-dist, 0, 0), ACad.XYZ(dist, 0, 0))
        // center lines
        if style.centerMarkSize < 0 {
            line(ACad.XYZ(2 * dist, 0, 0), ACad.XYZ(radius + dist, 0, 0))
            line(ACad.XYZ(-2 * dist, 0, 0), ACad.XYZ(-radius - dist, 0, 0))
            line(ACad.XYZ(0, 2 * dist, 0), ACad.XYZ(0, radius + dist, 0))
            line(ACad.XYZ(0, -2 * dist, 0), ACad.XYZ(0, -radius - dist, 0))
        }
        return lines
    }

    /// `angularBlock`: common picture of radial dimensions.
    func angularBlock(_ radius: Double, _ centerRef: ACad.XY, _ ref1: ACad.XY, _ minOffset: Double, _ drawRef2: Bool, _ block: ACad.BlockRecord) throws {
        var offset = ACad.XYZ.distance(definitionPoint, textMiddlePoint)
        let defPoint = definitionPoint.xy
        let angleRef = CSMathPort.angle(centerRef, ref1)

        let inside: Int16 // 1 if the dimension line is inside the circumference, -1 otherwise
        if offset >= radius && offset <= radius + minOffset {
            offset = radius + minOffset
            inside = -1
        } else if offset >= radius - minOffset && offset <= radius {
            offset = radius - minOffset
            inside = 1
        } else if offset > radius {
            inside = -1
        } else {
            inside = 1
        }

        let style = self.style
        let dimRef = CSMathPort.polar(centerRef, offset - style.dimensionLineGap * style.scaleFactor, angleRef)

        // reference points
        let point = ACad.Point(ACad.XYZ(ref1.x, ref1.y, 0))
        point.layer = ACad.Layer.makeDefpoints()
        block.entities.add(point)

        // dimension lines
        if !style.suppressFirstDimensionLine && !style.suppressSecondDimensionLine {
            if inside > 0 {
                block.entities.add(dimensionRadialLine(dimRef, ref1, angleRef, inside))
            } else {
                let line = ACad.Line(ACad.XYZ(defPoint.x, defPoint.y, 0), ACad.XYZ(ref1.x, ref1.y, 0))
                line.color = style.dimensionLineColor
                line.lineType = style.lineType ?? ACad.LineType.makeByLayer()
                line.lineWeight = style.dimensionLineWeight
                block.entities.add(line)
                block.entities.add(dimensionRadialLine(dimRef, ref1, angleRef, inside))
                if drawRef2 {
                    let dimRef2 = CSMathPort.polar(centerRef, radius + minOffset - style.dimensionLineGap * style.scaleFactor, Double.pi + angleRef)
                    block.entities.add(dimensionRadialLine(dimRef2, defPoint, Double.pi + angleRef, inside))
                }
            }
        }

        // center cross
        if !CSMathPort.isZero(style.centerMarkSize) {
            for line in centerCross(ACad.XYZ(centerRef.x, centerRef.y, 0), radius, style) { block.entities.add(line) }
        }

        // dimension text
        let text = try measurementText()
        var textRot = angleRef
        var reverse: Int16 = 1
        if textRot > Double.pi / 2 && textRot <= 3 * Double.pi * 0.5 {
            textRot += Double.pi
            reverse = -1
        }
        if !isTextUserDefinedLocation {
            let textPos = CSMathPort.polar(dimRef, Double(-reverse * inside) * style.dimensionLineGap * style.scaleFactor, textRot)
            textMiddlePoint = ACad.XYZ(textPos.x, textPos.y, 0)
        }
        let mtext = createTextEntity(textMiddlePoint, text)
        mtext.attachmentPoint = reverse * inside < 0 ? ACad.AttachmentPoint.middleLeft : ACad.AttachmentPoint.middleRight
        block.entities.add(mtext)
    }

    // ───────────────────────── Measurement text ─────────────────────────

    /// The style values `GetMeasurementText` reads, with the dimension's DSTYLE overrides applied.
    struct MeasurementStyle {
        var rounding: Double
        var decimalPlaces: Int16
        var angularDecimalPlaces: Int16
        var decimalSeparator: UInt16
        var toleranceScaleFactor: Double
        var fractionFormat: Int16
        var zeroHandling: UInt8
        var angularZeroHandling: UInt8
        var angularUnit: Int16
        var linearScaleFactor: Double
        var linearUnitFormat: Int16
        var postFix: String

        init(_ style: ACad.DimensionStyle) {
            rounding = style.rounding
            decimalPlaces = style.decimalPlaces
            angularDecimalPlaces = style.angularDecimalPlaces
            decimalSeparator = style.decimalSeparator
            toleranceScaleFactor = style.toleranceScaleFactor
            fractionFormat = style.fractionFormat
            zeroHandling = style.zeroHandling
            angularZeroHandling = style.angularZeroHandling
            angularUnit = style.angularUnit
            linearScaleFactor = style.linearScaleFactor
            linearUnitFormat = style.linearUnitFormat
            postFix = style.postFix
        }

        /// Prefix and suffix around the first "<>" of DIMPOST (`getDimStylePrefixAndSuffix`).
        var prefixAndSuffix: (String, String) {
            let units = Array(postFix.utf16)
            var index = -1
            for i in units.indices where units[i] == 0x3C && i + 1 < units.count && units[i + 1] == 0x3E {
                index = i
                break
            }
            if index < 0 { return ("", postFix) }
            return (String(decoding: units[..<index], as: UTF16.self), String(decoding: units[(index + 2)...], as: UTF16.self))
        }
    }

    /// `GetActiveDimensionStyle`: the style with the overrides from the "ACAD" extended data (DSTYLE). Malformed
    /// overrides and overrides of style references (text style, arrows, line types) fail like in ACadSharp.
    func activeMeasurementStyle() throws -> MeasurementStyle {
        var result = MeasurementStyle(style)
        guard hasExtendedData, let data = extendedData.get(ACad.AppId.defaultName),
              case let .string(header)? = data.records.first, header == ACad.DimensionStyle.styleOverrideEntryName else { return result }
        var values: [ACad.XDataRecord] = []
        var inside = false
        for record in data.records {
            if case .controlString = record {
                if inside { break }
                inside = true
                continue
            }
            if inside { values.append(record) }
        }
        if !inside || values.count % 2 != 0 { throw ConversionError("Object reference not set to an instance of an object.") }
        var i = 0
        while i < values.count {
            guard case let .integer16(code) = values[i] else { throw ConversionError("Object reference not set to an instance of an object.") }
            try apply(code, values[i + 1], to: &result)
            i += 2
        }
        return result
    }

    private func apply(_ code: Int16, _ value: ACad.XDataRecord, to style: inout MeasurementStyle) throws {
        func number() -> Double? {
            switch value {
            case let .integer16(v): return Double(v)
            case let .integer32(v): return Double(v)
            case let .real(v), let .distance(v), let .scale(v): return v
            default: return nil
            }
        }
        let isReference = (340...347).contains(code)
        let isKnown = isReference || (3...7).contains(code) || (40...49).contains(code) || (140...148).contains(code)
            || (69...79).contains(code) || (170...179).contains(code) || (270...290).contains(code) || code == 371 || code == 372
        guard isKnown else { throw ConversionError("The given key '\(code)' was not present in the dictionary.") }
        if isReference { throw ConversionError("Object of type 'System.UInt64' cannot be converted to the style reference.") }
        func integer() -> Int? { number().map { CadMath.int($0) } }
        switch code {
        case 45: if let v = number() { style.rounding = v }
        case 271: if let v = integer() { style.decimalPlaces = Int16(truncatingIfNeeded: v) }
        case 179: if let v = integer() { style.angularDecimalPlaces = Int16(truncatingIfNeeded: v) }
        case 278: if let v = integer() { style.decimalSeparator = UInt16(truncatingIfNeeded: v) }
        case 146: if let v = number() { style.toleranceScaleFactor = v }
        case 276: if let v = integer() { style.fractionFormat = Int16(truncatingIfNeeded: v) }
        case 78: if let v = integer() { style.zeroHandling = UInt8(truncatingIfNeeded: v) }
        case 79: if let v = integer() { style.angularZeroHandling = UInt8(truncatingIfNeeded: v) }
        case 275: if let v = integer() { style.angularUnit = Int16(truncatingIfNeeded: v) }
        case 144: if let v = number() { style.linearScaleFactor = v }
        case 277: if let v = integer() { style.linearUnitFormat = Int16(truncatingIfNeeded: v) }
        case 3: if case let .string(v) = value { style.postFix = v }
        default: break // overrides that do not change the measurement text
        }
    }

    /// `GetMeasurementText()`.
    func measurementText() throws -> String {
        let style = try activeMeasurementStyle()
        var value = try measurement()
        if style.rounding != 0 { value = style.rounding * (value / style.rounding).rounded(.toNearestOrEven) }
        let format = UnitStyleFormat(style)

        var text: String
        if isAngular {
            switch style.angularUnit {
            case 0: text = format.toDegrees(value)
            case 1: text = format.toDegreesMinutesSeconds(value)
            case 2: text = format.toGradians(value)
            case 3: text = format.toRadians(value)
            default: text = format.toDecimal(value, isAngular: true)
            }
        } else {
            let scaled = value * style.linearScaleFactor
            switch style.linearUnitFormat {
            case 1: text = format.toScientific(scaled)
            case 3: text = format.toEngineering(scaled)
            case 4: text = format.toArchitectural(scaled)
            case 5: text = format.toFractional(scaled)
            default: text = format.toDecimal(scaled)
            }
        }

        let (stylePrefix, suffix) = style.prefixAndSuffix
        let prefix: String
        // The whole flags value is compared (the BlockReference bit normally makes these cases miss, as in ACadSharp).
        switch flags {
        case ACad.DimensionType.diameter: prefix = stylePrefix.isEmpty ? "Ø" : stylePrefix
        case ACad.DimensionType.radius: prefix = stylePrefix.isEmpty ? "R" : stylePrefix
        default: prefix = stylePrefix
        }
        let valueText = prefix + text + suffix
        if let own = self.text, !own.isEmpty { return own.replacingOccurrences(of: "<>", with: valueText) }
        return valueText
    }

    /// `UnitStyleFormat` as `DimensionStyle.GetUnitStyleFormat` sets it up.
    struct UnitStyleFormat {
        var linearDecimalPlaces: Int16
        var angularDecimalPlaces: Int16
        var decimalSeparator: String
        var fractionHeightScale: Double
        var fractionType: Int16
        var linearZeroHandling: UInt8
        var angularZeroHandling: UInt8
        let feetInchesSeparator = "-"
        let degreesSymbol = "°"
        let minutesSymbol = "'"
        let secondsSymbol = "\""
        let radiansSymbol = "r"
        let gradiansSymbol = "g"
        let feetSymbol = "'"
        let inchesSymbol = "\""

        init(_ style: MeasurementStyle) {
            linearDecimalPlaces = style.decimalPlaces
            angularDecimalPlaces = style.angularDecimalPlaces == -1 ? style.decimalPlaces : style.angularDecimalPlaces
            decimalSeparator = String(decoding: [style.decimalSeparator], as: UTF16.self)
            fractionHeightScale = style.toleranceScaleFactor
            fractionType = style.fractionFormat
            linearZeroHandling = style.zeroHandling
            angularZeroHandling = style.angularZeroHandling
        }

        private var suppressZeroFeet: Bool { linearZeroHandling == 0 || linearZeroHandling == 3 }
        private var suppressZeroInches: Bool { linearZeroHandling == 0 || linearZeroHandling == 2 }

        /// `GetZeroHandlingFormat`: the .NET custom format ("0.00", "#.##" …).
        private func zeroHandlingFormat(isAngular: Bool) -> (leading: Character, decimals: Int, trailing: Character) {
            if isAngular {
                let leading: Character = angularZeroHandling == 1 || angularZeroHandling == 3 ? "#" : "0"
                let trailing: Character = angularZeroHandling == 2 || angularZeroHandling == 3 ? "#" : "0"
                return (leading, max(0, Int(angularDecimalPlaces)), trailing)
            }
            let leading: Character = linearZeroHandling == 4 || linearZeroHandling == 12 ? "#" : "0"
            let trailing: Character = linearZeroHandling == 8 || linearZeroHandling == 12 ? "#" : "0"
            return (leading, max(0, Int(linearDecimalPlaces)), trailing)
        }

        func toDecimal(_ value: Double, isAngular: Bool = false) -> String {
            let f = zeroHandlingFormat(isAngular: isAngular)
            return NetCustomFormat.fixed(value, leading: f.leading, decimals: f.decimals, trailing: f.trailing, separator: decimalSeparator)
        }

        func toDegrees(_ angle: Double) -> String {
            toDecimal(CSMathPort.radToDeg(angle), isAngular: true) + degreesSymbol
        }

        func toDegreesMinutesSeconds(_ angle: Double) -> String {
            let degrees = CSMathPort.radToDeg(angle)
            let minutes = (degrees - Double(CadMath.int(degrees))) * 60
            let seconds = (minutes - Double(CadMath.int(minutes))) * 60
            if angularDecimalPlaces == 0 {
                return "\(CadMath.int(degrees.rounded(.toNearestOrEven)))\(degreesSymbol)"
            }
            if angularDecimalPlaces == 1 || angularDecimalPlaces == 2 {
                return "\(CadMath.int(degrees))\(degreesSymbol)\(CadMath.int(minutes.rounded(.toNearestOrEven)))\(minutesSymbol)"
            }
            if angularDecimalPlaces == 3 || angularDecimalPlaces == 4 {
                return "\(CadMath.int(degrees))\(degreesSymbol)\(CadMath.int(minutes))\(minutesSymbol)\(CadMath.int(seconds.rounded(.toNearestOrEven)))\(secondsSymbol)"
            }
            // the suppression of leading or trailing zeros is not applicable to DegreesMinutesSeconds angles format
            let secondsText = NetCustomFormat.fixed(seconds, leading: "0", decimals: Int(angularDecimalPlaces) - 4, trailing: "0", separator: decimalSeparator)
            return "\(CadMath.int(degrees))\(degreesSymbol)\(CadMath.int(minutes))\(minutesSymbol)\(secondsText)\(secondsSymbol)"
        }

        func toGradians(_ angle: Double) -> String { toDecimal(angle * (200 / Double.pi), isAngular: true) + gradiansSymbol }

        func toRadians(_ angle: Double) -> String { toDecimal(angle, isAngular: true) + radiansSymbol }

        func toScientific(_ value: Double) -> String {
            let f = zeroHandlingFormat(isAngular: false)
            return NetCustomFormat.scientific(value, decimals: f.decimals, trailing: f.trailing)
        }

        func toEngineering(_ value: Double) -> String {
            let feet = CadMath.int(value / 12)
            let inches = value - 12 * Double(feet)
            if CSMathPort.isZero(inches) {
                if feet == 0 {
                    if suppressZeroFeet { return "0\(inchesSymbol)" }
                    if suppressZeroInches { return "0\(feetSymbol)" }
                    return "0\(feetSymbol)\(feetInchesSeparator)0\(inchesSymbol)"
                }
                if suppressZeroInches { return "\(feet)\(feetSymbol)" }
                return "\(feet)\(feetSymbol)\(feetInchesSeparator)0\(inchesSymbol)"
            }
            let inchesDec = toDecimal(inches)
            if feet == 0 {
                if suppressZeroFeet { return "\(ACad.DxfNumber.netString(inches))\(inchesSymbol)" }
                return "0\(feetSymbol)\(feetInchesSeparator)\(inchesDec)\(inchesSymbol)"
            }
            return "\(feet)\(feetSymbol)\(feetInchesSeparator)\(inchesDec)\(inchesSymbol)"
        }

        func toArchitectural(_ value: Double) -> String {
            let feet = CadMath.int(value / 12)
            let inchesDec = value - 12 * Double(feet)
            let inches = CadMath.int(inchesDec)
            func zeroInches() -> String {
                if feet == 0 {
                    if suppressZeroFeet { return "0\(inchesSymbol)" }
                    if suppressZeroInches { return "0\(feetSymbol)" }
                    return "0\(feetSymbol)\(feetInchesSeparator)0\(inchesSymbol)"
                }
                if suppressZeroInches { return "\(feet)\(feetSymbol)" }
                return "\(feet)\(feetSymbol)\(feetInchesSeparator)0\(inchesSymbol)"
            }
            if CSMathPort.isZero(inchesDec) { return zeroInches() }
            let (numerator, denominator) = fraction(inchesDec, Int(Int16(truncatingIfNeeded: CadMath.int(pow(2, Double(linearDecimalPlaces))))))
            if numerator == 0 {
                if inches == 0 { return zeroInches() }
                if feet == 0 {
                    if suppressZeroFeet { return "\(inches)\(inchesSymbol)" }
                    return "0\(feetSymbol)\(feetInchesSeparator)\(inches)\(inchesSymbol)"
                }
                return "\(feet)\(feetSymbol)\(feetInchesSeparator)\(inches)\(inchesSymbol)"
            }
            let feetText = suppressZeroFeet && feet == 0 ? "" : "\(feet)\(feetSymbol)\(feetInchesSeparator)"
            let scale = ACad.DxfNumber.netString(fractionHeightScale)
            switch fractionType {
            case 1: return "\\A1;\(feetText)\(inches){\\H\(scale)x;\\S\(numerator)#\(denominator);}\(inchesSymbol)"
            case 0: return "\\A1;\(feetText)\(inches){\\H\(scale)x;\\S\(numerator)/\(denominator);}\(inchesSymbol)"
            case 2: return "\(feetText)\(inches) \(numerator)/\(denominator)\(inchesSymbol)"
            default: return ""
            }
        }

        func toFractional(_ value: Double) -> String {
            let num = CadMath.int(value)
            let (numerator, denominator) = fraction(value, Int(Int16(truncatingIfNeeded: CadMath.int(pow(2, Double(linearDecimalPlaces))))))
            if numerator == 0 { return "\(CadMath.int(value))" }
            let scale = ACad.DxfNumber.netString(fractionHeightScale)
            switch fractionType {
            case 1: return "\\A1;\(num){\\H\(scale)x;\\S\(numerator)#\(denominator);}"
            case 0: return "\\A1;\(num){\\H\(scale)x;\\S\(numerator)/\(denominator);}"
            case 2: return (num == 0 ? "" : "\(num) ") + "\(numerator)/\(denominator)"
            default: return ""
            }
        }

        /// `getFraction`: `Convert.ToInt32` rounds half to even.
        private func fraction(_ number: Double, _ precision: Int) -> (Int, Int) {
            var numerator = CadMath.int(((number - Double(CadMath.int(number))) * Double(precision)).rounded(.toNearestOrEven))
            var a = numerator, b = precision
            while b != 0 {
                let r = a % b
                a = b
                b = r
            }
            let common = a <= 0 ? 1 : a
            numerator /= common
            return (numerator, precision / common)
        }
    }
}

extension ACad.DimensionAligned {
    /// `DimensionAligned.UpdateBlock`.
    fileprivate func updateAlignedBlock() throws {
        let block = createBlock()
        let style = self.style
        let dir = CSMathPort.normalize(secondPoint - firstPoint)
        let vec = CSMathPort.normalize(ACad.XYZ.cross(normal, dir))
        // ACadSharp 3.8's Offset getter: the distance from the second point to the definition point.
        let offset = ACad.XYZ.distance(secondPoint, definitionPoint)

        let dimRef1 = firstPoint + vec * offset
        let dimRef2 = definitionPoint

        // reference points
        block.entities.add(createDefinitionPoint(firstPoint))
        block.entities.add(createDefinitionPoint(secondPoint))
        block.entities.add(createDefinitionPoint(dimRef1))
        block.entities.add(createDefinitionPoint(dimRef2))

        if !style.suppressFirstDimensionLine && !style.suppressSecondDimensionLine {
            block.entities.add(ACad.Dimension.dimensionLine(dimRef1, dimRef2, style))
            block.entities.add(dimensionArrow(dimRef1, dir * -1, style, style.dimArrow1))
            block.entities.add(dimensionArrow(dimRef1, dir, style, style.dimArrow2))
        }

        // extension lines
        let sign = offset > 0 ? 1.0 : offset < 0 ? -1.0 : 0.0
        let exo = sign * style.extensionLineOffset * style.scaleFactor
        let exe = sign * style.extensionLineExtension * style.scaleFactor
        if !style.suppressFirstExtensionLine {
            block.entities.add(ACad.Dimension.extensionLine(firstPoint + vec * exo, dimRef1 + vec * exe, style, style.lineTypeExt1))
        }
        if !style.suppressSecondExtensionLine {
            block.entities.add(ACad.Dimension.extensionLine(secondPoint + vec * exo, dimRef2 + vec * exe, style, style.lineTypeExt2))
        }

        // dimension text
        let textRef = CSMathPort.mid(dimRef1, dimRef2)
        var gap = style.dimensionLineGap * style.scaleFactor
        var textRot = extLineRotation
        if textRot > Double.pi / 2 && textRot <= 3 * Double.pi * 0.5 {
            gap = -gap
            textRot += Double.pi
        }
        let text = try measurementText()
        if !isTextUserDefinedLocation { textMiddlePoint = textRef + vec * gap }
        block.entities.add(createTextEntity(textMiddlePoint, text))
    }
}

extension ACad.DimensionLinear {
    /// `DimensionLinear.UpdateBlock`.
    fileprivate func updateLinearBlock() throws {
        let block = createBlock()
        let style = self.style
        let yVec = CSMathPort.normalize(CSMathPort.rotate(ACad.XYZ.axisY, around: normal, by: rotation))
        let xVec = CSMathPort.normalize(CSMathPort.rotate(ACad.XYZ.axisX, around: normal, by: rotation))

        guard yVec != .zero, xVec != .zero else { throw ConversionError("The direction vector of the line cannot be a zero vector.") }
        let dimRef1 = CSMathPort.intersection(firstPoint, yVec, definitionPoint, xVec)
        let dimRef2 = definitionPoint
        let dir = CSMathPort.normalize(dimRef2 - dimRef1)

        // reference points
        block.entities.add(createDefinitionPoint(firstPoint))
        block.entities.add(createDefinitionPoint(secondPoint))
        block.entities.add(createDefinitionPoint(dimRef1))
        block.entities.add(createDefinitionPoint(dimRef2))

        if !style.suppressFirstDimensionLine && !style.suppressSecondDimensionLine {
            block.entities.add(ACad.Dimension.dimensionLine(dimRef1, dimRef2, style))
            block.entities.add(dimensionArrow(dimRef1, dir * -1, style, style.dimArrow1))
            block.entities.add(dimensionArrow(dimRef2, dir, style, style.dimArrow2))
        }

        // extension lines
        let dirRef1 = CSMathPort.normalize(dimRef1 - firstPoint)
        let dirRef2 = CSMathPort.normalize(dimRef2 - secondPoint)
        let exo = style.extensionLineOffset * style.scaleFactor
        let exe = style.extensionLineExtension * style.scaleFactor
        if !style.suppressFirstExtensionLine {
            block.entities.add(ACad.Dimension.extensionLine(firstPoint + dirRef1 * exo, dimRef1 + dirRef1 * exe, style, style.lineTypeExt1))
        }
        if !style.suppressSecondExtensionLine {
            block.entities.add(ACad.Dimension.extensionLine(secondPoint + dirRef2 * exo, dimRef2 + dirRef2 * exe, style, style.lineTypeExt2))
        }

        // dimension text
        let textRef = CSMathPort.mid(dimRef1, dimRef2)
        var gap = style.dimensionLineGap * style.scaleFactor
        var textRot = rotation
        if textRot > Double.pi / 2 && textRot <= 3 * Double.pi * 0.5 {
            gap = -gap
            textRot += Double.pi
        }
        let text = try measurementText()
        if !isTextUserDefinedLocation { textMiddlePoint = textRef + yVec * gap }
        block.entities.add(createTextEntity(textMiddlePoint, text))
    }
}

extension ACad.DimensionRadius {
    /// `DimensionRadius.UpdateBlock`.
    fileprivate func updateRadiusBlock() throws {
        let block = createBlock()
        let style = self.style
        let centerRef = definitionPoint.xy
        let ref1 = angleVertex.xy
        let minOffset = 2 * style.arrowSize * style.scaleFactor
        try angularBlock(try measurement(), centerRef, ref1, minOffset, false, block)
    }
}

extension ACad.DimensionDiameter {
    /// `DimensionDiameter.UpdateBlock`.
    fileprivate func updateDiameterBlock() throws {
        let block = createBlock()
        let style = self.style
        var offset = ACad.XYZ.distance(definitionPoint, textMiddlePoint)
        let measure = try measurement()
        let radius = measure * 0.5
        let center = CSMathPort.mid(angleVertex, definitionPoint)
        let ref1 = angleVertex.xy
        let defPoint = definitionPoint.xy
        let minOffset = (2 * style.arrowSize + style.dimensionLineGap) * style.scaleFactor

        let angleRef = CSMathPort.angle(defPoint, ref1)
        let inside: Int16
        if offset >= radius && offset <= radius + minOffset {
            offset = radius + minOffset
            inside = -1
        } else if offset >= radius - minOffset && offset <= radius {
            offset = radius - minOffset
            inside = 1
        } else if offset > radius {
            inside = -1
        } else {
            inside = 1
        }

        let dimRef = CSMathPort.polar(defPoint, offset - style.dimensionLineGap * style.scaleFactor, angleRef)

        // reference points
        let point = ACad.Point(ACad.XYZ(ref1.x, ref1.y, 0))
        point.layer = ACad.Layer.makeDefpoints()
        block.entities.add(point)

        // dimension lines
        if !style.suppressFirstDimensionLine && !style.suppressSecondDimensionLine {
            block.entities.add(dimensionRadialLine(dimRef, ref1, angleRef, inside))
        }

        // center cross
        if !CSMathPort.isZero(style.centerMarkSize) {
            for line in centerCross(center, radius, style) { block.entities.add(line) }
        }

        // dimension text: ACadSharp's provisional `Measurement.ToString("#.##")`
        let text = NetCustomFormat.fixed(measure, leading: "#", decimals: 2, trailing: "#", separator: ".")
        var textRot = angleRef
        var reverse: Int16 = 1
        if textRot > Double.pi / 2 && textRot <= 3 * Double.pi * 0.5 {
            textRot += Double.pi
            reverse = -1
        }
        if !isTextUserDefinedLocation {
            let textPos = CSMathPort.polar(ref1, Double(-reverse * inside) * style.dimensionLineGap * style.scaleFactor, textRot)
            textMiddlePoint = ACad.XYZ(textPos.x, textPos.y, 0)
        }
        let mtext = createTextEntity(textMiddlePoint, text)
        mtext.attachmentPoint = reverse * inside < 0 ? ACad.AttachmentPoint.middleLeft : ACad.AttachmentPoint.middleRight
        block.entities.add(mtext)
    }
}

extension ACad.DimensionOrdinate {
    /// `DimensionOrdinate.UpdateBlock`.
    fileprivate func updateOrdinateBlock() throws {
        let block = createBlock()
        let style = self.style
        _ = try measurement()
        let minOffset = 2 * style.arrowSize
        let ref1 = featureLocation.xy
        let ref2 = leaderEndpoint.xy
        let refDim = ACad.XY(ref2.x - ref1.x, ref2.y - ref1.y)
        var rotation = horizontalDirection
        var side = 1.0
        if isOrdinateTypeX { rotation += Double.pi / 2 }

        let ocsDimRef = CSMathPort.rotate(refDim, -rotation)
        var pto1: ACad.XY, pto2: ACad.XY
        if ocsDimRef.x >= 0 {
            if ocsDimRef.x >= 2 * minOffset {
                pto1 = ACad.XY(ocsDimRef.x - minOffset, 0)
                pto2 = ACad.XY(ocsDimRef.x - minOffset, ocsDimRef.y)
            } else {
                pto1 = ACad.XY(minOffset, 0)
                pto2 = ACad.XY(ocsDimRef.x - minOffset, ocsDimRef.y)
            }
        } else {
            if ocsDimRef.x <= -2 * minOffset {
                pto1 = ACad.XY(ocsDimRef.x + minOffset, 0)
                pto2 = ACad.XY(ocsDimRef.x + minOffset, ocsDimRef.y)
            } else {
                pto1 = ACad.XY(-minOffset, 0)
                pto2 = ACad.XY(ocsDimRef.x + minOffset, ocsDimRef.y)
            }
            side = -1
        }
        let r1 = CSMathPort.rotate(pto1, rotation), r2 = CSMathPort.rotate(pto2, rotation)
        pto1 = ACad.XY(ref1.x + r1.x, ref1.y + r1.y)
        pto2 = ACad.XY(ref1.x + r2.x, ref1.y + r2.y)

        // reference points
        block.entities.add(createDefinitionPoint(definitionPoint))
        block.entities.add(createDefinitionPoint(featureLocation))

        // dimension lines
        func xyz(_ p: ACad.XY) -> ACad.XYZ { ACad.XYZ(p.x, p.y, 0) }
        block.entities.add(ACad.Line(xyz(CSMathPort.polar(ref1, style.extensionLineOffset * style.scaleFactor, rotation)), xyz(pto1)))
        block.entities.add(ACad.Line(xyz(pto1), xyz(pto2)))
        block.entities.add(ACad.Line(xyz(pto2), xyz(ref2)))

        // dimension text
        let midText = CSMathPort.polar(ref2, side * style.dimensionLineGap * style.scaleFactor, rotation)
        let text = try measurementText()
        if !isTextUserDefinedLocation { textMiddlePoint = xyz(midText) }
        let mtext = createTextEntity(textMiddlePoint, text)
        mtext.attachmentPoint = side < 0 ? ACad.AttachmentPoint.middleRight : ACad.AttachmentPoint.middleLeft
        block.entities.add(mtext)
    }
}

/// The CSMath operations the dimension blocks use, with CSMath's exact semantics.
enum CSMathPort {
    static let epsilon = 1e-12

    /// `IsZero(threshold)`: inclusive.
    static func isZero(_ value: Double, _ threshold: Double = epsilon) -> Bool { value >= -threshold && value <= threshold }

    /// `Normalize`: components divided by the length (NaN for a zero vector).
    static func normalize(_ v: ACad.XYZ) -> ACad.XYZ {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return ACad.XYZ(v.x / length, v.y / length, v.z / length)
    }

    static func mid(_ a: ACad.XYZ, _ b: ACad.XYZ) -> ACad.XYZ { ACad.XYZ((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5) }

    static func polar(_ u: ACad.XY, _ distance: Double, _ angle: Double) -> ACad.XY {
        ACad.XY(u.x + cos(angle) * distance, u.y + sin(angle) * distance)
    }

    static func rotate(_ value: ACad.XY, _ angle: Double) -> ACad.XY {
        let s = sin(angle), c = cos(angle)
        return ACad.XY(value.x * c - value.y * s, value.x * s + value.y * c)
    }

    /// `XY.GetAngle(v)`: the angle of the line from `a` to `b`.
    static func angle(_ a: ACad.XY, _ b: ACad.XY) -> Double { atan2(b.y - a.y, b.x - a.x) }

    /// `MathHelper.RadToDeg` (normalised to [0, 360)).
    static func radToDeg(_ value: Double) -> Double {
        let degrees = value * (180 / Double.pi)
        if abs(abs(degrees) - 360) <= epsilon { return 360 }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        if isZero(normalized) { return 0 }
        return normalized < 0 ? 360 + normalized : normalized
    }

    /// `Transform.CreateRotation(axis, angle).ApplyTransform(v)` (with RoundZero).
    static func rotate(_ v: ACad.XYZ, around axis: ACad.XYZ, by angle: Double) -> ACad.XYZ {
        let u = normalize(axis)
        let x = u.x, y = u.y, z = u.z
        let sa = sin(angle), ca = cos(angle)
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        let m00 = xx + ca * (1.0 - xx), m01 = xy - ca * xy + sa * z, m02 = xz - ca * xz - sa * y
        let m10 = xy - ca * xy - sa * z, m11 = yy + ca * (1.0 - yy), m12 = yz - ca * yz + sa * x
        let m20 = xz - ca * xz + sa * y, m21 = yz - ca * yz - sa * x, m22 = zz + ca * (1.0 - zz)
        // Rows are (M0i, M1i, M2i, M3i) dotted with (x, y, z, 1).
        let rx = m00 * v.x + m10 * v.y + m20 * v.z + 0 * 1
        let ry = m01 * v.x + m11 * v.y + m21 * v.z + 0 * 1
        let rz = m02 * v.x + m12 * v.y + m22 * v.z + 0 * 1
        return ACad.XYZ(isZero(rx) ? 0 : rx, isZero(ry) ? 0 : ry, isZero(rz) ? 0 : rz)
    }

    /// `Line3D.FindIntersection`: the exact intersection point, or NaN when the closest points differ.
    static func intersection(_ origin0: ACad.XYZ, _ direction0: ACad.XYZ, _ origin1: ACad.XYZ, _ direction1: ACad.XYZ) -> ACad.XYZ {
        let u = normalize(direction0), v = normalize(direction1)
        let w0 = origin0 - origin1
        func dot(_ a: ACad.XYZ, _ b: ACad.XYZ) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
        let a = dot(u, u), b = dot(u, v), c = dot(v, v), d = dot(u, w0), e = dot(v, w0)
        let sc = ((b * e) - (c * d)) / ((a * c) - (b * b))
        let tc = ((a * e) - (b * d)) / ((a * c) - (b * b))
        let pt1 = origin0 + u * sc
        let pt2 = origin1 + v * tc
        return pt1.x == pt2.x && pt1.y == pt2.y && pt1.z == pt2.z ? pt1 : ACad.XYZ(.nan, .nan, .nan)
    }
}

/// .NET custom numeric format strings for the patterns ACadSharp builds ("0.00", "#.##", "0.##E+00").
enum NetCustomFormat {
    /// `value.ToString("L.TTT")` with `L`, `T` each '0' or '#'.
    static func fixed(_ value: Double, leading: Character, decimals: Int, trailing: Character, separator: String) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        var (digits, exponent) = significantDigits(value)
        var pointPosition = exponent + 1 // digits before the decimal point
        // Round the 15 significant digits half away from zero at the last shown decimal.
        let keep = pointPosition + decimals
        if keep < digits.count {
            let roundUp = keep >= 0 && digits[keep] >= 5
            digits = keep > 0 ? Array(digits[..<keep]) : []
            if roundUp && increment(&digits) { pointPosition += 1 }
        }

        var integer = ""
        if pointPosition > 0 {
            for i in 0..<pointPosition { integer += i < digits.count ? String(digits[i]) : "0" }
            while integer.count > 1 && integer.hasPrefix("0") { integer.removeFirst() }
            if integer == "0" && leading == "#" { integer = "" }
        } else if leading == "0" {
            integer = "0"
        }
        var fraction = ""
        for i in 0..<decimals {
            let index = pointPosition + i
            fraction += index >= 0 && index < digits.count ? String(digits[index]) : "0"
        }
        if trailing == "#" { while fraction.hasSuffix("0") { fraction.removeLast() } }
        let result = fraction.isEmpty ? integer : integer + separator + fraction
        // A negative number that rounds to zero loses its sign.
        return (value < 0 && digits.contains { $0 != 0 } ? "-" : "") + result
    }

    /// Adds one unit in the last place; true when a digit was added in front (9.99 → 10.0).
    private static func increment(_ digits: inout [Int]) -> Bool {
        var i = digits.count - 1
        while i >= 0 {
            digits[i] += 1
            if digits[i] < 10 { return false }
            digits[i] = 0
            i -= 1
        }
        digits.insert(1, at: 0)
        return true
    }

    /// `value.ToString("0.TTTE+00")`.
    static func scientific(_ value: Double, decimals: Int, trailing: Character) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        var (mantissa, exponent) = significantDigits(value)
        if mantissa.allSatisfy({ $0 == 0 }) { exponent = 0 }
        if decimals + 1 < mantissa.count {
            let roundUp = mantissa[decimals + 1] >= 5
            mantissa = Array(mantissa[...decimals])
            if roundUp && increment(&mantissa) {
                mantissa.removeLast()
                exponent += 1
            }
        }
        var fraction = ""
        for i in 0..<decimals { fraction += i + 1 < mantissa.count ? String(mantissa[i + 1]) : "0" }
        if trailing == "#" { while fraction.hasSuffix("0") { fraction.removeLast() } }
        let exponentText = String(abs(exponent))
        return (value < 0 && mantissa.contains { $0 != 0 } ? "-" : "") + String(mantissa.first ?? 0) + (fraction.isEmpty ? "" : "." + fraction)
            + "E" + (exponent < 0 ? "-" : "+") + (exponentText.count < 2 ? "0" + exponentText : exponentText)
    }

    /// The value rounded to 15 significant digits (what .NET formats custom patterns from) and its decimal exponent.
    private static func significantDigits(_ value: Double) -> ([Int], Int) {
        if value == 0 { return ([0], 0) }
        let text = String(format: "%.14e", locale: nil, abs(value)) // d.ddddddddddddddde±XX
        let parts = text.split(separator: "e")
        let digits = parts[0].compactMap { $0.wholeNumberValue }
        let exponent = Int(parts[1]) ?? 0
        return (digits, exponent)
    }
}
