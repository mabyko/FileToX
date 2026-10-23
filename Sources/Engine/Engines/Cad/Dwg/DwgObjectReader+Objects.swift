// ACadSharp 3.8.0 `DwgObjectReader`: the non-graphical objects (dictionaries, layouts and plot settings, groups,
// xrecords, multiline styles, image and PDF definitions, scales, sort tables, colours, spatial filters, visual
// styles, materials and geographic data).

import Foundation

private typealias A = ACad

extension ACad {
    /// `AecBinRecord`: the binary payload of an AEC entity (proprietary format, kept as bytes).
    final class AecBinRecord: NonGraphicalObject {
        var version: Int32 = 0
        var binaryData = Data()

        override var objectName: String { DxfFileToken.objectBinRecord }
        override var subclassMarker: String { DxfSubclassMarker.binRecord }
    }

    /// `CadGeoDataTemplate`.
    final class CadGeoDataTemplate: CadTemplate {
        var hostBlockHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let host: BlockRecord = tableReference(builder, hostBlockHandle, nil) {
                (cadObject as! GeoData).hostBlock = host
            }
        }
    }
}

extension ACad.DwgObjectReader {
    // ───────────────────────── Dictionaries ─────────────────────────

    private func readCommonDictionary(_ template: ACad.CadDictionaryTemplate) throws {
        try readCommonNonEntityData(template)
        let dictionary = template.cadObject as! A.CadDictionary

        // Numitems L number of dictonary items
        let nentries = try objectReader.readBitLong()
        // R14 Only: Unknown R14 RC, has always been 0
        if version == .ac1014 { _ = try objectReader.readByte() }
        // R2000 +:
        if r2000Plus {
            // Cloning flag BS 281
            dictionary.cloningFlags = try objectReader.readBitShort()
            // Hard Owner flag RC 280
            dictionary.hardOwnerFlag = try objectReader.readByte() > 0
        }

        if nentries > 0 {
            for _ in 0..<nentries {
                // Text TV string name of dictionary entry
                let name = try textReader.readVariableText()
                // itemhandles (soft owner)
                let handle = try handleReference()
                if handle == 0 || name.isEmpty { continue }
                // `Dictionary.Add`: a repeated name fails the object.
                if template.entries.contains(where: { $0.0 == name }) { throw A.DwgError.duplicateKey(name) }
                template.entries.append((name, handle))
            }
        }
    }

    func readDictionary() throws -> ACad.CadTemplate? {
        let template = A.CadDictionaryTemplate(A.CadDictionary())
        try readCommonDictionary(template)
        return template
    }

    func readDictionaryVar() throws -> ACad.CadTemplate? {
        let dictvar = A.DictionaryVariable(name: "", value: "")
        let template = A.CadTemplate(dictvar)
        try readCommonNonEntityData(template)
        // Intval RC an integer value
        _ = try objectReader.readByte()
        // BS a string
        dictvar.value = try textReader.readVariableText()
        return template
    }

    func readDictionaryWithDefault() throws -> ACad.CadTemplate? {
        let template = A.CadDictionaryWithDefaultTemplate(A.CadDictionaryWithDefault())
        try readCommonDictionary(template)
        // H 7 Default entry (hard pointer)
        template.defaultEntryHandle = try handleReference()
        return template
    }

    // ───────────────────────── Layouts and plot settings ─────────────────────────

