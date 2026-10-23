// DXF OBJECTS section (ACadSharp DxfObjectsSectionReader) for the object types the model keeps, and the ACDSDATA
// section (ACIS data of R2013+ solids). Dynamic block, AEC and evaluation objects are skipped like unknown objects.

import Foundation

extension ACad.DxfReader {
    func readObjectsSection() throws {
        if reader.valueAsString != ACad.DxfFileToken.objectsSection { _ = try reader.find(ACad.DxfFileToken.objectsSection) }
        try reader.readNext()
        while reader.valueAsString != ACad.DxfFileToken.endSection {
            var template: ACad.CadTemplate?
            do {
                template = try readObject()
            } catch let error where !(error is CancellationError) {
                builder.notify("Error while reading an object at line \(reader.position): \(error)")
                while reader.code != 0 { try reader.readNext() }
            }
            if let template { builder.addTemplate(template) }
        }
    }

    /// `readObjectCodes`.
    func readObjectCodes<T: ACad.CadTemplate>(_ template: T, _ read: () throws -> Bool) throws -> T {
        try reader.readNext()
        while reader.code != 0 {
            if try !read() {
                if try readCommonCodes(template) { continue }
            }
            if lockPointer {
                lockPointer = false
                continue
            }
            if reader.code != 0 { try reader.readNext() }
        }
        return template
    }

