// DXF reader (ACadSharp DxfReader with its section readers): ASCII and binary DXF, every section Filee needs.
// Entities and objects live in DxfReader+Entities.swift and DxfReader+Objects.swift.

import Foundation

extension ACad {
    /// `CadNotSupportedException`.
    struct CadNotSupportedError: Error, CustomStringConvertible {
        let version: Version?
        var description: String {
            version.map { "File version not supported: \($0.name)" } ?? "File version not recognised"
        }
    }

    final class DxfReader {
        /// `Failsafe` (Filee always reads failsafe).
        let failsafe = true
        let createDefaults: Bool

        private let data: Data
        var reader: DxfGroupReader!
        var builder: DxfDocumentBuilder!
        private(set) var document = Document(createDefaults: false)
        private var version: Version = .unknown
        private var encoding: String.Encoding = .utf8
        private let isBinary: Bool
        private var isAC1009Binary = false

        /// The subclass marker being read (`currentSubclass`).
        var currentSubclass = ""
        /// Keeps the current group for the caller (`lockPointer`).
        var lockPointer = false

        init(data: Data, createDefaults: Bool) {
            self.data = data
            self.createDefaults = createDefaults
            isBinary = DxfReader.isBinary(data)
        }

        /// `IsBinary`.
        static func isBinary(_ data: Data) -> Bool {
            data.count >= 22 && Array(data.prefix(22)) == DxfBinaryGroupReader.sentinel
        }

        var notifications: [String] { builder?.notifications ?? [] }

        // ───────────────────────── Read ─────────────────────────

        /// `Read`.
        func read() throws -> Document {
            document.summaryInfo = SummaryInfo()
            reader = try makeReader()
            builder = DxfDocumentBuilder(version: version, document: document, createDefaults: createDefaults)
            while reader.valueAsString != DxfFileToken.endOfFile {
                if reader.valueAsString != DxfFileToken.beginSection {
                    try reader.readNext()
                    continue
                }
                try reader.readNext()
                switch reader.valueAsString {
                case DxfFileToken.headerSection:
                    document.header = try readHeader()
                    document.header.document = document
                    builder.initialHandSeed = document.header.handleSeed
                case DxfFileToken.classesSection: try readClasses()
                case DxfFileToken.tablesSection: try readTables()
                case DxfFileToken.blocksSection: try readBlocks()
                case DxfFileToken.entitiesSection: try readEntitiesSection()
                case DxfFileToken.objectsSection: try readObjectsSection()
                case DxfFileToken.acdsDataSection: try readAcdsData()
                default: builder.notify("Section not implemented \(reader.valueAsString)")
                }
                try reader.readNext()
            }
            document.header.document = document
            builder.buildDocument()
            if let failure = builder.failure { throw DxfException(failure) }
            return document
        }

        /// `getReader`: finds the version and code page in the header, then reads with the drawing's encoding.
        private func makeReader() throws -> DxfGroupReader {
            version = .unknown
            if isBinary, data.count > 23 { isAC1009Binary = data[data.startIndex + 23] != 0 }
            let probe = createReader(encoding: .utf8)
            if try !probe.find(DxfFileToken.headerSection) {
                builder?.notify("Header section not found, using a generic reader.")
                try probe.start()
                return probe
            }
            while probe.valueAsString != DxfFileToken.endSection {
                if probe.valueAsString == "$ACADVER" {
                    try probe.readNext()
                    version = Version.from(name: probe.valueAsString)
                    if version >= .ac1021 {
                        encoding = .utf8
                        break
                    }
                    if version < .ac1002 {
                        throw CadNotSupportedError(version: version == .unknown ? nil : version)
                    }
                } else if probe.valueAsString == "$DWGCODEPAGE" {
                    try probe.readNext()
                    encoding = CodePages.encoding(CodePages.codePage(name: probe.valueAsString.lowercased()))
                }
                try probe.readNext()
            }
            return createReader(encoding: encoding)
        }

        private func createReader(encoding: String.Encoding) -> DxfGroupReader {
            isBinary ? DxfBinaryGroupReader(data, encoding: encoding, isAC1009: isAC1009Binary)
                : DxfTextGroupReader(data, encoding: encoding)
        }

        /// `goToSection`.
        private func goToSection(_ name: String) throws {
            if reader.valueAsString == name { return }
            _ = try reader.find(name)
        }

        // ───────────────────────── Header ─────────────────────────

        /// `ReadHeader`.
        private func readHeader() throws -> CadHeader {
            try goToSection(DxfFileToken.headerSection)
            let header = CadHeader()
            try reader.readNext()
            while reader.valueAsString != DxfFileToken.endSection {
                let name = reader.valueAsString
                guard let variable = CadHeader.variablesByName[name] else {
                    try reader.readNext()
                    continue
                }
                var values: [DxfRawValue?] = []
                for _ in variable.codes {
                    try reader.readNext()
                    if reader.code == 9 || reader.code == 0 {
                        // Irregular files may not follow the header type.
                        values.append(nil)
                        break
                    }
                    values.append(reader.value)
                }
                if !header.setValue(variable, values) {
                    builder?.notify("Invalid value for header variable \(name)")
                }
                if reader.code != 9, reader.code != 0 { try reader.readNext() }
            }
            return header
        }