    func readLayout() throws -> ACad.CadTemplate? {
        let layout = A.Layout()
        let template = A.CadLayoutTemplate(layout)
        try readCommonNonEntityData(template)
        try readPlotSettings(layout)

        let r = objectReader!
        // Layout name TV 1
        layout.name = try textReader.readVariableText()
        // Tab order BL 71
        layout.tabOrder = try r.readBitLong()
        // Flag BS 70
        layout.layoutFlags = try r.readBitShort()
        // Ucs origin 3BD 13
        layout.origin = try r.read3BitDouble()
        // Limmin 2RD 10, Limmax 2RD 11
        layout.minLimits = try r.read2RawDouble()
        layout.maxLimits = try r.read2RawDouble()
        // Inspoint 3BD 12
        layout.insertionBasePoint = try r.read3BitDouble()
        // Ucs x axis 3BD 16, Ucs y axis 3BD 17
        layout.xAxis = try r.read3BitDouble()
        layout.yAxis = try r.read3BitDouble()
        // Elevation BD 146
        layout.elevation = try r.readBitDouble()
        // Orthoview type BS 76
        layout.ucsOrthographicType = try r.readBitShort()
        // Extmin 3BD 14, Extmax 3BD 15
        layout.minExtents = try r.read3BitDouble()
        layout.maxExtents = try r.read3BitDouble()

        // R2004 +: Viewport count RL
        var nLayouts: Int32 = 0
        if r2004Plus { nLayouts = try r.readBitLong() }

        // 330 associated paperspace block record handle(soft pointer)
        template.paperSpaceBlockHandle = try handleReference()
        // 331 last active viewport handle(soft pointer)
        template.activeViewportHandle = try handleReference()
        // 346 base ucs handle(hard pointer)
        template.baseUcsHandle = try handleReference()
        // 345 named ucs handle(hard pointer)
        template.namesUcsHandle = try handleReference()

        // R2004+: Viewport handle(repeats Viewport count times) (soft pointer)
        if r2004Plus && nLayouts > 0 {
            for _ in 0..<nLayouts { template.viewportHandles.insert(try handleReference()) }
        }
        return template
    }

    func readPlotSettings() throws -> ACad.CadTemplate? {
        let plotsettings = A.PlotSettings()
        let template = A.CadTemplate(plotsettings)
        try readCommonNonEntityData(template)
        try readPlotSettings(plotsettings)
        return template
    }

    private func readPlotSettings(_ plot: ACad.PlotSettings) throws {
        let r = objectReader!
        // Page setup name TV 1
        plot.pageName = try textReader.readVariableText()
        // Printer / Config TV 2
        plot.systemPrinterName = try textReader.readVariableText()
        // Plot layout flags BS 70
        plot.flags = try r.readBitShort()

        // Left, Bottom, Right, Top Margin BD 40 … 43
        var margin = A.PaperMargin()
        margin.left = try r.readBitDouble()
        margin.bottom = try r.readBitDouble()
        margin.right = try r.readBitDouble()
        margin.top = try r.readBitDouble()
        plot.unprintableMargin = margin

        // Paper Width BD 44, Paper Height BD 45
        plot.paperWidth = try r.readBitDouble()
        plot.paperHeight = try r.readBitDouble()
        // Paper Size TV 4
        plot.paperSize = try textReader.readVariableText()
        // Plot origin 2BD 46,47
        plot.plotOriginX = try r.readBitDouble()
        plot.plotOriginY = try r.readBitDouble()
        // Paper units BS 72, Plot rotation BS 73, Plot type BS 74
        plot.paperUnits = try r.readBitShort()
        plot.paperRotation = try r.readBitShort()
        plot.plotType = try r.readBitShort()
        // Window min 2BD 48,49, Window max 2BD 140,141
        plot.windowLowerLeftX = try r.readBitDouble()
        plot.windowLowerLeftY = try r.readBitDouble()
        plot.windowUpperLeftX = try r.readBitDouble()
        plot.windowUpperLeftY = try r.readBitDouble()

        // R13 - R2000 Only: Plot view name T 6
        if version >= .ac1012 && version <= .ac1015 {
            plot.plotViewName = try textReader.readVariableText()
        }

        // Real world units BD 142, Drawing units BD 143 (both setters require > 0)
        let numerator = try r.readBitDouble()
        guard numerator > 0 else { throw A.DwgError("Value must be greater than zero (Parameter 'NumeratorScale')") }
        plot.numeratorScale = numerator
        let denominator = try r.readBitDouble()
        guard denominator > 0 else { throw A.DwgError("Value must be greater than zero (Parameter 'DenominatorScale')") }
        plot.denominatorScale = denominator
        // Current style sheet TV 7
        plot.styleSheet = try textReader.readVariableText()
        // Scale type BS 75
        plot.scaledFit = try r.readBitShort()
        // Scale factor BD 147
        plot.standardScale = try r.readBitDouble()
        // Paper image origin 2BD 148,149
        let origin = try r.read2BitDouble()
        plot.paperImageOriginX = origin.x
        plot.paperImageOriginY = origin.y

        // R2004+:
        if r2004Plus {
            // Shade plot mode BS 76, Shade plot res.Level BS 77
            plot.shadePlotMode = try r.readBitShort()
            plot.shadePlotResolutionMode = try r.readBitShort()
            // Shade plot custom DPI BS 78 (the setter accepts 100 … 32767)
            let dpi = try r.readBitShort()
            guard dpi >= 100 else { throw A.DwgError("The valid shade plot DPI values range from 100 to 23767. (Parameter 'value')") }
            plot.shadePlotDPI = dpi
            // 6 plot view handle(hard pointer)
            _ = try handleReference()
        }

        // R2007 +: Visual Style handle(soft pointer)
        if r2007Plus { _ = try handleReference() }
    }