    private func readObject() throws -> ACad.CadTemplate? {
        currentSubclass = ""
        typealias T = ACad.DxfFileToken
        switch reader.valueAsString {
        case T.objectPlaceholder:
            let t = ACad.CadNonGraphicalObjectTemplate(ACad.AcdbPlaceHolder())
            return try readObjectCodes(t) { false }
        case T.objectDBColor:
            let color = ACad.BookColor()
            let t = ACad.CadNonGraphicalObjectTemplate(color)
            return try readObjectCodes(t) { try self.readBookColor(color) }
        case T.objectDictionary:
            let t = ACad.CadDictionaryTemplate(ACad.CadDictionary())
            return try readObjectCodes(t) { try self.readDictionary(t) }
        case T.objectDictionaryWithDefault:
            let t = ACad.CadDictionaryWithDefaultTemplate(ACad.CadDictionaryWithDefault())
            return try readObjectCodes(t) {
                if self.reader.code == 340 {
                    t.defaultEntryHandle = try self.reader.valueAsHandle
                    return true
                }
                return try self.readDictionary(t)
            }
        case T.objectLayout:
            let t = ACad.CadLayoutTemplate(ACad.Layout())
            return try readObjectCodes(t) { try self.readLayout(t) }
        case T.objectPlotSettings:
            let plot = ACad.PlotSettings()
            let t = ACad.CadNonGraphicalObjectTemplate(plot)
            return try readObjectCodes(t) { self.mapped { try self.assignPlotSettings(plot) } }
        case T.objectImageDefinition:
            let definition = ACad.ImageDefinition()
            let t = ACad.CadNonGraphicalObjectTemplate(definition)
            return try readObjectCodes(t) { self.mapped { try self.assignImageDefinition(definition) } }
        case T.objectDictionaryVar:
            let variable = ACad.DictionaryVariable()
            let t = ACad.CadNonGraphicalObjectTemplate(variable)
            return try readObjectCodes(t) {
                self.mapped {
                    switch self.reader.code {
                    case 280: variable.objectSchemaNumber = Int32(try self.reader.valueAsShort)
                    case 1: variable.value = self.rawString
                    default: return false
                    }
                    return true
                }
            }
        case T.objectPdfDefinition:
            let definition = ACad.PdfUnderlayDefinition()
            let t = ACad.CadNonGraphicalObjectTemplate(definition)
            return try readObjectCodes(t) {
                switch self.reader.code {
                case 1: definition.file = self.rawString
                case 2: definition.page = self.rawString
                default: return false
                }
                return true
            }
        case T.objectSortEntsTable:
            return try readSortentsTable()
        case T.objectImageDefinitionReactor:
            let reactor = ACad.ImageDefinitionReactor()
            let t = ACad.CadNonGraphicalObjectTemplate(reactor)
            return try readObjectCodes(t) {
                self.mapped {
                    switch self.reader.code {
                    case 90: reactor.classVersion = try self.reader.valueAsInt
                    case 330 where self.currentSubclass == ACad.DxfSubclassMarker.rasterImageDefReactor: return false
                    default: return false
                    }
                    return true
                }
            }
        case T.objectRasterVariables:
            let variables = ACad.RasterVariables()
            let t = ACad.CadNonGraphicalObjectTemplate(variables)
            return try readObjectCodes(t) {
                self.mapped {
                    switch self.reader.code {
                    case 90: variables.classVersion = try self.reader.valueAsInt
                    case 71: variables.displayQuality = try self.reader.valueAsShort
                    case 70: variables.isDisplayFrameShown = try self.reader.valueAsBool
                    case 72: variables.units = try self.reader.valueAsShort
                    default: return false
                    }
                    return true
                }
            }
        case T.objectWipeoutVariables:
            let variables = ACad.WipeoutVariables()
            let t = ACad.CadNonGraphicalObjectTemplate(variables)
            return try readObjectCodes(t) {
                self.mapped {
                    guard self.reader.code == 70 else { return false }
                    variables.displayFrame = try self.reader.valueAsBool
                    return true
                }
            }
        case T.objectGroup:
            let t = ACad.CadGroupTemplate(ACad.Group())
            return try readObjectCodes(t) { try self.readGroup(t) }
        case T.objectMaterial:
            let t = ACad.CadNonGraphicalObjectTemplate(ACad.Material())
            return try readObjectCodes(t) { try self.readMaterial(t.cadObject as! ACad.Material) }
        case T.objectScale:
            let scale = ACad.Scale()
            let t = ACad.CadNonGraphicalObjectTemplate(scale)
            return try readObjectCodes(t) {
                switch self.reader.code {
                case 70: return true
                default:
                    return self.mapped {
                        switch self.reader.code {
                        case 141: scale.drawingUnits = try self.reader.valueAsDouble
                        case 290: scale.isUnitScale = try self.reader.valueAsBool
                        case 140: scale.paperUnits = try self.reader.valueAsDouble
                        case 300: scale.name = self.rawString
                        default: return false
                        }
                        return true
                    }
                }
            }
        case T.objectVisualStyle:
            // Not modelled (the DXF writer leaves visual styles out); every code is consumed like ACadSharp does.
            let t = ACad.CadNonGraphicalObjectTemplate(ACad.UnmodelledObject(dxfName: T.objectVisualStyle))
            return try readObjectCodes(t) { true }
        case T.objectSpatialFilter:
            let filter = ACad.SpatialFilter()
            let t = ACad.CadNonGraphicalObjectTemplate(filter)
            var hasFrontPlane = false
            var insertTransformRead = false
            return try readObjectCodes(t) { try self.readSpatialFilter(filter, &hasFrontPlane, &insertTransformRead) }
        case T.objectMLineStyle:
            let t = ACad.CadMLineStyleTemplate(ACad.MLineStyle())
            return try readObjectCodes(t) { try self.readMLineStyle(t) }
        case T.objectMLeaderStyle:
            let t = ACad.CadMLeaderStyleTemplate(ACad.MultiLeaderStyle())
            return try readObjectCodes(t) { try self.readMLeaderStyle(t) }
        case T.objectTableStyle:
            let t = ACad.CadTableStyleTemplate(ACad.TableStyle())
            return try readObjectCodes(t) { try self.readTableStyle(t) }
        case T.objectTableContent:
            let t = ACad.CadTableContentTemplate(ACad.TableContent())
            return try readObjectCodes(t) { try self.readTableContent(t) }
        case T.objectXRecord:
            let t = ACad.CadXRecordTemplate(ACad.XRecord())
            return try readObjectCodes(t) { try self.readXRecord(t) }
        default:
            if let template = try readEvaluationObject(reader.valueAsString) { return template }
            // Objects of a known class become placeholders that take a new handle (KeepUnknownEntities = false).
            var template: ACad.CadTemplate?
            if let dxfClass = builder.document.classes[reader.valueAsString] {
                builder.notify("NonGraphicalObject not supported read as an UnknownNonGraphicalObject: \(reader.valueAsString)")
                template = ACad.CadNonGraphicalObjectTemplate(ACad.UnknownNonGraphicalObject(dxfClass: dxfClass))
            } else {
                builder.notify("UnknownNonGraphicalObject not supported: \(reader.valueAsString)")
            }
            try reader.readNext()
            repeat { try reader.readNext() } while reader.code != 0
            return template
        }
    }

