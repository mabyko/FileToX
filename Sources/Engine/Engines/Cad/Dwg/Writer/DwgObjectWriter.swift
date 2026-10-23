// ACadSharp 3.8.0 `DwgObjectWriter`: the AcDbObjects section. Tables and their entries first, then the entities of
// every block, then the objects queued from the root dictionary and the extension dictionaries. Each object is
// written into a merged (data / text / handle) stream and appended with its size and CRC; `map` keeps its offset.
// Entities and objects are in DwgObjectWriter+Entities.swift and DwgObjectWriter+Objects.swift.

import Foundation

extension ACad {
    final class DwgObjectWriter: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.acDbObjects }

        /// Offset of every object in the section, by handle.
        private(set) var map: [UInt64: Int64] = [:]
        /// `DwgWriterConfiguration` defaults: XRecords, XData; no shapes, no dynamic block data.
        let writeDynamicParameters = false
        let writeShapes = false
        let writeXData = true
        let writeXRecords = true

        let document: Document
        private let stream: DwgMemoryStream
        private let msmain = DwgMemoryStream()
        let writer: DwgMergedStreamWriter
        private var insertsByBlockNameCache: [String?: [Insert]]?
        private var blockCompatibleEntities: [ObjectIdentifier: [Entity]] = [:]
        private var objects: [NonGraphicalObject] = []
        private var objectsHead = 0
        var prev: Entity?
        var next: Entity?
        /// `OnNotification` messages, for the log.
        private(set) var messages: [String] = []

        init(_ stream: DwgMemoryStream, _ document: Document) {
            self.stream = stream
            self.document = document
            writer = DwgMergedStreamWriter(msmain)
            super.init(document.header.version)
        }

        func note(_ message: String) { messages.append(message) }

        /// `InsertsByBlockName`: the model space inserts by block name, built on first use.
        func insertsByBlockName(_ name: String) -> [Insert] {
            if insertsByBlockNameCache == nil {
                var lookup: [String?: [Insert]] = [:]
                for case let insert as Insert in document.entities { lookup[insert.block?.name, default: []].append(insert) }
                insertsByBlockNameCache = lookup
            }
            return insertsByBlockNameCache?[name] ?? []
        }

        func write() throws {
            // For R18 and later the section data starts with a RL value of 0x0dca (meaning unknown).
            if r2004Plus { stream.write(DwgLE.bytes(Int32(0xDCA))) }
            guard let root = document.rootDictionary else { throw DxfWriteError.nullReference }
            enqueueValidObject(root)
            try writeBlockControl()
            try writeTable(document.layers)
            try writeTable(document.textStyles)
            try writeLTypeControlObject()
            try writeTable(document.views)
            try writeTable(document.ucss)
            try writeTable(document.vports)
            try writeTable(document.appIds)
            // For some reason the dimension must be writen the last
            try writeTable(document.dimensionStyles)
            try writeBlockEntities()
            try writeObjects()
        }

        func enqueueValidObject(_ object: NonGraphicalObject) { objects.append(object) }

        private func writeObjects() throws {
            while objectsHead < objects.count {
                let object = objects[objectsHead]
                objectsHead += 1
                try writeObject(object)
            }
        }

        private func compatibleEntities<S: Sequence>(_ entities: S) throws -> [Entity] where S.Element == Entity {
            try entities.filter { try isEntitySupported($0) }
        }

        /// `getEntMode`: 01 paper space, 10 model space, 00 owner handle present.
        private func entMode(_ entity: Entity) throws -> UInt8 {
            guard let owner = entity.owner else { return 0 }
            guard let paper = document.paperSpace else { throw DwgError.keyNotFound(BlockRecord.paperSpaceName) }
            if owner.handle == paper.handle { return 0b01 }
            if owner.handle == document.modelSpace.handle { return 0b10 }
            return 0
        }

        private func isEntitySupported(_ entity: Entity) throws -> Bool {
            guard try entity.isValid(format: .dwg, version: version) else {
                note("Invalid entity \(type(of: entity)) with handle \(entity.handle)")
                return false
            }
            switch entity {
            case is UnknownEntity:
                return false
            case is Shape:
                return writeShapes
            case is TableEntity where !r2010Plus, is ProxyEntity, is Solid3D, is CadBody, is Region:
                note("Entity type not implemented \(type(of: entity))")
                return false
            default:
                // `Wall` and `MechanicalEntity` are read as unknown entities by this model.
                return true
            }
        }

        /// `registerObject`: size (MS), handle stream size in bits (MC, R2010+), the object, its CRC.
        func registerObject(_ object: CadObject) throws {
            try writer.writeSpearShift()
            let position = stream.position
            let size = UInt32(truncatingIfNeeded: msmain.length)
            let sizeb = Int64(msmain.length << 3) - Int64(writer.savedPositionInBits)
            var head: [UInt8] = []
            Self.writeSize(&head, size)
            if r2010Plus { Self.writeSizeInBits(&head, UInt64(bitPattern: sizeb)) }
            let crc = DwgCrc.crc8(0xC0C1, head + msmain.bytes)
            stream.write(head)
            stream.write(msmain.bytes)
            stream.write(DwgLE.bytes(crc))
            // `Dictionary.Add`
            guard map[object.handle] == nil else { throw DwgError.duplicateKey(object.handle) }
            map[object.handle] = Int64(position)
        }

        private static func writeSize(_ out: inout [UInt8], _ size: UInt32) {
            if size >= 0b1000_0000_0000_0000 {
                out.append(UInt8(size & 0xFF))
                out.append(UInt8(((size >> 8) & 0b111_1111) | 0b1000_0000))
                out.append(UInt8((size >> 15) & 0xFF))
                out.append(UInt8((size >> 23) & 0xFF))
            } else {
                out.append(UInt8(size & 0xFF))
                out.append(UInt8((size >> 8) & 0xFF))
            }
        }

        private static func writeSizeInBits(_ out: inout [UInt8], _ size: UInt64) {
            if size == 0 {
                out.append(0)
                return
            }
            var size = size
            var shift = size >> 7
            while size != 0 {
                var b = UInt8(size & 0b111_1111)
                if shift != 0 { b |= 0b1000_0000 }
                out.append(b)
                size = shift
                shift = size >> 7
            }
        }

        // ───────────────────────── Common data ─────────────────────────

        func writeCommonData(_ object: CadObject) throws {
            // Reset the current stream to re-write a new object in it
            writer.resetStream()
            switch object.objectType {
            case .unlisted:
                if let dxfClass = document.classes[object.objectName] {
                    writer.writeObjectType(dxfClass.classNumber)
                } else {
                    note("Dxf Class not found for UNLISTED fullname: \(type(of: object))")
                    return
                }
            case .invalid, .undefined:
                note("CadObject type: \(object.objectType.rawValue) fullname: \(type(of: object))")
                return
            default:
                writer.writeObjectType(object.objectType.rawValue)
            }
            // Handle H 5 code 0, length followed by the handle bytes.
            writer.main.handleReference(.undefined, object.handle)
            try writeExtendedData(object)
        }

        func writeCommonEntityData(_ entity: Entity) throws {
            try writeCommonData(entity)
            // Graphic present Flag B 1 if a graphic is present
            writer.writeBit(false)
            try writeEntityMode(entity)
        }

        func writeCommonNonEntityData(_ object: CadObject) throws {
            try writeCommonData(object)
            // [Owner ref handle (soft pointer)]: the document's tables and root dictionary have no owner object.
            writer.handleReference(.softPointer, object.ownerHandle)
            writeReactorsAndDictionaryHandle(object)
        }

        func writeEntityMode(_ entity: Entity) throws {
            let entmode = try entMode(entity)
            writer.write2Bits(entmode)
            if entmode == 0 {
                writer.handleReference(.softPointer, entity.owner?.handle ?? 0)
            }
            writeReactorsAndDictionaryHandle(entity)
            writer.writeEnColor(entity.color, entity.transparency, entity.bookColor != nil)
            // R2004+: Color book color handle
            if let book = entity.bookColor { writer.handleReference(.hardPointer, book.handle) }
            writer.writeBitDouble(entity.lineTypeScale)
            // R2000+: 8 LAYER (hard pointer)
            writer.handleReference(.hardPointer, entity.layer.handle)
            switch entity.lineType.name {
            case LineType.byLayerName: writer.write2Bits(0b00)
            case LineType.byBlockName: writer.write2Bits(0b01)
            case LineType.continuousName: writer.write2Bits(0b10)
            default:
                writer.write2Bits(0b11)
                writer.handleReference(.hardPointer, entity.lineType.handle)
            }
            // R2007+: material flags, shadow flags
            if let material = entity.material {
                writer.write2Bits(0b11)
                writer.handleReference(.hardPointer, material.handle)
            } else {
                writer.write2Bits(0b00)
            }
            writer.writeByte(0)
            // R2000+: plot style flags
            writer.write2Bits(0b00)
            // R2010+: full / face / edge visual style flags
            writer.writeBit(false)
            writer.writeBit(false)
            writer.writeBit(false)
            // Invisibility BS 60
            writer.writeBitShort(entity.isInvisible ? 1 : 0)
            // R2000+: Lineweight RC 370
            writer.writeByte(entity.lineWeight.dwgIndex)
        }

        /// `CleanReactors` (reactors outside the document are dropped), the reactors and the extension dictionary.
        func writeReactorsAndDictionaryHandle(_ object: CadObject) {
            object.reactors.removeAll { document.object($0) == nil && !document.retiredHandles.contains($0) }
            writer.writeBitLong(Int32(object.reactors.count))
            for reactor in object.reactors { writer.handleReference(.softPointer, reactor) }
            let xdictionary = object.xDictionary
            // R2004+
            writer.writeBit(xdictionary == nil)
            if let xdictionary { writer.handleReference(.hardOwnership, xdictionary.handle) }
            // R2013+: Has DS binary data
            writer.writeBit(false)
            if let xdictionary { enqueueValidObject(xdictionary) }
        }

        func writeXrefDependantBit(_ entry: TableEntry) {
            // R2007+
            writer.writeBitShort(entry.flags & 16 != 0 ? 0b1_0000_0000 : 0) // StandardFlags.XrefDependent
        }

        private func writeExtendedData(_ object: CadObject) throws {
            if writeXData && object.hasExtendedData {
                for (app, data) in object.extendedData.entries {
                    try writeExtendedDataEntry(app, data)
                }
            }
            writer.writeBitShort(0)
        }

        private func writeExtendedDataEntry(_ app: AppId, _ entry: ExtendedData) throws {
            var m: [UInt8] = []
            for record in entry.records {
                m.append(UInt8(truncatingIfNeeded: record.code - 1000))
                switch record {
                case let .binaryChunk(data):
                    m.append(UInt8(truncatingIfNeeded: data.count))
                    m += data
                case let .controlString(isClosing):
                    m.append(isClosing ? 1 : 0)
                case let .integer16(v): m += DwgLE.bytes(v)
                case let .integer32(v): m += DwgLE.bytes(v)
                case let .real(v), let .scale(v), let .distance(v): m += DwgLE.bytes(v)
                case let .direction(v), let .displacement(v), let .coordinate(v), let .worldCoordinate(v):
                    m += DwgLE.bytes(v.x) + DwgLE.bytes(v.y) + DwgLE.bytes(v.z)
                case let .layer(handle):
                    let h = document.object(handle) is Layer ? handle : 0
                    m += withUnsafeBytes(of: h.bigEndian, Array.init)
                case let .handle(handle):
                    let h = document.object(handle) != nil ? handle : 0
                    m += withUnsafeBytes(of: h.bigEndian, Array.init)
                case let .string(s):
                    // R2007+: 2-byte length, UTF-16 characters, a 2-byte terminator.
                    let units = Array(s.utf16)
                    m += DwgLE.bytes(UInt16(truncatingIfNeeded: units.count + 1))
                    for u in units { m += DwgLE.bytes(u) }
                    m += [0, 0]
                }
            }
            writer.writeBitShort(Int16(truncatingIfNeeded: m.count))
            writer.main.handleReference(.hardPointer, app.handle)
            writer.writeBytes(m)
        }

        // ───────────────────────── Tables ─────────────────────────

        private func writeTable<T: TableEntry>(_ table: Table<T>) throws {
            try writeCommonNonEntityData(table)
            // Common: Numentries BL 70
            writer.writeBitLong(Int32(table.count))
            // R2000+: dimension styles have an extra byte
            if table is DimensionStylesTable { writer.writeByte(0) }
            for item in table { writer.handleReference(.softOwnership, item.handle) }
            try registerObject(table)
            try writeEntries(table)
        }

        private func writeEntries<T: TableEntry>(_ table: Table<T>) throws {
            for entry in table {
                guard try entry.isValid(format: .dwg, version: version) else {
                    note("\(type(of: entry)) with name \(entry.name) is not valid for version \(version.name).")
                    continue
                }
                switch entry {
                case let app as AppId: try writeAppId(app)
                case let record as BlockRecord: try writeBlockRecord(record)
                case let layer as Layer: try writeLayer(layer)
                case let ltype as LineType: try writeLineType(ltype)
                case let style as TextStyle: try writeTextStyle(style)
                case let ucs as UCS: try writeUCS(ucs)
                case let view as View: try writeView(view)
                case let style as DimensionStyle: try writeDimensionStyle(style)
                case let vport as VPort: try writeVPort(vport)
                default: note("Table entry not implemented : \(type(of: entry))")
                }
            }
        }

        private func writeAppId(_ app: AppId) throws {
            try writeCommonNonEntityData(app)
            writer.writeVariableText(app.name)
            writeXrefDependantBit(app)
            // Unknown RC 71
            writer.writeByte(0)
            // External reference block handle (hard pointer)
            writer.handleReference(.hardPointer, 0)
            try registerObject(app)
        }

        private func writeBlockBegin(_ block: Block) throws {
            try writeCommonEntityData(block)
            writer.writeVariableText(block.name)
            try registerObject(block)
        }

        private func writeBlockControl() throws {
            let records = document.blockRecords!
            try writeCommonNonEntityData(records)
            // Numentries BL 70 Doesn't count *MODEL_SPACE and *PAPER_SPACE.
            writer.writeBitLong(Int32(records.count - 2))
            for item in records {
                if item.name.caseInsensitiveCompare(BlockRecord.modelSpaceName) == .orderedSame
                    || item.name.caseInsensitiveCompare(BlockRecord.paperSpaceName) == .orderedSame { continue }
                writer.handleReference(.softOwnership, item.handle)
            }
            guard let paper = document.paperSpace else { throw DwgError.keyNotFound(BlockRecord.paperSpaceName) }
            writer.handleReference(.hardOwnership, document.modelSpace.handle)
            writer.handleReference(.hardOwnership, paper.handle)
            try registerObject(records)
            try writeEntries(records)
        }

        private func writeBlockEnd(_ end: BlockEnd) throws {
            try writeCommonEntityData(end)
            try registerObject(end)
        }

        private func writeBlockEntities() throws {
            for record in document.blockRecords {
                try writeBlockBegin(record.blockEntity)
                prev = nil
                next = nil
                guard let arr = blockCompatibleEntities[ObjectIdentifier(record)] else { throw DwgError.keyNotFound(record.name) }
                for i in arr.indices {
                    prev = i > 0 ? arr[i - 1] : nil
                    let e = arr[i]
                    next = i + 1 < arr.count ? arr[i + 1] : nil
                    try writeEntity(e)
                }
                prev = nil
                next = nil
                try writeBlockEnd(record.blockEnd)
            }
        }

        private func writeBlockHeader(_ record: BlockRecord) throws -> [Entity] {
            let entities = try compatibleEntities(record.entities)
            try writeCommonNonEntityData(record)
            let flags = record.blockFlags
            if flags & BlockTypeFlags.anonymous != 0 {
                // Anonymous blocks only write *{type character} (`Substring(0, 2)`).
                let units = Array(record.name.utf16)
                guard units.count >= 2 else { throw DwgError("startIndex cannot be larger than length of string. (Parameter 'startIndex')") }
                writer.writeVariableText(String(utf16CodeUnits: Array(units[0..<2]), count: 2))
            } else if record.layout != nil {
                writer.writeVariableText(String(String.UnicodeScalarView(record.name.unicodeScalars.filter {
                    $0.properties.generalCategory != .decimalNumber
                })))
            } else {
                writer.writeVariableText(record.name)
            }
            writeXrefDependantBit(record)
            writer.writeBit(flags & BlockTypeFlags.anonymous != 0)
            writer.writeBit(record.hasAttributes)
            writer.writeBit(flags & BlockTypeFlags.xRef != 0)
            writer.writeBit(flags & BlockTypeFlags.xRefOverlay != 0)
            // R2000+: Loaded Bit
            writer.writeBit(record.blockEntity.isUnloaded)
            // R2004+: Owned Object Count
            if flags & BlockTypeFlags.xRef == 0 && flags & BlockTypeFlags.xRefOverlay == 0 {
                writer.writeBitLong(Int32(entities.count))
            }
            writer.write3BitDouble(record.blockEntity.basePoint)
            writer.writeVariableText(record.blockEntity.xRefPath)
            // R2000+: one non-zero RC per insert, a 0 terminator
            let inserts = insertsByBlockName(record.name)
            for _ in inserts { writer.writeByte(1) }
            writer.writeByte(0)
            writer.writeVariableText(record.blockEntity.comments)
            // Size of preview data
            writer.writeBitLong(0)
            // R2007+
            writer.writeBitShort(record.units)
            writer.writeBit(record.isExplodable)
            writer.writeByte(record.canScale ? 1 : 0)
            // NULL (hard pointer)
            writer.handleReference(.hardPointer, 0)
            // BLOCK entity (hard owner)
            writer.handleReference(.hardOwnership, record.blockEntity.handle)
            // R2004+: H[ENTITY (hard owner)]
            for item in entities { writer.handleReference(.hardOwnership, item.handle) }
            // ENDBLK entity (hard owner)
            writer.handleReference(.hardOwnership, record.blockEnd.handle)
            // R2000+: insert handles, layout handle
            for item in inserts { writer.handleReference(.softPointer, item.handle) }
            writer.handleReference(.hardPointer, record.layout?.handle ?? 0)
            try registerObject(record)
            return entities
        }

        private func writeBlockRecord(_ record: BlockRecord) throws {
            let entities = try writeBlockHeader(record)
            let key = ObjectIdentifier(record)
            guard blockCompatibleEntities[key] == nil else { throw DwgError.duplicateKey(record.name) }
            blockCompatibleEntities[key] = entities
        }

        private func writeDimensionStyle(_ d: DimensionStyle) throws {
            try writeCommonNonEntityData(d)
            writer.writeVariableText(d.name)
            writeXrefDependantBit(d)
            // R2000+
            writer.writeVariableText(d.postFix)
            writer.writeVariableText(d.alternateDimensioningSuffix)
            writer.writeBitDouble(d.scaleFactor)
            writer.writeBitDouble(d.arrowSize)
            writer.writeBitDouble(d.extensionLineOffset)
            writer.writeBitDouble(d.dimensionLineIncrement)
            writer.writeBitDouble(d.extensionLineExtension)
            writer.writeBitDouble(d.rounding)
            writer.writeBitDouble(d.dimensionLineExtension)
            writer.writeBitDouble(d.plusTolerance)
            writer.writeBitDouble(d.minusTolerance)
            // R2007+
            writer.writeBitDouble(d.fixedExtensionLineLength)
            writer.writeBitDouble(d.joggedRadiusDimensionTransverseSegmentAngle)
            writer.writeBitShort(d.textBackgroundFillMode)
            writer.writeCmColor(d.textBackgroundColor)
            // R2000+
            writer.writeBit(d.generateTolerances)
            writer.writeBit(d.limitsGeneration)
            writer.writeBit(d.textInsideHorizontal)
            writer.writeBit(d.textOutsideHorizontal)
            writer.writeBit(d.suppressFirstExtensionLine)
            writer.writeBit(d.suppressSecondExtensionLine)
            writer.writeBitShort(Int16(truncatingIfNeeded: d.textVerticalAlignment))
            writer.writeBitShort(Int16(d.zeroHandling))
            writer.writeBitShort(Int16(d.angularZeroHandling))
            // R2007+
            writer.writeBitShort(d.arcLengthSymbolPosition)
            // R2000+
            writer.writeBitDouble(d.textHeight)
            writer.writeBitDouble(d.centerMarkSize)
            writer.writeBitDouble(d.tickSize)
            writer.writeBitDouble(d.alternateUnitScaleFactor)
            writer.writeBitDouble(d.linearScaleFactor)
            writer.writeBitDouble(d.textVerticalPosition)
            writer.writeBitDouble(d.toleranceScaleFactor)
            writer.writeBitDouble(d.dimensionLineGap)
            writer.writeBitDouble(d.alternateUnitRounding)
            writer.writeBit(d.alternateUnitDimensioning)
            writer.writeBitShort(d.alternateUnitDecimalPlaces)
            writer.writeBit(d.textOutsideExtensions)
            writer.writeBit(d.separateArrowBlocks)
            writer.writeBit(d.textInsideExtensions)
            writer.writeBit(d.suppressOutsideExtensions)
            writer.writeCmColor(d.dimensionLineColor)
            writer.writeCmColor(d.extensionLineColor)
            writer.writeCmColor(d.textColor)
            writer.writeBitShort(d.angularDecimalPlaces)
            writer.writeBitShort(d.decimalPlaces)
            writer.writeBitShort(d.toleranceDecimalPlaces)
            writer.writeBitShort(d.alternateUnitFormat)
            writer.writeBitShort(d.alternateUnitToleranceDecimalPlaces)
            writer.writeBitShort(d.angularUnit)
            writer.writeBitShort(d.fractionFormat)
            writer.writeBitShort(d.linearUnitFormat)
            writer.writeBitShort(Int16(bitPattern: d.decimalSeparator))
            writer.writeBitShort(d.textMovement)
            writer.writeBitShort(Int16(d.textHorizontalAlignment))
            writer.writeBit(d.suppressFirstDimensionLine)
            writer.writeBit(d.suppressSecondDimensionLine)
            writer.writeBitShort(Int16(d.toleranceAlignment))
            writer.writeBitShort(Int16(d.toleranceZeroHandling))
            writer.writeBitShort(Int16(d.alternateUnitZeroHandling))
            writer.writeBitShort(Int16(d.alternateUnitToleranceZeroHandling))
            writer.writeBit(d.cursorUpdate)
            writer.writeBitShort(3)
            // R2007+
            writer.writeBit(d.isExtensionLineLengthFixed)
            // R2010+
            writer.writeBit(d.textDirection == 1) // TextDirection.RightToLeft
            writer.writeBitDouble(d.altMzf)
            writer.writeVariableText(d.altMzs)
            writer.writeBitDouble(d.mzf)
            writer.writeVariableText(d.mzs)
            // R2000+
            writer.writeBitShort(d.dimensionLineWeight.rawValue)
            writer.writeBitShort(d.extensionLineWeight.rawValue)
            // Common: Unknown B
            writer.writeBit(false)
            // External reference block handle (hard pointer)
            writer.handleReference(.hardPointer, 0)
            // 340 shapefile (DIMTXSTY) (hard pointer)
            writer.handleReference(.hardPointer, d.style.handle)
            // R2000+
            writer.handleReference(.hardPointer, d.leaderArrow?.handle ?? 0)
            writer.handleReference(.hardPointer, d.arrowBlock?.handle ?? 0)
            writer.handleReference(.hardPointer, d.dimArrow1?.handle ?? 0)
            writer.handleReference(.hardPointer, d.dimArrow2?.handle ?? 0)
            // R2007+
            writer.handleReference(.hardPointer, d.lineType?.handle ?? 0)
            writer.handleReference(.hardPointer, d.lineTypeExt1?.handle ?? 0)
            writer.handleReference(.hardPointer, d.lineTypeExt2?.handle ?? 0)
            try registerObject(d)
        }

        private func writeLayer(_ layer: Layer) throws {
            try writeCommonNonEntityData(layer)
            writer.writeVariableText(layer.name)
            writeXrefDependantBit(layer)
            // R2000+: flags with the line weight index in bits 5..9
            var values = Int16(truncatingIfNeeded: Int(layer.lineWeight.dwgIndex) << 5)
            if layer.flags & LayerFlags.frozen != 0 { values |= 0b1 }
            if !layer.isOn { values |= 0b10 }
            if layer.flags & LayerFlags.frozen != 0 { values |= 0b100 }
            if layer.flags & LayerFlags.locked != 0 { values |= 0b1000 }
            if layer.plotFlag { values |= 0b1_0000 }
            writer.writeBitShort(values)
            writer.writeCmColor(layer.color)
            // External reference block handle (hard pointer)
            writer.handleReference(.hardPointer, 0)
            // R2000+: Plotstyle (hard pointer)
            writer.handleReference(.hardPointer, 0)
            // R2007+: Material
            writer.handleReference(.hardPointer, 0)
            // Common: Linetype (hard pointer)
            writer.handleReference(.hardPointer, layer.lineType.handle)
            // R2013+: Unknown handle
            writer.handleReference(.hardPointer, 0)
            try registerObject(layer)
        }

        private func writeLineType(_ ltype: LineType) throws {
            try writeCommonNonEntityData(ltype)
            writer.writeVariableText(ltype.name)
            writeXrefDependantBit(ltype)
            writer.writeVariableText(ltype.description)
            writer.writeBitDouble(ltype.patternLength)
            writer.writeByte(UInt8(truncatingIfNeeded: ltype.alignment.utf16.first ?? 0))
            writer.writeByte(UInt8(truncatingIfNeeded: ltype.segments.count))
            let hasTextSegments = ltype.segments.contains { $0.flags & LineTypeShapeFlags.text != 0 }
            // R2007+: UTF-16 text area of 512 bytes when there are text segments.
            var textArea: [UInt8]? = hasTextSegments ? [UInt8](repeating: 0, count: 512) : nil
            var textCursor = 0
            let terminator: [UInt8] = [0, 0]
            for segment in ltype.segments {
                if segment.flags & LineTypeShapeFlags.text != 0 {
                    if textArea == nil || segment.text.isEmpty {
                        segment.shapeNumber = 0
                    } else {
                        let textBytes = segment.text.utf16.flatMap { DwgLE.bytes($0) }
                        let required = textBytes.count + terminator.count
                        if textCursor + required <= textArea!.count {
                            segment.shapeNumber = Int16(truncatingIfNeeded: textCursor)
                            textArea!.replaceSubrange(textCursor..<(textCursor + textBytes.count), with: textBytes)
                            textCursor += textBytes.count
                            textArea!.replaceSubrange(textCursor..<(textCursor + terminator.count), with: terminator)
                            textCursor += terminator.count
                        } else {
                            segment.shapeNumber = 0
                        }
                    }
                }
                writer.writeBitDouble(segment.length)
                writer.writeBitShort(segment.shapeNumber)
                writer.writeRawDouble(segment.offset.x)
                writer.writeRawDouble(segment.offset.y)
                writer.writeBitDouble(segment.scale)
                writer.writeBitDouble(segment.rotation)
                writer.writeBitShort(segment.flags)
            }
            if hasTextSegments {
                for b in textArea! { writer.writeByte(b) }
            }
            // External reference block handle (hard pointer)
            writer.handleReference(.hardPointer, 0)
            for segment in ltype.segments { writer.handleReference(.hardPointer, segment.style?.handle ?? 0) }
            try registerObject(ltype)
        }

        private func writeLTypeControlObject() throws {
            let types = document.lineTypes!
            try writeCommonNonEntityData(types)
            writer.writeBitLong(Int32(types.count - 2))
            for item in types {
                if item.name.caseInsensitiveCompare(LineType.byBlockName) == .orderedSame
                    || item.name.caseInsensitiveCompare(LineType.byLayerName) == .orderedSame { continue }
                writer.handleReference(.softOwnership, item.handle)
            }
            guard let byBlock = types[LineType.byBlockName] else { throw DwgError.keyNotFound(LineType.byBlockName) }
            guard let byLayer = types[LineType.byLayerName] else { throw DwgError.keyNotFound(LineType.byLayerName) }
            writer.handleReference(.hardOwnership, byBlock.handle)
            writer.handleReference(.hardOwnership, byLayer.handle)
            try registerObject(types)
            try writeEntries(types)
        }

        private func writeTextStyle(_ style: TextStyle) throws {
            try writeCommonNonEntityData(style)
            writer.writeVariableText(style.isShapeFile ? "" : style.name)
            writeXrefDependantBit(style)
            writer.writeBit(style.flags & 1 != 0) // StyleFlags.IsShape
            writer.writeBit(style.flags & 4 != 0) // StyleFlags.VerticalText
            writer.writeBitDouble(style.height)
            writer.writeBitDouble(style.width)
            writer.writeBitDouble(style.obliqueAngle)
            writer.writeByte(UInt8(truncatingIfNeeded: style.mirrorFlag))
            writer.writeBitDouble(style.lastHeight)
            writer.writeVariableText(style.filename)
            writer.writeVariableText(style.bigFontFilename)
            writer.handleReference(.hardPointer, document.textStyles.handle)
            try registerObject(style)
        }

        private func writeUCS(_ ucs: UCS) throws {
            try writeCommonNonEntityData(ucs)
            writer.writeVariableText(ucs.name)
            writeXrefDependantBit(ucs)
            writer.write3BitDouble(ucs.origin)
            writer.write3BitDouble(ucs.xAxis)
            writer.write3BitDouble(ucs.yAxis)
            // R2000+
            writer.writeBitDouble(ucs.elevation)
            writer.writeBitShort(ucs.orthographicViewType)
            writer.writeBitShort(ucs.orthographicType)
            writer.handleReference(.softPointer, document.ucss.handle)
            // R2000+: Base UCS, Named UCS
            writer.handleReference(.hardPointer, 0)
            writer.handleReference(.hardPointer, 0)
            try registerObject(ucs)
        }

        private func writeView(_ view: View) throws {
            try writeCommonNonEntityData(view)
            writer.writeVariableText(view.name)
            writeXrefDependantBit(view)
            writer.writeBitDouble(view.height)
            writer.writeBitDouble(view.width)
            writer.write2RawDouble(view.center)
            writer.write3BitDouble(view.target)
            writer.write3BitDouble(view.direction)
            writer.writeBitDouble(view.angle)
            writer.writeBitDouble(view.lensLength)
            writer.writeBitDouble(view.frontClipping)
            writer.writeBitDouble(view.backClipping)
            writer.writeBit(view.viewMode & 1 != 0)
            writer.writeBit(view.viewMode & 2 != 0)
            writer.writeBit(view.viewMode & 4 != 0)
            writer.writeBit(view.viewMode & 16 != 0)
            // R2000+
            writer.writeByte(view.renderMode)
            // R2007+
            writer.writeBit(true)
            writer.writeByte(1)
            writer.writeBitDouble(0.0)
            writer.writeBitDouble(0.0)
            writer.writeCmColor(Color(index: 250))
            // Common: pspace flag
            writer.writeBit(view.flags & 1 != 0)
            // R2000+
            writer.writeBit(view.isUcsAssociated)
            if view.isUcsAssociated {
                writer.write3BitDouble(view.ucsOrigin)
                writer.write3BitDouble(view.ucsXAxis)
                writer.write3BitDouble(view.ucsYAxis)
                writer.writeBitDouble(view.ucsElevation)
                writer.writeBitShort(view.ucsOrthographicType)
            }
            writer.handleReference(.softPointer, document.views.handle)
            // R2007+
            writer.writeBit(view.isPlottable)
            writer.handleReference(.softPointer, 0)
            writer.handleReference(.hardPointer, 0)
            writer.handleReference(.hardOwnership, 0)
            // R2000+
            if view.isUcsAssociated {
                writer.handleReference(.hardPointer, 0)
                writer.handleReference(.hardPointer, 0)
            }
            // R2007+
            writer.handleReference(.softPointer, 0)
            try registerObject(view)
        }

        private func writeVPort(_ vport: VPort) throws {
            try writeCommonNonEntityData(vport)
            writer.writeVariableText(vport.name)
            writeXrefDependantBit(vport)
            writer.writeBitDouble(vport.viewHeight)
            writer.writeBitDouble(vport.aspectRatio * vport.viewHeight)
            writer.write2RawDouble(vport.center)
            writer.write3BitDouble(vport.target)
            writer.write3BitDouble(vport.direction)
            writer.writeBitDouble(vport.twistAngle)
            writer.writeBitDouble(vport.lensLength)
            writer.writeBitDouble(vport.frontClippingPlane)
            writer.writeBitDouble(vport.backClippingPlane)
            writer.writeBit(vport.viewMode & 1 != 0)
            writer.writeBit(vport.viewMode & 2 != 0)
            writer.writeBit(vport.viewMode & 4 != 0)
            writer.writeBit(vport.viewMode & 16 != 0)
            // R2000+
            writer.writeByte(vport.renderMode)
            // R2007+
            writer.writeBit(vport.useDefaultLighting)
            writer.writeByte(vport.defaultLighting)
            writer.writeBitDouble(vport.brightness)
            writer.writeBitDouble(vport.contrast)
            writer.writeCmColor(vport.ambientColor)
            writer.write2RawDouble(vport.bottomLeft)
            writer.write2RawDouble(vport.topRight)
            writer.writeBit(vport.viewMode & 8 != 0)
            writer.writeBitShort(vport.circleZoomPercent)
            writer.writeBit(true)
            // `UscIconType` is not a flags enum: HasFlag(OnLower = 1), HasFlag(OnOrigin = 3).
            writer.writeBit(vport.ucsIconDisplay & 1 == 1)
            writer.writeBit(vport.ucsIconDisplay & 3 == 3)
            writer.writeBit(vport.showGrid)
            writer.write2RawDouble(vport.gridSpacing)
            writer.writeBit(vport.snapOn)
            writer.writeBit(vport.isometricSnap)
            writer.writeBitShort(vport.snapIsoPair)
            writer.writeBitDouble(vport.snapRotation)
            writer.write2RawDouble(vport.snapBasePoint)
            writer.write2RawDouble(vport.snapSpacing)
            // R2000+
            writer.writeBit(false)
            writer.writeBit(true)
            writer.write3BitDouble(vport.origin)
            writer.write3BitDouble(vport.xAxis)
            writer.write3BitDouble(vport.yAxis)
            writer.writeBitDouble(vport.elevation)
            writer.writeBitShort(vport.orthographicType)
            // R2007+
            writer.writeBitShort(vport.gridFlags)
            writer.writeBitShort(vport.minorGridLinesPerMajorGridLine)
            // External reference block handle (hard pointer)
            writer.handleReference(.hardPointer, 0)
            // R2007+
            writer.handleReference(.softPointer, 0)
            writer.handleReference(.hardPointer, 0)
            writer.handleReference(.hardOwnership, 0)
            // R2000+
            if vport.orthographicType == 0 {
                writer.handleReference(.hardPointer, vport.namedUcs?.handle ?? 0)
                writer.handleReference(.hardPointer, 0)
            } else {
                writer.handleReference(.hardPointer, 0)
                writer.handleReference(.hardPointer, vport.baseUcs?.handle ?? 0)
            }
            try registerObject(vport)
        }
    }
}
