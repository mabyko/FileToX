// DXF entity reading (ACadSharp DxfSectionReaderBase): one reader per entity type. ACadSharp assigns most codes
// through its reflection map of the current subclass; here each subclass's codes are written out.

import Foundation

extension ACad.DxfReader {
    typealias XYZ = ACad.XYZ
    typealias XY = ACad.XY

    /// The vector component a group code addresses (`(code / 10) % 10 - 1`).
    @inline(__always) func axis(_ code: Int) -> Int { (code / 10) % 10 - 1 }

    /// `readEntity`.
    func readEntity() throws -> ACad.CadEntityTemplate? {
        currentSubclass = ""
        switch reader.valueAsString {
        case ACad.DxfFileToken.entityAttribute:
            let t = ACad.CadTextEntityTemplate(ACad.AttributeEntity())
            return try readEntityCodes(t) { try self.readAttributeDefinition(t) }
        case ACad.DxfFileToken.entityAttributeDefinition:
            let t = ACad.CadTextEntityTemplate(ACad.AttributeDefinition())
            return try readEntityCodes(t) { try self.readAttributeDefinition(t) }
        case ACad.DxfFileToken.entityArc:
            let t = ACad.CadEntityTemplate(ACad.Arc())
            return try readEntityCodes(t) { try self.readArc(t.cadObject as! ACad.Arc) }
        case ACad.DxfFileToken.entityBody:
            let t = ACad.CadModelerGeometryTemplate(ACad.CadBody())
            return try readEntityCodes(t) { try self.readModelerGeometry(t) }
        case ACad.DxfFileToken.entityCircle:
            let t = ACad.CadEntityTemplate(ACad.Circle())
            return try readEntityCodes(t) { try self.readCircle(t.cadObject as! ACad.Circle) }
        case ACad.DxfFileToken.entityDimension, ACad.DxfFileToken.entityArcDimension:
            let t = ACad.CadDimensionTemplate(ACad.DimensionAligned())
            t.isPlaceholder = true
            let result = try readEntityCodes(t) { try self.readDimension(t) }
            if t.isPlaceholder {
                builder.notify("[DIMENSION] No subtype found, object discarded.")
                return nil
            }
            return result
        case ACad.DxfFileToken.entity3DFace:
            let t = ACad.CadEntityTemplate(ACad.Face3D())
            return try readEntityCodes(t) { try self.readFace3D(t.cadObject as! ACad.Face3D) }
        case ACad.DxfFileToken.entityEllipse:
            let t = ACad.CadEntityTemplate(ACad.Ellipse())
            return try readEntityCodes(t) { try self.readEllipse(t.cadObject as! ACad.Ellipse) }
        case ACad.DxfFileToken.entityLeader:
            let t = ACad.CadLeaderTemplate(ACad.Leader())
            return try readEntityCodes(t) { try self.readLeader(t) }
        case ACad.DxfFileToken.entityLine:
            let t = ACad.CadEntityTemplate(ACad.Line())
            return try readEntityCodes(t) { try self.readLine(t.cadObject as! ACad.Line) }
        case ACad.DxfFileToken.entityLwPolyline:
            let t = ACad.CadEntityTemplate(ACad.LwPolyline())
            return try readEntityCodes(t) { try self.readLwPolyline(t.cadObject as! ACad.LwPolyline) }
        case ACad.DxfFileToken.entityMesh:
            let t = ACad.CadEntityTemplate(ACad.Mesh())
            var subclassMarker = false
            return try readEntityCodes(t) { try self.readMesh(t.cadObject as! ACad.Mesh, &subclassMarker) }
        case ACad.DxfFileToken.entityHatch:
            let t = ACad.CadHatchTemplate(ACad.Hatch())
            return try readEntityCodes(t) { try self.readHatch(t) }
        case ACad.DxfFileToken.entityInsert:
            let t = ACad.CadInsertTemplate(ACad.Insert())
            return try readEntityCodes(t) { try self.readInsert(t) }
        case ACad.DxfFileToken.entityMText:
            let t = ACad.CadTextEntityTemplate(ACad.MText())
            return try readEntityCodes(t) { try self.readTextEntity(t, subclass: nil) }
        case ACad.DxfFileToken.entityMLine:
            let t = ACad.CadMLineTemplate(ACad.MLine())
            return try readEntityCodes(t) { try self.readMLine(t) }
        case ACad.DxfFileToken.entityMultiLeader:
            let t = ACad.CadMLeaderTemplate(ACad.MultiLeader())
            return try readEntityCodes(t) { try self.readMLeader(t) }
        case ACad.DxfFileToken.entityPdfUnderlay:
            let t = ACad.CadUnderlayTemplate(ACad.PdfUnderlay())
            return try readEntityCodes(t) { try self.readUnderlay(t) }
        case ACad.DxfFileToken.entityPoint:
            let t = ACad.CadEntityTemplate(ACad.Point())
            return try readEntityCodes(t) { try self.readPoint(t.cadObject as! ACad.Point) }
        case ACad.DxfFileToken.entityPolyline:
            return try readPolyline()
        case ACad.DxfFileToken.entityOle2Frame:
            let t = ACad.CadOle2FrameTemplate(ACad.Ole2Frame())
            return try readEntityCodes(t) { try self.readOle2Frame(t) }
        case ACad.DxfFileToken.entityRay:
            let t = ACad.CadEntityTemplate(ACad.Ray())
            return try readEntityCodes(t) { try self.readRay(t.cadObject as! ACad.Ray) }
        case ACad.DxfFileToken.endSequence:
            let t = ACad.CadEntityTemplate(ACad.Seqend())
            return try readEntityCodes(t) { false }
        case ACad.DxfFileToken.entityTrace, ACad.DxfFileToken.entitySolid:
            // ACadSharp reads both through the modeler geometry reader: only the AcDbTrace map applies.
            let t = ACad.CadEntityTemplate(ACad.Solid())
            return try readEntityCodes(t) { try self.readSolid(t.cadObject as! ACad.Solid) }
        case ACad.DxfFileToken.entityTable:
            let t = ACad.CadTableEntityTemplate(ACad.TableEntity())
            return try readEntityCodes(t) { try self.readTableEntity(t) }
        case ACad.DxfFileToken.entityText:
            let t = ACad.CadTextEntityTemplate(ACad.TextEntity())
            return try readEntityCodes(t) { try self.readTextEntity(t, subclass: nil) }
        case ACad.DxfFileToken.entityTolerance:
            let t = ACad.CadToleranceTemplate(ACad.Tolerance())
            return try readEntityCodes(t) { try self.readTolerance(t) }
        case ACad.DxfFileToken.entityVertex:
            let t = ACad.CadVertexTemplate(ACad.Vertex())
            t.isPlaceholder = true
            return try readEntityCodes(t) { try self.readVertex(t) }
        case ACad.DxfFileToken.entityViewport:
            let t = ACad.CadViewportTemplate(ACad.Viewport())
            return try readEntityCodes(t) { try self.readViewport(t) }
        case ACad.DxfFileToken.entityShape:
            let t = ACad.CadShapeTemplate(ACad.Shape())
            return try readEntityCodes(t) { try self.readShape(t) }
        case ACad.DxfFileToken.entitySpline:
            let t = ACad.CadEntityTemplate(ACad.Spline())
            return try readEntityCodes(t) { try self.readSpline(t.cadObject as! ACad.Spline) }
        case ACad.DxfFileToken.entity3DSolid:
            let t = ACad.CadModelerGeometryTemplate(ACad.Solid3D())
            return try readEntityCodes(t) {
                if self.reader.code == 350 {
                    t.historyHandle = try self.reader.valueAsHandle
                    return true
                }
                return try self.readModelerGeometry(t)
            }
        case ACad.DxfFileToken.entityRegion:
            let t = ACad.CadModelerGeometryTemplate(ACad.Region())
            return try readEntityCodes(t) { try self.readModelerGeometry(t) }
        case ACad.DxfFileToken.entityImage:
            let t = ACad.CadWipeoutBaseTemplate(ACad.RasterImage())
            return try readEntityCodes(t) { try self.readWipeoutBase(t) }
        case ACad.DxfFileToken.entityProxyEntity:
            let t = ACad.CadProxyEntityTemplate(ACad.ProxyEntity())
            return try readEntityCodes(t) { try self.readProxyEntity(t) }
        case ACad.DxfFileToken.entityWipeout:
            let t = ACad.CadWipeoutBaseTemplate(ACad.Wipeout())
            return try readEntityCodes(t) { try self.readWipeoutBase(t) }
        case ACad.DxfFileToken.entityXline:
            let t = ACad.CadEntityTemplate(ACad.XLine())
            return try readEntityCodes(t) { try self.readXLine(t.cadObject as! ACad.XLine) }
        default:
            // Entities of a known class become placeholders that take a new handle; their codes are skipped
            // (KeepUnknownEntities = false) and they never join a block.
            var template: ACad.CadEntityTemplate?
            if let dxfClass = builder.document.classes[reader.valueAsString] {
                builder.notify("Entity not supported read as an UnknownEntity: \(reader.valueAsString)")
                template = ACad.CadEntityTemplate(ACad.UnknownEntity(dxfClass: dxfClass))
            } else {
                builder.notify("Entity not supported: \(reader.valueAsString)")
            }
            try reader.readNext()
            repeat { try reader.readNext() } while reader.code != 0
            return template
        }
    }

    /// `readEntityCodes`: reads codes until the next entity with `read`, then the common entity codes.
    func readEntityCodes<T: ACad.CadEntityTemplate>(_ template: T, _ read: () throws -> Bool) throws -> T {
        try reader.readNext()
        while reader.code != 0 {
            if try !read() {
                if try readCommonEntityCodes(template) { continue }
            }
            if lockPointer {
                lockPointer = false
                continue
            }
            if reader.code != 0 { try reader.readNext() }
        }
        return template
    }