        // ───────────────────────── Classes ─────────────────────────

        private func readClasses() throws {
            try goToSection(DxfFileToken.classesSection)
            try reader.readNext()
            while reader.valueAsString != DxfFileToken.endSection {
                if reader.valueAsString == DxfFileToken.classEntry {
                    let item = try readClass()
                    if item.classNumber < 500 { item.classNumber = Int16(500 + document.classes.count) }
                    document.classes.add(item)
                } else {
                    try reader.readNext()
                }
            }
        }

        private func readClass() throws -> DxfClass {
            let item = DxfClass()
            try reader.readNext()
            while reader.code != 0 {
                switch reader.code {
                case 1: item.dxfName = reader.valueAsString
                case 2: item.cppClassName = reader.valueAsString
                case 3: item.applicationName = reader.valueAsString
                case 90: item.proxyFlags = Int32(UInt16(truncatingIfNeeded: try reader.valueAsInt))
                case 91: item.instanceCount = try reader.valueAsInt
                case 280: item.wasZombie = try reader.valueAsBool
                case 281: item.isAnEntity = try reader.valueAsBool
                default: break
                }
                try reader.readNext()
            }
            return item
        }

        // ───────────────────────── Common data ─────────────────────────

        /// `readCommonObjectData` of tables.
        func readCommonObjectData() throws -> (name: String?, handle: UInt64, owner: UInt64?, xdict: UInt64?, reactors: HandleSet) {
            var name: String?
            var handle: UInt64 = 0
            var owner: UInt64?
            var xdict: UInt64?
            var reactors = HandleSet()
            if reader.code == 0 || reader.code == 100 { try reader.readNext() }
            while reader.code != 0, reader.code != 100 {
                switch reader.code {
                case 2: name = reader.valueAsString
                case 5, 105: handle = try reader.valueAsHandle
                case 102:
                    let groups = try readDefinedGroups()
                    xdict = groups.xdict ?? xdict
                    reactors.formUnion(groups.reactors)
                case 330: owner = try reader.valueAsHandle
                default: builder.notify("Unhandled dxf code \(reader.code) at line \(reader.position).")
                }
                try reader.readNext()
            }
            return (name, handle, owner, xdict, reactors)
        }

        /// `readCommonCodes`; returns true when extended data was read (the next group is already current).
        func readCommonCodes(_ template: CadTemplate) throws -> Bool {
            switch reader.code {
            case 5: template.cadObject.handle = try reader.valueAsHandle
            case 100: currentSubclass = reader.valueAsString
            case 102:
                let groups = try readDefinedGroups()
                if let xdict = groups.xdict { template.xdictHandle = xdict }
                template.reactorsHandles.formUnion(groups.reactors)
            case 330: template.ownerHandle = try reader.valueAsHandle
            case 1001:
                try readExtendedData(&template.edataByAppName)
                return true
            default:
                builder.notify("[\(currentSubclass)] Unhandled dxf code \(reader.code) with value \(reader.valueAsString)")
            }
            return false
        }

        /// `readDefinedGroups`.
        func readDefinedGroups() throws -> (xdict: UInt64?, reactors: [UInt64]) {
            switch reader.valueAsString {
            case DxfFileToken.dictionaryToken:
                try reader.readNext()
                let handle = try reader.valueAsHandle
                try reader.readNext()
                return (handle, [])
            case DxfFileToken.reactorsToken:
                var reactors: [UInt64] = []
                try reader.readNext()
                while reader.code != 102 {
                    reactors.append(try reader.valueAsHandle)
                    try reader.readNext()
                }
                return (nil, reactors)
            default:
                repeat { try reader.readNext() } while reader.code != 102
                return (nil, [])
            }
        }

        /// `readExtendedData`: one application's records (and the following applications').
        func readExtendedData(_ edata: inout [(String, [XDataRecord])]) throws {
            let app = reader.valueAsString
            var records: [XDataRecord] = []
            try reader.readNext()
            while reader.code >= 1000 {
                if reader.code == 1001 {
                    edata.append((app, records))
                    try readExtendedData(&edata)
                    return
                }
                func point() throws -> XYZ {
                    let x = try reader.valueAsDouble
                    try reader.readNext()
                    let y = try reader.valueAsDouble
                    try reader.readNext()
                    return XYZ(x, y, try reader.valueAsDouble)
                }
                switch reader.code {
                case 1000: records.append(.string(reader.valueAsString))
                case 1002: records.append(.controlString(isClosing: reader.valueAsString == "}"))
                case 1003:
                    if let layer = builder.layers[reader.valueAsString] {
                        records.append(.layer(layer.handle))
                    } else {
                        builder.notify("[XData] Could not found the linked Layer \(reader.valueAsString).")
                    }
                case 1004: records.append(.binaryChunk(reader.valueAsBinaryChunk ?? Data()))
                case 1005: records.append(.handle(try reader.valueAsHandle))
                case 1010: records.append(.coordinate(try point()))
                case 1011: records.append(.worldCoordinate(try point()))
                case 1012: records.append(.displacement(try point()))
                case 1013: records.append(.direction(try point()))
                case 1040: records.append(.real(try reader.valueAsDouble))
                case 1041: records.append(.distance(try reader.valueAsDouble))
                case 1042: records.append(.scale(try reader.valueAsDouble))
                case 1070: records.append(.integer16(try reader.valueAsShort))
                case 1071: records.append(.integer32(try reader.valueAsInt))
                default: builder.notify("Unknown code for extended data: \(reader.code)")
                }
                try reader.readNext()
            }
            edata.append((app, records))
        }