    // ───────────────────────── Groups, xrecords, styles ─────────────────────────

    func readGroup() throws -> ACad.CadTemplate? {
        let group = A.Group()
        let template = A.CadGroupTemplate(group)
        try readCommonNonEntityData(template)
        // Str TV name of group
        group.description = try textReader.readVariableText()
        // Unnamed BS 1 if group has no name
        _ = try objectReader.readBitShort()
        // Selectable BS 1 if group selectable
        group.selectable = try objectReader.readBitShort() > 0
        // Numhandles BL # objhandles in this group
        let numhandles = try objectReader.readBitLong()
        if numhandles > 0 {
            for _ in 0..<numhandles { template.handles.insert(try handleReference()) }
        }
        return template
    }

    func readXRecord() throws -> ACad.CadTemplate? {
        let xRecord = A.XRecord()
        let template = A.CadXRecordTemplate(xRecord)
        try readCommonNonEntityData(template)

        let r = objectReader!
        // Numdatabytes BL number of databytes
        let offset = Int(try r.readBitLong()) + r.position
        // Databytes X: pairs of RS indicator number (the DXF group code) and the data.
        while r.position < offset {
            let code = Int(try r.readShort())
            switch A.GroupCodeValueType.of(code) {
            case .string, .extendedDataString:
                xRecord.entries.append(.init(code: code, value: .string(try r.readTextUnicode())))
            case .point3D:
                xRecord.entries.append(.init(code: code, value: .point(A.XYZ(try r.readDouble(), try r.readDouble(), try r.readDouble()))))
            case .double, .extendedDataDouble:
                xRecord.entries.append(.init(code: code, value: .double(try r.readDouble())))
            case .byte:
                xRecord.entries.append(.init(code: code, value: .byte(try r.readByte())))
            case .int16, .extendedDataInt16:
                xRecord.entries.append(.init(code: code, value: .int16(try r.readShort())))
            case .int32, .extendedDataInt32:
                // ReadRawLong boxes a long.
                xRecord.entries.append(.init(code: code, value: .int64(try r.readRawLong())))
            case .int64:
                // ReadRawULong boxes a ulong.
                xRecord.entries.append(.init(code: code, value: .int64(Int64(bitPattern: try r.readRawULong()))))
            case .handle:
                let hex = try r.readTextUnicode()
                if let result = UInt64(hex.trimmingCharacters(in: .whitespaces), radix: 16) {
                    template.handleReferences.append((code, result))
                } else {
                    notify("Failed to parse \(hex) to handle")
                }
            case .bool:
                xRecord.entries.append(.init(code: code, value: .bool(try r.readByte() > 0)))
            case .chunk, .extendedDataChunk:
                xRecord.entries.append(.init(code: code, value: .bytes(Data(try r.readBytes(Int(try r.readByte()))))))
            case .objectId, .extendedDataHandle:
                template.handleReferences.append((code, try r.readRawULong()))
            default:
                notify("Unidentified GroupCodeValueType \(code) for XRecord [\(xRecord.handle)]")
            }
        }

        // R2000+: Cloning flag BS 280
        if r2000Plus { xRecord.cloningFlags = try r.readBitShort() }

        // objid object handles, as many as you can read until you run out of data
        let end = objectInitialPos + Int(size) * 8 - 7
        while handlesReader.positionInBits() < end {
            _ = try handleReference()
        }
        return template
    }

    func readDbColor() throws -> ACad.CadTemplate? {
        let bookColor = A.BookColor()
        let template = A.CadNonGraphicalObjectTemplate(bookColor)
        try readCommonNonEntityData(template)

        let colorIndex = try objectReader.readBitShort()
        if r2004Plus {
            let trueColor = UInt32(bitPattern: try objectReader.readBitLong())
            let flags = try objectReader.readByte()
            if flags & 1 != 0 { bookColor.colorName = try textReader.readVariableText() }
            if flags & 2 != 0 { bookColor.bookName = try textReader.readVariableText() }
            bookColor.color = rgb(trueColor)
        } else {
            bookColor.color = try A.Color.checked(index: colorIndex)
        }
        return template
    }