    private func readBookColor(_ color: ACad.BookColor) throws -> Bool {
        switch reader.code {
        case 430:
            color.name = reader.valueAsString
            return true
        default:
            return mapped {
                switch reader.code {
                case 62: color.color = try self.color(index: reader.valueAsShort)
                case 420: color.color = ACad.Color.fromRgb24(try reader.valueAsInt)
                default: return false
                }
                return true
            }
        }
    }

    private func readDictionary(_ t: ACad.CadDictionaryTemplate) throws -> Bool {
        let dictionary = t.cadObject as! ACad.CadDictionary
        switch reader.code {
        case 280: dictionary.hardOwnerFlag = try reader.valueAsBool
        case 281: dictionary.cloningFlags = try reader.valueAsShort
        case 3: t.addEntryName(reader.valueAsString)
        case 350, 360: t.setLastEntryHandle(try reader.valueAsHandle)
        default: return false
        }
        return true
    }

    private func readLayout(_ t: ACad.CadLayoutTemplate) throws -> Bool {
        let layout = t.cadObject as! ACad.Layout
        switch reader.code {
        case 330 where t.ownerHandle != nil:
            t.paperSpaceBlockHandle = try reader.valueAsHandle
            return true
        case 331:
            t.lastActiveViewportHandle = try reader.valueAsHandle
            return true
        default:
            let assigned = mapped {
                let i = axis(reader.code)
                switch reader.code {
                case 146: layout.elevation = try reader.valueAsDouble
                case 12, 22, 32: layout.insertionBasePoint[i] = try reader.valueAsDouble
                case 70: layout.layoutFlags = try reader.valueAsShort
                case 15, 25, 35: layout.maxExtents[i] = try reader.valueAsDouble
                case 11, 21: layout.maxLimits[i] = try reader.valueAsDouble
                case 14, 24, 34: layout.minExtents[i] = try reader.valueAsDouble
                case 10, 20: layout.minLimits[i] = try reader.valueAsDouble
                case 13, 23, 33: layout.origin[i] = try reader.valueAsDouble
                case 71: layout.tabOrder = Int32(try reader.valueAsShort)
                case 76: layout.ucsOrthographicType = try reader.valueAsShort
                case 16, 26, 36: layout.xAxis[i] = try reader.valueAsDouble
                case 17, 27, 37: layout.yAxis[i] = try reader.valueAsDouble
                // The layout map is tried first for every code: 1 is the name (PageName is never read) and 70 / 76
                // are layout values even in the plot settings part, like ACadSharp.
                case 1: layout.name = rawString
                default: return false
                }
                return true
            }
            return assigned ? true : mapped { try assignPlotSettings(layout) }
        }
    }

    /// The AcDbPlotSettings map.
    private func assignPlotSettings(_ p: ACad.PlotSettings) throws -> Bool {
        switch reader.code {
        case 70: p.flags = try reader.valueAsShort
        case 1: p.pageName = rawString
        case 45: p.paperHeight = try reader.valueAsDouble
        case 148: p.paperImageOriginX = try reader.valueAsDouble
        case 149: p.paperImageOriginY = try reader.valueAsDouble
        case 73: p.paperRotation = try reader.valueAsShort
        case 4: p.paperSize = rawString
        case 72: p.paperUnits = try reader.valueAsShort
        case 44: p.paperWidth = try reader.valueAsDouble
        case 46: p.plotOriginX = try reader.valueAsDouble
        case 47: p.plotOriginY = try reader.valueAsDouble
        case 74: p.plotType = try reader.valueAsShort
        case 6: p.plotViewName = rawString
        case 75: p.scaledFit = try reader.valueAsShort
        case 76: p.shadePlotMode = try reader.valueAsShort
        case 77: p.shadePlotResolutionMode = try reader.valueAsShort
        case 78: p.shadePlotDPI = try reader.valueAsShort
        case 147: p.standardScale = try reader.valueAsDouble
        case 7: p.styleSheet = rawString
        case 2: p.systemPrinterName = rawString
        case 40: p.unprintableMargin.left = try reader.valueAsDouble
        case 41: p.unprintableMargin.bottom = try reader.valueAsDouble
        case 42: p.unprintableMargin.right = try reader.valueAsDouble
        case 43: p.unprintableMargin.top = try reader.valueAsDouble
        case 48: p.windowLowerLeftX = try reader.valueAsDouble
        case 49: p.windowLowerLeftY = try reader.valueAsDouble
        case 140: p.windowUpperLeftX = try reader.valueAsDouble
        case 141: p.windowUpperLeftY = try reader.valueAsDouble
        case 142:
            let value = try reader.valueAsDouble
            guard value > 0 else { throw ACad.DxfException("Value must be greater than zero") }
            p.numeratorScale = value
        case 143:
            let value = try reader.valueAsDouble
            guard value > 0 else { throw ACad.DxfException("Value must be greater than zero") }
            p.denominatorScale = value
        case 333: p.shadePlotIDHandle = try reader.valueAsHandle
        default: return false
        }
        return true
    }

