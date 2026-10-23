// The DWG section readers of ACadSharp 3.8.0 besides the objects: header variables (DwgHeaderReader), classes,
// the handle map, summary info, the aux header and the AcDs prototype section.

import Foundation

extension ACad {
    /// `DwgSectionIO`: the version flags every section reader uses.
    class DwgSectionIO {
        let version: Version
        let r13_14Only: Bool
        let r13_15Only: Bool
        let r2000Plus: Bool
        let r2004Pre: Bool
        let r2007Pre: Bool
        let r2004Plus: Bool
        let r2007Plus: Bool
        let r2010Plus: Bool
        let r2013Plus: Bool
        let r2018Plus: Bool
        var notifications: [String] = []
        var sectionName: String { "" }

        init(_ version: Version) {
            self.version = version
            r13_14Only = version == .ac1014 || version == .ac1012
            r13_15Only = version >= .ac1012 && version <= .ac1015
            r2000Plus = version >= .ac1015
            r2004Pre = version < .ac1018
            r2007Pre = version <= .ac1021
            r2004Plus = version >= .ac1018
            r2007Plus = version >= .ac1021
            r2010Plus = version >= .ac1024
            r2013Plus = version >= .ac1027
            r2018Plus = version >= .ac1032
        }

        func notify(_ message: String) { notifications.append(message) }

        func checkSentinel(_ reader: DwgBitReader, _ expected: [UInt8]?) throws {
            let sentinel = try reader.readSentinel()
            guard let expected else { throw DwgError.keyNotFound(sectionName) }
            if sentinel != expected { notify("Invalid section sentinel found in \(sectionName)") }
        }
    }

    /// `DwgHeaderHandlesCollection`: the handles of the header, by variable name in the order they were set.
    final class DwgHeaderHandlesCollection {
        private var names: [String] = []
        private var values: [String: UInt64?] = [:]

        subscript(name: String) -> UInt64? {
            get { values[name] ?? nil }
            set {
                if values[name] == nil { names.append(name) }
                values[name] = .some(newValue)
            }
        }

        /// `GetHandles`: the values in dictionary order.
        var handles: [UInt64?] { names.map { values[$0] ?? nil } }

        /// `UpdateHeader`: names of the current table entries.
        func updateHeader(_ header: CadHeader, _ builder: CadDocumentBuilder) {
            if let entry: TableEntry = builder.tryGetObject(self["CLAYER"]) { header.currentLayerName = entry.name }
            if let entry: TableEntry = builder.tryGetObject(self["CELTYPE"]) { header.currentLineTypeName = entry.name }
            if let entry: TableEntry = builder.tryGetObject(self["CMLSTYLE"]) { header.currentMLineStyleName = entry.name }
            if let entry: TableEntry = builder.tryGetObject(self["TEXTSTYLE"]) { header.currentTextStyleName = entry.name }
            if let entry: TableEntry = builder.tryGetObject(self["DIMTXSTY"]) { header.dimensionTextStyleName = entry.name }
            if let entry: TableEntry = builder.tryGetObject(self["DIMSTYLE"]) { header.currentDimensionStyleName = entry.name }
            if let record: BlockRecord = builder.tryGetObject(self["DIMBLK"]) { header.dimensionBlockName = record.name }
            // ACadSharp assigns DIMLDRBLK to DimensionBlockName as well.
            if let record: BlockRecord = builder.tryGetObject(self["DIMLDRBLK"]) { header.dimensionBlockName = record.name }
            if let record: BlockRecord = builder.tryGetObject(self["DIMBLK1"]) { header.dimensionBlockNameFirst = record.name }
            if let record: BlockRecord = builder.tryGetObject(self["DIMBLK2"]) { header.dimensionBlockNameSecond = record.name }
        }
    }