        // ───────────────────────── Tables ─────────────────────────

        private func readTables() throws {
            try goToSection(DxfFileToken.tablesSection)
            try reader.readNext()
            while reader.valueAsString != DxfFileToken.endSection {
                guard reader.valueAsString == DxfFileToken.tableEntry else {
                    throw DxfException("Unexpected token at the beginning of a table: \(reader.valueAsString)")
                }
                try readTable()
                guard reader.valueAsString == DxfFileToken.endTable else {
                    throw DxfException("Unexpected token at the end of a table: \(reader.valueAsString)")
                }
                try reader.readNext()
            }
        }

        /// `ReadTable`.
        func readTable() throws {
            try reader.readNext()
            var edata: [(String, [XDataRecord])] = []
            let common = try readCommonObjectData()
            if reader.code == 100 {
                while reader.code != 0 {
                    switch reader.code {
                    case 70: break
                    case 100 where reader.valueAsString == DxfSubclassMarker.dimensionStyleTable:
                        while reader.code != 0 { try reader.readNext() }
                    case 100: break
                    case 1001: try readExtendedData(&edata)
                    default: builder.notify("[AcDbSymbolTable] Unhandeled dxf code \(reader.code) at line \(reader.position).")
                    }
                    if reader.code == 0 { break }
                    try reader.readNext()
                }
            } else if reader.valueAsString == DxfFileToken.endTable {
                return
            }

            let template: CadTemplate
            switch common.name {
            case DxfFileToken.tableAppId:
                let t = CadTableTemplate<AppId>(AppIdsTable())
                try readEntries(t)
                builder.appIds = t.cadObject as! AppIdsTable
                template = t
            case DxfFileToken.tableBlockRecord:
                let t = CadTableTemplate<BlockRecord>(BlockRecordsTable())
                try readEntries(t)
                builder.blockRecords = t.cadObject as! BlockRecordsTable
                template = t
            case DxfFileToken.tableVport:
                let t = CadTableTemplate<VPort>(VPortsTable())
                try readEntries(t)
                builder.vports = t.cadObject as! VPortsTable
                template = t
            case DxfFileToken.tableLinetype:
                let t = CadTableTemplate<LineType>(LineTypesTable())
                try readEntries(t)
                builder.lineTypes = t.cadObject as! LineTypesTable
                template = t
            case DxfFileToken.tableLayer:
                let t = CadTableTemplate<Layer>(LayersTable())
                try readEntries(t)
                builder.layers = t.cadObject as! LayersTable
                template = t
            case DxfFileToken.tableStyle:
                let t = CadTableTemplate<TextStyle>(TextStylesTable())
                try readEntries(t)
                builder.textStyles = t.cadObject as! TextStylesTable
                template = t
            case DxfFileToken.tableView:
                let t = CadTableTemplate<View>(ViewsTable())
                try readEntries(t)
                builder.views = t.cadObject as! ViewsTable
                template = t
            case DxfFileToken.tableUcs:
                let t = CadTableTemplate<UCS>(UCSTable())
                try readEntries(t)
                builder.ucss = t.cadObject as! UCSTable
                template = t
            case DxfFileToken.tableDimstyle:
                let t = CadTableTemplate<DimensionStyle>(DimensionStylesTable())
                try readEntries(t)
                builder.dimensionStyles = t.cadObject as! DimensionStylesTable
                template = t
            default:
                throw DxfException("Unknown table name \(common.name ?? "")")
            }
            template.cadObject.handle = common.handle
            template.ownerHandle = common.owner
            template.xdictHandle = common.xdict
            template.reactorsHandles = common.reactors
            template.edataByAppName = edata
            builder.addTemplate(template)
        }

