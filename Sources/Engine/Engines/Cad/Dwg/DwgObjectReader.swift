// ACadSharp 3.8.0 `DwgObjectReader`: the AcDbObjects section. Starting from the header handles, every object is
// read from its offset in the handle map and every handle it refers to is queued, until the queue is empty.
// This file holds the reading loop, the common object/entity data and the type dispatch; the readers of the
// single types live in the DwgObjectReader+*.swift files.

import Foundation

extension ACad {
    final class DwgObjectReader: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.acDbObjects }

        let classes: [Int16: DxfClass]
        /// Stream decoded using the crc.
        private let crcReader: DwgStreamReader
        private let map: [UInt64: Int64]
        private let memoryStream: DwgStream
        private(set) var readedObjects: [UInt64: Int16] = [:]
        private let reader: DwgStreamReader
        let builder: DwgDocumentBuilder
        /// During the object reading the handles will be added at the queue.
        private var handles: [UInt64]
        private var handlesHead = 0
        /// Reader focused on the handles section of the stream.
        var handlesReader: DwgBitReader!
        /// Has DS binary data flag of the object being read (R2013+), consumed by the modeler geometry reader.
        var hasDsBinaryData = false
        var mergedReaders: DwgBitReader!
        var objectInitialPos = 0
        /// Reader to handle the object data.
        var objectReader: DwgStreamReader!
        var size: UInt32 = 0
        /// Reader focused on the string data section of the stream.
        var textReader: DwgBitReader!

        init(_ version: Version, _ builder: DwgDocumentBuilder, _ reader: DwgStreamReader, _ handles: [UInt64],
             _ handleMap: [UInt64: Int64], _ classes: DxfClassCollection) throws {
            self.builder = builder
            self.reader = reader
            self.handles = handles
            map = handleMap
            var byNumber: [Int16: DxfClass] = [:]
            for item in classes {
                // `ToDictionary` throws on a repeated class number.
                guard byNumber[item.classNumber] == nil else { throw DwgError.duplicateKey(item.classNumber) }
                byNumber[item.classNumber] = item
            }
            self.classes = byNumber
            memoryStream = reader.stream
            crcReader = try DwgStreamReader(version, memoryStream)
            super.init(version)
        }

        /// Read all the entities, tables and objects in the file.
        func read() throws {
            while handlesHead < handles.count {
                let handle = handles[handlesHead]
                handlesHead += 1
                if handlesHead > 4096 && handlesHead * 2 > handles.count {
                    handles.removeFirst(handlesHead)
                    handlesHead = 0
                }

                guard let offset = map[handle], builder.objectTemplate(handle) as CadTemplate? == nil,
                      readedObjects[handle] == nil else { continue }

                // Outside the try block of the C# loop: its errors abort the reading.
                let type = try getEntityType(offset)
                readedObjects[handle] = type
                let template: CadTemplate?
                do {
                    template = try readObject(type)
                } catch {
                    // Failsafe (Filee always reads failsafe).
                    if let dxf = classes[type] {
                        builder.notify("Could not read \(dxf.dxfName) number \(dxf.classNumber) with handle: \(handle)")
                    } else {
                        builder.notify("Could not read \(Self.typeName(type)) with handle: \(handle)")
                    }
                    continue
                }
                guard let template else { continue }
                builder.addTemplate(template)
            }
        }

        /// The C# enum name of an object type (`ObjectType.ToString()`), the number for values outside the enum.
        static func typeName(_ type: Int16) -> String {
            guard let value = ObjectType(rawValue: type) else { return String(type) }
            return value.dotNetName
        }

        private func getEntityType(_ offset: Int64) throws -> Int16 {
            var type = ObjectType.invalid.rawValue
            try crcReader.setPosition(Int(offset))
            // MS : Size of object, not including the CRC
            size = UInt32(bitPattern: try crcReader.readModularShort())
            if size <= 0 { return type }
            // remove the padding bits make sure the object stream ends on a byte boundary
            let sizeInBits = UInt32(truncatingIfNeeded: UInt64(size) << 3)

            if r2010Plus {
                // MC : Size in bits of the handle stream (unsigned, 0x40 is not interpreted as sign).
                let handleSize = try crcReader.readModularChar()
                let handleSectionOffset = UInt64(crcReader.positionInBits()) &+ UInt64(sizeInBits) &- handleSize

                objectReader = try DwgStreamReader(version, memoryStream.clone(), encoding: reader.encoding)
                try objectReader.setPositionInBits(crcReader.positionInBits())
                objectInitialPos = objectReader.positionInBits()
                type = try objectReader.readObjectType()

                let handlesStream = try DwgStreamReader(version, memoryStream.clone(), encoding: reader.encoding)
                try handlesStream.setPositionInBits(Int(Int64(bitPattern: handleSectionOffset)))
                handlesReader = handlesStream

                let textStream = try DwgStreamReader(version, memoryStream.clone(), encoding: reader.encoding)
                _ = try textStream.setPositionByFlag(Int(Int64(bitPattern: handleSectionOffset)) - 1)
                textReader = textStream

                mergedReaders = DwgMergedReader(objectReader, textReader, handlesReader)
            } else {
                objectReader = try DwgStreamReader(version, memoryStream.clone(), encoding: reader.encoding)
                try objectReader.setPositionInBits(crcReader.positionInBits())
                handlesReader = try DwgStreamReader(version, memoryStream.clone(), encoding: reader.encoding)
                textReader = objectReader
                objectInitialPos = objectReader.positionInBits()
                type = try objectReader.readObjectType()
            }
            return type
        }

        /// Get the handle of the entity and saves the value to the handles queue.
        func handleReference(_ handle: UInt64 = 0) throws -> UInt64 {
            let value = try handlesReader.handleReference(handle)
            if value != 0 && builder.objectTemplate(value) as CadTemplate? == nil && readedObjects[value] == nil {
                handles.append(value)
            }
            return value
        }

        func readCommonData(_ template: CadTemplate) throws {
            if version >= .ac1015 && version < .ac1024 {
                // Obj size RL size of object in bits, not including end handles
                try updateHandleReader()
            }
            // Handle H 5 code 0, length followed by the handle bytes.
            template.cadObject.handle = try objectReader.handleReference(0)
            // Extended object data, if any
            try readExtendedData(template)
        }

        /// Read the common entity format.
        func readCommonEntityData(_ template: CadEntityTemplate) throws {
            try readCommonData(template)
            // Graphic present Flag B 1 if a graphic is present
            if try objectReader.readBit() {
                // R13 - R007: RL, R2010+: BLL: Size of graphic image in bytes
                let graphicImageSize = version >= .ac1024 ? try objectReader.readBitLongLong() : try objectReader.readRawLong()
                // X: The graphic image (ProxyGraphics, unused by Filee)
                _ = try objectReader.readBytes(Int(Int32(truncatingIfNeeded: graphicImageSize)))
            }
            // R13 - R14 Only:
            if version >= .ac1012 && version <= .ac1014 {
                try updateHandleReader()
            }
            try readEntityMode(template)
        }

        func readCommonNonEntityData(_ template: CadTemplate) throws {
            try readCommonData(template)
            // R13-R14 Only: Obj size RL size of object in bits, not including end handles
            if r13_14Only { try updateHandleReader() }
            // [Owner ref handle (soft pointer)]
            template.ownerHandle = try handleReference(template.cadObject.handle)
            // Read the cad object reactors
            try readReactorsAndDictionaryHandle(template)
        }

        private func readEntityMode(_ template: CadEntityTemplate) throws {
            let entity = template.entity
            // Entmode BB entity mode
            template.entityMode = try objectReader.read2Bits()
            // 00 : The owner relative handle reference is present.
            // 01 : PSPACE entity without a owner relative handle ref.
            // 10 : MSPACE entity without a owner relative handle ref.
            if template.entityMode == 0 {
                template.ownerHandle = try handlesReader.handleReference(entity.handle)
            } else if template.entityMode == 1 {
                builder.paperSpaceEntities.append(entity)
            } else if template.entityMode == 2 {
                builder.modelSpaceEntities.append(entity)
            }

            // Numreactors BL number of persistent reactors attached to this object
            try readReactorsAndDictionaryHandle(template)

            // R13-R14 Only:
            if r13_14Only {
                // 8 LAYER (hard pointer)
                template.layerHandle = try handleReference()
                // Isbylayerlt B 1 if bylayer linetype, else 0
                if !(try objectReader.readBit()) {
                    // 6 [LTYPE (hard pointer)] (present if Isbylayerlt is 0)
                    template.lineTypeHandle = try handleReference()
                }
            }

            // R13-R2000 Only: previous/next handles present if Nolinks is 0.
            if !r2004Plus, !(try objectReader.readBit()) {
                template.prevEntity = try handleReference(entity.handle)
                template.nextEntity = try handleReference(entity.handle)
            } else if !r2004Plus {
                if readedObjects[entity.handle &- 1] == nil { handles.append(entity.handle &- 1) }
                if readedObjects[entity.handle &+ 1] == nil { handles.append(entity.handle &+ 1) }
            }

            // Color CMC(B) 62
            var transparency = Transparency.byLayer
            var colorFlag = false
            entity.color = try objectReader.readEnColor(&transparency, &colorFlag)
            entity.transparency = transparency

            // R2004+: [Color book color handle (hard pointer)]
            if version >= .ac1018 && colorFlag {
                template.colorHandle = try handleReference()
            }

            // Ltype scale BD 48
            entity.lineTypeScale = try objectReader.readBitDouble()

            guard version >= .ac1015 else {
                // Invisibility BS 60
                entity.isInvisible = (try objectReader.readBitShort() & 1) == 1
                return
            }

            // R2000+: 8 LAYER (hard pointer)
            template.layerHandle = try handleReference()
            // Ltype flags BB 00 = bylayer, 01 = byblock, 10 = continous, 11 = linetype handle present at end of object
            template.ltypeFlags = try objectReader.read2Bits()
            if template.ltypeFlags == 3 {
                template.lineTypeHandle = try handleReference()
            }

            // R2007+:
            if r2007Plus {
                // Material flags BB 00 = bylayer, 01 = byblock, 11 = material handle present at end of object
                if try objectReader.read2Bits() == 3 {
                    template.materialHandle = try handleReference()
                }
                // Shadow flags RC
                _ = try objectReader.readByte()
            }

            // R2000 +: Plotstyle flags BB, 11 = plotstyle handle present at end of object
            if try objectReader.read2Bits() == 3 {
                _ = try handleReference()
            }

            // R2010 +: full visual style, face visual style, edge visual style handles (hard pointers)
            if r2010Plus {
                if try objectReader.readBit() { _ = try handleReference() }
                if try objectReader.readBit() { _ = try handleReference() }
                if try objectReader.readBit() { _ = try handleReference() }
            }

            // Invisibility BS 60
            entity.isInvisible = (try objectReader.readBitShort() & 1) == 1
            // R2000+: Lineweight RC 370
            entity.lineWeight = LineWeight.fromIndex(try objectReader.readByte())
        }

        private func readExtendedData(_ template: CadTemplate) throws {
            // EED size BS size of extended entity data, if any
            var size = try objectReader.readBitShort()
            while size != 0 {
                // App handle
                let appHandle = try objectReader.handleReference(0)
                let endPos = objectReader.position + Int(size)
                let edata = try readExtendedDataRecords(endPos)
                // `Dictionary.Add`
                if template.edataByHandle.contains(where: { $0.0 == appHandle }) { throw DwgError.duplicateKey(appHandle) }
                template.edataByHandle.append((appHandle, edata))
                size = try objectReader.readBitShort()
            }
        }

        private func readExtendedDataRecords(_ endPos: Int) throws -> [XDataRecord] {
            var records: [XDataRecord] = []
            while objectReader.position < endPos {
                // Each data item has a 1-byte code (DXF group code minus 1000) followed by the value.
                let code = 1000 + Int(try objectReader.readByte())
                let record: XDataRecord
                switch code {
                case 1000, 1001:
                    record = .string(try objectReader.readTextUnicode())
                case 1002:
                    record = .controlString(isClosing: try objectReader.readByte() == 1)
                case 1003:
                    record = .layer(try objectReader.readBytes(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                case 1004:
                    record = .binaryChunk(Data(try objectReader.readBytes(Int(try objectReader.readByte()))))
                case 1005:
                    record = .handle(try objectReader.readBytes(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                case 1010:
                    record = .coordinate(XYZ(try objectReader.readDouble(), try objectReader.readDouble(), try objectReader.readDouble()))
                case 1011:
                    record = .worldCoordinate(XYZ(try objectReader.readDouble(), try objectReader.readDouble(), try objectReader.readDouble()))
                case 1012:
                    record = .displacement(XYZ(try objectReader.readDouble(), try objectReader.readDouble(), try objectReader.readDouble()))
                case 1013:
                    record = .direction(XYZ(try objectReader.readDouble(), try objectReader.readDouble(), try objectReader.readDouble()))
                case 1040:
                    record = .real(try objectReader.readDouble())
                case 1041:
                    record = .distance(try objectReader.readDouble())
                case 1042:
                    record = .scale(try objectReader.readDouble())
                case 1070:
                    record = .integer16(try objectReader.readShort())
                case 1071:
                    record = .integer32(Int32(truncatingIfNeeded: try objectReader.readRawLong()))
                default:
                    _ = try objectReader.readBytes(endPos - objectReader.position)
                    builder.notify("Unknown code for extended data: \(Self.xdataCodeName(code))")
                    return records
                }
                records.append(record)
            }
            return records
        }

        /// `DxfCode.ToString()` for the codes the switch above does not handle.
        static func xdataCodeName(_ code: Int) -> String {
            let names = [1020: "ExtendedDataYCoordinate", 1030: "ExtendedDataZCoordinate", 1021: "ExtendedDataWorldYCoordinate",
                         1031: "ExtendedDataWorldZCoordinate", 1022: "ExtendedDataWorldYDisp", 1032: "ExtendedDataWorldZDisp",
                         1023: "ExtendedDataWorldYDir", 1033: "ExtendedDataWorldZDir"]
            return names[code] ?? String(code)
        }

        /// Add the reactors to the template.
        func readReactorsAndDictionaryHandle(_ template: CadTemplate) throws {
            // Numreactors S number of reactors in this object
            let numberOfReactors = try objectReader.readBitLong()
            if numberOfReactors > 0 {
                for _ in 0..<numberOfReactors {
                    template.reactorsHandles.insert(try handleReference())
                }
            }
            var flag = false
            // R2004+: XDic Missing Flag B, If 1, no XDictionary handle is stored for this object.
            if r2004Plus { flag = try objectReader.readBit() }
            if !flag {
                // xdicobjhandle(hard owner)
                template.xdictHandle = try handleReference()
            }
            // R2013+: Has DS binary data B
            if r2013Plus {
                hasDsBinaryData = try objectReader.readBit()
            }
        }

        func readXrefDependantBit(_ entry: TableEntry) throws {
            if r2007Plus {
                // xrefindex+1 BS 70
                let xrefindex = try objectReader.readBitShort()
                // Xdep B 70 dependent on an xref. (16 bit)
                if UInt32(bitPattern: Int32(xrefindex)) & 0b1_0000_0000 > 0 {
                    entry.flags |= 16 // StandardFlags.XrefDependent
                }
            } else {
                // 64-flag B 70 The 64-bit of the 70 group.
                if try objectReader.readBit() {
                    entry.flags |= 64 // StandardFlags.Referenced
                }
                // xrefindex + 1 BS 70
                _ = try objectReader.readBitShort()
                // Xdep B 70 dependent on an xref. (16 bit)
                if try objectReader.readBit() {
                    entry.flags |= 16 // StandardFlags.XrefDependent
                }
            }
        }

        /// Update the text reader and the handler reader at the end of the object position.
        func updateHandleReader() throws {
            // RL: Size of object data in bits (number of bits before the handles)
            let size = try objectReader.readRawLong()
            try handlesReader.setPositionInBits(Int(size) + objectInitialPos)
            if version == .ac1021 {
                let text = try DwgStreamReader(version, memoryStream.clone(), encoding: reader.encoding)
                // "endbit" of the pre-handles section.
                _ = try text.setPositionByFlag(Int(size) + objectInitialPos - 1)
                textReader = text
            }
            mergedReaders = DwgMergedReader(objectReader, textReader, handlesReader)
        }

        static func looksLikeUtf16Le(_ buffer: [UInt8], _ offset: Int) -> Bool {
            guard offset >= 0, offset + 1 < buffer.count else { return false }
            var sawNonZero = false
            var i = offset
            while i + 1 < buffer.count {
                let lo = buffer[i], hi = buffer[i + 1]
                if lo == 0 && hi == 0 { return sawNonZero }
                if hi != 0 { return false }
                if lo != 0 { sawNonZero = true }
                i += 2
            }
            return false
        }

        // ───────────────────────── Dispatch ─────────────────────────

        private func readObject(_ rawType: Int16) throws -> CadTemplate? {
            var template: CadTemplate?
            guard let type = ObjectType(rawValue: rawType) else { return try readUnlistedType(rawType) }
            switch type {
            case .text: template = try readText()
            case .attrib: template = try readAttribute()
            case .attdef: template = try readAttributeDefinition()
            case .block: template = try readBlock()
            case .endblk: template = try readEndBlock()
            case .seqend: template = try readSeqend()
            case .insert: template = try readInsert()
            case .minsert: template = try readMInsert()
            case .vertex2D: template = try readVertex2D()
            case .vertex3D: template = try readVertex3D(Vertex3D())
            case .vertexPface: template = try readVertex3D(VertexFaceMesh())
            case .vertexMesh: template = try readVertex3D(PolygonMeshVertex())
            case .vertexPfaceFace: template = try readPfaceVertex()
            case .polyline2D: template = try readPolyline2D()
            case .polyline3D: template = try readPolyline3D()
            case .arc: template = try readArc()
            case .circle: template = try readCircle()
            case .line: template = try readLine()
            case .dimensionOrdinate: template = try readDimOrdinate()
            case .dimensionLinear: template = try readDimLinear()
            case .dimensionAligned: template = try readDimAligned()
            case .dimensionAng3Pt: template = try readDimAngular3pt()
            case .dimensionAng2Ln: template = try readDimLine2pt()
            case .dimensionRadius: template = try readDimRadius()
            case .dimensionDiameter: template = try readDimDiameter()
            case .point: template = try readPoint()
            case .face3D: template = try read3dFace()
            case .polylinePface: template = try readPolyfaceMesh()
            case .polylineMesh: template = try readPolylineMesh()
            case .solid, .trace: template = try readSolid()
            case .shape: template = try readShape()
            case .viewport: template = try readViewport()
            case .ellipse: template = try readEllipse()
            case .spline: template = try readSpline()
            case .region: template = try readModelerGeometry(CadModelerGeometryTemplate(Region()))
            case .solid3D: template = try readSolid3D()
            case .body: template = try readModelerGeometry(CadModelerGeometryTemplate(CadBody()))
            case .ray: template = try readRay()
            case .xline: template = try readXLine()
            case .dictionary: template = try readDictionary()
            case .mtext: template = try readMText()
            case .leader: template = try readLeader()
            case .tolerance: template = try readTolerance()
            case .mline: template = try readMLine()
            case .blockControlObj:
                let t = try readBlockControlObject()
                builder.blockRecords = t.cadObject as! BlockRecordsTable
                template = t
            case .blockHeader: template = try readBlockHeader()
            case .layerControlObj:
                let t = try readDocumentTable(LayersTable())
                builder.layers = t.cadObject as! LayersTable
                template = t
            case .layer: template = try readLayer()
            case .styleControlObj:
                let t = try readDocumentTable(TextStylesTable())
                builder.textStyles = t.cadObject as! TextStylesTable
                template = t
            case .style: template = try readTextStyle()
            case .ltypeControlObj:
                let t = try readLTypeControlObject()
                builder.lineTypes = t.cadObject as! LineTypesTable
                template = t
            case .ltype: template = try readLType()
            case .viewControlObj:
                let t = try readDocumentTable(ViewsTable())
                builder.views = t.cadObject as! ViewsTable
                template = t
            case .view: template = try readView()
            case .ucsControlObj:
                let t = try readDocumentTable(UCSTable())
                builder.ucss = t.cadObject as! UCSTable
                template = t
            case .ucs: template = try readUcs()
            case .vportControlObj:
                let t = try readDocumentTable(VPortsTable())
                builder.vports = t.cadObject as! VPortsTable
                template = t
            case .vport: template = try readVPort()
            case .appidControlObj:
                let t = try readDocumentTable(AppIdsTable())
                builder.appIds = t.cadObject as! AppIdsTable
                template = t
            case .appid: template = try readAppId()
            case .dimstyleControlObj:
                let t = try readDocumentTable(DimensionStylesTable())
                builder.dimensionStyles = t.cadObject as! DimensionStylesTable
                template = t
            case .dimstyle: template = try readDimStyle()
            case .vpEntHdrCtrlObj: template = try readViewportEntityControl()
            case .vpEntHdr: template = try readViewportEntityHeader()
            case .group: template = try readGroup()
            case .mlinestyle: template = try readMLineStyle()
            case .lwpolyline: template = try readLWPolyline()
            case .hatch: template = try readHatch()
            case .xrecord: template = try readXRecord()
            case .acdbplaceholder: template = try readPlaceHolder()
            case .layout: template = try readLayout()
            case .acadProxyEntity: template = try readProxyEntity()
            case .acadProxyObject: template = try readProxyObject()
            case .ole2frame: template = try readOle2Frame()
            // Not implemented entities:
            case .oleframe, .dummy:
                let t = try readUnknownEntity(nil)
                builder.notify("Unlisted object with DXF name \(type.dotNetName) has been read as an UnknownEntity")
                return t
            // Not implemented objects:
            case .vbaProject, .longTransaction:
                let t = try readUnknownNonGraphicalObject(nil)
                builder.notify("Unlisted object with DXF name \(type.dotNetName) has been read as an UnknownNonGraphicalObject")
                return t
            // Unknown:
            case .undefined, .unknow3A, .unknow3B, .unknow36, .unknow37, .unknow9:
                break
            case .unlisted, .invalid:
                return try readUnlistedType(rawType)
            }
            if template == nil {
                builder.notify("Object type not implemented: \(type.dotNetName)")
            }
            return template
        }

        private func readUnlistedType(_ classNumber: Int16) throws -> CadTemplate? {
            guard let c = classes[classNumber] else {
                // "Class number … not found in classes dictionary." goes to an event nobody subscribes to.
                return nil
            }
            var template: CadTemplate?
            switch c.dxfName {
            case DxfFileToken.acmPartRef: template = try readAcmPartRef()
            case DxfFileToken.acmBalloon: template = try readAcmBalloon()
            case DxfFileToken.acmPartList: template = try readAcmPartList()
            case DxfFileToken.objectDynamicBlockPurgePreventer: template = try readDynamicBlockPurgePreventer()
            case DxfFileToken.entityAecWall: template = try readAecWall()
            case DxfFileToken.entityArcDimension: template = try readDimArc()
            case DxfFileToken.objectBinRecord: template = try readBinRecord()
            case DxfFileToken.objectAecWallStyle: template = try readAecWallStyle()
            case DxfFileToken.objectAecCleanupGroupDef: template = try readAecCleanupGroup()
            case "ACDBDICTIONARYWDFLT": template = try readDictionaryWithDefault()
            case "ACDBPLACEHOLDER": template = try readPlaceHolder()
            case "ACAD_TABLE": template = try readTableEntity()
            case DxfFileToken.objectDimensionAssociation: template = try readDimensionAssociation()
            case "DBCOLOR": template = try readDbColor()
            case "DICTIONARYVAR": template = try readDictionaryVar()
            case "DICTIONARYWDFLT": template = try readDictionaryWithDefault()
            case DxfFileToken.objectGeoData: template = try readGeoData()
            case "GROUP": template = try readGroup()
            case "HATCH": template = try readHatch()
            case "IMAGE": template = try readCadImage(RasterImage())
            case "IMAGEDEF": template = try readImageDefinition()
            case "IMAGEDEF_REACTOR": template = try readImageDefinitionReactor()
            case "LAYOUT": template = try readLayout()
            case "LWPLINE", "LWPOLYLINE": template = try readLWPolyline()
            case "MATERIAL": template = try readMaterial()
            case "MESH": template = try readMesh()
            case "MULTILEADER": template = try readMultiLeader()
            case "ACDB_MLEADEROBJECTCONTEXTDATA_CLASS": template = try readMultiLeaderAnnotContext()
            case "MLEADERSTYLE": template = try readMultiLeaderStyle()
            case "PDFDEFINITION": template = try readPdfDefinition()
            case "PDFUNDERLAY", "PDFREFERENCE": template = try readPdfUnderlay()
            case "SCALE": template = try readScale()
            case "SORTENTSTABLE": template = try readSortentsTable()
            case "RASTERVARIABLES": template = try readRasterVariables()
            case "WIPEOUT": template = try readCadImage(Wipeout())
            case "XRECORD": template = try readXRecord()
            case DxfFileToken.objectEvalGraph: template = try readEvaluationGraph()
            case DxfFileToken.objectBlockPolarParameter: template = try readBlockPolarParameter()
            case DxfFileToken.objectBlockLinearParameter: template = try readBlockLinearParameter()
            case DxfFileToken.objectBlockRotationParameter: template = try readBlockRotationParameter()
            case DxfFileToken.objectBlockVisibilityParameter: template = try readBlockVisibilityParameter()
            case DxfFileToken.objectBlockLookupParameter: template = try readBlockLookupParameter()
            case DxfFileToken.objectBlockFlipParameter: template = try readBlockFlipParameter()
            case DxfFileToken.objectBlockBasePointParameter: template = try readBlockBasePointParameter()
            case DxfFileToken.objectBlockPointParameter: template = try readBlockPointParameter()
            case DxfFileToken.objectBlockXYParameter: template = try readBlockXYParameter()
            case DxfFileToken.objectBlockAlignmentParameter: template = try readBlockAlignmentParameter()
            case DxfFileToken.objectBlockRepresentationData: template = try readBlockRepresentationData()
            case DxfFileToken.objectBlockGripLocationComponent: template = try readBlockGripLocationComponent()
            case DxfFileToken.objectBlockAlignmentGrip: template = try readAlignmentGrip()
            case DxfFileToken.objectBlockFlipGrip: template = try readFlipGrip()
            case DxfFileToken.objectBlockLinearGrip: template = try readLinearGrip()
            case DxfFileToken.objectBlockXYGrip: template = try readBlockGrip(BlockXYGrip())
            case DxfFileToken.objectBlockRotationGrip: template = try readBlockGrip(BlockRotationGrip())
            case DxfFileToken.objectBlockVisibilityGrip: template = try readBlockGrip(BlockVisibilityGrip())
            case DxfFileToken.objectBlockLookupGrip: template = try readBlockGrip(BlockLookupGrip())
            case DxfFileToken.objectBlockPolarGrip: template = try readBlockGrip(BlockPolarGrip())
            case DxfFileToken.objectBlockPolarStretchAction: template = try readBlockPolarStretchAction()
            case DxfFileToken.objectBlockFlipAction: template = try readBlockFlipAction()
            case DxfFileToken.objectBlockRotateAction: template = try readBlockRotateAction()
            case DxfFileToken.objectBlockScaleAction: template = try readBlockScaleAction()
            case DxfFileToken.objectBlockMoveAction: template = try readBlockMoveAction()
            case DxfFileToken.objectBlockLookupAction: template = try readBlockLookupAction()
            case DxfFileToken.objectBlockArrayAction: template = try readBlockArrayAction()
            case DxfFileToken.objectBlockStretchAction: template = try readBlockStretchAction()
            case DxfFileToken.objectSpatialFilter: template = try readSpatialFilter()
            case DxfFileToken.entityProxyEntity: template = try readProxyEntity()
            case DxfFileToken.objectProxyObject: template = try readProxyObject()
            case DxfFileToken.objectVisualStyle: template = try readVisualStyle()
            case DxfFileToken.objectPlotSettings: template = try readPlotSettings()
            case DxfFileToken.objectTableStyle: template = try readTableStyle()
            case DxfFileToken.blkRefObjectContextData: template = try readBlkRefObjectContextData()
            case DxfFileToken.mTextAttributeObjectContextData: template = try readMTextAttributeObjectContextData()
            case DxfFileToken.objectFieldList: template = try readFieldList()
            case DxfFileToken.objectField: template = try readField()
            case DxfFileToken.objectWipeoutVariables: template = try readWipeoutVariables()
            default: break
            }

            if template == nil && c.isAnEntity {
                template = try readUnknownEntity(c)
                builder.notify("Unlisted object with DXF name \(c.dxfName) has been read as an UnknownEntity")
            } else if template == nil && !c.isAnEntity {
                template = try readUnknownNonGraphicalObject(c)
                builder.notify("Unlisted object with DXF name \(c.dxfName) has been read as an UnknownNonGraphicalObject")
            }
            template?.dxfClass = c
            return template
        }

        func readUnknownEntity(_ dxfClass: DxfClass?) throws -> CadTemplate {
            let template = CadEntityTemplate(UnknownEntity(dxfClass: dxfClass))
            try readCommonEntityData(template)
            return template
        }

        func readUnknownNonGraphicalObject(_ dxfClass: DxfClass?) throws -> CadTemplate {
            let template = CadNonGraphicalObjectTemplate(UnknownNonGraphicalObject(dxfClass: dxfClass))
            try readCommonNonEntityData(template)
            return template
        }
    }
}

extension ACad.ObjectType {
    /// The C# enum member name (`ObjectType.ToString()`).
    var dotNetName: String {
        switch self {
        case .unlisted: return "UNLISTED"
        case .invalid: return "INVALID"
        case .undefined: return "UNDEFINED"
        case .text: return "TEXT"
        case .attrib: return "ATTRIB"
        case .attdef: return "ATTDEF"
        case .block: return "BLOCK"
        case .endblk: return "ENDBLK"
        case .seqend: return "SEQEND"
        case .insert: return "INSERT"
        case .minsert: return "MINSERT"
        case .unknow9: return "UNKNOW_9"
        case .vertex2D: return "VERTEX_2D"
        case .vertex3D: return "VERTEX_3D"
        case .vertexMesh: return "VERTEX_MESH"
        case .vertexPface: return "VERTEX_PFACE"
        case .vertexPfaceFace: return "VERTEX_PFACE_FACE"
        case .polyline2D: return "POLYLINE_2D"
        case .polyline3D: return "POLYLINE_3D"
        case .arc: return "ARC"
        case .circle: return "CIRCLE"
        case .line: return "LINE"
        case .dimensionOrdinate: return "DIMENSION_ORDINATE"
        case .dimensionLinear: return "DIMENSION_LINEAR"
        case .dimensionAligned: return "DIMENSION_ALIGNED"
        case .dimensionAng3Pt: return "DIMENSION_ANG_3_Pt"
        case .dimensionAng2Ln: return "DIMENSION_ANG_2_Ln"
        case .dimensionRadius: return "DIMENSION_RADIUS"
        case .dimensionDiameter: return "DIMENSION_DIAMETER"
        case .point: return "POINT"
        case .face3D: return "FACE3D"
        case .polylinePface: return "POLYLINE_PFACE"
        case .polylineMesh: return "POLYLINE_MESH"
        case .solid: return "SOLID"
        case .trace: return "TRACE"
        case .shape: return "SHAPE"
        case .viewport: return "VIEWPORT"
        case .ellipse: return "ELLIPSE"
        case .spline: return "SPLINE"
        case .region: return "REGION"
        case .solid3D: return "SOLID3D"
        case .body: return "BODY"
        case .ray: return "RAY"
        case .xline: return "XLINE"
        case .dictionary: return "DICTIONARY"
        case .oleframe: return "OLEFRAME"
        case .mtext: return "MTEXT"
        case .leader: return "LEADER"
        case .tolerance: return "TOLERANCE"
        case .mline: return "MLINE"
        case .blockControlObj: return "BLOCK_CONTROL_OBJ"
        case .blockHeader: return "BLOCK_HEADER"
        case .layerControlObj: return "LAYER_CONTROL_OBJ"
        case .layer: return "LAYER"
        case .styleControlObj: return "STYLE_CONTROL_OBJ"
        case .style: return "STYLE"
        case .unknow36: return "UNKNOW_36"
        case .unknow37: return "UNKNOW_37"
        case .ltypeControlObj: return "LTYPE_CONTROL_OBJ"
        case .ltype: return "LTYPE"
        case .unknow3A: return "UNKNOW_3A"
        case .unknow3B: return "UNKNOW_3B"
        case .viewControlObj: return "VIEW_CONTROL_OBJ"
        case .view: return "VIEW"
        case .ucsControlObj: return "UCS_CONTROL_OBJ"
        case .ucs: return "UCS"
        case .vportControlObj: return "VPORT_CONTROL_OBJ"
        case .vport: return "VPORT"
        case .appidControlObj: return "APPID_CONTROL_OBJ"
        case .appid: return "APPID"
        case .dimstyleControlObj: return "DIMSTYLE_CONTROL_OBJ"
        case .dimstyle: return "DIMSTYLE"
        case .vpEntHdrCtrlObj: return "VP_ENT_HDR_CTRL_OBJ"
        case .vpEntHdr: return "VP_ENT_HDR"
        case .group: return "GROUP"
        case .mlinestyle: return "MLINESTYLE"
        case .ole2frame: return "OLE2FRAME"
        case .dummy: return "DUMMY"
        case .longTransaction: return "LONG_TRANSACTION"
        case .lwpolyline: return "LWPOLYLINE"
        case .hatch: return "HATCH"
        case .xrecord: return "XRECORD"
        case .acdbplaceholder: return "ACDBPLACEHOLDER"
        case .vbaProject: return "VBA_PROJECT"
        case .layout: return "LAYOUT"
        case .acadProxyEntity: return "ACAD_PROXY_ENTITY"
        case .acadProxyObject: return "ACAD_PROXY_OBJECT"
        }
    }
}