    private func assignImageDefinition(_ d: ACad.ImageDefinition) throws -> Bool {
        switch reader.code {
        case 90: d.classVersion = try reader.valueAsInt
        case 11, 21: d.defaultSize[axis(reader.code)] = try reader.valueAsDouble
        case 1: d.fileName = rawString
        case 280: d.isLoaded = try reader.valueAsBool
        case 10, 20: d.size[axis(reader.code)] = try reader.valueAsDouble
        case 281: d.units = UInt8(try reader.value.integer(0...255))
        default: return false
        }
        return true
    }

    private func readGroup(_ t: ACad.CadGroupTemplate) throws -> Bool {
        let group = t.cadObject as! ACad.Group
        switch reader.code {
        case 70: return true
        case 340:
            t.handles.insert(try reader.valueAsHandle)
            return true
        default:
            return mapped {
                switch reader.code {
                case 300: group.description = rawString
                case 71: group.selectable = try reader.valueAsBool
                default: return false
                }
                return true
            }
        }
    }

    private func readMaterial(_ material: ACad.Material) throws -> Bool {
        switch reader.code {
        case 5, 100, 102, 330, 1001:
            return false
        case 1:
            material.name = rawString
            return true
        case 43, 47, 49, 142, 144, 147:
            // 16 matrix values in a row.
            let code = reader.code
            for _ in 0..<16 where reader.code == code { try reader.readNext() }
            lockPointer = true
            return true
        default:
            return true
        }
    }

    private func readSortentsTable() throws -> ACad.CadTemplate {
        let table = ACad.SortEntitiesTable()
        let template = ACad.CadSortensTableTemplate(table)
        try reader.readNext()
        // readCommonObjectData(template): handle, groups and owner until the subclass marker.
        while reader.code != 100 {
            switch reader.code {
            case 5: table.handle = try reader.valueAsHandle
            case 102:
                let groups = try readDefinedGroups()
                if let xdict = groups.xdict { template.xdictHandle = xdict }
                template.reactorsHandles.formUnion(groups.reactors)
            case 330: template.ownerHandle = try reader.valueAsHandle
            default: break
            }
            try reader.readNext()
        }
        try reader.readNext()
        var pair: (UInt64?, UInt64?) = (nil, nil)
        while reader.code != 0 {
            switch reader.code {
            case 5: pair.0 = try reader.valueAsHandle
            case 330: template.blockOwnerHandle = try reader.valueAsHandle
            case 331: pair.1 = try reader.valueAsHandle
            default: builder.notify("Group Code not handled for SortEntitiesTable, code : \(reader.code) | value : \(reader.valueAsString)")
            }
            if pair.0 != nil, pair.1 != nil {
                template.values.append(pair)
                pair = (nil, nil)
            }
            try reader.readNext()
        }
        return template
    }

    private func readXRecord(_ t: ACad.CadXRecordTemplate) throws -> Bool {
        let record = t.cadObject as! ACad.XRecord
        switch reader.code {
        case 100 where reader.valueAsString == ACad.DxfSubclassMarker.xRecord:
            try reader.readNext()
            while reader.code != 0 {
                let code = reader.code
                switch reader.groupType {
                case .point3D:
                    let x = try reader.valueAsDouble
                    try reader.readNext()
                    let y = try reader.valueAsDouble
                    try reader.readNext()
                    record.entries.append(.init(code: code, value: .point(ACad.XYZ(x, y, try reader.valueAsDouble))))
                case .handle, .objectId, .extendedDataHandle:
                    t.handleReferences.append((code, try reader.valueAsHandle))
                default:
                    record.entries.append(.init(code: code, value: reader.value.dxfValue))
                }
                try reader.readNext()
            }
            return true
        default:
            return mapped {
                guard reader.code == 280 else { return false }
                record.cloningFlags = try reader.valueAsShort
                return true
            }
        }
    }