    /// `readCommonEntityCodes`; true when extended data was read.
    func readCommonEntityCodes(_ template: ACad.CadEntityTemplate) throws -> Bool {
        let entity = template.entity
        switch reader.code {
        case 6: template.lineTypeName = reader.valueAsString
        case 8: template.layerName = reader.valueAsString
        case 67, 92, 160, 310: break
        case 347: template.materialHandle = try reader.valueAsHandle
        case 430: template.bookColorName = reader.valueAsString
        case 62: entity.color = try color(index: reader.valueAsShort)
        case 420: entity.color = ACad.Color.fromRgb24(try reader.valueAsInt)
        case 60: entity.isInvisible = try reader.valueAsBool
        case 48: entity.lineTypeScale = try reader.valueAsDouble
        case 370: entity.lineWeight = ACad.LineWeight(try reader.valueAsShort)
        case 440: entity.transparency = ACad.Transparency.fromAlphaValue(try reader.valueAsInt)
        default: return try readCommonCodes(template)
        }
        return false
    }

    /// Runs a map assignment the way `tryAssignCurrentValue` does: conversion errors are logged and the code
    /// counts as unhandled.
    func mapped(_ assign: () throws -> Bool) -> Bool {
        do {
            return try assign()
        } catch {
            builder.notify("An error occurred while assigning a property using mapper: \(error)")
            return false
        }
    }

    // ───────────────────────── Simple entities ─────────────────────────

    private func readLine(_ line: ACad.Line) throws -> Bool {
        mapped {
            switch reader.code {
            case 10, 20, 30: line.startPoint[axis(reader.code)] = try reader.valueAsDouble
            case 11, 21, 31: line.endPoint[axis(reader.code)] = try reader.valueAsDouble
            case 39: line.thickness = try reader.valueAsDouble
            case 210, 220, 230: line.normal[axis(reader.code)] = try reader.valueAsDouble
            default: return false
            }
            return true
        }
    }