        private func readEntries<T: TableEntry>(_ tableTemplate: CadTableTemplate<T>) throws {
            let table = tableTemplate.table
            while reader.valueAsString != DxfFileToken.endTable {
                try reader.readNext()
                let template: CadTableEntryTemplate
                switch table.objectName {
                case DxfFileToken.tableAppId: template = try readTableEntry(CadTableEntryTemplate(AppId(name: ""))) { _ in false }
                case DxfFileToken.tableBlockRecord:
                    let block = CadBlockRecordTemplate(BlockRecord(name: ""))
                    template = try readTableEntry(block, readBlockRecord)
                    if block.name.caseInsensitiveCompare(BlockRecord.modelSpaceName) == .orderedSame { builder.modelSpaceTemplate = block }
                case DxfFileToken.tableDimstyle: template = try readTableEntry(CadDimensionStyleTemplate(DimensionStyle(name: "")), readDimensionStyle)
                case DxfFileToken.tableLayer: template = try readTableEntry(CadLayerTemplate(Layer(name: "")), readLayer)
                case DxfFileToken.tableLinetype: template = try readTableEntry(CadLineTypeTemplate(LineType(name: "")), readLineType)
                case DxfFileToken.tableStyle: template = try readTableEntry(CadTableEntryTemplate(TextStyle(name: "")), readTextStyle)
                case DxfFileToken.tableUcs: template = try readTableEntry(CadTableEntryTemplate(UCS(name: "")), readUcs)
                case DxfFileToken.tableView: template = try readTableEntry(CadViewTemplate(View(name: "")), readView)
                case DxfFileToken.tableVport: template = try readTableEntry(CadVPortTemplate(VPort(name: "")), readVPort)
                default: continue
                }
                // Failsafe: the later entry replaces the earlier one (default entries cannot be removed, so adding
                // a second one fails like Dictionary.Add).
                if table.contains(template.name), failsafe {
                    builder.notify("Duplicated entry with name \(template.name) found in \(template.cadObject.objectName)")
                    table.remove(template.name)
                }
                guard table.add(template.cadObject as! T) else {
                    throw DxfException("An item with the same key has already been added. Key: \(template.name)")
                }
                builder.addTemplate(template)
            }
        }

        private func readTableEntry<Template: CadTableEntryTemplate>(_ template: Template,
                                                                       _ readEntry: (Template) throws -> Bool) throws -> Template {
            while reader.code != 0 {
                if try !readEntry(template) {
                    if try readCommonTableEntryCodes(template) { continue }
                }
                if reader.code != 0 { try reader.readNext() }
            }
            return template
        }

        private func readCommonTableEntryCodes(_ template: CadTableEntryTemplate) throws -> Bool {
            switch reader.code {
            case 2: try template.entry.setName(reader.valueAsString)
            case 70: template.entry.flags = Int16(bitPattern: try reader.valueAsUShort)
            case 100: break
            default: return try readCommonCodes(template)
            }
            return false
        }

        private func readBlockRecord(_ template: CadBlockRecordTemplate) throws -> Bool {
            let record = template.record
            switch reader.code {
            case 70: record.units = try reader.valueAsShort
            case 340: template.layoutHandle = try reader.valueAsHandle
            case 280: record.isExplodable = try reader.valueAsBool
            case 281: record.canScale = try reader.valueAsBool
            case 310: record.preview = reader.valueAsBinaryChunk
            default: return false
            }
            return true
        }