    private func readMLineStyle(_ t: ACad.CadMLineStyleTemplate) throws -> Bool {
        let style = t.cadObject as! ACad.MLineStyle
        switch reader.code {
        case 6:
            t.elementTemplates.last?.lineTypeName = reader.valueAsString
            return true
        case 49:
            let element = ACad.MLineStyle.Element()
            element.offset = try reader.valueAsDouble
            t.elementTemplates.append(.init(element))
            style.addElement(element)
            return true
        case 62:
            // ACadSharp's map sends every 62 (element colours included) to the fill colour.
            return mapped { style.fillColor = try color(index: reader.valueAsShort); return true }
        default:
            return mapped {
                switch reader.code {
                case 2: style.name = rawString
                case 3: style.description = rawString
                case 52: style.endAngle = try reader.valueAsAngle
                case 70: style.flags = try reader.valueAsShort
                case 51: style.startAngle = try reader.valueAsAngle
                case 71: break
                default: return false
                }
                return true
            }
        }
    }

    private func readMLeaderStyle(_ t: ACad.CadMLeaderStyleTemplate) throws -> Bool {
        let s = t.cadObject as! ACad.MultiLeaderStyle
        let r = reader!
        switch r.code {
        case 179: return true
        case 340: t.leaderLineTypeHandle = try r.valueAsHandle
        case 342: t.mtextStyleHandle = try r.valueAsHandle
        default:
            return mapped {
                switch r.code {
                case 46: s.alignSpace = try r.valueAsDouble
                case 44: s.arrowheadSize = try r.valueAsDouble
                case 94: _ = try r.valueAsInt // BlockContentColor: no conversion for 94 in ACadSharp's map
                case 177: s.blockContentConnection = try r.valueAsShort
                case 141: s.blockContentRotation = try r.valueAsAngle
                case 143: s.breakGapSize = try r.valueAsDouble
                case 170: s.contentType = try r.valueAsShort
                case 300: s.defaultTextContents = rawString
                case 3: s.description = rawString
                case 294: s.enableBlockContentRotation = try r.valueAsBool
                case 293: s.enableBlockContentScale = try r.valueAsBool
                case 291: s.enableDogleg = try r.valueAsBool
                case 290: s.enableLanding = try r.valueAsBool
                case 40: s.firstSegmentAngleConstraint = try r.valueAsDouble
                case 296: s.isAnnotative = try r.valueAsBool
                case 43: s.landingDistance = try r.valueAsDouble
                case 42: s.landingGap = try r.valueAsDouble
                case 172: s.leaderDrawOrder = try r.valueAsShort
                case 92: s.leaderLineWeight = ACad.LineWeight(Int16(truncatingIfNeeded: try r.valueAsInt))
                case 91: _ = try r.valueAsInt // LineColor: no conversion for 91
                case 90: s.maxLeaderSegmentsPoints = try r.valueAsInt
                case 171: s.multiLeaderDrawOrder = try r.valueAsShort
                case 295: s.overwritePropertyValue = try r.valueAsBool
                case 173: s.pathType = try r.valueAsShort
                case 142: s.scaleFactor = try r.valueAsDouble
                case 41: s.secondSegmentAngleConstraint = try r.valueAsDouble
                case 297: s.textAlignAlwaysLeft = try r.valueAsBool
                case 176: s.textAlignment = try r.valueAsShort
                case 175: s.textAngle = try r.valueAsShort
                case 271: s.textAttachmentDirection = try r.valueAsShort
                case 272: s.textBottomAttachment = try r.valueAsShort
                case 93: _ = try r.valueAsInt // TextColor: no conversion for 93
                case 292: s.textFrame = try r.valueAsBool
                case 45: s.textHeight = try r.valueAsDouble
                case 174: s.textLeftAttachment = try r.valueAsShort
                case 178: s.textRightAttachment = try r.valueAsShort
                case 273: s.textTopAttachment = try r.valueAsShort
                case 298: s.unknownFlag298 = try r.valueAsBool
                default: return false
                }
                return true
            }
        }
        return true
    }

