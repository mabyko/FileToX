// ACadSharp 3.8.0 `DwgObjectReader`: the symbol table control objects and their entries (application ids, block
// headers, dimension styles, layers, line types, text styles, UCS, views, viewports, viewport entity headers).

import Foundation

private typealias A = ACad

extension ACad {
    /// `ViewportEntityHeader`: read so that its handles resolve, never added to the document.
    final class ViewportEntityHeader: TableEntry {
        override var objectType: ObjectType { .vpEntHdr }
    }

    /// `CadViewportEntityControlTemplate.VPEntityPlaceholder`.
    final class ViewportEntityControlPlaceholder: CadObject {}

    /// `CadViewportEntityControlTemplate`.
    final class CadViewportEntityControlTemplate: CadTemplate {
        var entryHandles = HandleSet()
        init() { super.init(ViewportEntityControlPlaceholder()) }
    }

    /// `CadViewportEntityHeaderTemplate`.
    final class CadViewportEntityHeaderTemplate: CadTableEntryTemplate {
        var blockHandle: UInt64?
    }
}

extension ACad.DwgObjectReader {
    /// `TableEntry.Name` setter: null or white space names throw.
    private func setName(_ entry: ACad.TableEntry, _ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ACad.DwgError("Table entry [\(type(of: entry))] must have a name (Parameter 'value')")
        }
        entry.name = name
    }

    func readAppId() throws -> ACad.CadTemplate? {
        let appId = A.AppId(name: "")
        let template = A.CadTemplate(appId)
        try readCommonNonEntityData(template)
        let name = try textReader.readVariableText()
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { appId.name = name }
        try readXrefDependantBit(appId)
        // Unknown RC 71 Undoc'd 71-group; doesn't even appear in DXF or an entget if it's 0.
        _ = try objectReader.readByte()
        // External reference block handle(hard pointer)
        _ = try handleReference()
        return template
    }

    func readBlockControlObject() throws -> ACad.CadTemplate {
        let template = A.CadTableTemplate<A.BlockRecord>(A.BlockRecordsTable())
        let control = A.CadTableTemplate<A.BlockRecord>.BlockControl()
        template.blockControl = control
        try readDocumentTable(template)
        // *MODEL_SPACE and *PAPER_SPACE(hard owner).
        control.modelSpaceHandle = try handleReference()
        control.paperSpaceHandle = try handleReference()
        return template
    }

    func readBlockHeader() throws -> ACad.CadTemplate? {
        let record = A.BlockRecord(name: "")
        let block = record.blockEntity
        let template = A.CadBlockRecordTemplate(record)
        builder.blockRecordTemplates.append(template)

        try readCommonNonEntityData(template)

        // Entry name TV 2 (anonymous blocks do not write the full name, only *{type character})
        let name = try textReader.readVariableText()
        if name.caseInsensitiveCompare(A.BlockRecord.modelSpaceName) == .orderedSame
            || name.caseInsensitiveCompare(A.BlockRecord.paperSpaceName) == .orderedSame {
            record.name = name
        }

        try readXrefDependantBit(record)

        // Anonymous B 1 if this is an anonymous block (1 bit)
        if try objectReader.readBit() { block.blockFlags |= A.BlockTypeFlags.anonymous }
        // Hasatts B 1 if block contains attdefs (2 bit)
        _ = try objectReader.readBit()
        // Blkisxref B 1 if block is xref (4 bit)
        if try objectReader.readBit() { block.blockFlags |= A.BlockTypeFlags.xRef }
        // Xrefoverlaid B 1 if an overlaid xref (8 bit)
        if try objectReader.readBit() { block.blockFlags |= A.BlockTypeFlags.xRefOverlay }

        // R2000+: Loaded Bit B 0 indicates loaded for an xref
        if r2000Plus { block.isUnloaded = try objectReader.readBit() }

        let isXRef = block.blockFlags & (A.BlockTypeFlags.xRef | A.BlockTypeFlags.xRefOverlay) != 0
        // R2004+: Owned Object Count BL
        var nownedObjects: Int32 = 0
        if r2004Plus && block.blockFlags & A.BlockTypeFlags.xRef == 0 && block.blockFlags & A.BlockTypeFlags.xRefOverlay == 0 {
            nownedObjects = try objectReader.readBitLong()
        }

        // Base pt 3BD 10 Base point of block.
        block.basePoint = try objectReader.read3BitDouble()
        // Xref pname TV 1 Xref pathname.
        block.xRefPath = try textReader.readVariableText()

        // R2000+:
        var insertCount = 0
        if r2000Plus {
            // Insert Count RC: zero or more non-zero RC's followed by a terminating 0 RC.
            while try objectReader.readByte() != 0 { insertCount += 1 }
            // Block Description TV 4
            block.comments = try textReader.readVariableText()
            // Size of preview data BL, Binary Preview Data N*RC 310
            let n = try objectReader.readBitLong()
            var data: [UInt8] = []
            if n > 0 {
                for _ in 0..<n { data.append(try objectReader.readByte()) }
            }
            record.preview = Data(data)
        }

        // R2007+:
        if r2007Plus {
            // Insert units BS 70
            record.units = try objectReader.readBitShort()
            // Explodable B 280
            record.isExplodable = try objectReader.readBit()
            // Block scaling RC 281
            record.canScale = try objectReader.readByte() > 0
        }

        // NULL(hard pointer)
        _ = try handleReference()
        // BLOCK entity. (hard owner)
        template.beginBlockHandle = try handleReference()

        // R13-R2000:
        if version >= .ac1012 && version <= .ac1015 && !isXRef {
            // first / last entity in the def. (soft pointer)
            template.firstEntityHandle = try handleReference()
            template.lastEntityHandle = try handleReference()
        }

        // R2004+: H[ENTITY(hard owner)] Repeats "Owned Object Count" times.
        if r2004Plus && nownedObjects > 0 {
            for _ in 0..<nownedObjects { template.ownedObjectsHandlers.insert(try handleReference()) }
        }

        // ENDBLK entity. (hard owner)
        template.endBlockHandle = try handleReference()

        // R2000+:
        if r2000Plus {
            // Insert Handles H N insert handles (soft pointer)
            for _ in 0..<insertCount { template.insertHandles.append(try handleReference()) }
            // Layout Handle H(hard pointer)
            template.layoutHandle = try handleReference()
        }
        return template
    }

    func readDimStyle() throws -> ACad.CadTemplate? {
        let dimStyle = A.DimensionStyle(name: "")
        let template = A.CadDimensionStyleTemplate(dimStyle)
        try readCommonNonEntityData(template)

        let name = try textReader.readVariableText()
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dimStyle.name = name }
        try readXrefDependantBit(dimStyle)

        let r = objectReader!
        // R13 & R14 Only:
        if r13_14Only {
            dimStyle.generateTolerances = try r.readBit()
            dimStyle.limitsGeneration = try r.readBit()
            dimStyle.textOutsideHorizontal = try r.readBit()
            dimStyle.suppressFirstExtensionLine = try r.readBit()
            dimStyle.suppressSecondExtensionLine = try r.readBit()
            dimStyle.textInsideHorizontal = try r.readBit()
            dimStyle.alternateUnitDimensioning = try r.readBit()
            dimStyle.textOutsideExtensions = try r.readBit()
            dimStyle.separateArrowBlocks = try r.readBit()
            dimStyle.textInsideExtensions = try r.readBit()
            dimStyle.suppressOutsideExtensions = try r.readBit()
            dimStyle.alternateUnitDecimalPlaces = Int16(try r.readByte())
            dimStyle.zeroHandling = try r.readRawChar()
            dimStyle.suppressFirstDimensionLine = try r.readBit()
            dimStyle.suppressSecondDimensionLine = try r.readBit()
            dimStyle.toleranceAlignment = try r.readRawChar()
            dimStyle.textHorizontalAlignment = try r.readByte()
            dimStyle.dimensionFit = Int16(try r.readRawChar())
            dimStyle.cursorUpdate = try r.readBit()
            dimStyle.toleranceZeroHandling = try r.readByte()
            dimStyle.alternateUnitZeroHandling = try r.readByte()
            dimStyle.alternateUnitToleranceZeroHandling = try r.readByte()
            dimStyle.textVerticalAlignment = Int32(try r.readByte())
            dimStyle.dimensionUnit = try r.readBitShort()
            dimStyle.angularUnit = try r.readBitShort()
            dimStyle.decimalPlaces = try r.readBitShort()
            dimStyle.toleranceDecimalPlaces = try r.readBitShort()
            dimStyle.alternateUnitFormat = try r.readBitShort()
            dimStyle.alternateUnitToleranceDecimalPlaces = try r.readBitShort()
            try dimStyle.setScaleFactor(try r.readBitDouble())
            try dimStyle.setArrowSize(try r.readBitDouble())
            dimStyle.extensionLineOffset = try r.readBitDouble()
            dimStyle.dimensionLineIncrement = try r.readBitDouble()
            dimStyle.extensionLineExtension = try r.readBitDouble()
            dimStyle.rounding = try r.readBitDouble()
            dimStyle.dimensionLineExtension = try r.readBitDouble()
            dimStyle.plusTolerance = try r.readBitDouble()
            dimStyle.minusTolerance = try r.readBitDouble()
            try dimStyle.setTextHeight(try r.readBitDouble())
            dimStyle.centerMarkSize = try r.readBitDouble()
            dimStyle.tickSize = try r.readBitDouble()
            dimStyle.alternateUnitScaleFactor = try r.readBitDouble()
            dimStyle.linearScaleFactor = try r.readBitDouble()
            dimStyle.textVerticalPosition = try r.readBitDouble()
            dimStyle.toleranceScaleFactor = try r.readBitDouble()
            dimStyle.dimensionLineGap = try r.readBitDouble()
            dimStyle.postFix = try textReader.readVariableText()
            dimStyle.alternateDimensioningSuffix = try textReader.readVariableText()
            template.dimblName = try textReader.readVariableText()
            template.dimblk1Name = try textReader.readVariableText()
            template.dimblk2Name = try textReader.readVariableText()
            dimStyle.dimensionLineColor = try r.readColorByIndex()
            dimStyle.extensionLineColor = try r.readColorByIndex()
            dimStyle.textColor = try r.readColorByIndex()
        }

        // R2000+:
        if r2000Plus {
            dimStyle.postFix = try textReader.readVariableText()
            dimStyle.alternateDimensioningSuffix = try textReader.readVariableText()
            try dimStyle.setScaleFactor(try r.readBitDouble())
            try dimStyle.setArrowSize(try r.readBitDouble())
            dimStyle.extensionLineOffset = try r.readBitDouble()
            dimStyle.dimensionLineIncrement = try r.readBitDouble()
            dimStyle.extensionLineExtension = try r.readBitDouble()
            dimStyle.rounding = try r.readBitDouble()
            dimStyle.dimensionLineExtension = try r.readBitDouble()
            dimStyle.plusTolerance = try r.readBitDouble()
            dimStyle.minusTolerance = try r.readBitDouble()
        }

        // R2007+:
        if r2007Plus {
            dimStyle.fixedExtensionLineLength = try r.readBitDouble()
            // DIMJOGANG: the setter only accepts 5 to 90 degrees (Math.Round(value, 6)).
            let jog = try r.readBitDouble()
            let rounded = (jog * 1e6).rounded(.toNearestOrEven) / 1e6
            if rounded <= A.MathHelper.degToRad(5) || rounded >= A.MathHelper.halfPI {
                throw A.DwgError("The JoggedRadiusDimensionTransverseSegmentAngle must be in range of 5 to 90 degrees. (Parameter 'value')")
            }
            dimStyle.joggedRadiusDimensionTransverseSegmentAngle = jog
            dimStyle.textBackgroundFillMode = try r.readBitShort()
            dimStyle.textBackgroundColor = try mergedReaders.readCmColor(useTextStream: false)
        }

        // R2000+:
        if r2000Plus {
            dimStyle.generateTolerances = try r.readBit()
            dimStyle.limitsGeneration = try r.readBit()
            dimStyle.textInsideHorizontal = try r.readBit()
            dimStyle.textOutsideHorizontal = try r.readBit()
            dimStyle.suppressFirstExtensionLine = try r.readBit()
            dimStyle.suppressSecondExtensionLine = try r.readBit()
            dimStyle.textVerticalAlignment = Int32(try r.readBitShort())
            dimStyle.zeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
            dimStyle.angularZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
        }

        // R2007 +: DIMARCSYM BS 90
        if r2007Plus { dimStyle.arcLengthSymbolPosition = try r.readBitShort() }

        // R2000 +:
        if r2000Plus {
            try dimStyle.setTextHeight(try r.readBitDouble())
            dimStyle.centerMarkSize = try r.readBitDouble()
            dimStyle.tickSize = try r.readBitDouble()
            dimStyle.alternateUnitScaleFactor = try r.readBitDouble()
            dimStyle.linearScaleFactor = try r.readBitDouble()
            dimStyle.textVerticalPosition = try r.readBitDouble()
            dimStyle.toleranceScaleFactor = try r.readBitDouble()
            dimStyle.dimensionLineGap = try r.readBitDouble()
            dimStyle.alternateUnitRounding = try r.readBitDouble()
            dimStyle.alternateUnitDimensioning = try r.readBit()
            dimStyle.alternateUnitDecimalPlaces = try r.readBitShort()
            dimStyle.textOutsideExtensions = try r.readBit()
            dimStyle.separateArrowBlocks = try r.readBit()
            dimStyle.textInsideExtensions = try r.readBit()
            dimStyle.suppressOutsideExtensions = try r.readBit()
            dimStyle.dimensionLineColor = try mergedReaders.readCmColor(useTextStream: false)
            dimStyle.extensionLineColor = try mergedReaders.readCmColor(useTextStream: false)
            dimStyle.textColor = try mergedReaders.readCmColor(useTextStream: false)
            dimStyle.angularDecimalPlaces = try r.readBitShort()
            dimStyle.decimalPlaces = try r.readBitShort()
            dimStyle.toleranceDecimalPlaces = try r.readBitShort()
            dimStyle.alternateUnitFormat = try r.readBitShort()
            dimStyle.alternateUnitToleranceDecimalPlaces = try r.readBitShort()
            dimStyle.angularUnit = try r.readBitShort()
            dimStyle.fractionFormat = try r.readBitShort()
            dimStyle.linearUnitFormat = try r.readBitShort()
            dimStyle.decimalSeparator = UInt16(bitPattern: try r.readBitShort())
            dimStyle.textMovement = try r.readBitShort()
            dimStyle.textHorizontalAlignment = UInt8(truncatingIfNeeded: try r.readBitShort())
            dimStyle.suppressFirstDimensionLine = try r.readBit()
            dimStyle.suppressSecondDimensionLine = try r.readBit()
            dimStyle.toleranceAlignment = UInt8(truncatingIfNeeded: try r.readBitShort())
            dimStyle.toleranceZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
            dimStyle.alternateUnitZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
            dimStyle.alternateUnitToleranceZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
            dimStyle.cursorUpdate = try r.readBit()
            dimStyle.dimensionFit = try r.readBitShort()
        }

        // R2007+: DIMFXLON B 290
        if r2007Plus { dimStyle.isExtensionLineLengthFixed = try r.readBit() }

        // R2010+:
        if r2010Plus {
            // DIMTXTDIRECTION B 295
            dimStyle.textDirection = try r.readBit() ? 1 : 0
            dimStyle.altMzf = try r.readBitDouble()
            dimStyle.altMzs = try textReader.readVariableText()
            dimStyle.mzf = try r.readBitDouble()
            dimStyle.mzs = try textReader.readVariableText()
        }

        // R2000+:
        if r2000Plus {
            dimStyle.dimensionLineWeight = A.LineWeight(try r.readBitShort())
            dimStyle.extensionLineWeight = A.LineWeight(try r.readBitShort())
        }

        // Unknown B 70 Seems to set the 0 - bit(1) of the 70 - group.
        _ = try r.readBit()
        // External reference block handle(hard pointer)
        template.blockHandle = try handleReference()
        // 340 shapefile(DIMTXSTY)(hard pointer)
        template.textStyleHandle = try handleReference()

        // R2000+:
        if r2000Plus {
            template.dimldrblk = try handleReference()
            template.dimblk = try handleReference()
            template.dimblk1 = try handleReference()
            template.dimblk2 = try handleReference()
        }

        // R2007+:
        if r2007Plus {
            template.dimltype = try handleReference()
            template.dimltex1 = try handleReference()
            template.dimltex2 = try handleReference()
        }
        return template
    }

    func readDocumentTable<T: ACad.TableEntry>(_ table: ACad.Table<T>) throws -> ACad.CadTemplate {
        let template = A.CadTableTemplate<T>(table)
        try readDocumentTable(template)
        return template
    }

    @discardableResult
    func readDocumentTable<T: ACad.TableEntry>(_ template: ACad.CadTableTemplate<T>) throws -> ACad.CadTemplate {
        try readCommonNonEntityData(template)
        // Numentries BL 70
        let numentries = try objectReader.readBitLong()
        if numentries > 0 {
            for _ in 0..<numentries {
                // numentries handles in the file (soft owner)
                template.entryHandles.insert(try handleReference())
            }
        }
        return template
    }

    func readLayer() throws -> ACad.CadTemplate? {
        let layer = A.Layer(name: "")
        let template = A.CadLayerTemplate(layer)
        try readCommonNonEntityData(template)

        let name = try textReader.readVariableText()
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { layer.name = name }
        try readXrefDependantBit(layer)

        // R13-R14 Only:
        if r13_14Only {
            // Frozen B 70 if frozen (1 bit)
            if try objectReader.readBit() { layer.flags |= A.LayerFlags.frozen }
            // On B 1 if off (bit set = off)
            layer.isOn = !(try objectReader.readBit())
            // Frz in new B 70 if frozen by default in new viewports (2 bit)
            if try objectReader.readBit() { layer.flags |= A.LayerFlags.frozenNewViewports }
            // Locked B 70 if locked (4 bit)
            if try objectReader.readBit() { layer.flags |= A.LayerFlags.locked }
        }
        // R2000+:
        if r2000Plus {
            // Values BS 70,290,370
            let values = try objectReader.readBitShort()
            if values & 0b1 != 0 { layer.flags |= A.LayerFlags.frozen }
            layer.isOn = values & 0b10 == 0
            if values & 0b100 != 0 { layer.flags |= A.LayerFlags.frozenNewViewports }
            if values & 0b1000 != 0 { layer.flags |= A.LayerFlags.locked }
            layer.plotFlag = values & 0b10000 != 0
            // and lineweight (mask with 0x03E0)
            layer.lineWeight = A.LineWeight.fromIndex(UInt8(truncatingIfNeeded: (values & 0x3E0) >> 5))
        }

        // Color CMC 62
        let color = try mergedReaders.readCmColor(useTextStream: false)
        layer.color = color.isByBlock || color.isByLayer ? A.Color.default : color

        template.layerControlHandle = try handleReference()
        // R2000+: H 390 Plotstyle (hard pointer)
        if r2000Plus { template.plotStyleHandle = try handleReference() }
        // R2007+: H 347 Material
        if r2007Plus { template.materialHandle = try handleReference() }
        // H 6 linetype (hard pointer)
        template.lineTypeHandle = try handleReference()
        // R2013+: H Unknown handle (hard pointer). Always seems to be NULL.
        if r2013Plus { _ = try handleReference() }
        return template
    }

    private func readLineTypeSegmentTexts(_ segments: [ACad.CadLineTypeTemplate.SegmentTemplate], _ textArea: [UInt8]?) {
        guard let textArea, !textArea.isEmpty else { return }
        // `_reader.Encoding`: the object readers are created with it.
        let encoding = objectReader.encoding
        for segment in segments where segment.segment.flags & A.LineTypeShapeFlags.text != 0 {
            let offset = Int(UInt16(bitPattern: segment.segment.shapeNumber))
            if offset >= textArea.count {
                builder.notify("Unable to read linetype text segment; offset \(offset) is outside the available buffer (\(textArea.count) bytes).")
                segment.segment.text = ""
                segment.segment.shapeNumber = 0
                continue
            }
            segment.segment.text = readLineTypeTextString(textArea, offset, encoding)
            segment.segment.shapeNumber = 0
        }
    }

    private func readLineTypeTextString(_ buffer: [UInt8], _ offset: Int, _ encoding: String.Encoding) -> String {
        guard offset >= 0, offset < buffer.count else { return "" }
        // `Encoding.IsSingleByte`: the drawing code pages read through this reader (UTF-8 is not single byte).
        if isSingleByte(encoding) && ACad.DwgObjectReader.looksLikeUtf16Le(buffer, offset) {
            // Trim trailing 0x0000 terminator if present.
            var end = offset
            while end + 1 < buffer.count {
                if buffer[end] == 0 && buffer[end + 1] == 0 { break }
                end += 2
            }
            return String(decoding: Array(buffer[offset..<min(end, buffer.count)]).utf16LittleEndianUnits, as: UTF16.self)
        }
        var endAscii = offset
        while endAscii < buffer.count && buffer[endAscii] != 0 { endAscii += 1 }
        if endAscii == offset { return "" }
        return A.DwgText.decode(Array(buffer[offset..<endAscii]), encoding)
    }

    /// `Encoding.IsSingleByte`.
    private func isSingleByte(_ encoding: String.Encoding) -> Bool {
        CFStringGetMaximumSizeForEncoding(1, CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)) == 1
    }

    func readLType() throws -> ACad.CadTemplate? {
        let ltype = A.LineType(name: "")
        let template = A.CadLineTypeTemplate(ltype)
        try readCommonNonEntityData(template)

        let name = try textReader.readVariableText()
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ltype.name = name }
        try readXrefDependantBit(ltype)

        // Description TV 3
        ltype.description = try textReader.readVariableText()
        // Pattern Len BD 40
        template.totalLen = try objectReader.readBitDouble()
        // Alignment RC 72 Always 'A'.
        ltype.alignment = Character(Unicode.Scalar(try objectReader.readRawChar()))

        // Numdashes RC 73
        let ndashes = Int(try objectReader.readByte())
        var isText = false
        for _ in 0..<ndashes {
            let segment = A.CadLineTypeTemplate.SegmentTemplate()
            // Dash length BD 49
            segment.segment.length = try objectReader.readBitDouble()
            // Complex shapecode BS 75
            segment.segment.shapeNumber = try objectReader.readBitShort()
            // X - offset RD 44, Y - offset RD 45
            segment.segment.offset = A.XY(try objectReader.readDouble(), try objectReader.readDouble())
            // Scale BD 46
            segment.segment.scale = try objectReader.readBitDouble()
            // Rotation BD 50
            segment.segment.rotation = try objectReader.readBitDouble()
            // Shapeflag BS 74
            segment.segment.flags = try objectReader.readBitShort()
            if segment.segment.flags & A.LineTypeShapeFlags.text != 0 { isText = true }
            template.segmentTemplates.append(segment)
        }

        var textarea: [UInt8]?
        // R2004 and earlier: Strings area X 9 256 bytes of text area.
        if version <= .ac1018 { textarea = try objectReader.readBytes(256) }
        // R2007+:
        if r2007Plus && isText { textarea = try objectReader.readBytes(512) }
        if isText { readLineTypeSegmentTexts(template.segmentTemplates, textarea) }

        // Handle refs H Ltype control(soft pointer)
        template.ltypeControlHandle = try handleReference()
        // 340 shapefile for dash/shape (1 each) (hard pointer)
        for i in 0..<ndashes {
            template.segmentTemplates[i].styleHandle = try handleReference()
        }
        return template
    }

    func readLTypeControlObject() throws -> ACad.CadTemplate {
        let template = A.CadTableTemplate<A.LineType>(A.LineTypesTable())
        try readDocumentTable(template)
        // the linetypes, ending with BYLAYER and BYBLOCK (hard owner references).
        template.entryHandles.insert(try handleReference())
        template.entryHandles.insert(try handleReference())
        return template
    }

    func readTextStyle() throws -> ACad.CadTemplate? {
        let style = A.TextStyle(name: "")
        let template = A.CadTableEntryTemplate(style)
        try readCommonNonEntityData(template)

        let name = try textReader.readVariableText()
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { style.name = name }
        try readXrefDependantBit(style)

        // shape file B 1 if a shape file rather than a font (1 bit)
        if try objectReader.readBit() { style.flags |= A.StyleFlags.isShape }
        // Vertical B 1 if vertical (4 bit of flag)
        if try objectReader.readBit() { style.flags |= A.StyleFlags.verticalText }
        // Fixed height BD 40
        style.height = try objectReader.readBitDouble()
        // Width factor BD 41
        style.width = try objectReader.readBitDouble()
        // Oblique ang BD 50
        style.obliqueAngle = try objectReader.readBitDouble()
        // Generation RC 71
        style.mirrorFlag = Int16(try objectReader.readByte())
        // Last height BD 42
        style.lastHeight = try objectReader.readBitDouble()
        // Font name TV 3
        style.filename = try textReader.readVariableText()
        // Bigfont name TV 4
        style.bigFontFilename = try textReader.readVariableText()
        // style control (soft pointer)
        _ = try handleReference()
        return template
    }

    func readUcs() throws -> ACad.CadTemplate? {
        let ucs = A.UCS(name: "")
        let template = A.CadTemplate(ucs)
        try readCommonNonEntityData(template)

        try setName(ucs, try textReader.readVariableText())
        try readXrefDependantBit(ucs)

        ucs.origin = try objectReader.read3BitDouble()
        ucs.xAxis = try objectReader.read3BitDouble()
        ucs.yAxis = try objectReader.read3BitDouble()

        if r2000Plus {
            ucs.elevation = try objectReader.readBitDouble()
            ucs.orthographicViewType = try objectReader.readBitShort()
            ucs.orthographicType = try objectReader.readBitShort()
        }

        // ucs control object (soft pointer)
        _ = try handleReference()
        if r2000Plus {
            // Base UCS Handle H 346 hard pointer, Named UCS Handle H
            _ = try handleReference()
            _ = try handleReference()
        }
        return template
    }

    func readView() throws -> ACad.CadTemplate? {
        let view = A.View(name: "")
        let template = A.CadViewTemplate(view)
        try readCommonNonEntityData(template)

        try setName(view, try textReader.readVariableText())
        try readXrefDependantBit(view)

        view.height = try objectReader.readBitDouble()
        view.width = try objectReader.readBitDouble()
        view.center = try objectReader.read2RawDouble()
        view.target = try objectReader.read3BitDouble()
        view.direction = try objectReader.read3BitDouble()
        view.angle = try objectReader.readBitDouble()
        view.lensLength = try objectReader.readBitDouble()
        view.frontClipping = try objectReader.readBitDouble()
        view.backClipping = try objectReader.readBitDouble()

        // View mode X 71 4 bits: 0123
        if try objectReader.readBit() { view.viewMode |= 1 } // PerspectiveView
        if try objectReader.readBit() { view.viewMode |= 2 } // FrontClipping
        if try objectReader.readBit() { view.viewMode |= 4 } // BackClipping
        if try objectReader.readBit() { view.viewMode |= 16 } // FrontClippingZ

        // R2000+: Render Mode RC 281
        if r2000Plus { view.renderMode = try objectReader.readByte() }

        // R2007+: default lights, lighting, brightness, contrast, ambient colour (not kept)
        if r2007Plus {
            _ = try mergedReaders.readBit()
            _ = try mergedReaders.readByte()
            _ = try mergedReaders.readBitDouble()
            _ = try mergedReaders.readBitDouble()
            _ = try mergedReaders.readCmColor(useTextStream: false)
        }

        // Pspace flag B 70 Bit 0(1) of the 70 - group.
        if try objectReader.readBit() { view.flags |= 0b1 }

        if r2000Plus {
            view.isUcsAssociated = try objectReader.readBit()
            if view.isUcsAssociated {
                view.ucsOrigin = try objectReader.read3BitDouble()
                view.ucsXAxis = try objectReader.read3BitDouble()
                view.ucsYAxis = try objectReader.read3BitDouble()
                view.ucsElevation = try objectReader.readBitDouble()
                view.ucsOrthographicType = try objectReader.readBitShort()
            }
        }

        // view control object (soft pointer)
        _ = try handleReference()

        if r2007Plus {
            // Camera plottable B 73
            view.isPlottable = try objectReader.readBit()
            // Background (soft pointer), Visual style (hard pointer), Sun (hard owner)
            _ = try handleReference()
            _ = try handleReference()
            _ = try handleReference()
        }

        if r2000Plus && view.isUcsAssociated {
            // Base UCS Handle H 346, Named UCS Handle H 345
            template.ucsHandle = try handleReference()
            template.namedUcsHandle = try handleReference()
        }

        // R2007+: Live section H 334 soft pointer
        if r2007Plus { _ = try handleReference() }
        return template
    }

    func readVPort() throws -> ACad.CadTemplate? {
        let vport = A.VPort(name: "")
        let template = A.CadVPortTemplate(vport)
        try readCommonNonEntityData(template)

        try setName(vport, try textReader.readVariableText())
        try readXrefDependantBit(vport)

        let r = objectReader!
        // View height BD 40
        vport.viewHeight = try r.readBitDouble()
        // Aspect ratio BD 41: the aspect ratio times the view height.
        vport.aspectRatio = try r.readBitDouble() / vport.viewHeight
        vport.center = try r.read2RawDouble()
        vport.target = try r.read3BitDouble()
        vport.direction = try r.read3BitDouble()
        vport.twistAngle = try r.readBitDouble()
        vport.lensLength = try r.readBitDouble()
        vport.frontClippingPlane = try r.readBitDouble()
        vport.backClippingPlane = try r.readBitDouble()

        // View mode X 71 4 bits: 0123
        if try r.readBit() { vport.viewMode |= 1 } // PerspectiveView
        if try r.readBit() { vport.viewMode |= 2 } // FrontClipping
        if try r.readBit() { vport.viewMode |= 4 } // BackClipping
        if try r.readBit() { vport.viewMode |= 16 } // FrontClippingZ

        // R2000+: Render Mode RC 281
        if r2000Plus { vport.renderMode = try r.readByte() }

        // R2007+:
        if r2007Plus {
            vport.useDefaultLighting = try r.readBit()
            vport.defaultLighting = try r.readByte()
            vport.brightness = try r.readBitDouble()
            vport.contrast = try r.readBitDouble()
            vport.ambientColor = try mergedReaders.readCmColor(useTextStream: false)
        }

        // Lower left / Upper right 2RD 10 / 11
        vport.bottomLeft = try r.read2RawDouble()
        vport.topRight = try r.read2RawDouble()

        // UCSFOLLOW B 71 Bit 3 (8) of the 71-group.
        if try r.readBit() { vport.viewMode |= 8 } // Follow

        // Circle zoom BS 72
        vport.circleZoomPercent = try r.readBitShort()
        // Fast zoom B 73
        _ = try r.readBit()

        // UCSICON X 74 2 bits: 01
        if try r.readBit() { vport.ucsIconDisplay = 1 } // OnLower
        if try r.readBit() { vport.ucsIconDisplay = 3 } // OnOrigin

        // Grid on/off B 76
        vport.showGrid = try r.readBit()
        // Grd spacing 2RD 15
        vport.gridSpacing = try r.read2RawDouble()
        // Snap on/off B 75
        vport.snapOn = try r.readBit()
        // Snap style B 77
        vport.isometricSnap = try r.readBit()
        // Snap isopair BS 78
        vport.snapIsoPair = try r.readBitShort()
        // Snap rot BD 50
        vport.snapRotation = try r.readBitDouble()
        // Snap base 2RD 13
        vport.snapBasePoint = try r.read2RawDouble()
        // Snp spacing 2RD 14
        vport.snapSpacing = try r.read2RawDouble()

        // R2000+:
        if r2000Plus {
            // Unknown B
            _ = try r.readBit()
            // UCS per Viewport B 71
            _ = try r.readBit()
            vport.origin = try r.read3BitDouble()
            vport.xAxis = try r.read3BitDouble()
            vport.yAxis = try r.read3BitDouble()
            vport.elevation = try r.readBitDouble()
            vport.orthographicType = try r.readBitShort()
        }

        // R2007+:
        if r2007Plus {
            vport.gridFlags = try r.readBitShort()
            vport.minorGridLinesPerMajorGridLine = try r.readBitShort()
        }

        // Handle refs H Vport control(soft pointer)
        template.vportControlHandle = try handleReference()

        if r2007Plus {
            template.backgroundHandle = try handleReference()
            template.styleHandle = try handleReference()
            template.sunHandle = try handleReference()
        }

        if r2000Plus {
            template.namedUcsHandle = try handleReference()
            template.baseUcsHandle = try handleReference()
        }
        return template
    }

    func readViewportEntityControl() throws -> ACad.CadTemplate? {
        let template = A.CadViewportEntityControlTemplate()
        try readCommonNonEntityData(template)
        // Numentries BL 70
        let numentries = try objectReader.readBitLong()
        if numentries > 0 {
            for _ in 0..<numentries {
                // Handle refs H NULL(soft pointer)
                template.entryHandles.insert(try handleReference())
            }
        }
        return template
    }

    func readViewportEntityHeader() throws -> ACad.CadTemplate? {
        let viewport = A.ViewportEntityHeader(name: "")
        let template = A.CadViewportEntityHeaderTemplate(viewport)
        try readCommonNonEntityData(template)

        // Entry name TV 2 (no name validation for this entry type)
        viewport.name = try textReader.readVariableText()
        try readXrefDependantBit(viewport)

        // 1 flag B The 1 bit of the 70 group
        _ = try objectReader.readBit()
        // viewport entity control (soft pointer)
        _ = try handleReference()
        // xdicobjhandle (hard owner)
        _ = try handleReference()
        // External reference block handle (hard pointer)
        template.blockHandle = try handleReference()
        return template
    }
}

private extension Array where Element == UInt8 {
    /// Little-endian UTF-16 code units of the bytes (`Encoding.Unicode.GetString`; an odd last byte becomes U+FFFD).
    var utf16LittleEndianUnits: [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(count / 2 + 1)
        var i = 0
        while i + 1 < count {
            units.append(UInt16(self[i]) | UInt16(self[i + 1]) << 8)
            i += 2
        }
        if i < count { units.append(0xFFFD) }
        return units
    }
}