    /// `new Color(arr[2], arr[1], arr[0])` of the little-endian bytes of a BL colour.
    private func rgb(_ value: UInt32) -> ACad.Color {
        A.Color(UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value))
    }

    func readMLineStyle() throws -> ACad.CadTemplate? {
        let mlineStyle = A.MLineStyle()
        let template = A.CadMLineStyleTemplate(mlineStyle)
        try readCommonNonEntityData(template)

        // Name TV, Desc TV
        mlineStyle.name = try textReader.readVariableText()
        mlineStyle.description = try textReader.readVariableText()
        // Flags BS: DWG bits map to other DXF bits (1↔2, 32↔64, 512↔1024).
        let flags = try objectReader.readBitShort()
        if flags & 1 != 0 { mlineStyle.flags |= 2 } // DisplayJoints
        if flags & 2 != 0 { mlineStyle.flags |= 1 } // FillOn
        if flags & 16 != 0 { mlineStyle.flags |= 16 } // StartSquareCap
        if flags & 32 != 0 { mlineStyle.flags |= 64 } // StartRoundCap
        if flags & 64 != 0 { mlineStyle.flags |= 32 } // StartInnerArcsCap
        if flags & 256 != 0 { mlineStyle.flags |= 256 } // EndSquareCap
        if flags & 512 != 0 { mlineStyle.flags |= 1024 } // EndRoundCap
        if flags & 1024 != 0 { mlineStyle.flags |= 512 } // EndInnerArcsCap

        // fillcolor CMC
        mlineStyle.fillColor = try mergedReaders.readCmColor(useTextStream: false)
        // startang BD, endang BD
        mlineStyle.startAngle = try objectReader.readBitDouble()
        mlineStyle.endAngle = try objectReader.readBitDouble()

        // linesinstyle RC
        let nlines = Int(try objectReader.readByte())
        for _ in 0..<nlines {
            let element = A.MLineStyle.Element()
            let elementTemplate = A.CadMLineStyleTemplate.ElementTemplate(element)
            // Offset BD, Color CMC
            element.offset = try objectReader.readBitDouble()
            element.color = try mergedReaders.readCmColor(useTextStream: false)
            if r2018Plus {
                // Line type handle H (hard pointer)
                elementTemplate.lineTypeHandle = try handleReference()
            } else {
                // Ltindex BS Linetype index (yes, index)
                elementTemplate.lineTypeIndex = Int32(try objectReader.readBitShort())
            }
            template.elementTemplates.append(elementTemplate)
            mlineStyle.addElement(element)
        }
        return template
    }

    // ───────────────────────── Images, PDF, scales, sort tables ─────────────────────────

    func readImageDefinition() throws -> ACad.CadTemplate? {
        let definition = A.ImageDefinition()
        let template = A.CadNonGraphicalObjectTemplate(definition)
        try readCommonNonEntityData(template)
        // Clsver BL 0 class version
        definition.classVersion = try mergedReaders.readBitLong()
        // Imgsize 2RD 10 size of image in pixels
        definition.size = try mergedReaders.read2RawDouble()
        // Filepath TV 1
        definition.fileName = try mergedReaders.readVariableText()
        // Isloaded B 280
        definition.isLoaded = try mergedReaders.readBit()
        // Resunits RC 281
        definition.units = try mergedReaders.readByte()
        // Pixelsize 2RD 11
        definition.defaultSize = try mergedReaders.read2RawDouble()
        return template
    }

    func readImageDefinitionReactor() throws -> ACad.CadTemplate? {
        let definition = A.ImageDefinitionReactor()
        let template = A.CadNonGraphicalObjectTemplate(definition)
        try readCommonNonEntityData(template)
        // Classver BL 90 class version
        definition.classVersion = try objectReader.readBitLong()
        return template
    }

    func readPdfDefinition() throws -> ACad.CadTemplate? {
        let definition = A.PdfUnderlayDefinition()
        let template = A.CadNonGraphicalObjectTemplate(definition)
        try readCommonNonEntityData(template)
        definition.file = try objectReader.readVariableText()
        definition.page = try objectReader.readVariableText()
        return template
    }

    func readRasterVariables() throws -> ACad.CadTemplate? {
        let vars = A.RasterVariables()
        let template = A.CadNonGraphicalObjectTemplate(vars)
        try readCommonNonEntityData(template)
        // Classver BL 90
        vars.classVersion = try mergedReaders.readBitLong()
        // Dispfrm BS 70
        vars.isDisplayFrameShown = try mergedReaders.readBitShort() != 0
        // Dispqual BS 71
        vars.displayQuality = try mergedReaders.readBitShort()
        // Units BS 72
        vars.units = try mergedReaders.readBitShort()
        return template
    }

    func readWipeoutVariables() throws -> ACad.CadTemplate? {
        let wipeoutVariables = A.WipeoutVariables()
        let template = A.CadNonGraphicalObjectTemplate(wipeoutVariables)
        try readCommonNonEntityData(template)
        wipeoutVariables.displayFrame = try mergedReaders.readBitShort() != 0
        return template
    }

    func readScale() throws -> ACad.CadTemplate? {
        let scale = A.Scale()
        let template = A.CadTemplate(scale)
        try readCommonNonEntityData(template)
        // BS 70 Unknown(ODA writes 0).
        _ = try mergedReaders.readBitShort()
        // TV 300 Name
        scale.name = try mergedReaders.readVariableText()
        // BD 140 Paper units, BD 141 Drawing units
        scale.paperUnits = try mergedReaders.readBitDouble()
        scale.drawingUnits = try mergedReaders.readBitDouble()
        // B 290 Has unit scale
        scale.isUnitScale = try mergedReaders.readBit()
        return template
    }

    func readSortentsTable() throws -> ACad.CadTemplate? {
        let sortTable = A.SortEntitiesTable()
        sortTable.name = A.SortEntitiesTable.dictionaryEntryName
        let template = A.CadSortensTableTemplate(sortTable)
        try readCommonNonEntityData(template)
        // parenthandle (soft pointer)
        template.blockOwnerHandle = try handleReference()
        // Numentries BL number of entries
        let numentries = try mergedReaders.readBitLong()
        if numentries > 0 {
            for _ in 0..<numentries {
                // Sort handle (part of the main bit stream), then the entity handle in the handle stream.
                let sortHandle = try objectReader.handleReference(0)
                let entityHandle = try handleReference()
                template.values.append((sortHandle, entityHandle))
            }
        }
        return template
    }

    func readPlaceHolder() throws -> ACad.CadTemplate? {
        let template = A.CadTemplate(A.AcdbPlaceHolder())
        try readCommonNonEntityData(template)
        return template
    }

    func readBinRecord() throws -> ACad.CadTemplate? {
        let binRecord = A.AecBinRecord()
        let template = A.CadNonGraphicalObjectTemplate(binRecord)
        try readCommonNonEntityData(template)
        // Version information
        if r2000Plus { binRecord.version = try mergedReaders.readBitLong() }
        // The remaining data (the two NotificationType.None messages are not passed on by Filee).
        let currentPos = mergedReaders.positionInBits()
        let endPos = objectInitialPos + Int(size) * 8
        let remainingBits = endPos - currentPos
        if remainingBits > 0 {
            let remainingBytes = remainingBits / 8
            if remainingBytes > 0 { binRecord.binaryData = Data(try mergedReaders.readBytes(remainingBytes)) }
        }
        return template
    }

    // ───────────────────────── Spatial filters, visual styles ─────────────────────────

    /// `read4x3Matrix`: rows 0 … 2 of a `Matrix4` (12 values, `M00 … M23`).
    func readSpatialFilter() throws -> ACad.CadTemplate? {
        let filter = A.SpatialFilter()
        let template = A.CadNonGraphicalObjectTemplate(filter)
        try readCommonNonEntityData(template)
        // Numpts BS 70
        let numPts = try mergedReaders.readBitShort()
        if numPts > 0 {
            for _ in 0..<numPts { filter.boundaryPoints.append(try mergedReaders.read2RawDouble()) }
        }
        // Extrusion 3BD 210
        filter.normal = try mergedReaders.read3BitDouble()
        // Clipbdorg 3BD 10
        filter.origin = try mergedReaders.read3BitDouble()
        // Dispbound BS 71
        filter.displayBoundary = try mergedReaders.readBitShort() != 0
        // Frontclipon BS 72, Frontdist BD 40
        filter.clipFrontPlane = try mergedReaders.readBitShort() != 0
        if filter.clipFrontPlane { filter.frontDistance = try mergedReaders.readBitDouble() }
        // Backclipon BS 73, Backdist BD 41
        filter.clipBackPlane = try mergedReaders.readBitShort() != 0
        if filter.clipBackPlane { filter.backDistance = try mergedReaders.readBitDouble() }
        // Invblktr 12BD 40, clipbdtr 12BD 40
        filter.inverseInsertTransform = try read4x3Matrix()
        filter.insertTransform = try read4x3Matrix()
        return template
    }

    func readVisualStyle() throws -> ACad.CadTemplate? {
        // Visual styles are kept only so that references to them resolve (as in the DXF reader).
        let visualStyle = A.UnmodelledObject(dxfName: A.DxfFileToken.objectVisualStyle)
        let template = A.CadTemplate(visualStyle)
        try readCommonNonEntityData(template)
        // The object is not documented: 2 Name, 70 Type, 177, 291, then a count; the rest is not read.
        visualStyle.name = try textReader.readVariableText()
        _ = try objectReader.readBitLong()
        _ = try objectReader.readBitShort()
        _ = try objectReader.readBit()
        _ = try objectReader.readBitLong()
        return template
    }

    // ───────────────────────── Materials ─────────────────────────

    /// `Material.*ColorFactor` setters: `ObjectExtensions.InRange(value, 0, 1)`.
    private func colorFactor(_ value: Double) throws -> Double {
        guard !(value > 1 || value < 0 || value.isNaN) else {
            throw A.DwgError("Specified argument was out of the range of valid values.")
        }
        return value
    }

    private func readMatrix4() throws -> [Double] {
        var values: [Double] = []
        for _ in 0..<16 { values.append(try mergedReaders.readBitDouble()) }
        return values
    }

    /// One map channel: blend factor, mapper (projection, tiling, auto transform, matrix) and source.
    private func readMapChannel(_ channel: inout ACad.Material.MapChannel) throws {
        channel.blendFactor = try mergedReaders.readBitDouble()
        channel.projection = try mergedReaders.readByte()
        channel.tiling = try mergedReaders.readByte()
        channel.autoTransform = try mergedReaders.readByte()
        channel.matrix = try readMatrix4()
        channel.source = try mergedReaders.readByte()
        switch channel.source {
        case 1: // UseImageFile
            channel.fileName = try mergedReaders.readVariableText()
        case 2: // Procedural: AcGiMaterialMap::Source Enumeration contains the missing type
            throw A.DwgError.notImplemented
        default:
            break
        }
    }

    func readMaterial() throws -> ACad.CadTemplate? {
        let material = A.Material()
        let template = A.CadTemplate(material)
        try readCommonNonEntityData(template)
        let r = mergedReaders!

        // Name VT 1, Description VT 2
        material.name = try r.readVariableText()
        material.description = try r.readVariableText()

        // Ambient: method B 70, factor 40, colour 90 when overridden
        material.ambientColorMethod = try r.readByte()
        material.ambientColorFactor = try colorFactor(try r.readBitDouble())
        if material.ambientColorMethod == 1 {
            material.ambientColor = rgb(UInt32(bitPattern: try r.readBitLong()))
        }

        // Diffuse: method 71, factor 41, colour 91, then the map
        material.diffuseColorMethod = try r.readByte()
        material.diffuseColorFactor = try colorFactor(try r.readBitDouble())
        if material.diffuseColorMethod == 1 {
            material.diffuseColor = rgb(UInt32(bitPattern: try r.readBitLong()))
        }
        try readMapChannel(&material.diffuse)

        // Specular: method 76, factor 45, colour 92, the map, then the gloss factor 44
        material.specularColorMethod = try r.readByte()
        material.specularColorFactor = try colorFactor(try r.readBitDouble())
        if material.specularColorMethod == 1 {
            material.specularColor = rgb(UInt32(bitPattern: try r.readBitLong()))
        }
        try readMapChannel(&material.specular)
        material.specularGlossFactor = try r.readBitDouble()

        // Reflection map, then the opacity 140
        try readMapChannel(&material.reflection)
        material.opacity = try r.readBitDouble()

        // Opacity map
        try readMapChannel(&material.opacityMap)

        // Bump map, then the refraction index 145
        try readMapChannel(&material.bump)
        material.refractionIndex = try r.readBitDouble()

        // Refraction map
        try readMapChannel(&material.refraction)

        // R2007+: the tail block with the render-mode hints.
        if r2007Plus {
            material.translucence = try r.readBitDouble()
            material.selfIllumination = try r.readBitDouble()
            material.reflectivity = try r.readBitDouble()
            material.illuminationModel = try r.readBitLong()
            material.channelFlags = try r.readBitLong()
            material.mode = try r.readBitLong()
        }
        return template
    }

    // ───────────────────────── Geographic data ─────────────────────────

    func readGeoData() throws -> ACad.CadTemplate? {
        let geoData = A.GeoData()
        let template = A.CadGeoDataTemplate(geoData)
        try readCommonNonEntityData(template)
        let r = mergedReaders!

        // BL Object version formats
        geoData.version = try r.readBitLong()
        // H Soft pointer to host block
        template.hostBlockHandle = try handleReference()
        // BS Design coordinate type
        geoData.coordinatesType = try r.readBitShort()

        /// `(UnitsType)int`: the short enum keeps the low 16 bits.
        func units(_ value: Int32) -> Int32 { Int32(Int16(truncatingIfNeeded: value)) }

        switch geoData.version {
        case A.GeoData.GeoDataVersion.r2009:
            geoData.referencePoint = try r.read3BitDouble()
            geoData.horizontalUnits = units(try r.readBitLong())
            geoData.verticalUnits = geoData.horizontalUnits
            geoData.designPoint = try r.read3BitDouble()
            // Obsolete, ODA writes (0, 0, 0)
            _ = try r.read3BitDouble()
            geoData.upDirection = try r.read3BitDouble()
            // Angle of north direction (radians, clockwise from the (0, 1) vector).
            let angle = Double.pi / 2.0 - (try r.readBitDouble())
            geoData.northDirection = A.XY(cos(angle), sin(angle))
            // Obsolete, ODA writes(1, 1, 1)
            _ = try r.read3BitDouble()
            geoData.coordinateSystemDefinition = try r.readVariableText()
            geoData.geoRssTag = try r.readVariableText()
            geoData.horizontalUnitScale = try r.readBitDouble()
            geoData.verticalUnitScale = geoData.horizontalUnitScale
            // Obsolete: coordinate system datum name and WKT
            _ = try r.readVariableText()
            _ = try r.readVariableText()
        case A.GeoData.GeoDataVersion.r2010, A.GeoData.GeoDataVersion.r2013:
            geoData.designPoint = try r.read3BitDouble()
            geoData.referencePoint = try r.read3BitDouble()
            geoData.horizontalUnitScale = try r.readBitDouble()
            geoData.horizontalUnits = units(try r.readBitLong())
            geoData.verticalUnitScale = try r.readBitDouble()
            // ACadSharp assigns the vertical units to the horizontal ones.
            geoData.horizontalUnits = units(try r.readBitLong())
            geoData.upDirection = try r.read3BitDouble()
            geoData.northDirection = try r.read2RawDouble()
            geoData.scaleEstimationMethod = try r.readBitLong()
            geoData.userSpecifiedScaleFactor = try r.readBitDouble()
            geoData.enableSeaLevelCorrection = try r.readBit()
            geoData.seaLevelElevation = try r.readBitDouble()
            geoData.coordinateProjectionRadius = try r.readBitDouble()
            geoData.coordinateSystemDefinition = try r.readVariableText()
            geoData.geoRssTag = try r.readVariableText()
        default:
            break
        }

        // VT Observation from / to / coverage tags
        geoData.observationFromTag = try r.readVariableText()
        geoData.observationToTag = try r.readVariableText()
        geoData.observationCoverageTag = try r.readVariableText()

        // BL Number of geo mesh points: 2RD source, 2RD destination
        let npts = try r.readBitLong()
        if npts > 0 {
            for _ in 0..<npts {
                var pt = A.GeoData.GeoMeshPoint()
                pt.source = try r.read2RawDouble()
                pt.destination = try r.read2RawDouble()
                geoData.points.append(pt)
            }
        }
        // BL Number of geo mesh faces: BL index 1 … 3
        let nfaces = try r.readBitLong()
        if nfaces > 0 {
            for _ in 0..<nfaces {
                var face = A.GeoData.GeoMeshFace()
                face.index1 = try r.readBitLong()
                face.index2 = try r.readBitLong()
                face.index3 = try r.readBitLong()
                geoData.faces.append(face)
            }
        }
        return template
    }
}