        private func readDimensionStyle(_ template: CadDimensionStyleTemplate) throws -> Bool {
            let s = template.cadObject as! DimensionStyle
            let r = reader!
            switch r.code {
            case 3: s.postFix = r.valueAsString
            case 4: s.alternateDimensioningSuffix = r.valueAsString
            case 5: template.dimblName = r.valueAsString
            case 6: template.dimblk1Name = r.valueAsString
            case 7: template.dimblk2Name = r.valueAsString
            case 40:
                let value = try r.valueAsDouble
                if value < 0 {
                    s.scaleFactor = MathHelper.epsilon
                    builder.notify("[\(s.subclassMarker)] Assignation error for ScaleFactor.")
                } else {
                    s.scaleFactor = value
                }
            case 41:
                let value = try r.valueAsDouble
                if value < 0 { builder.notify("[\(s.subclassMarker)] Assignation error for ArrowSize.") } else { s.arrowSize = value }
            case 42: s.extensionLineOffset = try r.valueAsDouble
            case 43: s.dimensionLineIncrement = try r.valueAsDouble
            case 44: s.extensionLineExtension = try r.valueAsDouble
            case 45: s.rounding = try r.valueAsDouble
            case 46: s.dimensionLineExtension = try r.valueAsDouble
            case 47: s.plusTolerance = try r.valueAsDouble
            case 48: s.minusTolerance = try r.valueAsDouble
            case 49: s.fixedExtensionLineLength = try r.valueAsDouble
            case 50:
                let value = try r.valueAsAngle
                let rounded = (value * 1e6).rounded(.toNearestOrEven) / 1e6
                if rounded <= MathHelper.degToRad(5) || rounded >= MathHelper.halfPI {
                    builder.notify("[\(s.subclassMarker)] Assignation error for JoggedRadiusDimensionTransverseSegmentAngle.")
                } else {
                    s.joggedRadiusDimensionTransverseSegmentAngle = value
                }
            case 69: s.textBackgroundFillMode = try r.valueAsShort
            case 70:
                if !template.dxfFlagsAssigned {
                    template.dxfFlagsAssigned = true
                } else if try r.valueAsShort >= 0 {
                    s.textBackgroundColor = Color(index: try r.valueAsShort)
                }
            case 71: s.generateTolerances = try r.valueAsBool
            case 72: s.limitsGeneration = try r.valueAsBool
            case 73: s.textInsideHorizontal = try r.valueAsBool
            case 74: s.textOutsideHorizontal = try r.valueAsBool
            case 75: s.suppressFirstExtensionLine = try r.valueAsBool
            case 76: s.suppressSecondExtensionLine = try r.valueAsBool
            case 77: s.textVerticalAlignment = Int32(try r.valueAsShort)
            case 78: s.zeroHandling = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 79: s.angularZeroHandling = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 90: s.arcLengthSymbolPosition = Int16(truncatingIfNeeded: try r.valueAsShort)
            case 105: s.handle = try r.valueAsHandle
            case 140:
                let value = try r.valueAsDouble
                if value <= 0 { builder.notify("[\(s.subclassMarker)] Assignation error for TextHeight.") } else { s.textHeight = value }
            case 141: s.centerMarkSize = try r.valueAsDouble
            case 142: s.tickSize = try r.valueAsDouble
            case 143: s.alternateUnitScaleFactor = try r.valueAsDouble
            case 144: s.linearScaleFactor = try r.valueAsDouble
            case 145: s.textVerticalPosition = try r.valueAsDouble
            case 146: s.toleranceScaleFactor = try r.valueAsDouble
            case 147: s.dimensionLineGap = try r.valueAsDouble
            case 148: s.alternateUnitRounding = try r.valueAsDouble
            case 170: s.alternateUnitDimensioning = try r.valueAsBool
            case 171: s.alternateUnitDecimalPlaces = try r.valueAsShort
            case 172: s.textOutsideExtensions = try r.valueAsBool
            case 173: s.separateArrowBlocks = try r.valueAsBool
            case 174: s.textInsideExtensions = try r.valueAsBool
            case 175: s.suppressOutsideExtensions = try r.valueAsBool
            case 176: s.dimensionLineColor = try color(index: r.valueAsShort)
            case 177: s.extensionLineColor = try color(index: r.valueAsShort)
            case 178: s.textColor = try color(index: r.valueAsShort)
            case 179: s.angularDecimalPlaces = try r.valueAsShort
            case 270, 277: s.linearUnitFormat = try r.valueAsShort
            case 271: s.decimalPlaces = try r.valueAsShort
            case 272: s.toleranceDecimalPlaces = try r.valueAsShort
            case 273: s.alternateUnitFormat = try r.valueAsShort
            case 274: s.alternateUnitToleranceDecimalPlaces = try r.valueAsShort
            case 275: s.angularUnit = try r.valueAsShort
            case 276: s.fractionFormat = try r.valueAsShort
            case 278: s.decimalSeparator = UInt16(bitPattern: try r.valueAsShort)
            case 279: s.textMovement = try r.valueAsShort
            case 280: s.textHorizontalAlignment = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 281: s.suppressFirstDimensionLine = try r.valueAsBool
            case 282: s.suppressSecondDimensionLine = try r.valueAsBool
            case 283: s.toleranceAlignment = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 284: s.toleranceZeroHandling = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 285: s.alternateUnitZeroHandling = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 286: s.alternateUnitToleranceZeroHandling = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 287: s.dimensionFit = try r.valueAsShort
            case 288: s.cursorUpdate = try r.valueAsBool
            case 289: s.dimensionTextArrowFit = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 290: s.isExtensionLineLengthFixed = try r.valueAsBool
            case 340: template.textStyleHandle = try r.valueAsHandle
            case 341: template.dimldrblk = try r.valueAsHandle
            case 342: template.dimblk = try r.valueAsHandle
            case 343: template.dimblk1 = try r.valueAsHandle
            case 344: template.dimblk2 = try r.valueAsHandle
            case 345: template.dimltype = try r.valueAsHandle
            case 346: template.dimltex1 = try r.valueAsHandle
            case 347: template.dimltex2 = try r.valueAsHandle
            case 371: s.dimensionLineWeight = LineWeight(try r.valueAsShort)
            case 372: s.extensionLineWeight = LineWeight(try r.valueAsShort)
            default: return false
            }
            return true
        }

        /// `new Color(short)`: throws outside 0 … 257 like ACadSharp.
        func color(index: Int16) throws -> Color {
            guard index >= 0, index <= 257 else { throw DxfException("True index must be a value between 0 and 257.") }
            return Color(index: index)
        }

        private func readLayer(_ template: CadLayerTemplate) throws -> Bool {
            let layer = template.cadObject as! Layer
            switch reader.code {
            case 6: template.lineTypeName = reader.valueAsString
            case 62:
                var index = try reader.valueAsShort
                if index < 0 {
                    layer.isOn = false
                    index = index == Int16.min ? Int16.max : abs(index)
                }
                let color = try color(index: index)
                if color.isByBlock || color.isByLayer {
                    builder.notify("Wrong index \(index) for layer \(layer.name)")
                } else {
                    layer.color = color
                }
            case 347: template.materialHandle = try reader.valueAsHandle
            case 348: break
            case 390: layer.plotStyleName = try reader.valueAsHandle
            case 430: template.trueColorName = reader.valueAsString
            case 420:
                // Map: Color (62, 420, 430) — a true colour replaces the index; the layer stays on/off as set by 62.
                layer.color = Color.fromRgb24(try reader.valueAsInt)
            case 290: layer.plotFlag = try reader.valueAsBool
            case 370: layer.lineWeight = LineWeight(try reader.valueAsShort)
            default: return false
            }
            return true
        }