    /// `DwgClassesReader`.
    final class DwgClassesReader: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.classes }
        private var reader: DwgBitReader
        private let fileHeader: DwgFileHeader
        private let classes: DxfClassCollection

        init(_ version: Version, _ reader: DwgBitReader, _ fileHeader: DwgFileHeader, _ classes: DxfClassCollection) {
            self.reader = reader
            self.fileHeader = fileHeader
            self.classes = classes
            super.init(version)
        }

        func read() throws {
            try checkSentinel(reader, DwgSectionDefinition.startSentinels[sectionName])
            let size = try reader.readRawLong()
            var endSection = reader.position + Int(size)
            // R2010+ (only present if the maintenance version is greater than 3!)
            if fileHeader.version >= .ac1024 && fileHeader.maintenanceVersion > 3 || fileHeader.version > .ac1027 {
                _ = try reader.readRawLong()
            }
            var flagPos = 0
            if r2007Plus {
                flagPos = reader.positionInBits() + Int(try reader.readRawLong()) - 1
                let savedOffset = reader.positionInBits()
                endSection = try reader.setPositionByFlag(flagPos)
                try reader.setPositionInBits(savedOffset)
                let textReader = try DwgStreamReader(version, try reader.stream.clone())
                try textReader.setPositionInBits(endSection)
                reader = DwgMergedReader(reader, textReader, nil)
                _ = try reader.readBitLong()
                _ = try reader.readBit()
            }
            if fileHeader.version == .ac1018 {
                _ = try reader.readBitShort()
                _ = try reader.readRawChar()
                _ = try reader.readRawChar()
                _ = try reader.readBit()
            }
            while currentPosition() < endSection {
                let dxfClass = DxfClass()
                dxfClass.classNumber = try reader.readBitShort()
                dxfClass.proxyFlags = Int32(UInt16(bitPattern: try reader.readBitShort()))
                dxfClass.applicationName = try reader.readVariableText()
                dxfClass.cppClassName = try reader.readVariableText()
                dxfClass.dxfName = try reader.readVariableText()
                dxfClass.wasZombie = try reader.readBit()
                dxfClass.itemClassId = try reader.readBitShort()
                if r2004Plus {
                    dxfClass.instanceCount = try reader.readBitLong()
                    dxfClass.dwgVersion = Int16(truncatingIfNeeded: try reader.readBitLong())
                    dxfClass.maintenanceVersion = Int16(truncatingIfNeeded: try reader.readBitLong())
                    _ = try reader.readBitLong()
                    _ = try reader.readBitLong()
                }
                classes.add(dxfClass)
            }
            if r2007Plus {
                try reader.setPositionInBits(flagPos + 1)
            }
            _ = try reader.resetShift()
            try checkSentinel(reader, DwgSectionDefinition.endSentinels[sectionName])
        }

        private func currentPosition() -> Int { r2007Plus ? reader.positionInBits() : reader.position }
    }

    /// `DwgHandleReader`: object handle → offset.
    final class DwgHandleReader: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.handles }
        private let reader: DwgStreamReader

        init(_ version: Version, _ reader: DwgStreamReader) {
            self.reader = reader
            super.init(version)
        }

        func read() throws -> [UInt64: Int64] {
            var objectMap: [UInt64: Int64] = [:]
            while true {
                var lastHandle: UInt64 = 0
                var lastLoc: Int64 = 0
                // Size of this section, big-endian.
                let size = Int(try reader.readShortBigEndian())
                if size == 2 { break }
                let startPos = reader.position
                var maxSectionOffset = size - 2
                // Each section is cut off at a maximum length of 2032.
                if maxSectionOffset > 2032 { maxSectionOffset = 2032 }
                let lastPosition = startPos + maxSectionOffset
                while reader.position < lastPosition {
                    let offset = try reader.readModularChar()
                    lastHandle &+= offset
                    lastLoc &+= try reader.readSignedModularChar()
                    if offset > 0 {
                        objectMap[lastHandle] = lastLoc
                    } else {
                        notify("Negative offset: \(offset) for the handle: \(lastHandle)")
                    }
                }
                // CRC (most significant byte first).
                _ = try reader.readByte()
                _ = try reader.readByte()
            }
            return objectMap
        }
    }

    /// `DwgSummaryInfoReader`.
    final class DwgSummaryInfoReader: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.summaryInfo }
        private let reader: DwgStreamReader

        init(_ version: Version, _ reader: DwgStreamReader) throws {
            self.reader = reader
            super.init(version)
        }

        private func readString() throws -> String {
            if version >= .ac1021 { return try reader.readTextUnicode() }
            // `readUnicodeString`: a 16-bit length and Windows-1252 bytes, read past the bit shift.
            let lengthBytes = Array(reader.stream.read(2))
            guard lengthBytes.count == 2 else { throw DwgError.endOfStream }
            let textLength = Int(Int16(bitPattern: UInt16(lengthBytes[0]) | UInt16(lengthBytes[1]) << 8))
            if textLength == 0 { return "" }
            guard textLength > 0 else { throw DwgError("Length cannot be negative.") }
            let bytes = Array(reader.stream.read(textLength))
            guard bytes.count == textLength else { throw DwgError.endOfStream }
            return DwgText.windows1252(bytes).replacingOccurrences(of: "\0", with: "")
        }

        func read() -> SummaryInfo {
            let summary = SummaryInfo()
            do {
                summary.title = try readString()
                summary.subject = try readString()
                summary.author = try readString()
                summary.keywords = try readString()
                summary.comments = try readString()
                summary.lastSavedBy = try readString()
                summary.revisionNumber = try readString()
                summary.hyperlinkBase = try readString()
                // Total editing time (ODA writes two zero Int32's).
                _ = try reader.readInt()
                _ = try reader.readInt()
                summary.createdDate = try reader.read8BitJulianDate()
                summary.modifiedDate = try reader.read8BitJulianDate()
                let nproperties = try reader.readShort()
                if nproperties > 0 {
                    for _ in 0..<nproperties {
                        let name = try readString()
                        let value = try readString()
                        if summary.properties.contains(where: { $0.0 == name }) {
                            notify("[SummaryInfo] An error ocurred while adding a property in the SummaryInfo")
                        } else {
                            summary.properties.append((name, value))
                        }
                    }
                }
                _ = try reader.readInt()
                _ = try reader.readInt()
            } catch {
                if reader.stream.position != reader.stream.length {
                    notify("An error occurred while reading the Summary Info")
                }
            }
            return summary
        }
    }

    /// `DwgAuxHeaderReader`: the values are read (and can fail the file) but not kept.
    final class DwgAuxHeaderReader: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.auxHeader }
        private let reader: DwgStreamReader

        init(_ version: Version, _ reader: DwgStreamReader) {
            self.reader = reader
            super.init(version)
        }

        func read() throws {
            _ = try reader.readByte()
            _ = try reader.readByte()
            _ = try reader.readByte()
            _ = try reader.readShort()
            _ = try readMaintenanceVersion()
            _ = try reader.readRawLong()
            _ = try reader.readRawLong()
            _ = try reader.readShort()
            _ = try reader.readShort()
            _ = try reader.readRawLong()
            _ = try reader.readShort()
            _ = try readMaintenanceVersion()
            _ = try reader.readShort()
            _ = try readMaintenanceVersion()
            for _ in 0..<6 { _ = try reader.readShort() }
            for _ in 0..<5 { _ = try reader.readRawLong() }
            _ = try reader.read8BitJulianDate()
            _ = try reader.read8BitJulianDate()
            _ = try reader.readRawLong()
            _ = try reader.readRawLong()
            _ = try reader.readShort()
            _ = try reader.readShort()
            for _ in 0..<8 { _ = try reader.readRawLong() }
            if r2018Plus {
                for _ in 0..<3 { _ = try reader.readShort() }
            }
        }

        private func readMaintenanceVersion() throws -> Int64 {
            version > .ac1027 ? try reader.readRawLong() : Int64(try reader.readShort())
        }
    }

    /// `DwgPrototype1bReader`. ACadSharp 3.8.0 parses the AcDs data storage into `CadDocument.DataStorage`, which
    /// nothing reads (the ACIS entities it collects are never assigned), and it catches every error itself; only
    /// building the section stream can fail the file, and the caller does that.
    final class DwgPrototype1bReader: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.acDsPrototype }

        init(_ version: Version, _ builder: DwgDocumentBuilder, _ reader: DwgStreamReader) {
            super.init(version)
        }

        func read() throws {}
    }

    /// `DwgHeaderReader`: the header variables and the handles of the current table entries.
    final class DwgHeaderReader: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.header }
        private var reader: DwgBitReader
        private let header: CadHeader

        init(_ version: Version, _ reader: DwgStreamReader, _ header: CadHeader) {
            self.reader = reader
            self.header = header
            super.init(version)
            header.version = version
        }

        func read(_ acadMaintenanceVersion: Int32) throws -> DwgHeaderHandlesCollection {
            let mainReader = reader
            let pointers = DwgHeaderHandlesCollection()
            let h = header
            let dims = header.dimensionStyleOverrides

            try checkSentinel(reader, DwgSectionDefinition.startSentinels[sectionName])
            let size = try reader.readRawLong()
            if r2010Plus && acadMaintenanceVersion > 3 || r2018Plus {
                _ = try reader.readRawLong()
            }
            let initialPos = reader.positionInBits()
            if r2007Plus {
                let sizeInBits = try reader.readRawLong()
                let lastPositionInBits = initialPos + Int(sizeInBits) - 1
                let source = try reader.stream
                let textReader = try DwgStreamReader(version, source.clone())
                _ = try textReader.setPositionByFlag(lastPositionInBits)
                let referenceReader = try DwgStreamReader(version, source.clone())
                try referenceReader.setPositionInBits(lastPositionInBits + 1)
                reader = DwgMergedReader(reader, textReader, referenceReader)
            }
            let r = reader

            if r2013Plus { h.requiredVersions = try r.readBitLongLong() }

            // Unknown values: 4 BD, 4 TV, 2 BL.
            for _ in 0..<4 { _ = try r.readBitDouble() }
            for _ in 0..<4 { _ = try r.readVariableText() }
            _ = try r.readBitLong()
            _ = try r.readBitLong()
            if r13_14Only { _ = try r.readBitShort() }
            if r2004Pre { _ = try r.handleReference(0) }

            h.associatedDimensions = try r.readBit()
            h.updateDimensionsWhileDragging = try r.readBit()
            if r13_14Only { h.dimsav = try r.readBit() }
            h.polylineLineTypeGeneration = try r.readBit()
            h.orthoMode = try r.readBit()
            h.regenerationMode = try r.readBit()
            h.fillMode = try r.readBit()
            h.quickTextMode = try r.readBit()
            h.paperSpaceLineTypeScaling = try r.readBit() ? 1 : 0
            h.limitCheckingOn = try r.readBit()
            if r13_14Only { h.blipMode = try r.readBit() }
            if r2004Plus { _ = try r.readBit() }
            h.userTimer = try r.readBit()
            h.sketchPolylines = try r.readBit()
            h.angularDirection = try r.readBitAsShort()
            h.showSplineControlPoints = try r.readBit()
            if r13_14Only {
                _ = try r.readBit()
                _ = try r.readBit()
            }
            h.mirrorText = try r.readBit()
            h.worldView = try r.readBit()
            if r13_14Only { _ = try r.readBit() }
            h.showModelSpace = try r.readBit()
            h.paperSpaceLimitsChecking = try r.readBit()
            h.retainXRefDependentVisibilitySettings = try r.readBit()
            if r13_14Only { _ = try r.readBit() }
            h.displaySilhouetteCurves = try r.readBit()
            h.createEllipseAsPolyline = try r.readBit()
            h.proxyGraphics = try r.readBitShortAsBool()
            if r13_14Only { _ = try r.readBitShort() }
            h.spatialIndexMaxTreeDepth = try r.readBitShort()
            h.linearUnitFormat = try r.readBitShort()
            let linearUnitPrecision = try r.readBitShort()
            if linearUnitPrecision >= 0 && linearUnitPrecision <= 8 { h.linearUnitPrecision = linearUnitPrecision }
            h.angularUnit = try r.readBitShort()
            let angularUnitPrecision = try r.readBitShort()
            if angularUnitPrecision >= 0 && angularUnitPrecision <= 8 { h.angularUnitPrecision = angularUnitPrecision }
            if r13_14Only { h.objectSnapMode = UInt16(bitPattern: try r.readBitShort()) }
            h.attributeVisibility = Int32(try r.readBitShort())
            if r13_14Only { _ = try r.readBitShort() }
            h.pointDisplayMode = try r.readBitShort()
            if r13_14Only { _ = try r.readBitShort() }
            if r2004Plus {
                _ = try r.readBitLong()
                _ = try r.readBitLong()
                _ = try r.readBitLong()
            }
            h.userShort1 = try r.readBitShort()
            h.userShort2 = try r.readBitShort()
            h.userShort3 = try r.readBitShort()
            h.userShort4 = try r.readBitShort()
            h.userShort5 = try r.readBitShort()
            h.numberOfSplineSegments = try r.readBitShort()
            h.surfaceDensityU = try r.readBitShort()
            h.surfaceDensityV = try r.readBitShort()
            h.surfaceType = try r.readBitShort()
            h.surfaceMeshTabulationCount1 = try r.readBitShort()
            h.surfaceMeshTabulationCount2 = try r.readBitShort()
            h.splineType = try r.readBitShort()
            h.shadeEdge = try r.readBitShort()
            h.shadeDiffuseToAmbientPercentage = try r.readBitShort()
            h.unitMode = try r.readBitShort()
            h.maxViewportCount = try r.readBitShort()
            let surfaceIsoLineCount = try r.readBitShort()
            if surfaceIsoLineCount >= 0 && surfaceIsoLineCount <= 2047 { h.surfaceIsolineCount = surfaceIsoLineCount }
            h.currentMultiLineJustification = try r.readBitShort()
            let textQuality = try r.readBitShort()
            if textQuality >= 0 && textQuality <= 100 { h.textQuality = textQuality }
            h.lineTypeScale = try r.readBitDouble()
            h.textHeightDefault = try r.readBitDouble()
            h.traceWidthDefault = try r.readBitDouble()
            h.sketchIncrement = try r.readBitDouble()
            h.filletRadius = try r.readBitDouble()
            h.thicknessDefault = try r.readBitDouble()
            h.angleBase = try r.readBitDouble()
            h.pointDisplaySize = try r.readBitDouble()
            h.polylineWidthDefault = try r.readBitDouble()
            h.userDouble1 = try r.readBitDouble()
            h.userDouble2 = try r.readBitDouble()
            h.userDouble3 = try r.readBitDouble()
            h.userDouble4 = try r.readBitDouble()
            h.userDouble5 = try r.readBitDouble()
            h.chamferDistance1 = try r.readBitDouble()
            h.chamferDistance2 = try r.readBitDouble()
            h.chamferLength = try r.readBitDouble()
            h.chamferAngle = try r.readBitDouble()
            let facetResolution = try r.readBitDouble()
            if facetResolution > 0 && facetResolution <= 10 { h.facetResolution = facetResolution }
            h.currentMultilineScale = try r.readBitDouble()
            h.currentEntityLinetypeScale = try r.readBitDouble()
            h.menuFileName = try r.readVariableText()
            h.createDateTime = try r.readDateTime()
            h.updateDateTime = try r.readDateTime()
            if r2004Plus {
                _ = try r.readBitLong()
                _ = try r.readBitLong()
                _ = try r.readBitLong()
            }
            h.totalEditingTime = try r.readTimeSpan()
            h.userElapsedTimeSpan = try r.readTimeSpan()
            h.currentEntityColor = try r.readCmColor(useTextStream: false)
            // HANDSEED is part of the main data stream, not of the handle stream.
            h.handleSeed = try mainReader.handleReference(0)
            pointers["CLAYER"] = try r.handleReference(0)
            pointers["TEXTSTYLE"] = try r.handleReference(0)
            pointers["CELTYPE"] = try r.handleReference(0)
            if r2007Plus { pointers["CMATERIAL"] = try r.handleReference(0) }
            pointers["DIMSTYLE"] = try r.handleReference(0)
            pointers["CMLSTYLE"] = try r.handleReference(0)
            if r2000Plus { h.viewportDefaultViewScaleFactor = try r.readBitDouble() }
            h.paperSpaceInsertionBase = try r.read3BitDouble()
            h.paperSpaceExtMin = try r.read3BitDouble()
            h.paperSpaceExtMax = try r.read3BitDouble()
            h.paperSpaceLimitsMin = try r.read2RawDouble()
            h.paperSpaceLimitsMax = try r.read2RawDouble()
            h.paperSpaceElevation = try r.readBitDouble()
            h.paperSpaceUcsOrigin = try r.read3BitDouble()
            h.paperSpaceUcsXAxis = try r.read3BitDouble()
            h.paperSpaceUcsYAxis = try r.read3BitDouble()
            pointers["UCSNAME_PSPACE"] = try r.handleReference(0)
            if r2000Plus {
                pointers["PUCSORTHOREF"] = try r.handleReference(0)
                _ = try r.readBitShort()
                pointers["PUCSBASE"] = try r.handleReference(0)
                h.paperSpaceOrthographicTopDOrigin = try r.read3BitDouble()
                h.paperSpaceOrthographicBottomDOrigin = try r.read3BitDouble()
                h.paperSpaceOrthographicLeftDOrigin = try r.read3BitDouble()
                h.paperSpaceOrthographicRightDOrigin = try r.read3BitDouble()
                h.paperSpaceOrthographicFrontDOrigin = try r.read3BitDouble()
                h.paperSpaceOrthographicBackDOrigin = try r.read3BitDouble()
            }
            h.modelSpaceInsertionBase = try r.read3BitDouble()
            h.modelSpaceExtMin = try r.read3BitDouble()
            h.modelSpaceExtMax = try r.read3BitDouble()
            h.modelSpaceLimitsMin = try r.read2RawDouble()
            h.modelSpaceLimitsMax = try r.read2RawDouble()
            h.elevation = try r.readBitDouble()
            h.modelSpaceOrigin = try r.read3BitDouble()
            h.modelSpaceXAxis = try r.read3BitDouble()
            h.modelSpaceYAxis = try r.read3BitDouble()
            pointers["UCSNAME_MSPACE"] = try r.handleReference(0)
            if r2000Plus {
                pointers["UCSORTHOREF"] = try r.handleReference(0)
                _ = try r.readBitShort()
                pointers["UCSBASE"] = try r.handleReference(0)
                h.modelSpaceOrthographicTopDOrigin = try r.read3BitDouble()
                h.modelSpaceOrthographicBottomDOrigin = try r.read3BitDouble()
                h.modelSpaceOrthographicLeftDOrigin = try r.read3BitDouble()
                h.modelSpaceOrthographicRightDOrigin = try r.read3BitDouble()
                h.modelSpaceOrthographicFrontDOrigin = try r.read3BitDouble()
                h.modelSpaceOrthographicBackDOrigin = try r.read3BitDouble()
                dims.postFix = try r.readVariableText()
                dims.alternateDimensioningSuffix = try r.readVariableText()
            }
            if r13_14Only {
                dims.generateTolerances = try r.readBit()
                dims.limitsGeneration = try r.readBit()
                dims.textInsideHorizontal = try r.readBit()
                dims.textOutsideHorizontal = try r.readBit()
                dims.suppressFirstExtensionLine = try r.readBit()
                dims.suppressSecondExtensionLine = try r.readBit()
                dims.alternateUnitDimensioning = try r.readBit()
                dims.textOutsideExtensions = try r.readBit()
                dims.separateArrowBlocks = try r.readBit()
                dims.textInsideExtensions = try r.readBit()
                dims.suppressOutsideExtensions = try r.readBit()
                dims.alternateUnitDecimalPlaces = Int16(try r.readRawChar())
                dims.zeroHandling = try r.readRawChar()
                dims.suppressFirstDimensionLine = try r.readBit()
                dims.suppressSecondDimensionLine = try r.readBit()
                dims.toleranceAlignment = try r.readRawChar()
                dims.textHorizontalAlignment = try r.readRawChar()
                dims.dimensionFit = Int16(try r.readRawChar())
                dims.cursorUpdate = try r.readBit()
                dims.toleranceZeroHandling = try r.readRawChar()
                dims.alternateUnitZeroHandling = try r.readRawChar()
                dims.alternateUnitToleranceZeroHandling = try r.readRawChar()
                dims.textVerticalAlignment = Int32(try r.readRawChar())
                dims.dimensionUnit = try r.readBitShort()
                dims.angularDecimalPlaces = try r.readBitShort()
                dims.decimalPlaces = try r.readBitShort()
                dims.toleranceDecimalPlaces = try r.readBitShort()
                dims.alternateUnitFormat = try r.readBitShort()
                dims.alternateUnitToleranceDecimalPlaces = try r.readBitShort()
                pointers["DIMTXSTY"] = try r.handleReference(0)
            }
            try dims.setScaleFactor(try r.readBitDouble())
            try dims.setArrowSize(try r.readBitDouble())
            dims.extensionLineOffset = try r.readBitDouble()
            dims.dimensionLineIncrement = try r.readBitDouble()
            dims.extensionLineExtension = try r.readBitDouble()
            dims.rounding = try r.readBitDouble()
            dims.dimensionLineExtension = try r.readBitDouble()
            dims.plusTolerance = try r.readBitDouble()
            dims.minusTolerance = try r.readBitDouble()
            if r2007Plus {
                dims.fixedExtensionLineLength = try r.readBitDouble()
                let jog = try r.readBitDouble()
                let rounded = (jog * 1e6).rounded(.toNearestOrEven) / 1e6
                if rounded > MathHelper.degToRad(5) && rounded < MathHelper.halfPI {
                    dims.joggedRadiusDimensionTransverseSegmentAngle = jog
                }
                dims.textBackgroundFillMode = try r.readBitShort()
                dims.textBackgroundColor = try r.readCmColor(useTextStream: false)
            }
            if r2000Plus {
                dims.generateTolerances = try r.readBit()
                dims.limitsGeneration = try r.readBit()
                dims.textInsideHorizontal = try r.readBit()
                dims.textOutsideHorizontal = try r.readBit()
                dims.suppressFirstExtensionLine = try r.readBit()
                dims.suppressSecondExtensionLine = try r.readBit()
                dims.textVerticalAlignment = Int32(UInt16(bitPattern: try r.readBitShort()))
                dims.zeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
                dims.angularZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
            }
            if r2007Plus { dims.arcLengthSymbolPosition = try r.readBitShort() }
            try dims.setTextHeight(try r.readBitDouble())
            dims.centerMarkSize = try r.readBitDouble()
            dims.tickSize = try r.readBitDouble()
            dims.alternateUnitScaleFactor = try r.readBitDouble()
            dims.linearScaleFactor = try r.readBitDouble()
            dims.textVerticalPosition = try r.readBitDouble()
            dims.toleranceScaleFactor = try r.readBitDouble()
            dims.dimensionLineGap = try r.readBitDouble()
            if r13_14Only {
                dims.postFix = try r.readVariableText()
                dims.alternateDimensioningSuffix = try r.readVariableText()
                h.dimensionBlockName = try r.readVariableText()
                h.dimensionBlockNameFirst = try r.readVariableText()
                h.dimensionBlockNameSecond = try r.readVariableText()
            }
            if r2000Plus {
                dims.alternateUnitRounding = try r.readBitDouble()
                dims.alternateUnitDimensioning = try r.readBit()
                dims.alternateUnitDecimalPlaces = try r.readBitShort()
                dims.textOutsideExtensions = try r.readBit()
                dims.separateArrowBlocks = try r.readBit()
                dims.textInsideExtensions = try r.readBit()
                dims.suppressOutsideExtensions = try r.readBit()
            }
            dims.dimensionLineColor = try r.readCmColor(useTextStream: false)
            dims.extensionLineColor = try r.readCmColor(useTextStream: false)
            dims.textColor = try r.readCmColor(useTextStream: false)
            if r2000Plus {
                dims.angularDecimalPlaces = try r.readBitShort()
                dims.decimalPlaces = try r.readBitShort()
                dims.toleranceDecimalPlaces = try r.readBitShort()
                dims.alternateUnitFormat = try r.readBitShort()
                dims.alternateUnitToleranceDecimalPlaces = try r.readBitShort()
                dims.angularUnit = try r.readBitShort()
                dims.fractionFormat = try r.readBitShort()
                dims.linearUnitFormat = try r.readBitShort()
                dims.decimalSeparator = UInt16(bitPattern: try r.readBitShort())
                dims.textMovement = try r.readBitShort()
                dims.textHorizontalAlignment = UInt8(truncatingIfNeeded: try r.readBitShort())
                // ACadSharp stores DIMSD1 / DIMSD2 in the extension line flags.
                dims.suppressFirstExtensionLine = try r.readBit()
                dims.suppressSecondExtensionLine = try r.readBit()
                dims.toleranceAlignment = UInt8(truncatingIfNeeded: try r.readBitShort())
                dims.toleranceZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
                dims.alternateUnitZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
                dims.alternateUnitToleranceZeroHandling = UInt8(truncatingIfNeeded: try r.readBitShort())
                dims.cursorUpdate = try r.readBit()
                dims.dimensionTextArrowFit = UInt8(truncatingIfNeeded: try r.readBitShort())
            }
            if r2007Plus { dims.isExtensionLineLengthFixed = try r.readBit() }
            if r2010Plus {
                dims.textDirection = try r.readBit() ? 1 : 0
                dims.altMzf = try r.readBitDouble()
                dims.altMzs = try r.readVariableText()
                dims.mzf = try r.readBitDouble()
                dims.mzs = try r.readVariableText()
            }
            if r2000Plus {
                pointers["DIMTXSTY"] = try r.handleReference(0)
                pointers["DIMLDRBLK"] = try r.handleReference(0)
                pointers["DIMBLK"] = try r.handleReference(0)
                pointers["DIMBLK1"] = try r.handleReference(0)
                pointers["DIMBLK2"] = try r.handleReference(0)
            }
            if r2007Plus {
                pointers["DIMLTYPE"] = try r.handleReference(0)
                pointers["DIMLTEX1"] = try r.handleReference(0)
                pointers["DIMLTEX2"] = try r.handleReference(0)
            }
            if r2000Plus {
                dims.dimensionLineWeight = LineWeight(try r.readBitShort())
                dims.extensionLineWeight = LineWeight(try r.readBitShort())
            }
            pointers["BLOCK_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["LAYER_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["STYLE_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["LINETYPE_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["VIEW_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["UCS_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["VPORT_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["APPID_CONTROL_OBJECT"] = try r.handleReference(0)
            pointers["DIMSTYLE_CONTROL_OBJECT"] = try r.handleReference(0)
            if r13_15Only { pointers["VIEWPORT_ENTITY_HEADER_CONTROL_OBJECT"] = try r.handleReference(0) }
            pointers["DICTIONARY_ACAD_GROUP"] = try r.handleReference(0)
            pointers["DICTIONARY_ACAD_MLINESTYLE"] = try r.handleReference(0)
            pointers["DICTIONARY_NAMED_OBJECTS"] = try r.handleReference(0)
            if r2000Plus {
                h.stackedTextAlignment = try r.readBitShort()
                h.stackedTextSizePercentage = try r.readBitShort()
                h.hyperLinkBase = try r.readVariableText()
                h.styleSheetName = try r.readVariableText()
                pointers["DICTIONARY_LAYOUTS"] = try r.handleReference(0)
                pointers["DICTIONARY_PLOTSETTINGS"] = try r.handleReference(0)
                pointers["DICTIONARY_PLOTSTYLES"] = try r.handleReference(0)
            }
            if r2004Plus {
                pointers["DICTIONARY_MATERIALS"] = try r.handleReference(0)
                pointers["DICTIONARY_COLORS"] = try r.handleReference(0)
            }
            if r2007Plus {
                pointers["DICTIONARY_VISUALSTYLE"] = try r.handleReference(0)
                // R2013+: an unknown handle, stored over the visual style dictionary.
                if r2013Plus { pointers["DICTIONARY_VISUALSTYLE"] = try r.handleReference(0) }
            }
            if r2000Plus {
                let flags = try r.readBitLong()
                h.currentEntityLineWeight = LineWeight(Int16(flags & 0x1F))
                h.endCaps = Int16(flags & 0x60)
                h.joinStyle = Int16(flags & 0x180)
                // ACadSharp compares the masked flags with 1: these are always false.
                h.displayLineWeight = false
                h.xEdit = false
                h.extendedNames = false
                h.plotStyleMode = Int16(flags & 0x2000)
                h.loadOLEObject = false
                h.insUnits = try r.readBitShort()
                h.currentEntityPlotStyle = try r.readBitShort()
                if h.currentEntityPlotStyle == 3 { pointers["CPSNID"] = try r.handleReference(0) }
                h.fingerPrintGuid = try r.readVariableText()
                h.versionGuid = try r.readVariableText()
            }
            if r2004Plus {
                h.entitySortingFlags = try r.readByte()
                h.indexCreationFlags = try r.readByte()
                h.hideText = try r.readByte()
                h.externalReferenceClippingBoundaryType = Int32(try r.readByte())
                h.dimensionAssociativity = Int16(try r.readByte())
                h.haloGapPercentage = try r.readByte()
                h.obscuredColor = try Color.checked(index: try r.readBitShort())
                h.interfereColor = try Color.checked(index: try r.readBitShort())
                h.obscuredType = try r.readByte()
                h.intersectionDisplay = try r.readByte()
                h.projectName = try r.readVariableText()
            }
            pointers["PAPER_SPACE"] = try r.handleReference(0)
            pointers["MODEL_SPACE"] = try r.handleReference(0)
            pointers["BYLAYER"] = try r.handleReference(0)
            pointers["BYBLOCK"] = try r.handleReference(0)
            pointers["CONTINUOUS"] = try r.handleReference(0)
            if r2007Plus {
                h.cameraDisplayObjects = try r.readBit()
                _ = try r.readBitLong()
                _ = try r.readBitLong()
                _ = try r.readBitDouble()
                let stepsPerSecond = try r.readBitDouble()
                if stepsPerSecond >= 1 && stepsPerSecond <= 30 { h.stepsPerSecond = stepsPerSecond }
                h.stepSize = try r.readBitDouble()
                h.dw3DPrecision = try r.readBitDouble()
                h.lensLength = try r.readBitDouble()
                h.cameraHeight = try r.readBitDouble()
                h.solidsRetainHistory = UInt16(try r.readRawChar())
                h.showSolidsHistory = UInt16(try r.readRawChar())
                h.sweptSolidWidth = try r.readBitDouble()
                h.sweptSolidHeight = try r.readBitDouble()
                h.draftAngleFirstCrossSection = try r.readBitDouble()
                h.draftAngleSecondCrossSection = try r.readBitDouble()
                h.draftMagnitudeFirstCrossSection = try r.readBitDouble()
                h.draftMagnitudeSecondCrossSection = try r.readBitDouble()
                h.solidLoftedShape = try r.readBitShort()
                h.loftedObjectNormals = UInt16(try r.readRawChar())
                h.latitude = try r.readBitDouble()
                h.longitude = try r.readBitDouble()
                h.northDirection = try r.readBitDouble()
                h.timeZone = try r.readBitLong()
                h.displayLightGlyphs = UInt16(try r.readRawChar())
                _ = try r.readRawChar()
                h.dwgUnderlayFramesVisibility = UInt16(try r.readRawChar())
                h.dgnUnderlayFramesVisibility = UInt16(try r.readRawChar())
                _ = try r.readBit()
                h.interfereColor = try r.readCmColor(useTextStream: false)
                pointers["INTERFEREOBJVS"] = try r.handleReference(0)
                pointers["INTERFEREVPVS"] = try r.handleReference(0)
                pointers["DRAGVS"] = try r.handleReference(0)
                h.shadowMode = try r.readByte()
                h.shadowPlaneLocation = try r.readBitDouble()
            }

            do {
                // Not necessary for the integrity of the data.
                try mainReader.setPositionInBits(initialPos + Int(size) * 8)
                _ = try mainReader.resetShift()
                try checkSentinel(reader, DwgSectionDefinition.endSentinels[sectionName])
            } catch {
                notify("An error ocurred at the end of the Header reading")
            }
            return pointers
        }
    }

    /// `DwgDocumentBuilder`.
    final class DwgDocumentBuilder: CadDocumentBuilder {
        var headerHandles = DwgHeaderHandlesCollection()
        var blockRecordTemplates: [CadBlockRecordTemplate] = []
        var paperSpaceEntities: [Entity] = []
        var modelSpaceEntities: [Entity] = []

        /// `BuildDocument`.
        func buildDwgDocument() throws {
            createMissingHandles()
            // Names of the block records before they are added to the table.
            for template in blockRecordTemplates {
                template.setBlockToRecord(self, modelSpace: headerHandles["MODEL_SPACE"], paperSpace: headerHandles["PAPER_SPACE"])
            }
            registerTables()
            buildTables()
            buildDictionaries()
            super.buildDocument()
            headerHandles.updateHeader(document.header, self)
            if let failure { throw DwgError(failure) }
        }
    }
}