    private func readCircle(_ circle: ACad.Circle) throws -> Bool {
        switch reader.code {
        case 40:
            let radius = try reader.valueAsDouble
            circle.radius = radius <= 0 ? ACad.MathHelper.epsilon : radius
            return true
        default:
            return mapped {
                switch reader.code {
                case 10, 20, 30: circle.center[axis(reader.code)] = try reader.valueAsDouble
                case 210, 220, 230: circle.normal[axis(reader.code)] = try reader.valueAsDouble
                case 39: circle.thickness = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
    }

    private func readArc(_ arc: ACad.Arc) throws -> Bool {
        let assigned = mapped {
            switch reader.code {
            case 50: arc.startAngle = try reader.valueAsAngle
            case 51: arc.endAngle = try reader.valueAsAngle
            default: return false
            }
            return true
        }
        return assigned ? true : try readCircle(arc)
    }

    private func readEllipse(_ e: ACad.Ellipse) throws -> Bool {
        mapped {
            switch reader.code {
            case 10, 20, 30: e.center[axis(reader.code)] = try reader.valueAsDouble
            case 11, 21, 31: e.majorAxisEndPoint[axis(reader.code)] = try reader.valueAsDouble
            case 210, 220, 230: e.normal[axis(reader.code)] = try reader.valueAsDouble
            case 39: e.thickness = try reader.valueAsDouble
            case 40:
                let value = try reader.valueAsDouble
                if value <= 0 || value > 1 {
                    throw ACad.DxfException("Radius ratio must be a value between 0 (not included) and 1.")
                }
                e.radiusRatio = value
            case 41: e.startParameter = try reader.valueAsDouble
            case 42: e.endParameter = try reader.valueAsDouble
            default: return false
            }
            return true
        }
    }

    private func readPoint(_ p: ACad.Point) throws -> Bool {
        mapped {
            switch reader.code {
            case 10, 20, 30: p.location[axis(reader.code)] = try reader.valueAsDouble
            case 210, 220, 230: p.normal[axis(reader.code)] = try reader.valueAsDouble
            case 39: p.thickness = try reader.valueAsDouble
            case 50: p.rotation = try reader.valueAsAngle
            default: return false
            }
            return true
        }
    }

    private func readRay(_ ray: ACad.Ray) throws -> Bool {
        mapped {
            switch reader.code {
            case 10, 20, 30: ray.startPoint[axis(reader.code)] = try reader.valueAsDouble
            case 11, 21, 31: ray.direction[axis(reader.code)] = try reader.valueAsDouble
            default: return false
            }
            return true
        }
    }

    private func readXLine(_ x: ACad.XLine) throws -> Bool {
        mapped {
            switch reader.code {
            case 10, 20, 30: x.firstPoint[axis(reader.code)] = try reader.valueAsDouble
            case 11, 21, 31: x.direction[axis(reader.code)] = try reader.valueAsDouble
            default: return false
            }
            return true
        }
    }

    private func readSolid(_ s: ACad.Solid) throws -> Bool {
        // ACadSharp reads SOLID / TRACE with the modeler geometry reader: SAT codes hit a null object there.
        if reader.code == 1 || reader.code == 2 || reader.code == 3 { throw ACad.DxfException("Object reference not set to an instance of an object.") }
        if reader.code == 290 { return true }
        return mapped {
            switch reader.code {
            case 10, 20, 30: s.firstCorner[axis(reader.code)] = try reader.valueAsDouble
            case 11, 21, 31: s.secondCorner[axis(reader.code)] = try reader.valueAsDouble
            case 12, 22, 32: s.thirdCorner[axis(reader.code)] = try reader.valueAsDouble
            case 13, 23, 33: s.fourthCorner[axis(reader.code)] = try reader.valueAsDouble
            case 39: s.thickness = try reader.valueAsDouble
            case 210, 220, 230: s.normal[axis(reader.code)] = try reader.valueAsDouble
            default: return false
            }
            return true
        }
    }

    private func readFace3D(_ f: ACad.Face3D) throws -> Bool {
        mapped {
            switch reader.code {
            case 10, 20, 30: f.firstCorner[axis(reader.code)] = try reader.valueAsDouble
            case 11, 21, 31: f.secondCorner[axis(reader.code)] = try reader.valueAsDouble
            case 12, 22, 32: f.thirdCorner[axis(reader.code)] = try reader.valueAsDouble
            case 13, 23, 33: f.fourthCorner[axis(reader.code)] = try reader.valueAsDouble
            case 70: f.flags = try reader.valueAsShort
            default: return false
            }
            return true
        }
    }

    private func readShape(_ t: ACad.CadShapeTemplate) throws -> Bool {
        let s = t.cadObject as! ACad.Shape
        if reader.code == 2 {
            t.shapeFileName = reader.valueAsString
            return true
        }
        return mapped {
            switch reader.code {
            case 10, 20, 30: s.insertionPoint[axis(reader.code)] = try reader.valueAsDouble
            case 210, 220, 230: s.normal[axis(reader.code)] = try reader.valueAsDouble
            case 51: s.obliqueAngle = try reader.valueAsAngle
            case 41: s.relativeXScale = try reader.valueAsDouble
            case 50: s.rotation = try reader.valueAsAngle
            case 40: s.size = try reader.valueAsDouble
            case 39: s.thickness = try reader.valueAsDouble
            default: return false
            }
            return true
        }
    }

    private func readTolerance(_ t: ACad.CadToleranceTemplate) throws -> Bool {
        let tol = t.cadObject as! ACad.Tolerance
        if reader.code == 3 {
            t.dimensionStyleName = reader.valueAsString
            return true
        }
        return mapped {
            switch reader.code {
            case 11, 21, 31: tol.direction[axis(reader.code)] = try reader.valueAsDouble
            case 10, 20, 30: tol.insertionPoint[axis(reader.code)] = try reader.valueAsDouble
            case 210, 220, 230: tol.normal[axis(reader.code)] = try reader.valueAsDouble
            case 1: tol.text = rawString
            default: return false
            }
            return true
        }
    }

    // ───────────────────────── Text ─────────────────────────

    /// `readTextEntity`: MTEXT codes or the AcDbText map.
    private func readTextEntity(_ t: ACad.CadTextEntityTemplate, subclass: String?) throws -> Bool {
        if let mtext = t.cadObject as? ACad.MText {
            switch reader.code {
            case 1, 3:
                mtext.value += reader.valueAsString
                return true
            case 50:
                let angle = try reader.valueAsAngle
                mtext.alignmentPoint = XYZ(cos(angle), sin(angle), 0)
                return true
            case 7:
                t.styleName = reader.valueAsString
                return true
            case 101:
                try readColumnData(mtext)
                lockPointer = true
                return true
            default:
                return mapped { try assignMText(mtext) }
            }
        }
        let text = t.cadObject as! ACad.TextEntity
        if reader.code == 7 {
            t.styleName = reader.valueAsString
            return true
        }
        return mapped { try assignText(text) }
    }

    /// The AcDbText map.
    private func assignText(_ text: ACad.TextEntity) throws -> Bool {
        switch reader.code {
        case 11, 21, 31: text.alignmentPoint[axis(reader.code)] = try reader.valueAsDouble
        case 40: text.height = try reader.valueAsDouble
        case 72: text.horizontalAlignment = try reader.valueAsShort
        case 10, 20, 30: text.insertPoint[axis(reader.code)] = try reader.valueAsDouble
        case 71: text.mirror = try reader.valueAsShort
        case 210, 220, 230: text.normal[axis(reader.code)] = try reader.valueAsDouble
        case 51: text.obliqueAngle = try reader.valueAsAngle
        case 50: text.rotation = try reader.valueAsAngle
        case 39: text.thickness = try reader.valueAsDouble
        case 1: text.value = rawString
        case 73: text.verticalAlignment = try reader.valueAsShort
        case 41: text.widthFactor = try reader.valueAsDouble
        default: return false
        }
        return true
    }

    /// The AcDbMText map.
    private func assignMText(_ m: ACad.MText) throws -> Bool {
        switch reader.code {
        case 11, 21, 31: m.alignmentPoint[axis(reader.code)] = try reader.valueAsDouble
        case 71: m.attachmentPoint = try reader.valueAsShort
        // [DxfCodeValue(63, 421, 430)]: the map's Color setter only handles 62 / 420, so these are consumed unset.
        case 63, 421, 430: break
        case 90: m.backgroundFillFlags = try reader.valueAsInt
        case 45: m.backgroundScale = try reader.valueAsDouble
        case 441: m.backgroundTransparency = ACad.Transparency.fromAlphaValue(try reader.valueAsInt)
        case 72: m.drawingDirection = try reader.valueAsShort
        case 40: m.height = try reader.valueAsDouble
        case 42: m.horizontalWidth = try reader.valueAsDouble
        case 10, 20, 30: m.insertPoint[axis(reader.code)] = try reader.valueAsDouble
        case 44: m.lineSpacing = try reader.valueAsDouble
        case 73: m.lineSpacingStyle = try reader.valueAsShort
        case 210, 220, 230: m.normal[axis(reader.code)] = try reader.valueAsDouble
        case 46: m.rectangleHeight = try reader.valueAsDouble
        case 41: m.rectangleWidth = try reader.valueAsDouble
        case 43: m.verticalHeight = try reader.valueAsDouble
        default: return false
        }
        return true
    }

    private func readColumnData(_ mtext: ACad.MText) throws {
        try reader.readNext()
        while reader.code != 0 {
            switch reader.code {
            case 71: mtext.columnData.columnType = try reader.valueAsShort
            case 72: mtext.columnData.columnCount = try reader.valueAsInt
            case 44: mtext.columnData.width = try reader.valueAsDouble
            case 45: mtext.columnData.gutter = try reader.valueAsDouble
            case 46: mtext.columnData.heights.append(try reader.valueAsDouble)
            case 73: mtext.columnData.autoHeight = try reader.valueAsBool
            case 74: mtext.columnData.flowReversed = try reader.valueAsBool
            default: break
            }
            try reader.readNext()
        }
    }

    /// `readAttributeDefinition` (ATTRIB and ATTDEF).
    private func readAttributeDefinition(_ t: ACad.CadTextEntityTemplate) throws -> Bool {
        let att = t.cadObject as! ACad.AttributeBase
        switch reader.code {
        case 44, 46:
            return true
        case 101:
            let mtext = ACad.MText()
            att.mtext = mtext
            let mtextTemplate = ACad.CadTextEntityTemplate(mtext)
            t.mtextTemplate = mtextTemplate
            _ = try readEntityCodes(mtextTemplate) { try self.readTextEntity(mtextTemplate, subclass: nil) }
            return true
        default:
            let assigned = mapped {
                switch reader.code {
                case 71: att.attributeType = UInt8(truncatingIfNeeded: try reader.valueAsShort)
                case 70: att.flags = try reader.valueAsShort
                case 2: att.tag = rawString
                case 280: att.version = UInt8(try reader.value.integer(0...255))
                case 74: att.verticalAlignment = try reader.valueAsShort
                case 3:
                    guard let definition = att as? ACad.AttributeDefinition else { return false }
                    definition.prompt = rawString
                default: return false
                }
                return true
            }
            return assigned ? true : try readTextEntity(t, subclass: ACad.DxfSubclassMarker.text)
        }
    }

    // ───────────────────────── Blocks ─────────────────────────

    private func readInsert(_ t: ACad.CadInsertTemplate) throws -> Bool {
        let insert = t.cadObject as! ACad.Insert
        switch reader.code {
        case 2: t.blockName = reader.valueAsString
        case 100, 66: break
        default: return mapped { try assignInsert(insert) }
        }
        return true
    }

    /// The AcDbBlockReference map.
    func assignInsert(_ insert: ACad.Insert) throws -> Bool {
        switch reader.code {
        case 70: insert.columnCount = try reader.valueAsUShort
        case 44: insert.columnSpacing = try reader.valueAsDouble
        case 10, 20, 30: insert.insertPoint[axis(reader.code)] = try reader.valueAsDouble
        case 210, 220, 230: insert.normal[axis(reader.code)] = try reader.valueAsDouble
        case 50: insert.rotation = try reader.valueAsAngle
        case 71: insert.rowCount = try reader.valueAsUShort
        case 45: insert.rowSpacing = try reader.valueAsDouble
        case 41, 42, 43:
            // The scale setters reject 0 (the value is then left out, like a failed map assignment).
            let value = try reader.valueAsDouble
            guard value != 0 else { throw ACad.DxfException("Scale value must be none zero.") }
            if reader.code == 41 { insert.xScale = value } else if reader.code == 42 { insert.yScale = value } else { insert.zScale = value }
        default: return false
        }
        return true
    }

    // ───────────────────────── Polylines ─────────────────────────

    /// `readPolyline`: POLYLINE with its VERTEX and SEQEND records.
    private func readPolyline() throws -> ACad.CadEntityTemplate? {
        if builder.version == .unknown || builder.version == .ac1009 { return try readLegacyPolyline() }
        let template = ACad.CadPolyLineTemplate(ACad.Polyline2D())
        template.isPlaceholder = true
        _ = try readEntityCodes(template) { try self.readPolylineCodes(template) }
        if template.isPlaceholder {
            builder.notify("[POLYLINE] Subclass not found, entity discarded")
            return nil
        }
        while reader.code == 0, reader.valueAsString == ACad.DxfFileToken.entityVertex {
            let vertexTemplate = ACad.CadVertexTemplate(ACad.Vertex())
            vertexTemplate.isPlaceholder = true
            _ = try readEntityCodes(vertexTemplate) { try self.readVertex(vertexTemplate) }
            if vertexTemplate.ownerHandle == nil { vertexTemplate.ownerHandle = template.cadObject.handle }
            template.ownedObjectsHandlers.insert(vertexTemplate.cadObject.handle)
            builder.addTemplate(vertexTemplate)
        }
        while reader.code == 0, reader.valueAsString == ACad.DxfFileToken.endSequence {
            let seqendTemplate = ACad.CadEntityTemplate(ACad.Seqend())
            _ = try readEntityCodes(seqendTemplate) { false }
            if seqendTemplate.ownerHandle == nil { seqendTemplate.ownerHandle = template.cadObject.handle }
            template.ownedObjectsHandlers.insert(seqendTemplate.cadObject.handle)
            builder.addTemplate(seqendTemplate)
        }
        return template
    }

    /// R12 polylines: no subclass markers; vertices without handles go straight into the polyline.
    private func readLegacyPolyline() throws -> ACad.CadEntityTemplate? {
        let polyline = ACad.Polyline2D()
        let template = ACad.CadPolyLineTemplate(polyline)
        _ = try readEntityCodes(template) { try self.readPolylineCodes(template) }
        while reader.code == 0, reader.valueAsString == ACad.DxfFileToken.entityVertex {
            let vertex = ACad.Vertex2D()
            let vertexTemplate = ACad.CadVertexTemplate(vertex)
            _ = try readEntityCodes(vertexTemplate) { try self.readVertex(vertexTemplate) }
            if vertexTemplate.cadObject.handle == 0 {
                polyline.vertices.add(vertexTemplate.cadObject as! ACad.Vertex)
            } else {
                template.ownedObjectsHandlers.insert(vertexTemplate.cadObject.handle)
                builder.addTemplate(vertexTemplate)
            }
        }
        while reader.code == 0, reader.valueAsString == ACad.DxfFileToken.endSequence {
            let seqend = ACad.Seqend()
            _ = try readEntityCodes(ACad.CadEntityTemplate(seqend)) { false }
            polyline.vertices.seqend = seqend
        }
        return template
    }

    private func readPolylineCodes(_ t: ACad.CadPolyLineTemplate) throws -> Bool {
        switch reader.code {
        case 10, 20, 66:
            return true
        case 100:
            switch reader.valueAsString {
            case ACad.DxfSubclassMarker.polyline: t.setPolyline(ACad.Polyline2D())
            case ACad.DxfSubclassMarker.polyline3d: t.setPolyline(ACad.Polyline3D())
            case ACad.DxfSubclassMarker.polyfaceMesh: t.setPolyline(ACad.PolyfaceMesh())
            case ACad.DxfSubclassMarker.polygonMesh: t.setPolyline(ACad.PolygonMesh())
            default: return false
            }
            return true
        default:
            let polyline = t.cadObject as! ACad.Polyline
            return mapped {
                switch reader.code {
                case 30: polyline.elevation = try reader.valueAsDouble
                case 41: polyline.endWidth = try reader.valueAsDouble
                case 70: polyline.flags = try reader.valueAsShort
                case 210, 220, 230: polyline.normal[axis(reader.code)] = try reader.valueAsDouble
                case 40: polyline.startWidth = try reader.valueAsDouble
                case 39: polyline.thickness = try reader.valueAsDouble
                case 75: polyline.smoothSurface = try reader.valueAsShort
                case 71:
                    guard let mesh = polyline as? ACad.PolygonMesh else { return false }
                    mesh.mVertexCount = try reader.valueAsShort
                case 72:
                    if let mesh = polyline as? ACad.PolygonMesh { mesh.nVertexCount = try reader.valueAsShort; return true }
                    return polyline is ACad.PolyfaceMesh // face count
                case 73:
                    guard let mesh = polyline as? ACad.PolygonMesh else { return false }
                    mesh.mSmoothSurfaceDensity = try reader.valueAsShort
                case 74:
                    guard let mesh = polyline as? ACad.PolygonMesh else { return false }
                    mesh.nSmoothSurfaceDensity = try reader.valueAsShort
                default: return false
                }
                return true
            }
        }
    }

    private func readVertex(_ t: ACad.CadVertexTemplate) throws -> Bool {
        switch reader.code {
        case 100:
            switch reader.valueAsString {
            case ACad.DxfSubclassMarker.vertex: return true
            case ACad.DxfSubclassMarker.polylineVertex: t.setVertex(ACad.Vertex2D())
            case ACad.DxfSubclassMarker.polyline3dVertex: t.setVertex(ACad.Vertex3D())
            case ACad.DxfSubclassMarker.polyfaceMeshVertex: t.setVertex(ACad.VertexFaceMesh())
            case ACad.DxfSubclassMarker.polyfaceMeshFace: t.setVertex(ACad.VertexFaceRecord())
            case ACad.DxfSubclassMarker.polygonMeshVertex: t.setVertex(ACad.PolygonMeshVertex())
            default: return false
            }
            return true
        default:
            let vertex = t.cadObject as! ACad.Vertex
            return mapped {
                switch reader.code {
                case 42: vertex.bulge = try reader.valueAsDouble
                case 50: vertex.curveTangent = try reader.valueAsAngle
                case 41: vertex.endWidth = try reader.valueAsDouble
                case 70: vertex.flags = try reader.valueAsShort
                case 91: vertex.id = try reader.valueAsInt
                case 10, 20, 30: vertex.location[axis(reader.code)] = try reader.valueAsDouble
                case 40: vertex.startWidth = try reader.valueAsDouble
                case 71, 72, 73, 74:
                    guard let face = vertex as? ACad.VertexFaceRecord else { return false }
                    let index = try reader.valueAsShort
                    switch reader.code {
                    case 71: face.index1 = index
                    case 72: face.index2 = index
                    case 73: face.index3 = index
                    default: face.index4 = index
                    }
                default: return false
                }
                return true
            }
        }
    }

    private func readLwPolyline(_ pl: ACad.LwPolyline) throws -> Bool {
        let hasLast = !pl.vertices.isEmpty
        let last = pl.vertices.count - 1
        switch reader.code {
        case 10: pl.vertices.append(ACad.LwPolyline.Vertex(try reader.valueAsDouble, 0))
        case 20: if hasLast { pl.vertices[last].location.y = try reader.valueAsDouble }
        case 40: if hasLast { pl.vertices[last].startWidth = try reader.valueAsDouble }
        case 41: if hasLast { pl.vertices[last].endWidth = try reader.valueAsDouble }
        case 42: if hasLast { pl.vertices[last].bulge = try reader.valueAsDouble }
        case 50: if hasLast { pl.vertices[last].curveTangent = try reader.valueAsDouble }
        case 66, 90: break
        case 91: if hasLast { pl.vertices[last].id = try reader.valueAsInt }
        default:
            return mapped {
                switch reader.code {
                case 43: pl.constantWidth = try reader.valueAsDouble
                case 38: pl.elevation = try reader.valueAsDouble
                case 70: pl.flags = try reader.valueAsShort
                case 210, 220, 230: pl.normal[axis(reader.code)] = try reader.valueAsDouble
                case 39: pl.thickness = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
        return true
    }

    private func readSpline(_ s: ACad.Spline) throws -> Bool {
        switch reader.code {
        case 10: s.controlPoints.append(XYZ(try reader.valueAsDouble, 0, 0))
        case 20: if !s.controlPoints.isEmpty { s.controlPoints[s.controlPoints.count - 1].y = try reader.valueAsDouble }
        case 30: if !s.controlPoints.isEmpty { s.controlPoints[s.controlPoints.count - 1].z = try reader.valueAsDouble }
        case 11: s.fitPoints.append(XYZ(try reader.valueAsDouble, 0, 0))
        case 21: if !s.fitPoints.isEmpty { s.fitPoints[s.fitPoints.count - 1].y = try reader.valueAsDouble }
        case 31: if !s.fitPoints.isEmpty { s.fitPoints[s.fitPoints.count - 1].z = try reader.valueAsDouble }
        case 40: s.knots.append(try reader.valueAsDouble)
        case 41: s.weights.append(try reader.valueAsDouble)
        case 72, 73, 74: break
        default:
            return mapped {
                switch reader.code {
                case 43: s.controlPointTolerance = try reader.valueAsDouble
                case 71: s.degree = Int32(try reader.valueAsShort)
                case 13, 23, 33: s.endTangent[axis(reader.code)] = try reader.valueAsDouble
                case 44: s.fitTolerance = try reader.valueAsDouble
                case 70: s.flags = try reader.valueAsShort
                case 42: s.knotTolerance = try reader.valueAsDouble
                case 210, 220, 230: s.normal[axis(reader.code)] = try reader.valueAsDouble
                case 12, 22, 32: s.startTangent[axis(reader.code)] = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
        return true
    }

    private func readMesh(_ mesh: ACad.Mesh, _ subclassMarker: inout Bool) throws -> Bool {
        switch reader.code {
        case 100:
            if reader.valueAsString.caseInsensitiveCompare(ACad.DxfSubclassMarker.mesh) == .orderedSame { subclassMarker = true }
            return true
        case 90:
            return true
        case 92:
            guard subclassMarker else { return false }
            let count = Int(try reader.valueAsInt)
            for _ in 0..<max(0, count) {
                try reader.readNext()
                let x = try reader.valueAsDouble
                try reader.readNext()
                let y = try reader.valueAsDouble
                try reader.readNext()
                mesh.vertices.append(XYZ(x, y, try reader.valueAsDouble))
            }
            return true
        case 93:
            let size = Int(try reader.valueAsInt)
            try reader.readNext()
            var i = 0
            while i < size {
                let indexes = Int(try reader.valueAsInt)
                try reader.readNext()
                var face: [Int32] = []
                for j in 0..<max(0, indexes) {
                    face.append(try reader.valueAsInt)
                    if i + j + 2 < size { try reader.readNext() }
                }
                mesh.faces.append(face)
                i += indexes + 1
            }
            return true
        case 94:
            let count = Int(try reader.valueAsInt)
            try reader.readNext()
            for i in 0..<max(0, count) {
                let start = try reader.valueAsInt
                try reader.readNext()
                let end = try reader.valueAsInt
                if i < count - 1 { try reader.readNext() }
                mesh.edges.append(.init(start: start, end: end, crease: nil))
            }
            return true
        case 95:
            try reader.readNext()
            for i in 0..<mesh.edges.count {
                mesh.edges[i].crease = try reader.valueAsDouble
                if i < mesh.edges.count - 1 { try reader.readNext() }
            }
            return true
        default:
            return mapped {
                switch reader.code {
                case 72: mesh.blendCrease = try reader.valueAsBool
                case 91: mesh.subdivisionLevel = try reader.valueAsInt
                case 71: mesh.version = try reader.valueAsShort
                default: return false
                }
                return true
            }
        }
    }

    // ───────────────────────── Hatch ─────────────────────────

    private func readHatch(_ t: ACad.CadHatchTemplate) throws -> Bool {
        let hatch = t.cadObject as! ACad.Hatch
        switch reader.code {
        case 2: hatch.pattern.name = reader.valueAsString
        case 10: hatch.seedPoints.append(XY(try reader.valueAsDouble, 0))
        case 20: if !hatch.seedPoints.isEmpty { hatch.seedPoints[hatch.seedPoints.count - 1].y = try reader.valueAsDouble }
        case 30: hatch.elevation = try reader.valueAsDouble
        case 53: setPatternAngle(hatch, try reader.valueAsAngle)
        case 90, 75, 98, 453: break
        case 78:
            try readPattern(hatch.pattern, Int(try reader.valueAsInt))
            lockPointer = true
        case 91:
            try readLoops(t, Int(try reader.valueAsInt))
            lockPointer = true
        case 450: hatch.gradientColor.enabled = try reader.valueAsBool
        case 451: hatch.gradientColor.reserved = try reader.valueAsInt
        case 452: hatch.gradientColor.isSingleColorGradient = try reader.valueAsBool
        case 460: hatch.gradientColor.angle = try reader.valueAsDouble
        case 461: hatch.gradientColor.shift = try reader.valueAsDouble
        case 462: hatch.gradientColor.colorTint = try reader.valueAsDouble
        case 463: hatch.gradientColor.colors.append(.init(value: try reader.valueAsDouble, color: .byLayer))
        case 63:
            if !hatch.gradientColor.colors.isEmpty {
                hatch.gradientColor.colors[hatch.gradientColor.colors.count - 1].color = try color(index: Int16(bitPattern: try reader.valueAsUShort))
            }
        case 421: break
        case 470: hatch.gradientColor.name = reader.valueAsString
        default:
            return mapped {
                switch reader.code {
                case 71: hatch.isAssociative = try reader.valueAsBool
                case 77: hatch.isDouble = try reader.valueAsBool
                case 70: hatch.isSolid = try reader.valueAsBool
                case 210, 220, 230: hatch.normal[axis(reader.code)] = try reader.valueAsDouble
                case 52: setPatternAngle(hatch, try reader.valueAsAngle)
                case 41: setPatternScale(hatch, try reader.valueAsDouble)
                case 76: hatch.patternType = try reader.valueAsShort
                case 47: hatch.pixelSize = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
        return true
    }

    /// `Hatch.PatternAngle` setter: rotates the pattern lines read so far.
    func setPatternAngle(_ hatch: ACad.Hatch, _ angle: Double) {
        hatch.patternAngle = angle
        ACad.HatchPatternUpdate.update(hatch.pattern, translation: .zero, rotation: angle, scale: 1)
    }

    /// `Hatch.PatternScale` setter: scales the pattern lines read so far.
    func setPatternScale(_ hatch: ACad.Hatch, _ scale: Double) {
        hatch.patternScale = scale
        ACad.HatchPatternUpdate.update(hatch.pattern, translation: .zero, rotation: 0, scale: scale)
    }

    private func readPattern(_ pattern: ACad.HatchPattern, _ count: Int) throws {
        try reader.readNext()
        for _ in 0..<max(0, count) {
            let line = ACad.HatchPattern.Line()
            var basePoint = XY.zero
            var offset = XY.zero
            var codes = Set<Int>()
            var end = false
            while !end {
                if codes.contains(reader.code) { break }
                codes.insert(reader.code)
                switch reader.code {
                case 53: line.angle = try reader.valueAsAngle
                case 43: basePoint.x = try reader.valueAsDouble
                case 44:
                    basePoint.y = try reader.valueAsDouble
                    line.basePoint = basePoint
                case 45:
                    offset.x = try reader.valueAsDouble
                    line.offset = offset
                case 46:
                    offset.y = try reader.valueAsDouble
                    line.offset = offset
                case 79:
                    let n = Int(try reader.valueAsInt)
                    for _ in 0..<max(0, n) {
                        try reader.readNext()
                        line.dashLengths.append(try reader.valueAsDouble)
                    }
                case 49: line.dashLengths.append(try reader.valueAsDouble)
                default: end = true
                }
                try reader.readNext()
            }
            pattern.lines.append(line)
        }
    }

    private func readLoops(_ t: ACad.CadHatchTemplate, _ count: Int) throws {
        if reader.code == 91 { try reader.readNext() }
        for _ in 0..<max(0, count) {
            guard reader.code == 92 else {
                builder.notify("Boundary path should start with code 92 but was \(reader.code)")
                break
            }
            if let path = try readLoop() { t.pathTemplates.append(path) }
        }
    }

    private func readLoop() throws -> ACad.CadHatchTemplate.BoundaryPathTemplate? {
        let template = ACad.CadHatchTemplate.BoundaryPathTemplate()
        let flags = try reader.valueAsInt
        template.path.flags = flags
        if flags & ACad.BoundaryPathFlags.polyline != 0 {
            if let polyline = try readPolylineBoundary() { template.path.edges.append(polyline) }
        } else {
            try reader.readNext()
            guard reader.code == 93 else {
                builder.notify("Edge Boundary path should start with code 93 but was \(reader.code)")
                return nil
            }
            let edges = Int(try reader.valueAsInt)
            try reader.readNext()
            for _ in 0..<max(0, edges) {
                if let edge = try readEdge() { template.path.edges.append(edge) }
            }
        }
        var end = false
        while !end {
            switch reader.code {
            case 97: break
            case 330: template.handles.insert(try reader.valueAsHandle)
            default:
                end = true
                continue
            }
            try reader.readNext()
        }
        return template
    }

    private func readPolylineBoundary() throws -> ACad.Hatch.BoundaryPath.Edge? {
        try reader.readNext()
        guard reader.code == 72 else {
            builder.notify("Polyline Boundary path should start with code 72 but was \(reader.code)")
            return nil
        }
        var vertices: [XYZ] = []
        var isClosed = false
        var hasBulge = false
        var end = false
        while !end {
            switch reader.code {
            case 72: hasBulge = try reader.valueAsBool
            case 73: isClosed = try reader.valueAsBool
            case 93:
                let n = Int(try reader.valueAsInt)
                try reader.readNext()
                for _ in 0..<max(0, n) {
                    let x = try reader.valueAsDouble
                    try reader.readNext()
                    let y = try reader.valueAsDouble
                    try reader.readNext()
                    var bulge = 0.0
                    if hasBulge {
                        bulge = try reader.valueAsDouble
                        try reader.readNext()
                    }
                    vertices.append(XYZ(x, y, bulge))
                }
                continue
            default:
                end = true
                continue
            }
            try reader.readNext()
        }
        return .polyline(vertices: vertices, isClosed: isClosed, hasBulge: hasBulge)
    }

    private func readEdge() throws -> ACad.Hatch.BoundaryPath.Edge? {
        guard reader.code == 72 else {
            builder.notify("Edge Boundary path should define the type with code 72 but was \(reader.code)")
            return nil
        }
        let type = try reader.valueAsInt
        try reader.readNext()
        switch type {
        case 1:
            var start = XY.zero, end = XY.zero
            while true {
                switch reader.code {
                case 10: start.x = try reader.valueAsDouble
                case 20: start.y = try reader.valueAsDouble
                case 11: end.x = try reader.valueAsDouble
                case 21: end.y = try reader.valueAsDouble
                default: return .line(start: start, end: end)
                }
                try reader.readNext()
            }
        case 2:
            var center = XY.zero, radius = 0.0, startAngle = 0.0, endAngle = 0.0, ccw = false
            while true {
                switch reader.code {
                case 10: center.x = try reader.valueAsDouble
                case 20: center.y = try reader.valueAsDouble
                case 40: radius = try reader.valueAsDouble
                case 50: startAngle = ACad.MathHelper.degToRad(try reader.valueAsDouble)
                case 51: endAngle = ACad.MathHelper.degToRad(try reader.valueAsDouble)
                case 73: ccw = try reader.valueAsBool
                default: return .arc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, counterClockWise: ccw)
                }
                try reader.readNext()
            }
        case 3:
            var center = XY.zero, major = XY.zero, ratio = 0.0, startAngle = 0.0, endAngle = 0.0, ccw = false
            while true {
                switch reader.code {
                case 10: center.x = try reader.valueAsDouble
                case 20: center.y = try reader.valueAsDouble
                case 11: major.x = try reader.valueAsDouble
                case 21: major.y = try reader.valueAsDouble
                case 40: ratio = try reader.valueAsDouble
                case 50: startAngle = ACad.MathHelper.degToRad(try reader.valueAsDouble)
                case 51: endAngle = ACad.MathHelper.degToRad(try reader.valueAsDouble)
                case 73: ccw = try reader.valueAsBool
                default:
                    return .ellipse(center: center, majorAxisEndPoint: major, radiusRatio: ratio, startAngle: startAngle,
                                    endAngle: endAngle, counterClockWise: ccw)
                }
                try reader.readNext()
            }
        case 4:
            var spline = ACad.Hatch.BoundaryPath.Spline()
            var controlPoint = XYZ.zero
            var fitPoint = XY.zero
            while true {
                switch reader.code {
                case 10: controlPoint = XYZ(try reader.valueAsDouble, 0, 1)
                case 20:
                    controlPoint = XYZ(controlPoint.x, try reader.valueAsDouble, controlPoint.z)
                    spline.controlPoints.append(controlPoint)
                case 11: fitPoint = XY(try reader.valueAsDouble, 0)
                case 21:
                    fitPoint = XY(fitPoint.x, try reader.valueAsDouble)
                    spline.fitPoints.append(fitPoint)
                case 42:
                    if !spline.controlPoints.isEmpty { spline.controlPoints[spline.controlPoints.count - 1].z = try reader.valueAsDouble }
                case 12: spline.startTangent.x = try reader.valueAsDouble
                case 22: spline.startTangent.y = try reader.valueAsDouble
                case 13: spline.endTangent.x = try reader.valueAsDouble
                case 23: spline.endTangent.y = try reader.valueAsDouble
                case 94: spline.degree = try reader.valueAsInt
                case 73: spline.isRational = try reader.valueAsBool
                case 74: spline.isPeriodic = try reader.valueAsBool
                case 95, 96, 97: break
                case 40: spline.knots.append(try reader.valueAsDouble)
                default: return .spline(spline)
                }
                try reader.readNext()
            }
        default:
            return nil
        }
    }

    // ───────────────────────── Dimensions ─────────────────────────

    private func readDimension(_ t: ACad.CadDimensionTemplate) throws -> Bool {
        switch reader.code {
        case 2:
            t.blockName = reader.valueAsString
            return true
        case 3:
            t.styleName = reader.valueAsString
            return true
        case 50:
            if !(t.cadObject is ACad.DimensionLinear) || t.isPlaceholder { t.setDimension(ACad.DimensionLinear()) }
            (t.cadObject as! ACad.DimensionLinear).rotation = try reader.valueAsAngle
            return true
        case 70 where t.cadObject is ACad.DimensionArc && currentSubclass == ACad.DxfSubclassMarker.arcDimension:
            (t.cadObject as! ACad.DimensionArc).isPartial = try reader.valueAsBool
            return true
        case 70:
            t.dimension.flags = try reader.valueAsShort
            if t.isPlaceholder, builder.version < .ac1012 {
                // The whole flags value is matched: R12 dimensions with other bits set stay placeholders and are
                // discarded. The current subclass stays AcDbDimension, so the type's own codes are not read.
                switch t.dimension.flags {
                case ACad.DimensionType.linear: t.setDimension(ACad.DimensionLinear())
                case ACad.DimensionType.aligned: t.setDimension(ACad.DimensionAligned())
                case ACad.DimensionType.angular: t.setDimension(ACad.DimensionAngular2Line())
                case ACad.DimensionType.diameter: t.setDimension(ACad.DimensionDiameter())
                case ACad.DimensionType.radius: t.setDimension(ACad.DimensionRadius())
                case ACad.DimensionType.angular3Point: t.setDimension(ACad.DimensionAngular3Pt())
                case ACad.DimensionType.ordinate, ACad.DimensionType.ordinateTypeX,
                     ACad.DimensionType.ordinate | ACad.DimensionType.ordinateTypeX:
                    t.setDimension(ACad.DimensionOrdinate())
                default: break
                }
            }
            return true
        // Measurement (read only) and undocumented codes; ACadSharp 3.8 also skips the arrow flips (74, 75).
        case 42, 73, 74, 75, 90, 361:
            return true
        case 100:
            currentSubclass = reader.valueAsString
            switch reader.valueAsString {
            case ACad.DxfSubclassMarker.dimension: return true
            case ACad.DxfSubclassMarker.alignedDimension: t.setDimension(ACad.DimensionAligned())
            case ACad.DxfSubclassMarker.diametricDimension: t.setDimension(ACad.DimensionDiameter())
            case ACad.DxfSubclassMarker.angular2LineDimension: t.setDimension(ACad.DimensionAngular2Line())
            case ACad.DxfSubclassMarker.angular3PointDimension: t.setDimension(ACad.DimensionAngular3Pt())
            case ACad.DxfSubclassMarker.arcDimension: t.setDimension(ACad.DimensionArc())
            case ACad.DxfSubclassMarker.radialDimension: t.setDimension(ACad.DimensionRadius())
            case ACad.DxfSubclassMarker.ordinateDimension: t.setDimension(ACad.DimensionOrdinate())
            case ACad.DxfSubclassMarker.linearDimension: t.setDimension(ACad.DimensionLinear())
            default: return false
            }
            return true
        default:
            // Pre R13 files have no subclass markers (the placeholder's marker is AcDbDimension).
            if currentSubclass.isEmpty {
                currentSubclass = t.isPlaceholder ? ACad.DxfSubclassMarker.dimension : t.cadObject.subclassMarker
            }
            return mapped({ try assignDimension(t.dimension, subclass: currentSubclass) })
        }
    }

    /// The dimension maps by subclass (`tryAssignCurrentValue(map)` with the current subclass).
    private func assignDimension(_ d: ACad.Dimension, subclass: String) throws -> Bool {
        let r = reader!
        let i = axis(r.code)
        switch subclass {
        case ACad.DxfSubclassMarker.dimension:
            switch r.code {
            case 71: d.attachmentPoint = try r.valueAsShort
            case 10, 20, 30: d.definitionPoint[i] = try r.valueAsDouble
            case 74: d.flipArrow1 = try r.valueAsBool
            case 75: d.flipArrow2 = try r.valueAsBool
            case 51: d.horizontalDirection = try r.valueAsAngle
            case 12, 22, 32: d.insertionPoint[i] = try r.valueAsDouble
            case 41: d.lineSpacingFactor = try r.valueAsDouble
            case 72: d.lineSpacingStyle = try r.valueAsShort
            case 210, 220, 230: d.normal[i] = try r.valueAsDouble
            case 1: d.text = rawString
            case 11, 21, 31: d.textMiddlePoint[i] = try r.valueAsDouble
            case 53: d.textRotation = try r.valueAsAngle
            case 280: d.version = UInt8(try r.value.integer(0...255))
            case 70: d.flags = try r.valueAsShort
            default: return false
            }
        case ACad.DxfSubclassMarker.alignedDimension:
            guard let a = d as? ACad.DimensionAligned else { return false }
            switch r.code {
            case 52: a.extLineRotation = try r.valueAsDouble
            case 13, 23, 33: a.firstPoint[i] = try r.valueAsDouble
            case 14, 24, 34: a.secondPoint[i] = try r.valueAsDouble
            default: return false
            }
        case ACad.DxfSubclassMarker.linearDimension:
            guard let l = d as? ACad.DimensionLinear, r.code == 50 else { return false }
            l.rotation = try r.valueAsAngle
        case ACad.DxfSubclassMarker.angular2LineDimension:
            guard let a = d as? ACad.DimensionAngular2Line else { return false }
            switch r.code {
            case 15, 25, 35: a.angleVertex[i] = try r.valueAsDouble
            case 16, 26, 36: a.dimensionArc[i] = try r.valueAsDouble
            case 13, 23, 33: a.firstPoint[i] = try r.valueAsDouble
            case 14, 24, 34: a.secondPoint[i] = try r.valueAsDouble
            default: return false
            }
        case ACad.DxfSubclassMarker.angular3PointDimension:
            guard let a = d as? ACad.DimensionAngular3Pt else { return false }
            switch r.code {
            case 15, 25, 35: a.angleVertex[i] = try r.valueAsDouble
            case 13, 23, 33: a.firstPoint[i] = try r.valueAsDouble
            case 14, 24, 34: a.secondPoint[i] = try r.valueAsDouble
            default: return false
            }
        case ACad.DxfSubclassMarker.arcDimension:
            guard let a = d as? ACad.DimensionArc else { return false }
            switch r.code {
            case 15, 25, 35: a.center[i] = try r.valueAsDouble
            case 41: a.endAngle = try r.valueAsDouble
            case 13, 23, 33: a.firstPoint[i] = try r.valueAsDouble
            case 71: a.hasLeader = try r.valueAsBool
            case 70: a.isPartial = try r.valueAsBool
            case 16, 26, 36: a.leaderPoint1[i] = try r.valueAsDouble
            case 17, 27, 37: a.leaderPoint2[i] = try r.valueAsDouble
            case 14, 24, 34: a.secondPoint[i] = try r.valueAsDouble
            case 40: a.startAngle = try r.valueAsDouble
            default: return false
            }
        case ACad.DxfSubclassMarker.diametricDimension:
            guard let a = d as? ACad.DimensionDiameter else { return false }
            switch r.code {
            case 15, 25, 35: a.angleVertex[i] = try r.valueAsDouble
            case 40: a.leaderLength = try r.valueAsDouble
            default: return false
            }
        case ACad.DxfSubclassMarker.radialDimension:
            guard let a = d as? ACad.DimensionRadius else { return false }
            switch r.code {
            case 15, 25, 35: a.angleVertex[i] = try r.valueAsDouble
            case 40: a.leaderLength = try r.valueAsDouble
            default: return false
            }
        case ACad.DxfSubclassMarker.ordinateDimension:
            guard let a = d as? ACad.DimensionOrdinate else { return false }
            switch r.code {
            case 13, 23, 33: a.featureLocation[i] = try r.valueAsDouble
            case 14, 24, 34: a.leaderEndpoint[i] = try r.valueAsDouble
            default: return false
            }
        default:
            return false
        }
        return true
    }

    // ───────────────────────── Leaders ─────────────────────────

    private func readLeader(_ t: ACad.CadLeaderTemplate) throws -> Bool {
        let leader = t.cadObject as! ACad.Leader
        switch reader.code {
        case 3: t.dimStyleName = reader.valueAsString
        case 10: leader.vertices.append(XYZ(try reader.valueAsDouble, 0, 0))
        case 20: if !leader.vertices.isEmpty { leader.vertices[leader.vertices.count - 1].y = try reader.valueAsDouble }
        case 30: if !leader.vertices.isEmpty { leader.vertices[leader.vertices.count - 1].z = try reader.valueAsDouble }
        case 340: t.annotationHandle = try reader.valueAsHandle
        case 75, 76: break
        default:
            return mapped {
                switch reader.code {
                case 213, 223, 233: leader.annotationOffset[axis(reader.code)] = try reader.valueAsDouble
                case 71: leader.arrowHeadEnabled = try reader.valueAsBool
                case 212, 222, 232: leader.blockOffset[axis(reader.code)] = try reader.valueAsDouble
                case 73: leader.creationType = try reader.valueAsShort
                case 74: leader.hookLineDirection = try reader.valueAsShort
                case 211, 221, 231: leader.horizontalDirection[axis(reader.code)] = try reader.valueAsDouble
                case 210, 220, 230: leader.normal[axis(reader.code)] = try reader.valueAsDouble
                case 72: leader.pathType = try reader.valueAsShort
                case 40: leader.textHeight = try reader.valueAsDouble
                case 41: leader.textWidth = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
        return true
    }

    private func readMLine(_ t: ACad.CadMLineTemplate) throws -> Bool {
        let mline = t.cadObject as! ACad.MLine
        switch reader.code {
        case 2: t.mlineStyleName = reader.valueAsString
        case 72: t.nVertex = try reader.valueAsInt
        case 73: t.nElements = try reader.valueAsInt
        case 340: t.mlineStyleHandle = try reader.valueAsHandle
        case 74: t.newSegment()
        case 75: break
        case 11, 21, 31, 12, 22, 32, 13, 23, 33, 41, 42:
            if t.tryReadVertex(reader.code, try reader.valueAsDouble) { return true }
            return false
        default:
            return mapped {
                switch reader.code {
                case 71: mline.flags = try reader.valueAsShort
                case 70: mline.justification = try reader.valueAsShort
                case 210, 220, 230: mline.normal[axis(reader.code)] = try reader.valueAsDouble
                case 40: mline.scaleFactor = try reader.valueAsDouble
                case 10, 20, 30: mline.startPoint[axis(reader.code)] = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
        return true
    }

    private func readMLeader(_ t: ACad.CadMLeaderTemplate) throws -> Bool {
        let leader = t.cadObject as! ACad.MultiLeader
        let r = reader!
        switch r.code {
        case 270: leader.version = try r.valueAsShort
        case 300: try readMultiLeaderObjectContextData(t)
        case 340: t.leaderStyleHandle = try r.valueAsHandle
        case 341: t.leaderLineTypeHandle = try r.valueAsHandle
        case 343: t.mtextStyleHandle = try r.valueAsHandle
        default:
            return mapped {
                switch r.code {
                case 42: leader.arrowheadSize = try r.valueAsDouble
                // ACadSharp's map has no conversion for colours under 91 / 92 / 93: they stay unset.
                case 93: _ = try r.valueAsInt
                case 176: leader.blockContentConnection = try r.valueAsShort
                case 43: leader.blockContentRotation = try r.valueAsAngle
                case 10, 20, 30: leader.blockContentScale[axis(r.code)] = try r.valueAsDouble
                case 172: leader.contentType = try r.valueAsShort
                case 293: leader.enableAnnotationScale = try r.valueAsBool
                case 291: leader.enableDogleg = try r.valueAsBool
                case 290: leader.enableLanding = try r.valueAsBool
                case 295: leader.extendedToText = try r.valueAsBool
                case 41: leader.landingDistance = try r.valueAsDouble
                case 171: leader.leaderLineWeight = ACad.LineWeight(try r.valueAsShort)
                case 91: _ = try r.valueAsInt
                case 170: leader.pathType = try r.valueAsShort
                case 90: leader.propertyOverrideFlags = try r.valueAsInt
                case 45: leader.scaleFactor = try r.valueAsDouble
                case 178: leader.textAligninIPE = try r.valueAsShort
                case 175: leader.textAlignment = try r.valueAsShort
                case 174: leader.textAngle = try r.valueAsShort
                case 271: leader.textAttachmentDirection = try r.valueAsShort
                case 179: leader.textAttachmentPoint = try r.valueAsShort
                case 272: leader.textBottomAttachment = try r.valueAsShort
                case 92: _ = try r.valueAsInt
                case 294: leader.textDirectionNegative = try r.valueAsBool
                case 292: leader.textFrame = try r.valueAsBool
                case 173: leader.textLeftAttachment = try r.valueAsShort
                case 95: leader.textRightAttachment = try r.valueAsShort
                case 273: leader.textTopAttachment = try r.valueAsShort
                default: return false
                }
                return true
            }
        }
        return true
    }

    private func readMultiLeaderObjectContextData(_ t: ACad.CadMLeaderTemplate) throws {
        try reader.readNext()
        let context = (t.cadObject as! ACad.MultiLeader).contextData
        let r = reader!
        while r.code != 0 {
            switch r.code {
            case 301 where r.valueAsString == "}":
                return
            case 302 where r.valueAsString == "LEADER{":
                context.leaderRoots.append(try readMultiLeaderLeader(t))
            case 340:
                t.contextTextStyleHandle = try r.valueAsHandle
            case 341:
                t.contextBlockRecordHandle = try r.valueAsHandle
            default:
                if !mapped({ try assignContextData(context) }) {
                    builder.notify("[AcDbMLeaderObjectContextData] Unhandled dxf code \(r.code) with value \(r.valueAsString)")
                }
            }
            try r.readNext()
        }
    }

    /// The `MultiLeaderObjectContextData` map.
    private func assignContextData(_ c: ACad.MultiLeaderObjectContextData) throws -> Bool {
        let r = reader!
        let i = axis(r.code)
        switch r.code {
        case 140: c.arrowheadSize = try r.valueAsDouble
        case 91: _ = try r.valueAsInt // no colour conversion for 91 in ACadSharp's map
        case 291: c.backgroundFillEnabled = try r.valueAsBool
        case 292: c.backgroundMaskFillOn = try r.valueAsBool
        case 141: c.backgroundScaleFactor = try r.valueAsDouble
        case 92: c.backgroundTransparency = try r.valueAsInt
        case 111, 121, 131: c.baseDirection[i] = try r.valueAsDouble
        case 110, 120, 130: c.basePoint[i] = try r.valueAsDouble
        case 112, 122, 132: c.baseVertical[i] = try r.valueAsDouble
        case 177: c.blockContentConnection = try r.valueAsShort
        case 15, 25, 35: c.blockContentLocation[i] = try r.valueAsDouble
        case 14, 24, 34: c.blockContentNormal[i] = try r.valueAsDouble
        case 46: c.blockContentRotation = try r.valueAsAngle
        case 16, 26, 36: c.blockContentScale[i] = try r.valueAsDouble
        case 44: c.boundaryHeight = try r.valueAsDouble
        case 43: c.boundaryWidth = try r.valueAsDouble
        case 294: c.columnFlowReversed = try r.valueAsBool
        case 143: c.columnGutter = try r.valueAsDouble
        case 144: c.columnSizes = [try r.valueAsDouble]
        case 173: c.columnType = try r.valueAsShort
        case 142: c.columnWidth = try r.valueAsDouble
        case 10, 20, 30: c.contentBasePoint[i] = try r.valueAsDouble
        case 13, 23, 33: c.direction[i] = try r.valueAsDouble
        case 172: c.flowDirection = try r.valueAsShort
        case 296: c.hasContentsBlock = try r.valueAsBool
        case 290: c.hasTextContents = try r.valueAsBool
        case 145: c.landingGap = try r.valueAsDouble
        case 170: c.lineSpacing = try r.valueAsShort
        case 45: c.lineSpacingFactor = try r.valueAsDouble
        case 297: c.normalReversed = try r.valueAsBool
        case 40: c.scaleFactor = try r.valueAsDouble
        case 176: c.textAlignment = try r.valueAsShort
        case 171: c.textAttachmentPoint = try r.valueAsShort
        case 272: c.textBottomAttachment = try r.valueAsShort
        case 90: c.textColor = ACad.Color.fromRgb24(try r.valueAsInt) // 90 is converted as a true colour
        case 41: c.textHeight = try r.valueAsDouble
        case 293: c.textHeightAutomatic = try r.valueAsBool
        case 304: c.textLabel = rawString
        case 174: c.textLeftAttachment = try r.valueAsShort
        case 12, 22, 32: c.textLocation[i] = try r.valueAsDouble
        case 11, 21, 31: c.textNormal[i] = try r.valueAsDouble
        case 175: c.textRightAttachment = try r.valueAsShort
        case 42: c.textRotation = try r.valueAsAngle
        case 273: c.textTopAttachment = try r.valueAsShort
        case 295: c.wordBreak = try r.valueAsBool
        default: return false
        }
        return true
    }

    private func readMultiLeaderLeader(_ t: ACad.CadMLeaderTemplate) throws -> ACad.MultiLeaderObjectContextData.LeaderRoot {
        let root = ACad.MultiLeaderObjectContextData.LeaderRoot()
        try reader.readNext()
        let r = reader!
        while r.code != 0 {
            switch r.code {
            case 303 where r.valueAsString == "}":
                return root
            case 304 where r.valueAsString == "LEADER_LINE{":
                let lineTemplate = ACad.CadMLeaderTemplate.LeaderLineTemplate()
                t.leaderLineTemplates.append(lineTemplate)
                root.lines.append(try readMultiLeaderLine(lineTemplate))
            default:
                let ok = mapped {
                    switch r.code {
                    case 10, 20, 30: root.connectionPoint[axis(r.code)] = try r.valueAsDouble
                    case 290: root.contentValid = try r.valueAsBool
                    case 11, 21, 31: root.direction[axis(r.code)] = try r.valueAsDouble
                    case 40: root.landingDistance = try r.valueAsDouble
                    case 90: root.leaderIndex = try r.valueAsInt
                    case 271: root.textAttachmentDirection = try r.valueAsShort
                    case 291: root.unknown = try r.valueAsBool
                    default: return false
                    }
                    return true
                }
                if !ok { builder.notify("[LeaderRoot] Unhandled dxf code \(r.code) with value \(r.valueAsString)") }
            }
            try r.readNext()
        }
        return root
    }

    private func readMultiLeaderLine(_ t: ACad.CadMLeaderTemplate.LeaderLineTemplate) throws -> ACad.MultiLeaderObjectContextData.LeaderLine {
        let line = t.leaderLine
        try reader.readNext()
        let r = reader!
        while r.code != 0 {
            switch r.code {
            case 10: line.points.append(XYZ(try r.valueAsDouble, 0, 0))
            case 20: if !line.points.isEmpty { line.points[line.points.count - 1].y = try r.valueAsDouble }
            case 30: if !line.points.isEmpty { line.points[line.points.count - 1].z = try r.valueAsDouble }
            case 305 where r.valueAsString == "}":
                return line
            default:
                let ok = mapped {
                    switch r.code {
                    case 341: t.arrowSymbolHandle = try r.valueAsHandle
                    case 40: line.arrowheadSize = try r.valueAsDouble
                    case 91: line.index = try r.valueAsInt
                    case 92: _ = try r.valueAsInt // not converted by ACadSharp's map
                    case 171: line.lineWeight = ACad.LineWeight(try r.valueAsShort)
                    case 93: line.overrideFlags = try r.valueAsInt
                    case 170: line.pathType = try r.valueAsShort
                    default: return false
                    }
                    return true
                }
                if !ok { builder.notify("[LeaderLine] Unhandled dxf code \(r.code) with value \(r.valueAsString)") }
            }
            try r.readNext()
        }
        return line
    }

    // ───────────────────────── Images, underlays, OLE, proxies, solids ─────────────────────────

    private func readWipeoutBase(_ t: ACad.CadWipeoutBaseTemplate) throws -> Bool {
        let w = t.cadObject as! ACad.CadWipeoutBase
        switch reader.code {
        case 71:
            return true
        case 91:
            let n = Int(try reader.valueAsInt)
            for _ in 0..<max(0, n) {
                try reader.readNext()
                let x = try reader.valueAsDouble
                try reader.readNext()
                w.clipBoundaryVertices.append(XY(x, try reader.valueAsDouble))
            }
            try reader.readNext()
            return reader.code == 0 ? true : try readWipeoutBase(t)
        case 340:
            t.imgDefHandle = try reader.valueAsHandle
            return true
        case 360:
            t.imgReactorHandle = try reader.valueAsHandle
            return true
        default:
            return mapped {
                switch reader.code {
                case 90: w.classVersion = try reader.valueAsInt
                case 290: w.clipMode = try reader.valueAsBool ? 1 : 0
                case 280: w.clippingState = try reader.valueAsBool
                case 70: w.flags = try reader.valueAsShort
                case 10, 20, 30: w.insertPoint[axis(reader.code)] = try reader.valueAsDouble
                case 13, 23: w.size[axis(reader.code)] = try reader.valueAsDouble
                case 11, 21, 31: w.uVector[axis(reader.code)] = try reader.valueAsDouble
                case 12, 22, 32: w.vVector[axis(reader.code)] = try reader.valueAsDouble
                case 281, 282, 283:
                    let value = UInt8(try reader.value.integer(0...255))
                    guard value <= 100 else { throw ACad.DxfException("Invalid Brightness value: \(value), must be in range 0-100") }
                    if reader.code == 281 { w.brightness = value } else if reader.code == 282 { w.contrast = value } else { w.fade = value }
                default: return false
                }
                return true
            }
        }
    }

    private func readUnderlay(_ t: ACad.CadUnderlayTemplate) throws -> Bool {
        let u = t.cadObject as! ACad.PdfUnderlay
        switch reader.code {
        case 340:
            t.definitionHandle = try reader.valueAsHandle
            return true
        case 11:
            u.clipBoundaryVertices.append(XY(try reader.valueAsDouble, 0))
            return true
        case 21:
            if !u.clipBoundaryVertices.isEmpty { u.clipBoundaryVertices[u.clipBoundaryVertices.count - 1].y = try reader.valueAsDouble }
            return true
        default:
            return mapped {
                switch reader.code {
                case 280: u.flags = UInt8(try reader.value.integer(0...255))
                case 10, 20, 30: u.insertPoint[axis(reader.code)] = try reader.valueAsDouble
                case 210, 220, 230: u.normal[axis(reader.code)] = try reader.valueAsDouble
                case 50: u.rotation = try reader.valueAsAngle
                case 41, 42, 43:
                    let value = try reader.valueAsDouble
                    guard value != 0 else { throw ACad.DxfException("Scale value must be none zero.") }
                    if reader.code == 41 { u.xScale = value } else if reader.code == 42 { u.yScale = value } else { u.zScale = value }
                case 281, 282:
                    let value = UInt8(try reader.value.integer(0...255))
                    guard value <= 100 else { throw ACad.DxfException("Invalid Brightness value: \(value), must be in range 0-100") }
                    if reader.code == 281 { u.contrast = value } else { u.fade = value }
                default: return false
                }
                return true
            }
        }
    }

    private func readOle2Frame(_ t: ACad.CadOle2FrameTemplate) throws -> Bool {
        let ole = t.cadObject as! ACad.Ole2Frame
        switch reader.code {
        case 1, 90, 73: return true
        case 310:
            t.chunks.append(reader.valueAsBinaryChunk ?? Data())
            return true
        default:
            return mapped {
                switch reader.code {
                case 72: ole.isPaperSpace = try reader.valueAsBool
                case 11, 21, 31: ole.lowerRightCorner[axis(reader.code)] = try reader.valueAsDouble
                case 71: ole.oleObjectType = try reader.valueAsShort
                case 3: ole.sourceApplication = rawString
                case 10, 20, 30: ole.upperLeftCorner[axis(reader.code)] = try reader.valueAsDouble
                case 70: ole.version = try reader.valueAsShort
                default: return false
                }
                return true
            }
        }
    }

    private func readProxyEntity(_ t: ACad.CadProxyEntityTemplate) throws -> Bool {
        let proxy = t.cadObject as! ACad.ProxyEntity
        switch reader.code {
        case 91:
            proxy.classNumber = Int32(try reader.valueAsShort)
            if document.classes.byClassNumber(try reader.valueAsShort) == nil {
                builder.notify("DxfClass with class number \(try reader.valueAsShort) not found.")
            }
        case 94: break
        case 160: _ = try readByteEntries(310)
        case 161: proxy.binaryData = try readByteEntries(310) ?? Data()
        case 162: proxy.data = try readByteEntries(311) ?? Data()
        case 330, 340, 350, 360: t.referencedObjectHandles.append(try reader.valueAsHandle)
        default:
            return mapped {
                switch reader.code {
                case 95: proxy.drawingFormat = try reader.valueAsInt
                case 97: proxy.maintenanceVersion = try reader.valueAsInt
                case 70: proxy.originalDataFormatDxf = try reader.valueAsBool
                case 90: proxy.proxyClassId = try reader.valueAsInt
                case 71: proxy.version = ACad.Version(rawValue: try reader.valueAsShort) ?? .unknown
                default: return false
                }
                return true
            }
        }
        return true
    }

    private func readByteEntries(_ code: Int) throws -> Data? {
        if try reader.valueAsInt == 0 { return nil }
        var data = Data()
        try reader.expectedCode(code)
        while reader.code == code {
            data.append(reader.valueAsBinaryChunk ?? Data())
            try reader.readNext()
        }
        lockPointer = true
        return data
    }

    private func readModelerGeometry(_ t: ACad.CadModelerGeometryTemplate) throws -> Bool {
        let geometry = t.cadObject as! ACad.ModelerGeometry
        switch reader.code {
        case 1:
            t.appendAcisLine(reader.valueAsString)
            geometry.proprietaryData += reader.valueAsString + "\n"
        case 3:
            t.appendAcisContinuation(reader.valueAsString)
            geometry.proprietaryData += reader.valueAsString + "\n"
        case 2, 290: break
        case 70:
            return mapped { geometry.modelerFormatVersion = try reader.valueAsShort; return true }
        default:
            return false
        }
        return true
    }

    private func readViewport(_ t: ACad.CadViewportTemplate) throws -> Bool {
        let v = t.cadObject as! ACad.Viewport
        let r = reader!
        switch r.code {
        case 67, 68: return true
        case 69:
            t.viewportId = try r.valueAsShort
            return true
        case 331:
            t.frozenLayerHandles.insert(try r.valueAsHandle)
            return true
        case 348:
            t.visualStyleHandle = try r.valueAsHandle
            return true
        case 340:
            t.boundaryHandle = try r.valueAsHandle
            return true
        default:
            return mapped {
                let i = axis(r.code)
                switch r.code {
                // [DxfCodeValue(63, 421, 431)]: consumed unset, as the map's Color setter only handles 62 / 420.
                case 63, 421, 431: break
                case 44: v.backClipPlane = try r.valueAsDouble
                case 141: v.brightness = try r.valueAsDouble
                case 10, 20, 30: v.center[i] = try r.valueAsDouble
                case 72: v.circleZoomPercent = try r.valueAsShort
                case 142: v.contrast = try r.valueAsDouble
                case 282: v.defaultLightingType = UInt8(try r.value.integer(0...255))
                case 74: v.displayUcsIcon = try r.valueAsBool
                case 146: v.elevation = try r.valueAsDouble
                case 43: v.frontClipPlane = try r.valueAsDouble
                case 15, 25: v.gridSpacing[i] = try r.valueAsDouble
                case 41: v.height = try r.valueAsDouble
                case 42: v.lensLength = try r.valueAsDouble
                case 61: v.majorGridLineFrequency = try r.valueAsShort
                case 281: v.renderMode = UInt8(truncatingIfNeeded: try r.valueAsShort)
                case 170: v.shadePlotMode = try r.valueAsShort
                case 50: v.snapAngle = try r.valueAsAngle
                case 13, 23: v.snapBase[i] = try r.valueAsDouble
                case 14, 24: v.snapSpacing[i] = try r.valueAsDouble
                case 90: v.status = try r.valueAsInt
                case 1: v.styleSheetName = rawString
                case 51: v.twistAngle = try r.valueAsAngle
                case 110, 120, 130: v.ucsOrigin[i] = try r.valueAsDouble
                case 79: v.ucsOrthographicType = try r.valueAsShort
                case 71: v.ucsPerViewport = try r.valueAsBool
                case 111, 121, 131: v.ucsXAxis[i] = try r.valueAsDouble
                case 112, 122, 132: v.ucsYAxis[i] = try r.valueAsDouble
                case 292: v.useDefaultLighting = try r.valueAsBool
                case 12, 22: v.viewCenter[i] = try r.valueAsDouble
                case 16, 26, 36: v.viewDirection[i] = try r.valueAsDouble
                case 45: v.viewHeight = try r.valueAsDouble
                case 17, 27, 37: v.viewTarget[i] = try r.valueAsDouble
                case 40: v.width = try r.valueAsDouble
                default: return false
                }
                return true
            }
        }
    }
}

extension ACad {
    /// `HatchPattern.Update`.
    enum HatchPatternUpdate {
        static func update(_ pattern: HatchPattern, translation: XY, rotation: Double, scale: Double) {
            let (s, c) = (sin(rotation), cos(rotation))
            func transform(_ p: XY) -> XY {
                // Translation · Scale · Rotation applied to a point: rotate, scale, then translate.
                let r = XY(p.x * c - p.y * s, p.x * s + p.y * c)
                return XY(r.x * scale + translation.x, r.y * scale + translation.y)
            }
            for line in pattern.lines {
                line.angle += rotation
                line.basePoint = transform(line.basePoint)
                line.offset = transform(line.offset)
                line.dashLengths = line.dashLengths.map { $0 * scale }
            }
        }
    }
}