        private func readLineType(_ template: CadLineTypeTemplate) throws -> Bool {
            let lineType = template.cadObject as! LineType
            switch reader.code {
            case 40: template.totalLen = try reader.valueAsDouble
            case 49:
                repeat {
                    template.segmentTemplates.append(try readLineTypeSegment())
                } while reader.code == 49
                return true
            case 73: break
            case 3: lineType.description = rawString
            case 72: lineType.alignment = Character(UnicodeScalar(UInt8(truncatingIfNeeded: try reader.valueAsShort)))
            default: return false
            }
            return true
        }

        private func readLineTypeSegment() throws -> CadLineTypeTemplate.SegmentTemplate {
            let template = CadLineTypeTemplate.SegmentTemplate()
            let segment = template.segment
            segment.length = try reader.valueAsDouble
            try reader.readNext()
            while reader.code != 49, reader.code != 0 {
                switch reader.code {
                case 9: segment.text = reader.valueAsString
                case 44: segment.offset.x = try reader.valueAsDouble
                case 45: segment.offset.y = try reader.valueAsDouble
                case 46: segment.scale = try reader.valueAsDouble
                case 50: segment.rotation = try reader.valueAsAngle
                case 74: segment.flags = Int16(bitPattern: try reader.valueAsUShort)
                case 75: segment.shapeNumber = Int16(truncatingIfNeeded: try reader.valueAsInt)
                case 340: break
                default:
                    builder.notify("[LineTypeSegment] Unhandeled dxf code \(reader.code) with value \(reader.valueAsString), positon \(reader.position)")
                }
                try reader.readNext()
            }
            return template
        }

        private func readTextStyle(_ template: CadTableEntryTemplate) throws -> Bool {
            let style = template.cadObject as! TextStyle
            switch reader.code {
            case 2:
                if !reader.valueAsString.isEmpty { try style.setName(reader.valueAsString) }
            case 3: style.filename = rawString
            case 4: style.bigFontFilename = rawString
            case 40: style.height = try reader.valueAsDouble
            case 41: style.width = try reader.valueAsDouble
            case 42: style.lastHeight = try reader.valueAsDouble
            case 50: style.obliqueAngle = try reader.valueAsAngle
            case 71: style.mirrorFlag = try reader.valueAsShort
            case 70: style.flags = Int16(bitPattern: try reader.valueAsUShort)
            default: return false
            }
            return true
        }