    private func readSpatialFilter(_ f: ACad.SpatialFilter, _ hasFrontPlane: inout Bool, _ insertTransformRead: inout Bool) throws -> Bool {
        switch reader.code {
        case 10:
            f.boundaryPoints.append(ACad.XY(try reader.valueAsDouble, 0))
            return true
        case 20:
            if !f.boundaryPoints.isEmpty { f.boundaryPoints[f.boundaryPoints.count - 1].y = try reader.valueAsDouble }
            return true
        case 40:
            if f.clipFrontPlane, !hasFrontPlane {
                f.frontDistance = try reader.valueAsDouble
                hasFrontPlane = true
                return true
            }
            var values: [Double] = []
            for i in 0..<12 {
                values.append(try reader.valueAsDouble)
                if i < 11 { try reader.readNext() }
            }
            // ACadSharp only ever stores the inverse transform here (its flag is never set).
            if insertTransformRead {
                f.insertTransform = values
                insertTransformRead = true
            } else {
                f.inverseInsertTransform = values
            }
            return true
        default:
            return mapped {
                switch reader.code {
                case 41: f.backDistance = try reader.valueAsDouble
                case 73: f.clipBackPlane = try reader.valueAsBool
                case 72: f.clipFrontPlane = try reader.valueAsBool
                case 71: f.displayBoundary = try reader.valueAsBool
                case 70: break
                case 210, 220, 230: f.normal[axis(reader.code)] = try reader.valueAsDouble
                case 11, 21, 31: f.origin[axis(reader.code)] = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
    }

    // ───────────────────────── ACDSDATA ─────────────────────────

    /// `DxfAcdsDataSectionReader`: records with an entity id (AcDbDs::ID) and its ASM data.
    /// `DxfAcdsDataSectionReader`: ACDSRECORD entries pair an entity handle (320) with its ACIS payload (310).
    func readAcdsData() throws {
        if reader.valueAsString != ACad.DxfFileToken.acdsDataSection { _ = try reader.find(ACad.DxfFileToken.acdsDataSection) }
        var inRecord = false
        var currentHandle: UInt64 = 0
        var payload: Data?
        func store() {
            guard currentHandle != 0, let payload, !payload.isEmpty else { return }
            // Dictionary semantics: a repeated handle keeps its position and takes the last payload.
            if let index = builder.acdsData.firstIndex(where: { $0.0 == currentHandle }) {
                builder.acdsData[index].1 = payload
            } else {
                builder.acdsData.append((currentHandle, payload))
            }
        }
        do {
            try reader.readNext()
            while reader.valueAsString != ACad.DxfFileToken.endSection {
                if reader.code == 0 {
                    store()
                    inRecord = reader.valueAsString == ACad.DxfFileToken.acdsRecord
                    currentHandle = 0
                    payload = nil
                } else if inRecord {
                    switch reader.code {
                    case 320: currentHandle = try reader.valueAsHandle
                    case 310: payload = (payload ?? Data()) + (reader.valueAsBinaryChunk ?? Data())
                    default: break
                    }
                }
                try reader.readNext()
            }
            store()
        } catch {
            builder.notify("An error occurred while reading the Prototype1b: \(error)")
        }
    }
}

extension ACad.DxfRawValue {
    /// The value as an xrecord entry.
    var dxfValue: ACad.DxfValue {
        switch self {
        case let .string(s): return .string(s)
        case let .double(d): return .double(d)
        case let .short(v): return .int16(v)
        case let .int(v): return .int32(v)
        case let .long(v): return .int64(v)
        case let .handle(h): return .handle(h)
        case let .bool(b): return .bool(b)
        case let .bytes(d): return .bytes(d)
        }
    }
}

extension ACad {
    /// Objects read only so that references to them resolve (visual styles): never drawn or written.
    final class UnmodelledObject: NonGraphicalObject {
        let dxfName: String
        init(dxfName: String) {
            self.dxfName = dxfName
            super.init()
        }

        override var objectName: String { dxfName }
    }
}