        private func readUcs(_ template: CadTableEntryTemplate) throws -> Bool {
            let ucs = template.cadObject as! UCS
            switch reader.code {
            case 10, 20, 30: ucs.origin[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 11, 21, 31: ucs.xAxis[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 12, 22, 32: ucs.yAxis[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 71: ucs.orthographicType = try reader.valueAsShort
            case 79: ucs.orthographicViewType = try reader.valueAsShort
            case 146: ucs.elevation = try reader.valueAsDouble
            default: return false
            }
            return true
        }

        private func readView(_ template: CadViewTemplate) throws -> Bool {
            let view = template.cadObject as! View
            switch reader.code {
            case 348: template.visualStyleHandle = try reader.valueAsHandle
            case 40: view.height = try reader.valueAsDouble
            case 41: view.width = try reader.valueAsDouble
            case 42: view.lensLength = try reader.valueAsDouble
            case 43: view.frontClipping = try reader.valueAsDouble
            case 44: view.backClipping = try reader.valueAsDouble
            case 50: view.angle = try reader.valueAsAngle
            case 71: view.viewMode = Int32(try reader.valueAsShort)
            case 72: view.isUcsAssociated = try reader.valueAsBool
            case 73: view.isPlottable = try reader.valueAsBool
            case 281: view.renderMode = UInt8(truncatingIfNeeded: try reader.valueAsShort)
            case 10, 20: view.center[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 11, 21, 31: view.direction[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 12, 22, 32: view.target[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 110, 120, 130: view.ucsOrigin[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 111, 121, 131: view.ucsXAxis[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 112, 122, 132: view.ucsYAxis[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
            case 146: view.ucsElevation = try reader.valueAsDouble
            case 79: view.ucsOrthographicType = try reader.valueAsShort
            default: return false
            }
            return true
        }

        private func readVPort(_ template: CadVPortTemplate) throws -> Bool {
            let v = template.cadObject as! VPort
            let r = reader!
            let i = (r.code / 10) % 10 - 1
            switch r.code {
            case 65, 73: break
            case 348: template.styleHandle = try r.valueAsHandle
            case 10, 20: v.bottomLeft[i] = try r.valueAsDouble
            case 11, 21: v.topRight[i] = try r.valueAsDouble
            case 12, 22: v.center[i] = try r.valueAsDouble
            case 13, 23: v.snapBasePoint[i] = try r.valueAsDouble
            case 14, 24: v.snapSpacing[i] = try r.valueAsDouble
            case 15, 25: v.gridSpacing[i] = try r.valueAsDouble
            case 16, 26, 36: v.direction[i] = try r.valueAsDouble
            case 17, 27, 37: v.target[i] = try r.valueAsDouble
            case 40: v.viewHeight = try r.valueAsDouble
            case 41: v.aspectRatio = try r.valueAsDouble
            case 42: v.lensLength = try r.valueAsDouble
            case 43: v.frontClippingPlane = try r.valueAsDouble
            case 44: v.backClippingPlane = try r.valueAsDouble
            case 50: v.snapRotation = try r.valueAsAngle
            case 51: v.twistAngle = try r.valueAsAngle
            case 72: v.circleZoomPercent = try r.valueAsShort
            case 281: v.renderMode = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 71: v.viewMode = Int32(try r.valueAsShort)
            case 74: v.ucsIconDisplay = try r.valueAsShort
            case 75: v.snapOn = try r.valueAsBool
            case 76: v.showGrid = try r.valueAsBool
            case 77: v.isometricSnap = try r.valueAsBool
            case 78: v.snapIsoPair = try r.valueAsShort
            case 110, 120, 130: v.origin[i] = try r.valueAsDouble
            case 111, 121, 131: v.xAxis[i] = try r.valueAsDouble
            case 112, 122, 132: v.yAxis[i] = try r.valueAsDouble
            case 79: v.orthographicType = try r.valueAsShort
            case 146: v.elevation = try r.valueAsDouble
            case 60: v.gridFlags = try r.valueAsShort
            case 61: v.minorGridLinesPerMajorGridLine = try r.valueAsShort
            case 292: v.useDefaultLighting = try r.valueAsBool
            case 282: v.defaultLighting = UInt8(truncatingIfNeeded: try r.valueAsShort)
            case 141: v.brightness = try r.valueAsDouble
            case 142: v.contrast = try r.valueAsDouble
            case 63: v.ambientColor = try color(index: r.valueAsShort)
            case 421: v.ambientColor = Color.fromRgb24(try r.valueAsInt)
            case 345: template.namedUcsHandle = try r.valueAsHandle
            case 346: template.baseUcsHandle = try r.valueAsHandle
            default: return false
            }
            return true
        }

        /// The raw value text (map assignments use `Value`, not `ValueAsString`).
        var rawString: String { reader.value.text }

        // ───────────────────────── Blocks ─────────────────────────

        private func readBlocks() throws {
            try goToSection(DxfFileToken.blocksSection)
            try reader.readNext()
            while reader.valueAsString != DxfFileToken.endSection {
                do {
                    guard reader.valueAsString == DxfFileToken.block else {
                        throw DxfException("Unexpected token at the BLOCKS table: \(reader.valueAsString)")
                    }
                    try readBlock()
                } catch let error where !(error is CancellationError) {
                    builder.notify("Error while reading a block at line \(reader.position): \(error)")
                    while !(reader.code == 0 && reader.valueAsString == DxfFileToken.endSection)
                        && !(reader.code == 0 && reader.valueAsString == DxfFileToken.block) {
                        try reader.readNext()
                    }
                }
            }
        }

        private func readBlock() throws {
            try reader.readNext()
            let blockEntity = Block()
            let template = CadBlockEntityTemplate(blockEntity)
            var name: String?
            var record: BlockRecord?
            currentSubclass = ""
            while reader.code != 0 {
                switch reader.code {
                case 2, 3:
                    var value = reader.valueAsString
                    if value.caseInsensitiveCompare("$MODEL_SPACE") == .orderedSame { value = BlockRecord.modelSpaceName }
                    else if value.caseInsensitiveCompare("$PAPER_SPACE") == .orderedSame { value = BlockRecord.paperSpaceName }
                    name = value
                    if record == nil, let found: BlockRecord = builder.tableEntry(value) {
                        record = found
                        found.setBlockEntity(blockEntity)
                    } else if record == nil {
                        builder.notify("Block record [\(value)] not found at line \(reader.position)")
                    }
                case 330:
                    if record == nil, let found: BlockRecord = builder.tryGetObject(try reader.valueAsHandle) {
                        record = found
                        found.setBlockEntity(blockEntity)
                    } else if record == nil {
                        builder.notify("Block record with handle [\(reader.valueAsString)] not found at line \(reader.position)")
                    }
                case 10, 20, 30: blockEntity.basePoint[(reader.code / 10) % 10 - 1] = try reader.valueAsDouble
                case 4: blockEntity.comments = rawString
                case 70: blockEntity.blockFlags = try reader.valueAsShort
                case 71: blockEntity.isUnloaded = try reader.valueAsBool
                case 1: blockEntity.xRefPath = rawString
                default:
                    if try readCommonEntityCodes(template) { continue }
                }
                try reader.readNext()
            }

            let recordTemplate: CadBlockRecordTemplate
            if record == nil {
                let newRecord = BlockRecord(name: name ?? "")
                newRecord.setBlockEntity(blockEntity)
                recordTemplate = CadBlockRecordTemplate(newRecord)
                builder.addTemplate(recordTemplate)
                builder.blockRecords.add(newRecord)
                if newRecord.name.caseInsensitiveCompare(BlockRecord.modelSpaceName) == .orderedSame { builder.modelSpaceTemplate = recordTemplate }
                record = newRecord
            } else if let existing: CadBlockRecordTemplate = builder.objectTemplate(record!.handle) {
                recordTemplate = existing
            } else {
                recordTemplate = CadBlockRecordTemplate(record!)
            }
            recordTemplate.blockEntityTemplate = template

            while reader.valueAsString != DxfFileToken.endBlock {
                var entityTemplate: CadEntityTemplate?
                do {
                    entityTemplate = try readEntity()
                } catch let error where !(error is CancellationError) {
                    builder.notify("Error while reading a block with name \(record!.name) at line \(reader.position): \(error)")
                    while reader.code != 0 { try reader.readNext() }
                }
                guard let entityTemplate else { continue }
                builder.addTemplate(entityTemplate)
                if entityTemplate.ownerHandle == nil {
                    recordTemplate.referenceTemplates.append(entityTemplate)
                } else if let owner: CadTemplate = builder.objectTemplate(entityTemplate.ownerHandle), let ownerTemplate = owner as? CadOwnerTemplate {
                    ownerTemplate.ownedObjectsHandlers.insert(entityTemplate.cadObject.handle)
                } else {
                    builder.orphanTemplates.append(entityTemplate)
                }
            }
            try readBlockEnd(record!.blockEnd)
            builder.addTemplate(template)
        }

        private func readBlockEnd(_ end: BlockEnd) throws {
            let template = CadEntityTemplate(end)
            currentSubclass = ""
            if reader.code == 0 { try reader.readNext() }
            while reader.code != 0 {
                if try readCommonEntityCodes(template) { continue }
                try reader.readNext()
            }
            builder.addTemplate(template)
        }

        // ───────────────────────── Entities section ─────────────────────────

        private func readEntitiesSection() throws {
            try goToSection(DxfFileToken.entitiesSection)
            try reader.readNext()
            while reader.valueAsString != DxfFileToken.endSection {
                var template: CadEntityTemplate?
                do {
                    template = try readEntity()
                } catch let error where !(error is CancellationError) {
                    builder.notify("Error while reading an entity at line \(reader.position): \(error)")
                    while reader.code != 0 { try reader.readNext() }
                }
                guard let template else { continue }
                builder.addTemplate(template)
                if template.ownerHandle == nil {
                    builder.modelSpaceEntities.append(template.entity)
                } else if let owner: CadTemplate = builder.objectTemplate(template.ownerHandle), let ownerTemplate = owner as? CadOwnerTemplate {
                    ownerTemplate.ownedObjectsHandlers.insert(template.cadObject.handle)
                } else {
                    builder.orphanTemplates.append(template)
                }
            }
        }

    }
}

extension ACad.CadHeader {
    /// `SetValue`: false when the value is rejected (ACadSharp throws and the reader warns).
    func setValue(_ variable: Variable, _ values: [ACad.DxfRawValue?]) -> Bool {
        func first() -> ACad.DxfRawValue? { values.first ?? nil }
        func double(_ i: Int = 0) -> Double? { i < values.count ? (try? values[i]?.double()) ?? 0 : nil }
        do {
            switch variable.accessor {
            case let .double(p):
                guard let v = try first()?.double() ?? Optional(0) else { return false }
                if let range = variable.range, !range.contains(v) { return false }
                self[keyPath: p] = v
            case let .int16(p):
                let v = Int16(try first()?.integer(-32768...32767) ?? 0)
                if let range = variable.range, !range.contains(Double(v)) { return false }
                self[keyPath: p] = v
            case let .uint16(p): self[keyPath: p] = UInt16(truncatingIfNeeded: try first()?.integer(-65536...65535) ?? 0)
            case let .int32(p): self[keyPath: p] = Int32(try first()?.integer(-2_147_483_648...2_147_483_647) ?? 0)
            case let .int64(p): self[keyPath: p] = try first()?.integer(Int64.min...Int64.max) ?? 0
            case let .uint8(p): self[keyPath: p] = UInt8(truncatingIfNeeded: try first()?.integer(Int64.min...Int64.max) ?? 0)
            case let .uint64(p):
                guard case let .handle(h)? = first() else { return false }
                self[keyPath: p] = h
            case let .bool(p): self[keyPath: p] = try first()?.bool() ?? false
            case let .string(p):
                guard case let .string(s)? = first() else { return values.first == nil ? false : false }
                if variable.isName, s.isEmpty { return true }
                self[keyPath: p] = s
            case let .optionalString(p):
                guard case let .string(s)? = first() else { self[keyPath: p] = nil; return true }
                if variable.isName, s.isEmpty { return true }
                self[keyPath: p] = s
            case let .xyz(p):
                guard values.count >= 3, let x = double(0), let y = double(1), let z = double(2) else { return false }
                self[keyPath: p] = ACad.XYZ(x, y, z)
            case let .xy(p):
                guard values.count >= 2, let x = double(0), let y = double(1) else { return false }
                self[keyPath: p] = ACad.XY(x, y)
            case let .color(p):
                let index = try first()?.integer(-32768...32767) ?? 0
                guard index >= 0, index <= 257 else { return false }
                self[keyPath: p] = ACad.Color(index: Int16(index))
            case let .lineWeight(p): self[keyPath: p] = ACad.LineWeight(Int16(truncatingIfNeeded: try first()?.integer(-32768...32767) ?? 0))
            case let .date(p):
                guard case let .double(julian)? = first(), let date = ACad.CadDateTime.fromJulian(julian) else { return false }
                self[keyPath: p] = date
            case let .timeSpan(p):
                guard case let .double(days)? = first() else { return false }
                self[keyPath: p] = ACad.CadTimeSpan.editingTime(days)
            }
            return true
        } catch {
            return false
        }
    }
}
